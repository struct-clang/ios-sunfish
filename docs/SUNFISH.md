# Porting notes: sunfish (Google Pixel 4a)

Status (2026-10-22): **ported, full XNU payload built, not yet booted on
hardware.** The shim, the kernel (`0082`/`0083` applied) and the full payload
pass the offline checks; the diagnostic shim has run on the phone. No XNU,
SpringBoard or touch test has run (see
[`ACCEPTANCE_TESTS.md`](../ACCEPTANCE_TESTS.md)). The first boot on the phone
has to confirm the points in "To check on first boot".

## Why it ports at all

sweet (Redmi Note 10 Pro, SM7150-AC) and sunfish (Pixel 4a, SM7150-AB) use the
same SoC. These parts are identical, and the existing code works unchanged:

| Block | Address / fact | Shared code |
| --- | --- | --- |
| CPUs | 6x A55 + 2x A76, MPIDR Aff1 = core, PSCI over `smc` | shim, 0065/0078 |
| GICv3, timer | GICD `0x17a00000`, GICR `0x17a60000`, vtimer PPI 19, 19.2 MHz | mkadt, 0017 |
| RAM | 6 GiB; upper bank `0x1_00000000` is free of carve-outs | `mkadt.py --highmem` |
| Splash framebuffer | `0x9c000000`, a8r8g8b8, stride 4320, region `0x1700000` | shim, fbcon, AppleCLCD |
| UFS | `ufshc@1d84000`, `userdata` on LUN 0 | `sweet_ufs.c` |
| USB | DWC3 at `0xa600000`, QSCRATCH `0xa6f8800` | `sweet_usb.c` |
| SPMI / PMICs | PM6150 + PM6150L, arbiter v5 at `0xc440000` | `sweet_spmi.c`, `sweet_keys.c` |
| Keys | power + volume down on the PM6150 PON, volume up on PM6150L GPIO2 | `sweet_keys.c` |
| Touch bus | QUP SE7 I2C (`0xa84000`) if ABL loaded GENI firmware; otherwise TLMM 6/7 open-drain bit-bang, reset GPIO 8, IRQ GPIO 9 | `sweet_touch.c` (auto/SE7/bit-bang) |

Sources: `linux` (`arch/arm64/boot/dts/qcom/sm7150-google-sunfish.dts` next to
`sm7150-xiaomi-sweet.dts`), `android_kernel_google_msm-4.14`
(`arch/arm64/boot/dts/google/sm7150-sunfish-*.dtsi`,
`drivers/input/touchscreen/fts_touch_s5`), and `android_device_google_sunfish`
(`BoardConfig-common.mk`, `fstab.hardware`).

## What is different, and how it is handled

| | sweet | sunfish | Change |
| --- | --- | --- | --- |
| Panel | 1080x2400 **video mode** (MDP scans RAM continuously) | 1080x2340 Samsung sofef01 **command mode** (MDP sends a frame only when kicked) | `shim/disp.c`: enable the pingpong's autorefresh (`PP_AUTOREFRESH_CONFIG = BIT(31) \| 1`) on every tear-checked pingpong, so every TE pulse re-sends the framebuffer. The downstream SDE driver uses the same mechanism instead of `CTL_START`. Panel height comes from `FB_H` (shim) → boot_args → AppleCLCD / SweetHIDTouch |
| Touch IC | Goodix GT9896 at `0x5d` | ST FTM5 at `0x49`, in-cell | `0082`: `sweet_touch.c` picks the FTM5 path when the ADT root says `google,sunfish`. Reset pin, wait for `CONTROLLER_READY` (`0x03`), scan mode `{fa 20 00 00 00 00 00}` then `{a0 00 00}` (the vendor `ftsCore.c` sequence, not `{a0 00 ff}`), events read 8 bytes at a time from `0x86` (enter `0x13`, motion `0x23`, leave `0x33`, ready `0x03`, error `0xf3`); valid records have bits 0-1 set. READY/error re-runs the scan, rate-limited to 250 ms. Coordinates are 1:1 panel pixels (`st,max-coords = <1079 2339>`) |
| Touch power | L11C through RPMh + GPIO 90 | Panel rails L13A / L7C (on from ABL) + a load switch on **PM6150 GPIO4** | `0082`: `sweet_spmi_write()`, allowed only for PM6150 GPIO4 config registers (`0xc340..0xc346`), sets it to output high if ABL didn't already. TLMM GPIO 72 is driven low (touch IRQ to the AP, not the SLPI) |
| Boot image | Xiaomi layout, Image text offset 0 | **Stock Pixel 4a** header v2: kernel `0x8000`, ramdisk `0x01000000`, tags `0x100`, DTB `0x1f00000`, page 4096; the Pixel ABL **rejects any Image header text offset other than `0x80000`** ("Kernel TextOffset does not match") | `DEVICE=sunfish shim/build.sh` (`-DTEXT_OFFSET=0x80000` in `start.S`; the shim is position independent). The LineageOS `BoardConfig` values `0x02000000`/`0x01e00000` are **not** used |
| Platform expert match | `xiaomi,sweet` | `google,sunfish` | `0082`: `IONameMatch = ('xiaomi,sweet', 'google,sunfish')`; `mkadt.py --device sunfish` |
| Digitizer surface | 68x151 mm | 62x134 mm | `0082`: SweetHIDTouch picks it from the panel height |

