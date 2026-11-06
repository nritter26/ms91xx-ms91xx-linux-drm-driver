# msdisp — MS91xx USB display driver for Ubuntu (DKMS)

Linux DRM driver for **MacroSilicon MS9132 / MS9133 / MS9135** USB display chips
(`lsusb`: `345f:9132` / `345f:9133` / `345f:9135`) and the **MS912C** VGA family
(`534d:6021`). These chips power brandless portable USB monitors, dual/tri-screen
laptop extenders and USB 3.0 → HDMI/VGA adapters.

This folder — `disp-ubuntu/` — is the Ubuntu port: the driver source plus an installer
that uses `apt-get`, installs the per-kernel headers (with a `linux-headers-generic`
fallback for HWE kernels), refreshes the initramfs and covers MOK enrollment for
Secure Boot. This is the configuration the driver was developed and tested on.

## Requirements

| | |
|---|---|
| Distro | Ubuntu 24.04 LTS (6.8) or 26.04 (7.0+) |
| Packages | `dkms`, `build-essential`, `rsync`, `linux-headers-$(uname -r)` |
| Secure Boot | supported — modules are signed with DKMS's MOK key |
| Desktop | GNOME/Mutter or KDE Plasma, X11 or Wayland |

Ubuntu publishes headers per kernel version. An HWE kernel installed via
`linux-generic-hwe-<release>` does not always pull its own headers package, so the
installer falls back to `linux-headers-generic` and then re-checks that
`/lib/modules/$(uname -r)/build` appeared before touching DKMS.

## Install

```sh
sudo ./dkms-install.sh                    # running kernel
sudo ./dkms-install.sh 7.0.0-42-generic   # or an explicit kernel version
```

The script, in order:

1. installs missing packages (`dkms`, `build-essential`, `rsync`, headers) with
   `apt-get`;
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

`dkms` signs with `/var/lib/dkms/mok.key`. With Secure Boot enabled that key must be
enrolled once, or every load fails with *Key was rejected by service*:

```sh
sudo mokutil --import /var/lib/dkms/mok.pub
sudo reboot
# in the blue MOK manager: Enroll MOK -> Continue -> Yes -> the password you set
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
| `no kernel headers for <ver>` | `apt install linux-headers-<ver>`, or `linux-headers-generic` when your HWE kernel has no per-version package. Verify `/lib/modules/$(uname -r)/build` exists afterwards. |
| `DKMS tree already contains: msdisp/3.1.6` | Leftover registry entry; the current script clears it. On an older copy: `sudo dkms remove msdisp/3.1.6 --all` first. |
| Modules build but do not load | Secure Boot: enrol the MOK key (above). |
| Panel stays dark while frames flow | Usually VGA-vs-S-Video output selection — see [docs/MS912C-VGA.md](docs/MS912C-VGA.md). |
| Screen freezes or the cursor vanishes on a multi-GPU laptop | Keep `hw_cursor=1` (the default). It selects the atomic cursor plane used on Mutter/Plasma multi-GPU setups. |

## Notes and limitations

- **Never `rmmod usbdisp_drm`.** The vendor teardown path has a use-after-free that
  oopses the kernel and leaves the module stuck. To reload, reboot.
- **USB 2.0 cannot carry 1080p60.** A full 1920×1080 UYVY frame is ~4.15 MB, i.e.
  ~249 MB/s at 60 Hz, while USB 2.0 usable bulk bandwidth is ~40–50 MB/s. On a
  480 Mbps link expect ~10–12 full-screen frames/s — fine for typing, laggy when
  dragging or scrolling. Use a USB 3 port and a USB 3 cable; `lsusb -t` shows the
  negotiated speed.
- Kernel coverage: 6.8 → 7.0+ is the tested range (24.04 LTS through 26.04), and the
  driver guards up to 7.2, where the atomic update type became
  `struct drm_atomic_commit` (see `msdisp_atomic_update` in
  `drm/msdisp_drm_modeset.c`). A newly released kernel may still need a small fix.

## Uninstall

```sh
sudo ./dkms-remove.sh
```

## Installation not working? Open a PR

If the installer fails or the panel stays dark on Ubuntu, please **open a pull
request** with your logs instead of just giving up. Attach:

```sh
uname -r
lsb_release -d
dpkg -l dkms build-essential rsync | tail -3
lsusb -t | grep -E '345f|534d'
lsmod | grep usbdisp
dmesg | grep -iE 'usbdisp|chip id|video port'
```

plus the installer output and your desktop/compositor. If you already have the fix,
send it as a PR against `disp-ubuntu/`; if the bug is in the driver itself, it belongs
in the driver source so every build benefits.

## Build status

The driver source here is byte-identical to the canonical `ms91xx-linux-drm` tree.
This is the best-covered port: the driver is developed and tested on Ubuntu 24.04 /
26.04 across kernels 6.8 → 7.0+, and the tree also builds cleanly against 7.2 headers.
`tests/test_damage_bounds.py` passes.

## License & provenance

GPL-2.0, same as the original MacroSilicon source — see [LICENSE](LICENSE).

Driver and packaging come from the
[bambinounos/ms91xx-linux-drm](https://github.com/bambinounos/ms91xx-linux-drm) fork
(this repository's upstream) built on MacroSilicon's official GPL-2.0 release and the
reverse-engineering work in [rhgndf/ms912x](https://github.com/rhgndf/ms912x). The
pristine vendor archive is kept in this folder for provenance.
