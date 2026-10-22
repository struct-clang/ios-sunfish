# Acceptance tests: Pixel 4a (sunfish)

Status legend: `PASS` (observed on the phone), `FAIL`, `NOT RUN` (blocked),
`N/A`. **No test below has been run on hardware.** The phone was not connected
during the work on 2026-10-22 (`fastboot devices` and `adb devices` were
empty), so every hardware row is `NOT RUN`. Do not mark a row PASS from a
photo of a logo or from a kernel log alone; the evidence column says what is
required.

## Offline checks (already run)

| ID | Check | Result | Evidence |
| --- | --- | --- | --- |
| O1 | Patch series applies to a fresh `xnu-8796.141.3` tree; the new `0082` reproduces the edited tree | PASS (0031/0041 pre-existing failures) | `git apply --check`, byte compare in the scratch tree |
| O2 | `sweet_touch.c` parses with the kernel headers | PASS | `clang -fsyntax-only` (only pre-existing implicit `delay`) |
| O3 | Shim cross-builds for sunfish; Image header and boot image header match the stock v2 layout | PASS | `scripts/check-artifacts.sh` output |
| O4 | Stock `boot.img` repacked with `tools/mkbootimg_v2.py` round-trips kernel/ramdisk/DTB | PASS | byte-identical payloads, identical fields |
| O5 | `mkadt.py --device sunfish` emits `google,sunfish` and a 1080x2340 framebuffer | PASS | ADT parsed with `tools/adt.py` |

Offline PASS only means "the tools and files are consistent". It says nothing
about ABL, the panel, the touch IC or iOS.

## Hardware tests

Run them in order. Each test is useful even if the later ones fail, and each
has a stop condition.

### H1 — ABL accepts the image and the shim runs

- Prerequisites: unlocked bootloader, `shim/out/shim-boot.img` built with
  `scripts/build.sh --shim-only` (payload-less), stock DTB present.
- Procedure: `scripts/flash-sunfish.sh` (temporary `fastboot boot`).
- Pass criteria: within ~10 s a red screen shows `SHIM`, the FDT/`DISP` lines,
  and the text keeps appearing. No reboot into Android, no `FAILED` from
  fastboot.
- Evidence: photo or short video of the whole screen, plus the serial text of
  the `DISP SRC` / `DISP PP` lines.
- Stop if: the phone reboots or the screen never changes (see
  `TROUBLESHOOTING.md`).
- **Status: NOT RUN (no device).**

### H2 — The shim keeps the command-mode panel refreshing

- Prerequisites: H1 PASS.
- Procedure: watch the shim screen for 30 s without touching the phone.
- Pass criteria: the lines continue to appear and the panel does not freeze on
  the first frame (the pingpong autorefresh works). `DISP PP ... ar now=80000001`
  is printed and `DISP SRC` points at `0x9c000000` with size `0x09240438`.
- Evidence: video covering at least 30 s; a second photo after the text stops.
- **Status: NOT RUN.**

### H3 — XNU boots from the payload and reaches UFS/launchd

- Prerequisites: H1/H2 PASS; CI kernel `xnu/out/kernel.development.sweet`;
  `scripts/build.sh --kernel ...`; TWRP (or `sweetusb=2`) for the log.
- Procedure: boot the full image (still `fastboot boot`), wait up to 10 min,
  then pull the persistent log.
- Pass criteria: the log contains the early XNU markers, `"userdata" on LUN 0`,
  `hfs: mounted`, launchd/backboardd lines. A panic is a FAIL; a hang with no
  new log line for 2 min is a FAIL.
- Evidence: `logs/boot-sunfish-H3.txt` (keep device-specific logs out of git),
  photo of the Apple logo phase.
- **Status: NOT RUN.**

### H4 — SpringBoard is visible on the internal display

- Prerequisites: H3 PASS; the iOS root image flashed to `userdata`.
- Procedure: boot, wait for the lock/home screen.
- Pass criteria: SpringBoard's UI (lock screen, home screen with icons, status
  bar) is rendered on the 1080x2340 panel and the backlight is on. A kernel
  text console or the Apple logo alone does **not** pass.
- Evidence: photo/video with the phone visible and no cable obscuring the
  panel; include a `date` printout next to the screen in one frame.
- **Status: NOT RUN.**

### H5 — Touch events reach iOS HID (taps)

- Prerequisites: H4 PASS; touch logs show `scan mode active err=0` and no
  repeating `FTM5 error event`.
- Procedure:
  1. On the home screen, tap an app icon and wait for it to open.
  2. Tap the home indicator / swipe up to return.
  3. Open Control Center or Settings and tap a switch.
- Pass criteria: the UI reacts at the touched coordinates; the app opens or
  the switch changes state. The kernel log must show the FTM5 path selected
  (`selected ST FTM5` and either the SE7 or the bit-banged ACK line).
- Evidence: continuous video of the screen during the taps; the log; note the
  `sweettouchbus` value used.
- **Status: NOT RUN.**

### H6 — Swipes and press/move/release

- Prerequisites: H5 PASS.
- Procedure:
  1. Swipe left/right between home-screen pages.
  2. Swipe down from the top for Control Center and up to dismiss.
  3. Long-press an icon until the context menu appears, then cancel.
  4. Start dragging an icon and cancel before dropping.
- Pass criteria: every gesture is recognised; a tap that is reported as a drag
  (or vice versa) is a FAIL. This exercises press, motion and release, not just
  the first event.
- Evidence: one continuous video showing the sequence, plus the kernel log for
  the same boot.
- **Status: NOT RUN.**

### H7 — Reproducible build

- Prerequisites: a clean checkout and the CI kernel.
- Procedure: run `scripts/build.sh --kernel ...` twice; compare SHA256 of
  `Image`, `shim-boot.img`, ADT and payload. Re-run the CI workflow on the same
  commit and compare the kernel hash.
- Pass criteria: identical local artifacts; the CI kernel hash is recorded with
  the run ID. The ADT/payload/shim have no timestamps and the cpio is
  deterministic.
- Evidence: `shasum -a 256` output for both runs and the CI run ID.
- **Status: NOT RUN (local build with the real kernel not done; the payload-less
  shim was built twice with the same hash).**

### H8 — Safety: no unintended partition writes

- Prerequisites: the scripts in this repository.
- Procedure: inspect `scripts/flash-sunfish.sh` and the session history; boot
  H1/H3 without `--flash-root`.
- Pass criteria: only `fastboot boot` is used; `boot`, `dtbo`, `recovery`,
  `modem`, `persist`, `userdata` are unchanged. `--flash-root` is the only
  path that writes, and it requires the typed confirmation.
- Evidence: `fastboot getvar all` before/after (hashes of the unchanged
  partitions are not readable, so record the `getvar` dump and the commands
  used).
- **Status: NOT RUN on hardware; the script path was reviewed and dry-run
  preflight fails before touching the phone.**

## Final acceptance

The port is accepted only when H1-H6 are PASS with evidence, H7 reproduces the
artifacts, and H8 shows no unintended writes. Until then the correct status is
"ported, not accepted" (see `PORTING_STATUS.md`).
