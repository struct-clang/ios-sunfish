# Porting status: Google Pixel 4a (sunfish)

**Last updated: 2026-10-22. Branch: `sunfish-port`.**

## Verdict

**Not accepted. The boot chain and the diagnostic display are now verified on a real Pixel 4a; SpringBoard and touch are not.** The payload-less shim built by `scripts/build.sh --shim-only` was accepted by `fastboot boot` and produced the red/yellow/white diagnostic screen on the internal panel on 2026-10-22. The full XNU payload (built kernel + sunfish ADT) is now built and passes every offline check, but it has not been booted; the iOS root has not been flashed. `ACCEPTANCE_TESTS.md` H2-H8 are still `NOT RUN`. The exact `DISP`/FDT lines are pending a photo; do not infer panel timings or touch from the screen colours alone.

Do not treat a compiled kernel, a built boot image or a red diagnostic screen
as proof of the port. Acceptance requires the six items in
`ACCEPTANCE_TESTS.md` on real hardware.

## What is implemented

| Area | Change | State |
| --- | --- | --- |
| Touch controller | ST FTM5 at I2C `0x49`, reset GPIO 8, IRQ GPIO 9, switch GPIO 72, `st,max-coords = <1079 2339>` | Written in patch `0082`; compile-tested only |
| Touch power | PM6150 GPIO4 load switch through a new, address-restricted `sweet_spmi_write()` (`0xc340..0xc346`, SID 0, EE0 ownership check) | Written; register sequence checked against downstream `pinctrl-spmi-gpio` and `spmi-pmic-arb` |
| Touch bus fallback | Pixel ABL has no GENI/I2C strings and does not appear to load SE7 firmware (the Xiaomi ABL does). If `touch_se_init()` fails, the same chip is driven with open-drain I2C bit-banged on TLMM 6/7; the pad order is auto-detected by ACK | Written; **never run on hardware** |
| Scan mode | Vendor `ftsCore.c` sequence: `{fa 20 00 00 00 00 00}` then `{a0 00 00}`; rescan after `0x03`/`0xf3` events, rate-limited | Written |
| Panel | 1080x2340 Samsung sofef01, DSI command mode; MDP pingpong autorefresh instead of `CTL_START` | `shim/disp.c`; the red diagnostic screen was observed on the panel (H1), iOS rendering is not yet tested |
| Boot image | header v2 with the **stock** offsets: kernel `0x8000`, ramdisk `0x01000000`, tags `0x100`, DTB `0x1f00000`; Image `text_offset=0x80000`; kernel **LZ4 frame**; unsigned AVB hash footer, padded to 64 MiB | Accepted by `fastboot boot` on 2026-10-22; repacking the stock payloads reproduces the stock image except avbtool's release string |
| Platform | ADT root `google,sunfish`, 1080x2340 framebuffer, platform expert matches both boards | `tools/mkadt.py --device sunfish` output checked |
| Boot args | `sweettouchbus=0` auto (default), `1` requires SE7/FIFO, `2` forces bit-banged I2C | New |

The kernel binary is still the shared `SWEET` machine config; only the ADT and
the shim boot image are per device.

## Offline verification performed (2026-10-22)

All of this is reproducible with `scripts/build.sh` and
`scripts/check-artifacts.sh`.

| Check | Result |
| --- | --- |
| Patches `0001`-`0081` apply to a fresh `xnu-8796.141.3` tree | 79 of 81 applied; `0031` and `0041` fail exactly as before this work (pre-existing, unrelated to sunfish) |
| New `0082-sunfish-board-support.patch` applies on top and reproduces the edited tree | yes (`git apply --check`, byte compare of the seven touched files) |
| `sweet_touch.c` syntax check with the kernel headers | passes (only pre-existing implicit declarations of `delay`/`memcmp`) |
| Shim cross-build with Homebrew `aarch64-elf-gcc` 16.2.0 | yes: `Image` 180224 bytes, LZ4 frame `Image.lz4` 8345 bytes, `shim-boot.img` 67108864 bytes |
| Shim Image header | `text_offset=0x80000`, `image_size=0x2c000` (= file size), magic `ARMd` |
| Boot image header | kernel `0x8000`, ramdisk `0x01000000`, tags `0x100`, DTB `0x1f00000`, page 4096, v2, `os_version=0x220001aa` |
| Repack of the stock `boot.img` with `tools/mkbootimg_v2.py` | byte-identical to stock except the avbtool release string (`1.3.0` vs `1.4.0`); the repacked image boots |
| Sunfish ADT | 10092 bytes; root `D22AP | iPhone10,3 | google,sunfish | qcom,sm7150 | AppleARM`; fb 1080x2340, stride 4320 |
| Device access | phone attached in fastboot, bootloader unlocked; `fastboot boot` of the stock, repacked-stock and frame-LZ4 shim images all accepted |
| Full XNU kernel build | **yes**, Xcode 16.2 + extracted 13.5 KDK + pinned dxb; `kernel.development.sweet` 16777216 bytes, SHA256 `0562cca00b2f98c91e22f379c05064a12f73e5733f7fc3ac71bd9d01b1e90d86`; contains `google,sunfish` and all four FTM5 strings |
| Full payload build | **yes**, 10 segments, entry `0xfffffe0007490488`, `payload.bin` 16628560 bytes; boot image SHA256 `fb61c5ef...` (see below); every `check-artifacts.sh` line passes |

