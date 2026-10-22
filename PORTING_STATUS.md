# Porting status: Google Pixel 4a (sunfish)

**Last updated: 2026-10-23. Branch: `sunfish-port`.**

## Verdict

**Not accepted. The boot chain and the diagnostic display are now verified on a real Pixel 4a; SpringBoard and touch are not.** The payload-less shim built by `scripts/build.sh --shim-only` was accepted by `fastboot boot` and produced the red/yellow/white diagnostic screen on the internal panel on 2026-10-22. The full XNU payload (built kernel + sunfish ADT) is now built and passes every offline check, but it has not been booted; the iOS root has not been flashed. `ACCEPTANCE_TESTS.md` H2-H6 and H8 are still `NOT RUN`; H7 passed offline (two byte-identical full builds). The exact `DISP`/FDT lines are pending a photo; do not infer panel timings or touch from the screen colours alone.

Do not treat a compiled kernel, a built boot image or a red diagnostic screen
as proof of the port. Acceptance requires the six items in
`ACCEPTANCE_TESTS.md` on real hardware.

## What is implemented

| Area | Change | State |
| --- | --- | --- |
| Touch controller | ST FTM5 at I2C `0x49`, reset GPIO 8, IRQ GPIO 9, switch GPIO 72, `st,max-coords = <1079 2339>` | Written in patch `0082`; compile-tested only |
| Touch power | PM6150 GPIO4 load switch through a new, address-restricted `sweet_spmi_write()` (`0xc340..0xc346`, SID 0, EE0 ownership check) | Written; register sequence checked against downstream `pinctrl-spmi-gpio` and `spmi-pmic-arb` |
| Touch bus fallback | Pixel ABL has no GENI/I2C strings and does not appear to load SE7 firmware (the Xiaomi ABL does). If `touch_se_init()` fails, the same chip is driven with open-drain I2C bit-banged on TLMM 6/7; the pad order is auto-detected by ACK | Written; **never run on hardware** |
| Scan mode | Vendor `ftsCore.c` sense-on sequence: `{fa 20 00 00 00 00 00}` then `{a0 00 ff}`; rescan after `0x03`/`0xf3` events, rate-limited | Written; compile-tested only. The earlier `{a0 00 00}` was the vendor's **sense-off** command and was fixed on 2026-10-23 after re-reading `fts_mode_handler` |
| Panel | 1080x2340 Samsung sofef01, DSI command mode; MDP pingpong autorefresh instead of `CTL_START` | `shim/disp.c`; the red diagnostic screen was observed on the panel (H1), iOS rendering is not yet tested |
| Boot image | header v2 with the **stock** offsets: kernel `0x8000`, ramdisk `0x01000000`, tags `0x100`, DTB `0x1f00000`; Image `text_offset=0x80000`; kernel **LZ4 frame**; unsigned AVB hash footer, padded to 64 MiB | Accepted by `fastboot boot` on 2026-10-22; repacking the stock payloads reproduces the stock image except avbtool's release string |
| Platform | ADT root `google,sunfish`, 1080x2340 framebuffer, platform expert matches both boards | `tools/mkadt.py --device sunfish` output checked |
| Boot args | `sweettouchbus=0` auto (default), `1` requires SE7/FIFO, `2` forces bit-banged I2C | New |

The kernel binary is still the shared `SWEET` machine config; only the ADT and
the shim boot image are per device.

## Offline verification performed (2026-10-22, updated 2026-10-23)

All of this is reproducible with `scripts/build.sh` and
`scripts/check-artifacts.sh`.

