# Porting status: Google Pixel 4a (sunfish)

**Last updated: 2026-10-22. Branch: `sunfish-port`.**

## Verdict

**Not accepted. The boot chain and the diagnostic display are now verified on a real Pixel 4a; SpringBoard and touch are not.** The payload-less shim built by `scripts/build.sh --shim-only` was accepted by `fastboot boot` and produced the red/yellow/white diagnostic screen on the internal panel on 2026-10-22. The XNU payload has not booted, the iOS root has not been flashed, and `ACCEPTANCE_TESTS.md` H2-H8 are still `NOT RUN`. The exact `DISP`/FDT lines are pending a photo; do not infer panel timings or touch from the screen colours alone.

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

Artifact hashes from the offline build (payload-less shim, scratch DTB):

```
04093e0658a7209fbef75d8d5a1d0830b3a750d33f581cc900a5abe23c5ecee4  shim/out/Image
c0023e4c1e0eb4420a0513547fd015e926727e34874f1cf9bb4f0cefe9713d1b  shim/out/Image.lz4
68a6493af1c1f323e97afc13d5bed2a20f35d8b387950d9ba2fb6bd85b0e634a  shim/out/shim-boot.img
```

The boot image is 67108864 bytes (the 64 MiB boot partition): LZ4 frame
kernel + unsigned AVB hash footer. `scripts/check-artifacts.sh` verifies the
frame magic, decompresses it back to `shim/out/Image`, and verifies the AVB
footer/hash descriptor.

These are diagnostics-only images. The hashes change as soon as the kernel or
the ADT changes; use `scripts/check-artifacts.sh` to print the current ones.

## What is blocked, and why

1. **Kernel build.** The local machine has Xcode 16.2, whose `iig` emits
   `IORPC.kernelContent`; xnu-8796 does not have it. The CI runner
   (`macos-14`, Xcode 15) is the supported build path. The branch was pushed to
   the fork and run `39827421032` was re-queued after a macOS-runner capacity
   cancellation; there is no kernel artifact yet.
2. **Hardware.** The boot chain and diagnostic display now run on the phone.
   Touch and SpringBoard cannot be observed until the XNU payload boots and the
   iOS root is present.
3. **Root image.** The 16 GiB HFSX image from the iPhone X 16.7.16 IPSW is not
   on this machine (it lives on the Linux host used for the sweet port).
4. **`0031`/`0041`.** Two pre-existing patches fail to apply in this tree.
   They are not needed for the sunfish path, but a fresh CI build will skip
   them (the workflow uses `git apply --check || skip`), so the kernel may lack
   the read-write root and HFS link-note changes. Confirm in the CI log whether
   they are applied before trusting a writable root.

## Immediate next steps

1. Finish the queued CI run; confirm in the log that `0082` applied and that
   the binary contains `SWEET TOUCH: FTM5 ACK on bit-banged I2C`,
   `SWEET TOUCH: selected ST FTM5` and `google,sunfish`.
2. With the phone: capture the shim's `DISP`/FDT lines (photo/video) and watch
   the panel for 30 s without touching it (H2).
3. Build the payload with the CI kernel and the sunfish ADT, then boot it and
   follow `ACCEPTANCE_TESTS.md` H3-H4.
4. If the SE7 firmware is present, test `sweettouchbus=1`; if not, the default
   auto path must report the bit-banged ACK. If neither works, the log lines
   listed in `TROUBLESHOOTING.md` isolate power, reset, pad order and protocol.
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
