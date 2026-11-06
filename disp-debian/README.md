# msdisp — MS91xx USB display driver for Debian (DKMS)

Linux DRM driver for **MacroSilicon MS9132 / MS9133 / MS9135** USB display chips
(`lsusb`: `345f:9132` / `345f:9133` / `345f:9135`) and the **MS912C** VGA family
(`534d:6021`). These chips power brandless portable USB monitors, dual/tri-screen
laptop extenders and USB 3.0 → HDMI/VGA adapters.

This folder — `disp-debian/` — is the Debian port: the driver source plus an
installer that uses `apt-get`, installs the per-kernel headers package, rebuilds the
initramfs with `update-initramfs` and points you at Debian's Secure Boot policy tool.

## Requirements

| | |
|---|---|
| Distro | Debian 12 (bookworm, 6.1) or Debian 13 (trixie, 6.12) |
| Packages | `dkms`, `build-essential`, `rsync`, `linux-headers-$(uname -r)` |
| Secure Boot | supported — modules are signed with DKMS's MOK key |
| Desktop | X11 or Wayland (GNOME/Mutter, KDE Plasma) |

Debian publishes headers **per kernel version** (`linux-headers-<version>`), so they
must match the kernel you are running. `rsync` is not part of a minimal Debian
install, but this script needs it to stage the tree in `/usr/src`. The installer adds
whatever is missing with `apt-get`.

## Install

```sh
sudo ./dkms-install.sh                        # running kernel
sudo ./dkms-install.sh 6.12.57+deb13-amd64    # or an explicit kernel version
```

The script, in order:

1. installs missing packages (`dkms`, `build-essential`, `rsync`,
   `linux-headers-<kernel>`) with `apt-get`;
2. purges stale `msdisp` versions from DKMS, including a tree left behind by a
   failed build — that entry otherwise makes `dkms add` abort on every later run;
3. deletes orphaned `usbdisp_*.ko` files in `/lib/modules` that would shadow DKMS;
4. syncs the tree to `/usr/src/msdisp-3.1.6`, registers, builds and signs it, then
   runs `depmod`;
5. rebuilds the initramfs with `update-initramfs -u -k <kernel>`;
6. attempts a live reload and tells you whether a reboot is required.

Plug the monitor in: `usbdisp_usb` auto-loads from the USB modalias and a new DRM
card appears. DKMS rebuilds the modules on every kernel upgrade.

## Verify

```sh
lsmod | grep usbdisp                    # usbdisp_drm + usbdisp_usb
cat /sys/module/usbdisp_drm/version     # 3.1.6
lsusb | grep -E '345f|534d'
lsusb -t | grep 345f                    # want 5000M/10000M, not 480M
dmesg | grep -iE 'usbdisp|chip id|video port|start video'
```

## Secure Boot

`dkms` signs with `/var/lib/dkms/mok.key`. On a Debian machine with Secure Boot
enabled, the key must be enrolled once or every load fails with *Key was rejected by
service*. Debian wraps the enrollment step:

```sh
sudo update-secureboot-policy --enroll-key
sudo reboot        # then confirm the key on the blue MOK manager screen
```

The installer prints this automatically when it detects Secure Boot enabled.

## Module options

Create `/etc/modprobe.d/usbdisp.conf`, then reboot or reload:

| Option | Module | Meaning |
|---|---|---|
| `hw_cursor=0\|1` | `usbdisp_drm` | hardware cursor plane (default `1`) |
| `port_type=<n>` | `usbdisp_usb` | override detected output: `0` CVBS, `1` S-Video, `2` VGA, `3` YPbPr, `4` CVBS+S-Video, `5` HDMI, `6` digital |
| `custom_mode=<vic>_<w>x<h>@<rate>,...` | `usbdisp_usb` | mode list used when there is no usable EDID (CEA-861 VICs only) |
| `idle_refresh_ms=<ms>` | `usbdisp_usb` | idle repaint interval (default `2500`) |

An MS912C USB→VGA dongle needs `port_type=2` **and** `custom_mode=` to produce any
picture at all — see [docs/MS912C-VGA.md](docs/MS912C-VGA.md).

## Troubleshooting

| Symptom | Fix |
|---|---|
| `no kernel headers for <ver>` | `apt install linux-headers-<ver>`. If you run a backports or custom kernel, install the headers from the same source (`-t bookworm-backports`) — mixing versions produces a build that fails or a module that will not load. |
| `DKMS tree already contains: msdisp/3.1.6` | Leftover registry entry; the current script clears it. On an older copy: `sudo dkms remove msdisp/3.1.6 --all` first. Debian's dkms 3.0.x reports `msdisp/3.1.6, <kernel>, <arch>: installed`, and the script parses that format. |
| Modules build but do not load | Secure Boot: enrol the MOK key (above). |
| Panel stays dark while frames flow | Usually VGA-vs-S-Video output selection — see [docs/MS912C-VGA.md](docs/MS912C-VGA.md). |

## Notes and limitations

- **Never `rmmod usbdisp_drm`.** The vendor teardown path has a use-after-free that
  oopses the kernel and leaves the module stuck. To reload, reboot.
- **USB 2.0 cannot carry 1080p60.** A full 1920×1080 UYVY frame is ~4.15 MB, i.e.
  ~249 MB/s at 60 Hz, while USB 2.0 usable bulk bandwidth is ~40–50 MB/s. On a
  480 Mbps link expect ~10–12 full-screen frames/s — fine for typing, laggy when
  dragging or scrolling. Use a USB 3 port and a USB 3 cable; `lsusb -t` shows the
  negotiated speed.
- Kernel coverage: the driver is tested from 6.8 through 7.0+ and guards up to 7.2
  (where the atomic update type became `struct drm_atomic_commit`; see the
  `msdisp_atomic_update` alias in `drm/msdisp_drm_modeset.c`). Debian 13's
  `6.12.x+deb13` backports the 6.13 EDID and fbdev-helper changes and the guards
  account for it. Debian 12's 6.1 is older than the tested range — the guards reach
  back to 4.19, but that combination is untested.

## Uninstall

```sh
sudo ./dkms-remove.sh
```

## Installation not working? Open a PR

If the installer fails or the panel stays dark on Debian, please **open a pull
request** with your logs instead of just giving up. Attach:

```sh
uname -r
head -3 /etc/os-release
dpkg -l dkms build-essential rsync linux-headers-"$(uname -r)" | tail -4
lsusb -t | grep -E '345f|534d'
lsmod | grep usbdisp
dmesg | grep -iE 'usbdisp|chip id|video port'
```

plus the installer output and your desktop/compositor. If you already have the fix,
send it as a PR against `disp-debian/`; if the bug is in the driver itself, it belongs
in the driver source so every build benefits.

## Build status

The driver source here is byte-identical to the canonical `ms91xx-linux-drm` tree and
builds cleanly against 6.8 → 7.2 headers; `tests/test_damage_bounds.py` passes. The
installer's dependency, headers, initramfs and Secure Boot handling is written to
Debian's layout and syntax-checked, but it has **not** been run on Debian hardware —
treat it as untested until you have run it once.

## License & provenance

GPL-2.0, same as the original MacroSilicon source — see [LICENSE](LICENSE).

Driver and packaging come from the
[bambinounos/ms91xx-linux-drm](https://github.com/bambinounos/ms91xx-linux-drm) fork
(this repository's upstream) built on MacroSilicon's official GPL-2.0 release and the
reverse-engineering work in [rhgndf/ms912x](https://github.com/rhgndf/ms912x). The
pristine vendor archive is kept in this folder for provenance.