| Check | Result |
| --- | --- |
| Patches `0001`-`0081` apply to a fresh `xnu-8796.141.3` tree | **all 81 apply in the real dxb/CI build**, including `0031` (read-write root) and `0041` (HFS link notes), because dxb runs the `*.sh` staging scripts between patches. A manual `.patch`-only replay without staging skips `0031`/`0041` and is not representative; the built kernel contains `rootrw`, `mounting dirty non-journaled root read-write` and `sweet_hfs_link_note` |
| New `0082-sunfish-board-support.patch` applies on top and reproduces the edited tree | yes (`git apply --check`, byte compare of the seven touched files) |
| `sweet_touch.c` syntax check with the kernel headers | passes (only pre-existing implicit declarations of `delay`/`memcmp`) |
| Shim cross-build with Homebrew `aarch64-elf-gcc` 16.2.0 | yes: `Image` 180224 bytes, LZ4 frame `Image.lz4` 8345 bytes, `shim-boot.img` 67108864 bytes |
| Shim Image header | `text_offset=0x80000`, `image_size=0x2c000` (= file size), magic `ARMd` |
| Boot image header | kernel `0x8000`, ramdisk `0x01000000`, tags `0x100`, DTB `0x1f00000`, page 4096, v2, `os_version=0x220001aa` |
| Repack of the stock `boot.img` with `tools/mkbootimg_v2.py` | byte-identical to stock except the avbtool release string (`1.3.0` vs `1.4.0`); the repacked image boots |
| Sunfish ADT | 10092 bytes; root `D22AP | iPhone10,3 | google,sunfish | qcom,sm7150 | AppleARM`; fb 1080x2340, stride 4320 |
| Device access | phone attached in fastboot, bootloader unlocked; `fastboot boot` of the stock, repacked-stock and frame-LZ4 shim images all accepted |
| Full XNU kernel build | **yes**, Xcode 16.2 + extracted 13.5 KDK + pinned dxb; `kernel.development.sweet` 17240048 bytes, SHA256 `e24fe3778f14b809d4a69465246f64f8accbbd55d21c021dbffbff92b2e8316c`; contains `google,sunfish`, the FTM5 strings and the corrected sense-on bytes `a0 00 ff` |
| Full payload build | **yes**, 10 segments, entry `0xfffffe0007490488`, `payload.bin` 16628560 bytes SHA256 `e77d29244b469c165bec298728ba66c74fb76c54a90c935710c228cb96f6bac2`; boot image SHA256 `2e2880...` (see below); every `check-artifacts.sh` line passes |
| Reproducible full build | **yes**: two consecutive `scripts/build.sh` runs produced byte-identical ADT, payload and 64 MiB boot image (`2e2880...`). `tools/mkadt.py` now uses a fixed 64-byte `random-seed` by default (`--random-seed` still exists). This satisfies H7 offline |
| FTM5 sense-on fix | **yes**: re-reading vendor `ftsCore.c` showed `{0xa0, 0x00, 0xff}` is sense-on and `{0xa0, 0x00, 0x00}` is **sense-off**; `0082` and the rebuilt binary use `0xff` |

The kernel was built locally with `scripts/build-kernel-local.sh` (same
pinned dxb revision and patches as CI). This removes the macOS-14 CI runner
from the critical path. The queued run `39827421032` was on the deprecated
macOS-14 image; the workflow now targets `macos-15`.

Artifact hashes from the offline build (payload-less diagnostic shim, scratch DTB):

```
04093e0658a7209fbef75d8d5a1d0830b3a750d33f581cc900a5abe23c5ecee4  shim/out/Image
c0023e4c1e0eb4420a0513547fd015e926727e34874f1cf9bb4f0cefe9713d1b  shim/out/Image.lz4
68a6493af1c1f323e97afc13d5bed2a20f35d8b387950d9ba2fb6bd85b0e634a  shim/out/shim-boot-diagnostic.img
```

Full payload image (kernel + ADT + shim, the image to boot for H3+):

```
e77d29244b469c165bec298728ba66c74fb76c54a90c935710c228cb96f6bac2  shim/out/payload.bin
2e28809ed12dda6255e952ea404210f44c4c289400b2d5a447d9ed74bf5f4402  shim/out/shim-boot.img  (full payload, console muted)
```

Debug payload for the first XNU boot (`sweetfb_noconsole=0`, `sweetusb=2`):

```
3d1466e1013a31dbc54d22a2b10220af3c5210a7cbfeb48f0c994cd8f92bda86  shim/out/payload-debug.bin
4558eb51aac221ed9f7d5e9d417ef46ae2c09bc7622b14a6a3d502ca356003a2  shim/out/shim-boot-debug.img
```

The local tree keeps the images: `shim/out/shim-boot-diagnostic.img`
(`68a649...`) for H1/H2, `shim/out/shim-boot-debug.img` (`4558eb...`) for
H3 logging and `shim/out/shim-boot-payload.img` (`2e2880...`) for the normal
H4+ boot. `shim/out/shim-boot.img` is currently the full payload. The boot
image is 67108864 bytes (the 64 MiB boot partition): LZ4 frame kernel +
unsigned AVB hash footer. `scripts/check-artifacts.sh` verifies the frame
magic, decompresses it back to `shim/out/Image`, and verifies the AVB
footer/hash descriptor.

The hashes change as soon as the kernel or the ADT changes; use
`scripts/check-artifacts.sh` to print the current ones. The stock boot image
has a 17.5 MB kernel and 17.9 MB ramdisk at the same nominal offsets, so the
16.6 MB payload is within the proven stock layout; no header relocation is
needed.

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
4. **No patch-order blocker.** The real dxb/CI build runs the staging scripts
   and applies `0031` and `0041`; the earlier "skipped" observation came from
   a patch-only replay that omitted those scripts. The built kernel contains
   the read-write-root and HFS link-note code, so a writable root is not
   blocked by patch order.

## Immediate next steps

1. Reconnect the phone, boot `shim/out/shim-boot-diagnostic.img`
   (`68a649...`) with `fastboot boot`, and capture the shim's `DISP`/FDT
   lines (photo/video). Watch the panel for 30 s without touching it (H2).
2. Boot `shim/out/shim-boot-debug.img` (`4558eb...`, `sweetusb=2`, console
   on) for H3 and capture the XNU/UFS/launchd log; then boot
   `shim/out/shim-boot-payload.img` (`2e2880...`, console muted) for H4.
   If it resets, record the last visible line and the reset reason; do not
   guess.
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