The kernel binary is the same for both phones (machine config `SWEET`). Only the
shim image and the ADT are per device.

Presented display: iOS still sees the iPhone X panel (1125x2436). The 1080x2340
panel shows its centred part: 22 px are cropped at each side, 48 px at the top
and the bottom (the status bar and home indicator sit inside that safe area).

## Build

Use the scripts (they select the toolchain and the stock offsets, and they check
the result):

```sh
# stock DTB from the phone's own boot.img (factory image or a backup)
python3 tools/unpack_bootv2.py backup/boot.img dtb/sunfish          # -> dtb/sunfish/dtb

scripts/build.sh --shim-only            # diagnostics image, no kernel
scripts/check-artifacts.sh --shim-only
scripts/build-kernel-local.sh           # or download the CI xnu-kernel artifact
scripts/build.sh --kernel xnu/out/kernel.development.sweet
```

The manual equivalent is:

```sh
python3 tools/mkadt.py shim/out/sunfish.adt --highmem --device sunfish
python3 tools/mkpayload.py xnu/out/kernel.development.sweet shim/out/sunfish.adt shim/out/payload.bin \
    --cmdline 'debug=0xc serial=3 cpus=6 keepsyms=1 -enable_kprintf_spam -noprogress rd=ufsroot0 unentitled_ios_sim_launch=1 ignition_level=1 wdt_test=no_user_checkin ufsrw=1 rootrw=1 launchd_unsecure_cache=1 wdt=-1 sweetfb_noconsole=1 sweetfb_hz=30'
DEVICE=sunfish shim/build.sh shim/out/payload.bin                # -> shim/out/shim-boot.img
```

`tools/mkbootimg_v2.py` packs the v2 header, so neither `mkbootimg` nor a
specific toolchain prefix is required (set `CROSS=` to override).

The iOS root image is the same as on sweet (iPhone X 16.7.16). Flash it to
`userdata` with `scripts/flash-sunfish.sh --flash-root ios16-root.simg`. That
**erases Android's user data**. The bootloader must be unlocked
(`fastboot flashing unlock`). Then run `scripts/flash-sunfish.sh` (temporary
`fastboot boot`; nothing is flashed to `boot_a`/`boot_b`).

Read the persistent log from TWRP for sunfish (adb root) with
`tools/sweet-log-pull.sh`. It finds `userdata` by name.

## To check on first boot

Try these steps in order. Each one can be tested without the steps after it.

1. **Shim without payload** (`DEVICE=sunfish shim/build.sh`, no argument): the
   red screen must **update** (UFS probe lines appear one by one). The `DISP`
   lines show:
   - `DISP SRC addr=9C000000 size=09240438`: ABL scans out our framebuffer
     (size = 2340 << 16 | 1080). A `NOT FB!` line means ABL used another buffer.
     Then set `FB_BASE` from it.
   - `DISP PP n=… ar now=80000001`: autorefresh is on. If the line says `no
     tear-checked pingpong`, ABL left the panel in video mode (unexpected) or
     the display was off. If the screen freezes on the first frame, autorefresh
     did not take. The fallback is to kick `CTL_START` (CTL base + `0x1c`) after
     each frame, in the shim's console and in AppleCLCD's present path.
2. **Kernel**: the early console and the Apple logo phase, then the UFS line
   `"userdata" on LUN 0`.
3. **Touch**: log lines `SWEET TOUCH: PM6150 GPIO4 …`, then either
   `selected ST FTM5` after the SE7/FIFO path or `SE7 firmware unusable; using
   bit-banged I2C` followed by `FTM5 ACK on bit-banged I2C sda=6 scl=7`. Then
   `FTM5 0x49 err=0 ready=1` and `scan mode active err=0`. With `err=6`
   (ENXIO, no ACK on either pad order), check the load switch and the reset pin.
   `sweettouchbus=1` requires SE7, `sweettouchbus=2` forces the bit-bang path;
   `sweettouch=0` disables the driver.
4. **Keys and USB**: these should behave as on sweet (same PMIC and the same
   DWC3 wrapper).
