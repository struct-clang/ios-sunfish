# Troubleshooting the Pixel 4a port

The phone has no serial console. The **screen is the first log**, then the
persistent kernel ring, then USB networking. Debug in that order.

First rule: **boot the payload-less shim** (`scripts/build.sh --shim-only`)
before involving the kernel or the root image. It isolates ABL, the boot image
layout, the panel and the FDT.

## ABL rejects the boot image

Symptoms: `fastboot boot` returns `FAILED (remote: ...)`, or the phone reboots
straight into Android without showing the red screen.

| Message / behaviour | Cause | Fix |
| --- | --- | --- |
| `Kernel TextOffset does not match` | the Image header's `text_offset` is not `0x80000` | build with `DEVICE=sunfish`; confirm `scripts/check-artifacts.sh` prints `text_offset=0x80000` |
| `Invalid boot image header` / `header version` | not header v2, bad page size | use `tools/mkbootimg_v2.py` through `shim/build.sh`; do not repack with an old `mkbootimg` |
| `Failed to load/verify boot images` | the image is larger than ABL's fastboot buffer or the boot slot | use the payload-less shim first; the full payload is bigger |
| `Error verifying the received boot.img: Unsupported` | the kernel is a raw arm64 Image or legacy-LZ4, or the image has no AVB footer | build through `scripts/build.sh` for sunfish: it emits an LZ4 **frame** kernel and an unsigned 64 MiB AVB hash footer. `scripts/check-artifacts.sh` must print `kernel is LZ4 frame` and `AVB footer present`; stock and repacked-stock images are accepted, so compare against those |
| `FAIL: boot image ramdisk differs from ...` | the image and `--payload` file are from different builds (for example, the debug image with the normal payload) | rebuild, or pass the matching payload: `--payload shim/out/payload-debug.bin` for `shim-boot-debug.img` |
| immediate reboot, no screen | wrong `kernel_addr`/`ramdisk_addr` or a non-arm64 Image | check the header fields; `scripts/check-artifacts.sh` compares them with the stock layout |
| `device is locked` | bootloader locked | unlock it yourself; the scripts refuse to do it |

The stock offsets used here are from the phone's own `boot.img`:
kernel `0x8000`, ramdisk `0x01000000`, tags `0x100`, DTB `0x1f00000`, page
4096. The LineageOS `BoardConfig` values (`0x02000000` / `0x01e00000`) are for
a different loader path and are **not** used.

The Pixel 4a ABL is stricter than the Xiaomi ABL used for sweet:

- the kernel must be **LZ4 frame** (`04 22 4d 18`), as in the stock LineageOS
  image. A raw `Image` and the legacy LZ4 format (`02 21 4c 18`) both fail with
  `Error verifying the received boot.img: Unsupported`;
- the image must end in an AVB hash footer. Stock uses `Algorithm: NONE`
  (no signature), so the build writes the same unsigned footer and pads to the
  64 MiB boot partition. No Google key is needed;
- `os_version` must be encoded (stock `0x220001aa`, Android 17.0.0/2026-10),
  not zero. `tools/mkbootimg_v2.py` encodes it and includes the DTB in the
  header `id`.

`shim/build.sh` and `scripts/check-artifacts.sh` enforce all three for
`DEVICE=sunfish`. If you repack by hand, use `lz4 -12` (not `-l`) and
`tools/avbtool.py add_hash_footer --algorithm NONE --partition_size 67108864`.

## The red screen does not update

The 1080x2340 panel is DSI **command mode**: the controller sends a frame only
when it is kicked. The shim turns on the pingpong autorefresh so every TE pulse
re-sends the framebuffer.

Look at the `DISP` lines:

- `DISP SRC addr=9C000000 size=09240438` — ABL left the splash framebuffer at
  the expected address and size (2340<<16 | 1080).
- `NOT FB!` — ABL scans out a different buffer. The shim's `FB_BASE` must be
  changed to the address it prints.
- `DISP PP n=... ar now=80000001` — autorefresh is on (`BIT(31) | 1`).
- `no tear-checked pingpong` — ABL left the panel in video mode (unexpected) or
  the display is off. Check the ABL display handoff; the fallback is to kick
  `CTL_START` (CTL base + `0x1c`) after each frame.

If the first frame appears and then the screen freezes, autorefresh did not
take. If the screen is black, the panel rails may be off: check the display
power sequence in `shim/disp.c` and `sweet_early.c`.

## The shim prints, but XNU shows nothing

1. Confirm the payload is in the boot image's **ramdisk** and its header starts
   with `SWEETXNU` (`scripts/check-artifacts.sh` prints the segment count).
2. Boot with `-noprogress` removed? No: keep it; instead check the early
   markers. The early framebuffer console is enabled by patch series 0001-0018
   and prints before the kernel log is ready.
3. If the screen goes Apple-logo and hangs, get the persistent ring: boot TWRP
   for sunfish temporarily and run `tools/sweet-log-pull.sh logs/boot.txt`.
   The last line tells which subsystem hung.
4. `debug=0xc serial=3` is for the (absent) UART; it does not hurt. The
   framebuffer console is what you see.

