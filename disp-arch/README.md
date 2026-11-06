# msdisp — MS91xx USB display driver for Arch Linux (DKMS)

Linux DRM driver for **MacroSilicon MS9132 / MS9133 / MS9135** USB display chips
(`lsusb`: `345f:9132` / `345f:9133` / `345f:9135`) and the **MS912C** VGA family
(`534d:6021`). These chips power brandless portable USB monitors, dual/tri-screen
laptop extenders and USB 3.0 → HDMI/VGA adapters.

This folder — `disp-arch/` — is the Arch Linux / Manjaro port: the driver source
plus an installer that uses `pacman`, picks the headers package for your kernel
flavour and regenerates the initramfs with `mkinitcpio`.

## Requirements

| | |
|---|---|
| Distro | Arch Linux or Manjaro (rolling) |
| Packages | `dkms`, `base-devel`, `rsync`, `linux-headers` for your kernel flavour |
| Secure Boot | supported — modules are signed with DKMS's MOK key, or with `sbctl` |
| Desktop | X11 or Wayland (GNOME/Mutter, KDE Plasma) |

Arch ships headers as a **separate package per kernel flavour**, and the package must
match the kernel you are running:

| Kernel | Headers package |
|---|---|
| `linux` (default) | `linux-headers` |
| `linux-lts` | `linux-lts-headers` |
| `linux-zen` | `linux-zen-headers` |
| `linux-hardened` | `linux-hardened-headers` |

The installer infers the right one from `uname -r` and installs it if
`/lib/modules/$(uname -r)/build` is missing.

## Install

```sh
sudo ./dkms-install.sh                 # running kernel
sudo ./dkms-install.sh 6.12.57-1-lts   # or an explicit kernel version
```

The script, in order:

1. installs missing packages with `pacman -S --needed --noconfirm` (`dkms`,
   `base-devel`, `rsync`, and the matching headers package);
2. purges stale `msdisp` versions from DKMS, including a tree left behind by a
   failed build — that entry otherwise makes `dkms add` abort on every later run;
3. deletes orphaned `usbdisp_*.ko` files in `/lib/modules` that would shadow DKMS;
4. syncs the tree to `/usr/src/msdisp-3.1.6`, registers, builds and signs it, then
   runs `depmod`;
5. regenerates the initramfs with `mkinitcpio -P`;
6. attempts a live reload and tells you whether a reboot is required.

Plug the monitor in: `usbdisp_usb` auto-loads from the USB modalias and a new DRM
card appears. DKMS rebuilds the modules on every kernel update.

## Verify

```sh
lsmod | grep usbdisp                    # usbdisp_drm + usbdisp_usb
cat /sys/module/usbdisp_drm/version     # 3.1.6
lsusb | grep -E '345f|534d'
lsusb -t | grep 345f                    # want 5000M/10000M, not 480M
dmesg | grep -iE 'usbdisp|chip id|video port|start video'
```

## Secure Boot

`dkms` signs with `/var/lib/dkms/mok.key`. With Secure Boot enabled that key must be
enrolled once, or every load fails with *Key was rejected by service*:

```sh
sudo mokutil --import /var/lib/dkms/mok.pub
sudo reboot
# in the blue MOK manager: Enroll MOK -> Continue -> Yes -> the password you set
```

If you manage your own keys with `sbctl`, sign the modules with those instead and make
sure the key is enrolled in the firmware's db (`sbctl status`, `sbctl enroll-keys`).

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
| `no kernel headers for <ver>` | `pacman -S linux-headers` (or the flavour that matches `uname -r`). After a `pacman -Syu` that upgraded the kernel, the running kernel's headers can be gone until you reboot — reboot, then rerun the installer. |
| `DKMS tree already contains: msdisp/3.1.6` | Leftover registry entry; the current script clears it. On an older copy: `sudo dkms remove msdisp/3.1.6 --all` first. |
| Modules build but do not load | Secure Boot: enrol the MOK key or sign with `sbctl` (above). |
| Panel stays dark while frames flow | Usually VGA-vs-S-Video output selection — see [docs/MS912C-VGA.md](docs/MS912C-VGA.md). |

## Notes and limitations

- **Never `rmmod usbdisp_drm`.** The vendor teardown path has a use-after-free that
  oopses the kernel and leaves the module stuck. To reload, reboot.
- **USB 2.0 cannot carry 1080p60.** A full 1920×1080 UYVY frame is ~4.15 MB, i.e.
  ~249 MB/s at 60 Hz, while USB 2.0 usable bulk bandwidth is ~40–50 MB/s. On a
  480 Mbps link expect ~10–12 full-screen frames/s — fine for typing, laggy when
  dragging or scrolling. Use a USB 3 port and a USB 3 cable; `lsusb -t` shows the
  negotiated speed.
- Arch is rolling, so the kernel can move ahead of the driver's tested range. The
  tree builds against 6.8 → 7.2 headers; 7.2 renamed the atomic update type to
  `struct drm_atomic_commit` and the driver carries the matching alias in
  `drm/msdisp_drm_modeset.c`. A newly released kernel may still need a small fix.

## Uninstall

```sh
sudo ./dkms-remove.sh
```

## Installation not working? Open a PR

If the installer fails or the panel stays dark on Arch, please **open a pull request**
with your logs instead of just giving up. Attach:

```sh
uname -r                                    # kernel line, e.g. 7.2.11-arch1-1
pacman -Q dkms linux-headers base-devel rsync
lsusb -t | grep -E '345f|534d'
lsmod | grep usbdisp
dmesg | grep -iE 'usbdisp|chip id|video port'
```

plus the installer output and your desktop/compositor. If you already have the fix,
send it as a PR against `disp-arch/`; if the bug is in the driver itself, it belongs
in the driver source so every build benefits.

## Build status

The driver source here is byte-identical to the canonical `ms91xx-linux-drm` tree and
builds cleanly against 7.2 headers (verified on Arch 7.2.11-arch1-1, `make` exit 0,
both modules produced); `tests/test_damage_bounds.py` passes. The installer itself has
been syntax-checked but not run end-to-end on a clean Arch install.

## License & provenance

GPL-2.0, same as the original MacroSilicon source — see [LICENSE](LICENSE).

Driver and packaging come from the
[bambinounos/ms91xx-linux-drm](https://github.com/bambinounos/ms91xx-linux-drm) fork
(this repository's upstream) built on MacroSilicon's official GPL-2.0 release and the
reverse-engineering work in [rhgndf/ms912x](https://github.com/rhgndf/ms912x). The
pristine vendor archive is kept in this folder for provenance.
