#!/bin/bash
# msdisp DKMS installer -- Fedora.
#
# Installs usbdisp_drm + usbdisp_usb for the running kernel (or the kernel
# version given as the first argument) and rebuilds the initramfs with dracut.
#
#   sudo ./dkms-install.sh
#   sudo ./dkms-install.sh 6.15.4-200.fc42.x86_64
set -e

if [ "$EUID" -ne 0 ]; then
    echo "Error: This script must be run as root or with sudo:"
    echo "  sudo ./dkms-install.sh"
    exit 1
fi

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION=$(grep -m1 '^PACKAGE_VERSION=' "$DIR/dkms.conf" | cut -d'"' -f2)
SRC_DIR="/usr/src/msdisp-$VERSION"
KVER="${1:-$(uname -r)}"

echo "=== Installing msdisp driver version $VERSION for kernel $KVER (Fedora) ==="

# 0. Build dependencies and headers for the target kernel.
# Fedora ships kernel-devel-<ver> per kernel under /usr/src/kernels, with
# /lib/modules/<ver>/build as the symlink kbuild actually uses. Fedora keeps
# kernel-devel only for kernels it still has installed, so after an update the
# running kernel may have no headers until you boot the new one - that is the
# most common reason this build fails.
need=()
command -v dkms  >/dev/null 2>&1 || need+=(dkms)
command -v rsync >/dev/null 2>&1 || need+=(rsync)
command -v gcc   >/dev/null 2>&1 || need+=(gcc)
command -v make  >/dev/null 2>&1 || need+=(make)
[ -d "/lib/modules/$KVER/build" ] || need+=("kernel-devel-$KVER")

