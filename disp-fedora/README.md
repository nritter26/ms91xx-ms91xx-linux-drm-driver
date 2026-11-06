# msdisp — MS91xx USB display driver for Fedora (DKMS)

Linux DRM driver for **MacroSilicon MS9132 / MS9133 / MS9135** USB display chips
(`lsusb`: `345f:9132` / `345f:9133` / `345f:9135`) and the **MS912C** VGA family
(`534d:6021`). These chips power brandless portable USB monitors, dual/tri-screen
laptop extenders and USB 3.0 → HDMI/VGA adapters.

This folder — `disp-fedora/` — is the Fedora port: the driver source plus an
installer that uses `dnf`, installs `kernel-devel` for your running kernel, rebuilds
the initramfs with `dracut` and walks you through MOK enrollment for Secure Boot.

## Requirements

| | |
|---|---|
| Distro | Fedora 41 (6.11) or Fedora 42 (6.14) |
| Packages | `dkms`, `gcc`, `make`, `rsync`, `kernel-devel-$(uname -r)` |
| Secure Boot | supported — modules are signed with DKMS's MOK key |
| Desktop | X11 or Wayland (GNOME/Mutter, KDE Plasma) |

Fedora keeps `kernel-devel` **only for kernels that are still installed**, and the
headers for the *running* kernel can disappear right after a system update until you
boot the new kernel. The installer stops with a clear message rather than letting
kbuild fail on a missing header tree.

## Install

```sh
sudo ./dkms-install.sh                         # running kernel
sudo ./dkms-install.sh 6.14.4-300.fc42.x86_64  # or an explicit kernel version
```

The script, in order:

1. installs missing packages (`dkms`, `gcc`, `make`, `rsync`,
   `kernel-devel-<kernel>`) with `dnf`;
2. purges stale `msdisp` versions from DKMS, including a tree left behind by a
   failed build — that entry otherwise makes `dkms add` abort on every later run;
3. deletes orphaned `usbdisp_*.ko` files in `/lib/modules` that would shadow DKMS;
4. syncs the tree to `/usr/src/msdisp-3.1.6`, registers, builds and signs it, then
   runs `depmod`;
5. rebuilds the initramfs with `dracut -f --kver <kernel>`;
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

Fedora enforces module signatures when Secure Boot is on. `dkms` signs with
`/var/lib/dkms/mok.key`, and that key must be enrolled once or the modules are
rejected with *Key was rejected by service*:

```sh
sudo mokutil --import /var/lib/dkms/mok.pub
sudo reboot
# in the blue MOK manager: Enroll MOK -> Continue -> Yes -> password set above
```

The installer prints this automatically when it detects Secure Boot enabled.

If you prefer Fedora's own `akmods` framework over DKMS, that is a separate packaging
path and these scripts do not cover it.

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
| `no kernel headers for <ver>` | `dnf install kernel-devel-<ver>`. After a kernel update, boot the new kernel first — Fedora drops `kernel-devel` for kernels it no longer ships, so rebuilding for the old one is impossible. |
| `DKMS tree already contains: msdisp/3.1.6` | Leftover registry entry; the current script clears it. On an older copy: `sudo dkms remove msdisp/3.1.6 --all` first. |
| Modules build but do not load | Secure Boot: enrol the MOK key (above), and check `journalctl -k` for *Key was rejected by service*. |
| Panel stays dark while frames flow | Usually VGA-vs-S-Video output selection — see [docs/MS912C-VGA.md](docs/MS912C-VGA.md). |

SELinux needs no extra policy: the modules load from
`/lib/modules/$(uname -r)/updates/dkms/` with no custom labelling. If module loading
is blocked, `ausearch -m avc -ts recent` shows it.

## Notes and limitations

- **Never `rmmod usbdisp_drm`.** The vendor teardown path has a use-after-free that
  oopses the kernel and leaves the module stuck. To reload, reboot.
- **USB 2.0 cannot carry 1080p60.** A full 1920×1080 UYVY frame is ~4.15 MB, i.e.
  ~249 MB/s at 60 Hz, while USB 2.0 usable bulk bandwidth is ~40–50 MB/s. On a
  480 Mbps link expect ~10–12 full-screen frames/s — fine for typing, laggy when
  dragging or scrolling. Use a USB 3 port and a USB 3 cable; `lsusb -t` shows the
  negotiated speed.
- Fedora's kernel is usually ahead of the driver's tested range (6.8 → 7.0+). The
  tree builds against up to 7.2, which renamed the atomic update type to
  `struct drm_atomic_commit`; the driver carries the matching alias in
  `drm/msdisp_drm_modeset.c`. A brand-new kernel may still need a small API fix.

## Uninstall

```sh
sudo ./dkms-remove.sh
```

## Installation not working? Open a PR

If the installer fails or the panel stays dark on Fedora, please **open a pull
request** with your logs instead of just giving up. Attach:

```sh
uname -r
cat /etc/fedora-release
rpm -q dkms gcc make rsync "kernel-devel-$(uname -r)"
lsusb -t | grep -E '345f|534d'
lsmod | grep usbdisp
dmesg | grep -iE 'usbdisp|chip id|video port'
```

plus the installer output and your desktop/compositor. If you already have the fix,
send it as a PR against `disp-fedora/`; if the bug is in the driver itself, it belongs
in the driver source so every build benefits.

## Build status

The driver source here is byte-identical to the canonical `ms91xx-linux-drm` tree and
builds cleanly against 6.8 → 7.2 headers; `tests/test_damage_bounds.py` passes. The
`dnf`/`kernel-devel`/`dracut`/MOK handling in the installer is written to Fedora's
layout and syntax-checked, but it has **not** been run on Fedora hardware — treat it as
untested until you have run it once.

## License & provenance

GPL-2.0, same as the original MacroSilicon source — see [LICENSE](LICENSE).

Driver and packaging come from the
[bambinounos/ms91xx-linux-drm](https://github.com/bambinounos/ms91xx-linux-drm) fork
(this repository's upstream) built on MacroSilicon's official GPL-2.0 release and the
reverse-engineering work in [rhgndf/ms912x](https://github.com/rhgndf/ms912x). The
pristine vendor archive is kept in this folder for provenance.
