#!/bin/bash
# msdisp DKMS installer -- Linux Mint (Ubuntu base).
#
# Installs usbdisp_drm + usbdisp_usb for the running kernel (or the kernel
# version given as the first argument) and refreshes the initramfs.
#
#   sudo ./dkms-install.sh
#   sudo ./dkms-install.sh 6.8.0-45-generic
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

echo "=== Installing msdisp driver version $VERSION for kernel $KVER (Linux Mint) ==="

# 0. Build dependencies and headers for the target kernel.
# Mint inherits Ubuntu's per-kernel header packages (linux-headers-<ver>), and an
# HWE kernel installed through Update Manager does not always pull its own headers
# package. Fall back to linux-headers-generic, which tracks the default kernel.
need=()
command -v dkms  >/dev/null 2>&1 || need+=(dkms)
command -v rsync >/dev/null 2>&1 || need+=(rsync)
if ! command -v gcc >/dev/null 2>&1 || ! command -v make >/dev/null 2>&1; then
    need+=(build-essential)
fi
if [ ! -d "/lib/modules/$KVER/build" ]; then
    if apt-cache show "linux-headers-$KVER" >/dev/null 2>&1; then
        need+=("linux-headers-$KVER")
    else
        need+=(linux-headers-generic)
    fi
fi

if [ ${#need[@]} -gt 0 ]; then
    echo "Installing missing packages: ${need[*]}"
    DEBIAN_FRONTEND=noninteractive apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${need[@]}"
fi

if [ ! -d "/lib/modules/$KVER/build" ]; then
    echo "Error: no kernel headers for $KVER (/lib/modules/$KVER/build is missing)."
    echo "  apt install linux-headers-$KVER"
    echo "  If $KVER is not the kernel you are running, boot it first, or pass the"
    echo "  version explicitly:  sudo ./dkms-install.sh <kernel-version>"
    exit 1
fi

# 1. Clean up any obsolete/stale versions of msdisp in DKMS
# Mint 22 ships dkms 3.0.x, which prints "msdisp/<version>, <kernel>, <arch>:
# installed", while newer dkms prints "msdisp/<version>: added" for a tree that
# was registered but never built. Splitting that on "," and "/" produced the words
# "3.1.6:" and "added", so every remove below silently failed and the leftover tree
# entry then made `dkms add` abort on each later install. Parse the version out of
# the module/ prefix instead, which covers both forms.
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

# 4b. Secure Boot. Mint follows Ubuntu here: dkms creates /var/lib/dkms/mok.key and
# signs with it, but on a Secure Boot machine the key must be enrolled once via
# mokutil, or every load fails with "Key was rejected by service".
if command -v mokutil >/dev/null 2>&1 && mokutil --sb-state 2>/dev/null | grep -qi enabled; then
    echo "Secure Boot is enabled."
    if [ -f /var/lib/dkms/mok.key ]; then
        echo "  Modules are signed with the DKMS MOK key."
        echo "  If they fail to load, enrol the key once and reboot:"
        echo "    sudo mokutil --import /var/lib/dkms/mok.pub"
    else
        echo "  No DKMS MOK key exists yet; dkms creates one during this build."
        echo "  Enrol it afterwards or the modules will not load:"
        echo "    sudo mokutil --import /var/lib/dkms/mok.pub"
    fi
fi

# 5. Rebuild initramfs so early boot (initramfs-tools / hibernate resume) never
# loads a cached older usbdisp_drm.ko from /boot/initrd.img-$KVER
if command -v update-initramfs >/dev/null 2>&1; then
    echo "Updating initramfs for kernel $KVER (update-initramfs)..."
    update-initramfs -u -k "$KVER" || echo "Warning: update-initramfs returned non-zero, continuing..."
elif command -v dracut >/dev/null 2>&1; then
    echo "Updating initramfs for kernel $KVER (dracut)..."
    dracut -f --kver "$KVER" || echo "Warning: dracut returned non-zero, continuing..."
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