The kernel was built locally with `scripts/build-kernel-local.sh` (same
pinned dxb revision and patches as CI). This removes the macOS-14 CI runner
from the critical path. The queued run `39827421032` was on the deprecated
macOS-14 image; the workflow now targets `macos-15`.

Artifact hashes from the offline build (payload-less diagnostic shim, scratch DTB):

```
04093e0658a7209fbef75d8d5a1d0830b3a750d33f581cc900a5abe23c5ecee4  shim/out/Image
c0023e4c1e0eb4420a0513547fd015e926727e34874f1cf9bb4f0cefe9713d1b  shim/out/Image.lz4
68a6493af1c1f323e97afc13d5bed2a20f35d8b387950d9ba2fb6bd85b0e634a  shim/out/shim-boot.img  (diagnostic)
```

Full payload image (kernel + ADT + shim, the image to boot next):

```
fb61c5eff317992519cf44822ddb02c85e9de2c3bdd913625a6630f4bffc3e6a  shim/out/shim-boot.img  (full payload)
```

The boot image is 67108864 bytes (the 64 MiB boot partition): LZ4 frame
kernel + unsigned AVB hash footer. `scripts/check-artifacts.sh` verifies the
frame magic, decompresses it back to `shim/out/Image`, and verifies the AVB
footer/hash descriptor.

These are diagnostics-only images. The hashes change as soon as the kernel or
the ADT changes; use `scripts/check-artifacts.sh` to print the current ones.

## What is blocked, and why

1. **Kernel build: solved.** Xcode 16.2 builds xnu-8796 with the pinned dxb
   revision, the extracted 13.5 KDK and `xnu/patches/`; the resulting kernel
   is on disk. CI is optional and now uses `macos-15`; the old run
   `39827421032` is irrelevant.
2. **Hardware.** The boot chain and diagnostic display run on the phone, and
   the full XNU payload image is built and offline-checked. The phone is
   disconnected, so the payload has not been booted. Touch and SpringBoard
   cannot be observed until it boots and the iOS root is present.
3. **Root image.** The 16 GiB HFSX image from the iPhone X 16.7.16 IPSW is not
   on this machine (it lives on the Linux host used for the sweet port).
4. **`0031`/`0041`.** Two pre-existing patches fail to apply in this tree.
   They are not needed for the sunfish path, but a fresh CI build will skip
   them (the workflow uses `git apply --check || skip`), so the kernel may lack
   the read-write root and HFS link-note changes. Confirm in the CI log whether
   they are applied before trusting a writable root.

## Immediate next steps

1. Reconnect the phone, boot `shim/out/shim-boot.img` (`fb61c5ef...`) with
   `fastboot boot`, and capture the shim's `DISP`/FDT lines (photo/video).
   Watch the panel for 30 s without touching it (H2).
2. Follow `ACCEPTANCE_TESTS.md` H3-H4: XNU entry, framebuffer takeover and
   serial/PANIC output. If it resets, record the last visible line and the
   reset reason; do not guess.
3. If the SE7 firmware is present, test `sweettouchbus=1`; if not, the default
   auto path must report the bit-banged ACK. If neither works, the log lines
   listed in `TROUBLESHOOTING.md` isolate power, reset, pad order and protocol.
4. Flash the iOS root only after H1-H4 pass and the user confirms; then test
   SpringBoard and touch (H5-H6).
5. Only after SpringBoard and touch pass, update `README.md` to say "boots on
   sunfish".

## Honest limitations

- The panel refresh code is inherited from sweet and adapted from the
  downstream SDE driver; it has not been observed on a command-mode sofef01.
- The bit-banged I2C timing (5 us half period, ~100 kHz) is a conservative
  choice with a 50 kΩ internal pull-up as backup to the flex pull-ups. Its
  electrical behaviour on the actual flex is unverified.
- PM6150 GPIO4 is written directly over SPMI. The sequence matches the
  downstream pinctrl driver, but ABL leaves the PMIC in an unknown state; the
  code reads the registers first and only changes what it needs.
- The iOS userland is the iPhone X image, so the UI is still 1125x2436 letter-
  boxed into the 1080x2340 panel.