if [ ${#need[@]} -gt 0 ]; then
    echo "Installing missing packages: ${need[*]}"
    dnf install -y "${need[@]}"
fi

if [ ! -d "/lib/modules/$KVER/build" ]; then
    echo "Error: no kernel headers for $KVER (/lib/modules/$KVER/build is missing)."
    echo "  dnf install kernel-devel-$KVER"
    echo "  Fedora only provides kernel-devel for installed kernels: after a kernel"
    echo "  update, boot the new kernel first (or install its devel package) and retry."
    exit 1
fi

# 1. Clean up any obsolete/stale versions of msdisp in DKMS
# DKMS 3.x prints "msdisp/<version>: added" for a registered-but-never-built tree
# and "msdisp/<version>, <kernel>, <arch>: installed" once built. Splitting that
# on "," and "/" produced the words "3.1.6:" and "added", so every remove below
# silently failed and the leftover tree entry then made `dkms add` abort on each
# later install. Parse the version out of the module/ prefix instead.
while IFS= read -r v; do
    [ -n "$v" ] || continue
    echo "Purging previous msdisp version $v from DKMS..."
    dkms remove "msdisp/$v" --all 2>/dev/null || true
    if [ "$v" != "$VERSION" ]; then
        rm -rf "/usr/src/msdisp-$v"
    fi
done < <(dkms status msdisp 2>/dev/null | sed -n 's|^msdisp/\([^,: ]*\).*|\1|p' | sort -u)

# 2. Remove any orphaned/manual .ko files in /lib/modules/$KVER that could shadow DKMS
if [ -d "/lib/modules/$KVER" ]; then
    while IFS= read -r -d '' stale_ko; do
        echo "Removing stale module file: $stale_ko"
        rm -f "$stale_ko"
    done < <(find "/lib/modules/$KVER" \( -name "usbdisp_drm.ko*" -o -name "usbdisp_usb.ko*" \) -print0 2>/dev/null)
fi

# 3. Sync source tree to /usr/src/msdisp-<version>
echo "Copying source tree to $SRC_DIR..."
mkdir -p "$SRC_DIR"
rsync -a --delete --exclude .git --exclude "*.o" --exclude "*.ko" --exclude "*.mod*" --exclude "*.cmd" --exclude ".*.cmd" --exclude "Module.symvers" --exclude "modules.order" "$DIR/" "$SRC_DIR/"

# 4. Add and install into DKMS
echo "Registering msdisp/$VERSION in DKMS..."
# `dkms add` refuses a module/version that is still registered even when no kernel
# build exists for it - the state a failed build leaves behind. Clear the stale
# tree entry and register cleanly rather than aborting the install.
if ! dkms add "msdisp/$VERSION" 2>/dev/null; then
    dkms remove "msdisp/$VERSION" --all 2>/dev/null || true
    dkms add "msdisp/$VERSION"
fi

echo "Building and signing msdisp/$VERSION for $KVER..."
dkms install "msdisp/$VERSION" -k "$KVER" --force
depmod -a "$KVER"

DISK_PATH=$(modinfo -k "$KVER" -n usbdisp_drm 2>/dev/null || echo "unknown")
DISK_VER=$(modinfo -k "$KVER" -F version usbdisp_drm 2>/dev/null || echo "unknown")
echo "Resolved on-disk module: $DISK_PATH (version: $DISK_VER)"

# 4b. Secure Boot. dkms signs with /var/lib/dkms/mok.key when it exists, but on a
# Secure Boot machine that key must be enrolled in the kernel's MOK list once, or
# every load fails with "Key was rejected by service".
if command -v mokutil >/dev/null 2>&1 && mokutil --sb-state 2>/dev/null | grep -qi enabled; then
    echo "Secure Boot is enabled."
    if [ -f /var/lib/dkms/mok.key ]; then
        echo "  Modules are signed with /var/lib/dkms/mok.key."
        echo "  If loading fails with 'Key was rejected by service', enrol it once:"
        echo "    sudo mokutil --import /var/lib/dkms/mok.pub && sudo reboot"
        echo "  (in the MOK manager: Enroll MOK -> Continue -> Yes -> enter password)"
    else
        echo "  No DKMS MOK key exists yet; dkms creates one during this build."
        echo "  After it appears, enrol it or the modules will not load:"
        echo "    sudo mokutil --import /var/lib/dkms/mok.pub && sudo reboot"
    fi
fi

# 5. Rebuild the initramfs so early boot (dracut / hibernate resume) never loads a
# cached older usbdisp_drm.ko from the initramfs image for $KVER
if command -v dracut >/dev/null 2>&1; then
    echo "Updating initramfs for kernel $KVER (dracut)..."
    dracut -f --kver "$KVER" || echo "Warning: dracut returned non-zero, continuing..."
elif command -v update-initramfs >/dev/null 2>&1; then
    echo "Updating initramfs for kernel $KVER (update-initramfs)..."
    update-initramfs -u -k "$KVER" || echo "Warning: update-initramfs returned non-zero, continuing..."
elif command -v mkinitcpio >/dev/null 2>&1; then
    echo "Updating initramfs (mkinitcpio)..."
    mkinitcpio -P || echo "Warning: mkinitcpio returned non-zero, continuing..."
fi

# 6. Reload kernel modules if not pinned by DRM/fbcon/compositor
echo "Attempting live module reload..."
for dev in /sys/bus/platform/drivers/msdisp_plat/msdisp_plat.*; do
    if [ -e "$dev" ]; then
        dev_name=$(basename "$dev")
        echo "Unbinding $dev_name..."
        echo "$dev_name" > /sys/bus/platform/drivers/msdisp_plat/unbind 2>/dev/null || true
    fi
done
sleep 1

modprobe -r usbdisp_usb 2>/dev/null || true
modprobe -r usbdisp_drm 2>/dev/null || true
modprobe usbdisp_drm 2>/dev/null || true
modprobe usbdisp_usb 2>/dev/null || true

LOADED_VER=$(cat /sys/module/usbdisp_drm/version 2>/dev/null || echo "not loaded")
if [ "$LOADED_VER" = "$VERSION" ]; then
    echo "=== msdisp $VERSION successfully loaded into running kernel! ==="
elif [ "$LOADED_VER" = "not loaded" ]; then
    echo "=== msdisp $VERSION installed for kernel $KVER (module will auto-load when the USB display is plugged in, or after reboot). ==="
else
    echo ""
    echo "================================================================================"
    echo "ACTION REQUIRED: FULL REBOOT NEEDED (sudo reboot)"
    echo "  Running in RAM right now : usbdisp_drm v$LOADED_VER (pinned by DRM/fbdev/session)"
    echo "  Installed on disk/initrd : usbdisp_drm v$DISK_VER"
    echo "  Logging out is NOT enough because kernel fbdev keeps the old module pinned."
    echo "  Please run 'sudo reboot' now, then verify with:"
    echo "    cat /sys/module/usbdisp_drm/version   # must output $VERSION"
    echo "================================================================================"
fi