## Touch does not work

The FTM5 path logs every stage. Match the log:

| Log | Meaning | Action |
| --- | --- | --- |
| `SWEET TOUCH: PM6150 GPIO4 mode=... src=... en=...` | the load switch state read over SPMI | if the write below fails, see the SPMI row |
| `SWEET SPMI: write ... refused (APID=... not owned by EE 0)` | ABL/TZ did not give the AP the SPMI channel | this is an SPMI ownership problem, not touch; check `sweet_spmi_init`, do not hammer writes |
| `SWEET TOUCH: SE7 firmware unusable; using bit-banged I2C` | the expected Pixel path | continue |
| `SWEET TOUCH: FTM5 never acknowledged on TLMM 6/7` | no ACK on either pad order | power (GPIO4), reset (GPIO8), or the flex; measure 1.8 V on the touch rails |
| `SWEET TOUCH: FTM5 ACK on bit-banged I2C sda=6 scl=7` | the bus works, pad order detected | continue |
| `FTM5 0x49 err=0 ready=1` | the controller booted and sent CONTROLLER_READY | continue |
| `ready=0 err=0` | the IC answers but no READY event (missed during reset) | the driver still sends the scan command; touch may work |
| `err=6` (ENXIO) | no I2C ACK | power/reset/pad order |
| `scan mode active err=0` | sensing is on | touches should now produce HID events |
| `FTM5 error event f3 ...; releasing contacts and rescanning` | the IC reported an error, driver recovered | if it repeats, the panel/IC needs a reset |
| `report err=...` repeated | the I2C transfer fails at runtime | check the bit-bang timing/pull-ups; try `sweettouchbus=1` to see if SE7 is available |

Useful boot arguments:

- `sweettouchbus=0` auto (default), `1` require SE7, `2` force bit-bang.
- `sweettouch=0` disables the driver (display-only boot).
- `sweettouchdelay=N` delays the touch thread by N seconds (default 45) so the
  GUI and log are up before a possibly hanging bus access.

Pad order is not documented in the device tree; the driver tries SDA/SCL =
6/7 then 7/6 and keeps whichever the controller ACKs. Both are open-drain with
the internal pull-up enabled as a backup. If neither ACKs, the problem is
before the protocol: rails, reset, or the switch pin.

The PM6150 GPIO4 sequence is VIN `0x41=1`, pull disable `0x42=5`, CMOS/2 mA
`0x45=2`, output high `0x44=0x80`, mode digital output `0x40=1`, enable
`0x46=0x80`. This mirrors `pinctrl-spmi-gpio`.

## SPMI write refused

`sweet_spmi_write()` only accepts SID 0, addresses `0xc340..0xc346`, and
requires the APID's ownership field to say EE 0. If ABL configured the PMIC
differently, the write is refused and touch power cannot be enabled. The log
prints the APID and the ownership check. Do **not** bypass the ownership check
by writing random channels; first confirm the PMIC arbiter version and the
APID mapping from the live FDT.

## UFS / root problems

| Log | Meaning |
| --- | --- |
| `"userdata" on LUN 0` | the UFS driver found the partition |
| `UFS TUR ... rc/ocs/st=0x00040002` + `UFS SENSE key=2 asc/ascq=0x0402` | NOT READY / INITIALIZING COMMAND REQUIRED: the unit needs SCSI `START STOP UNIT` (0x1B, START=1) before TUR answers. The shim and kernel patch `0028` now send it and retry; expect a `UFS START lun=0` line before the first successful `UFS TUR`. Identical sense on all 8 LUNs is device-level initialization, not a wrong LUN. |
| `hfs: mounted ...` | the HFS+ root image is readable |
| `rootvp not authenticated` + panic | the root was not sealed (patch 0029 should make it continue); check that patch applied in CI |
| `no such file, no dyld cache` | the image lacks a dyld shared cache or the boot args skip ignition; see the sweet notes in `NOTES.md` |
| initproc / launchd panic | the userland is the iPhone X image; this is the sweet bring-up state, not sunfish-specific |

If Android's `userdata` is still there, the iOS root was not flashed (or the
flash went to the wrong partition). `fastboot getvar partition-size:userdata`
must be large enough; use the sparse image, not a raw 16 GiB file (fastboot
will run out of memory).

## USB log does not appear

- The boot args must include `sweetusb=2`.
- The host needs the CDC-ECM interface and `192.168.7.1/24`;
  `tools/sweet-usbnet.sh logs/live.txt` does that (sudo).
- The kernel starts USB late; wait for the UFS/launchd lines first.
- If the phone panics before USB, use TWRP and `tools/sweet-log-pull.sh`.

## Recovering the phone

- Back to the bootloader: hold **Power + Volume down**.
- Boot Android without flashing anything: `fastboot boot backup/boot.img`
  (only works if `boot` was not modified; this port never flashes `boot`).
- Full restore: flash the matching Pixel 4a factory image.
- Never run `fastboot flashing unlock`/`erase`/`format` from a script while
  debugging; the port only needs `fastboot boot` and (optionally)
  `fastboot flash userdata`.
