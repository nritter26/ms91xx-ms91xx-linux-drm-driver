# display — MS91xx / MS912C USB display driver (repo root)

Linux DRM driver for **MacroSilicon MS9132 / MS9133 / MS9135** USB display chips
(`lsusb`: `345f:9132` / `345f:9133` / `345f:9135`) and the **MS912C** VGA family
(`534d:6021`). These chips power brandless portable USB monitors, dual/tri-screen
laptop extenders and USB 3.0 → HDMI/VGA adapters.

This repository holds the driver plus one self-contained, distro-tailored port per
supported distribution. **Every distro folder has its own `README.md`** with that
target's install steps, verification commands and troubleshooting — this file only
explains the layout, where the code came from, and how to report problems.

## Layout

```
display/
├── README.md              ← you are here: repo layout, credits, how to report problems
├── LICENSE                ← GPL-2.0, applies to every folder in the repo
│
├── disp-arch/           ← port: Arch Linux / Manjaro   (pacman, mkinitcpio)     → README.md
├── disp-debian/         ← port: Debian 12 / 13         (apt, update-initramfs)  → README.md
├── disp-fedora/         ← port: Fedora 41 / 42         (dnf, dracut)            → README.md
├── disp-mint/           ← port: Linux Mint 21.3 / 22.x (apt, update-initramfs)  → README.md
└── disp-ubuntu/         ← port: Ubuntu 24.04 / 26.04   (apt, update-initramfs)  → README.md
```

### What a distro folder contains

Each `disp-<distro>/` is a complete, standalone copy of the driver:

```
disp-<distro>/
├── README.md          ← install/verify/troubleshooting for that distro
├── LICENSE            ← GPL-2.0
├── dkms.conf          ← DKMS package definition: msdisp 3.1.6
├── dkms-install.sh    ← the only file that differs between distros
├── dkms-remove.sh     ← uninstaller
├── drm/               ← DRM/KMS side: builds usbdisp_drm.ko
├── usb_hal/           ← USB transport + chip protocol: builds usbdisp_usb.ko
├── docs/              ← MS912C-VGA notes (VGA dongles, sysfs xdata debugging)
├── tests/             ← damage-bounds regression test (no hardware or kernel headers needed)
├── Makefile, insmod.sh, build_driver.txt
└── *.zip              ← MacroSilicon's pristine vendor source, kept for provenance
```

The driver code (`drm/`, `usb_hal/`, `docs/`, `tests/`, `dkms.conf`,
`dkms-remove.sh`) is **byte-identical across all five folders**; only
`dkms-install.sh` is distro-specific, because dependency handling, kernel headers,
initramfs regeneration and Secure Boot enrollment all differ:

| Folder | Package manager | Kernel headers | Initramfs | Secure Boot enrollment |
|---|---|---|---|---|
| `disp-arch/` | `pacman` | `linux-headers` (per kernel flavour) | `mkinitcpio -P` | `mokutil --import /var/lib/dkms/mok.pub` or `sbctl` |
| `disp-debian/` | `apt-get` | `linux-headers-<ver>` | `update-initramfs -u -k` | `update-secureboot-policy --enroll-key` |
| `disp-fedora/` | `dnf` | `kernel-devel-<ver>` | `dracut -f --kver` | `mokutil --import /var/lib/dkms/mok.pub` |
| `disp-mint/` | `apt-get` | `linux-headers-<ver>` → `linux-headers-generic` | `update-initramfs -u -k` | `mokutil --import /var/lib/dkms/mok.pub` |
| `disp-ubuntu/` | `apt-get` | `linux-headers-<ver>` → `linux-headers-generic` | `update-initramfs -u -k` | `mokutil --import /var/lib/dkms/mok.pub` |

All of them install the same two modules — `usbdisp_drm` and `usbdisp_usb` — from
the DKMS package `msdisp` 3.1.6, staged into `/usr/src/disp-3.1.6`.

## Quick start

```sh
cd disp-arch          # or disp-debian, disp-fedora, disp-mint, disp-ubuntu
sudo ./dkms-install.sh
```

Then plug the monitor in. See that folder's `README.md` for verification, module
options (`port_type`, `custom_mode`, `hw_cursor`, `idle_refresh_ms`) and the
Secure Boot step.

## Reporting problems / contributing

**If the installer fails or the display does not come up, please open a pull
request** with your logs — reports and fixes both land there, and that is how a port
improves. Include:

```sh
uname -r
head -3 /etc/os-release
lsusb -t | grep -E '345f|534d'                 # device + negotiated USB speed
lsmod | grep usbdisp                           # modules loaded?
dmesg | grep -iE 'usbdisp|chip id|video port'  # driver messages
```

plus the installer output and your desktop/compositor (GNOME, KDE, X11, …). Send a
packaging fix against the folder for your distro; send a driver fix to all folders
so no port is left behind.

Two quick things worth knowing before reporting: a ~10–12 fps ceiling on USB 2.0 is
expected (a full 1080p frame is ~4.15 MB, USB 2.0 manages ~40–50 MB/s — use a USB 3
port and cable), and never `rmmod usbdisp_drm` (the vendor teardown path oopses the
kernel; reboot instead).

## Credits & provenance

This repository is a fork and is **not** a clean-room implementation. The work it
stands on:

| Project | What it provides |
|---|---|
| **[bambinounos/ms91xx-linux-drm](https://github.com/bambinounos/ms91xx-linux-drm)** | **The upstream repository this repo is forked from.** It takes MacroSilicon's official GPL-2.0 source and makes it build and run on modern kernels (6.8 → 7.0+), packages it for DKMS, and adds the fixes for Wayland multi-monitor freezes, cursor handling, damage tracking, frame transfer reliability, teardown leaks and AMD GPU hosts. |
| **MacroSilicon Technology Co., Ltd.** | The original driver, licensed GPL-2.0, obtained from their public download server (`MS91xx_Linux_Drm_SourceCode_V3.0.3.13.zip`, 2025-07-10). The pristine archive is kept in every distro folder; the chip protocol and init sequences are the manufacturer's code. |
| **[rhgndf/ms912x](https://github.com/rhgndf/ms912x)** | Reverse-engineering work that kept these chips usable on Linux and whose issue tracker pointed the way to this driver. |

Changes made on top of that lineage: the kernel-space fixes are described in the
distro `README.md` compatibility notes (including the 7.2 `drm_atomic_commit`
rename), and the distro packaging lives in each `dkms-install.sh`.

## License

GPL-2.0, same as the original MacroSilicon source. See [LICENSE](LICENSE) — it
applies to every folder in this repository. If you redistribute any of this, keep
this license and the credits above with it.
