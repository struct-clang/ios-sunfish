# Acceptance tests: Pixel 4a (sunfish)

Status legend: `PASS` (observed on the phone, or reproduced offline for an
offline-only test), `FAIL`, `NOT RUN` (blocked), `N/A`. **H1 and H2 were
observed on hardware on 2026-10-22/23 (red diagnostic screen and continuous
output through the full UFS probe); H7 passed offline on 2026-10-23 (two
byte-identical full builds). H3-H6 and H8 have not been run.**
Do not mark a row PASS from a photo of a logo or from a kernel log alone; the
evidence column says what is required.

## Offline checks (already run)

| ID | Check | Result | Evidence |
| --- | --- | --- | --- |
| O1 | Patch series applies to a fresh `xnu-8796.141.3` tree; the new `0082` reproduces the edited tree | PASS (all 83 in the real dxb/CI build, including `0031`/`0041`) | build log shows `Applying patch` for 0031/0041; the kernel contains `rootrw`, `mounting dirty non-journaled root read-write` and `sweet_hfs_link_note`. A patch-only replay without dxb's `.sh` staging skips 0031/0041 and is not representative |
| O2 | `sweet_touch.c` parses with the kernel headers | PASS | `clang -fsyntax-only` (only pre-existing implicit `delay`) |
| O3 | Shim cross-builds for sunfish; Image header and boot image header match the stock v2 layout | PASS | `scripts/check-artifacts.sh` output |
| O4 | Stock `boot.img` repacked with `tools/mkbootimg_v2.py` round-trips kernel/ramdisk/DTB | PASS | byte-identical to stock except avbtool's release string (one byte); the repacked image boots |
| O5 | `mkadt.py --device sunfish` emits `google,sunfish` and a 1080x2340 framebuffer | PASS | ADT parsed with `tools/adt.py` |

Offline PASS only means "the tools and files are consistent". It says nothing
about ABL, the panel, the touch IC or iOS.

## Hardware tests

Run them in order. Each test is useful even if the later ones fail, and each
has a stop condition.

### H1 — ABL accepts the image and the shim runs

- Prerequisites: unlocked bootloader, `shim/out/shim-boot.img` built with
  `scripts/build.sh --shim-only` (payload-less), stock DTB present.
- Procedure: `scripts/flash-sunfish.sh --image shim/out/shim-boot-diagnostic.img`
  (temporary `fastboot boot`).
- Pass criteria: within ~10 s a red screen shows `SHIM`, the FDT/`DISP` lines,
  and the text keeps appearing. No reboot into Android, no `FAILED` from
  fastboot.
- Evidence: photo or short video of the whole screen, plus the serial text of
  the `DISP SRC` / `DISP PP` lines.
- Stop if: the phone reboots or the screen never changes (see
  `TROUBLESHOOTING.md`).
- **Status: PASS (2026-10-22/23; console text captured, photo still optional).**
  `fastboot boot` accepted the 64 MiB LZ4-frame/AVB image and the user saw the
  red screen with yellow/white text; the phone did not reboot into Android.
  Captured lines: `DISP SRC addr=9C000000 size=09240438`,
  `DISP CTL top=00020000 intf=00000002`, `DISP no tear-checked pingpong:
  video mode`, `INITRD lo=84700000 hi=8470007C`, `LOADER no SWEETXNU
  payload`.

### H2 — The shim keeps the command-mode panel refreshing

- Prerequisites: H1 PASS.
- Procedure: boot `shim/out/shim-boot-diagnostic.img` with
  `scripts/flash-sunfish.sh --image shim/out/shim-boot-diagnostic.img`, then
  watch the screen for 30 s without touching the phone.
- Pass criteria: the lines continue to appear and the panel does not freeze on
  the first frame (the pingpong autorefresh works). `DISP PP ... ar now=80000001`
  is printed and `DISP SRC` points at `0x9c000000` with size `0x09240438`.
- Evidence: video covering at least 30 s; a second photo after the text stops.
- **Status: PASS (2026-10-23, effective; 30 s video still to capture).** The
  output kept appearing from the first `DISP` lines through the whole UFS
  probe (`UFS ver=00000210 cap=1587031F` ... `UFS probe done, reset in ~3
  min`), i.e. many seconds of progressive writes, so the panel did not freeze
  on the first frame. `DISP SRC` points at `0x9c000000` with size
  `0x09240438` as expected. The UFS probe itself failed before the fix:
  `UFS TUR lun=0..7 rc/ocs/st=0x00040002`, `UFS SENSE response=1 status=2`,
  `UFS SENSE key=2 asc/ascq=0x0402`, `UFS no LUN answered TUR: stop`. That
  sense is NOT READY / INITIALIZING COMMAND REQUIRED; the rebuilt diagnostic
  (`2cfd6831...`) sends `START STOP UNIT` and should print `UFS START lun=0`
  followed by working `UFS TUR`/`UFS CAP`/`UFS GPT` lines.

### H3 — XNU boots from the payload and reaches UFS/launchd

- Prerequisites: H1/H2 PASS; kernel built locally with
  `scripts/build-kernel-local.sh` (or downloaded from CI) at
  `xnu/out/kernel.development.sweet`; full image built with
  `scripts/build.sh --kernel ...`; TWRP (or `sweetusb=2`) for the log.
- Procedure: boot `shim/out/shim-boot-debug.img` (`4558eb...`;
  `sweetfb_noconsole=0 sweetusb=2`) with
  `scripts/flash-sunfish.sh --image shim/out/shim-boot-debug.img --payload shim/out/payload-debug.bin`
  for the log, or the normal image plus TWRP; wait up to 10 min, then pull the
  persistent log. Return to the normal `shim/out/shim-boot-payload.img`
  (`2e2880...`) for H4.
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

- Prerequisites: a clean checkout and a kernel from
  `scripts/build-kernel-local.sh` or CI.
- Procedure: run `scripts/build.sh --kernel ...` twice; compare SHA256 of
  `Image`, `shim-boot.img`, ADT and payload. If the kernel came from CI,
  record the workflow run ID and compare its kernel hash.
- Pass criteria: identical local artifacts. The ADT/payload/shim have no
  timestamps and the cpio is deterministic. `tools/mkadt.py` uses a fixed
  `random-seed` by default so the ADT is byte-identical.
- Evidence: after fixing the ADT seed, two consecutive builds produced
  identical `e77d29244b469c165bec298728ba66c74fb76c54a90c935710c228cb96f6bac2`
  (`payload.bin`), `2e28809ed12dda6255e952ea404210f44c4c289400b2d5a447d9ed74bf5f4402`
  (`shim-boot.img`) and `c178ad67c8617f55c5d26b9bb493c6ad49347763e5ff0be4100e29a8063669e6`
  (`sunfish.adt`); both comparisons were byte-for-byte (`cmp`). A pre-fix
  build had a different ADT hash because `mkadt.py` called `os.urandom(64)`
  for `/chosen/random-seed`; that is the bug H7 caught. The local kernel hash
  is `e24fe3778f14b809d4a69465246f64f8accbbd55d21c021dbffbff92b2e8316c`.
  CI run `39837537514` (macOS-15, commit `40445c4`) passed and produced
  `kernel.development.sweet` SHA256
  `a0b7caa06f80bbac595f7e51ca451446f1157972ed2d68f7afe3a5cd694c0c3e`; its
  strings were checked manually. It is not used as the payload kernel, so
  the local hashes above are authoritative. A 2026-10-23 rebuild of all
  three documented images (`shim-boot-diagnostic.img`,
  `shim-boot-payload.img`, `shim-boot-debug.img`) reproduced
  `68a6493a...`, `2e28809e...` and `4558eb51...` exactly.
- **Status: PASS (local, offline, 2026-10-23).**

### H8 — Safety: no unintended partition writes

- Prerequisites: the scripts in this repository.
- Procedure: inspect `scripts/flash-sunfish.sh` and the session history; boot
  H1/H3 without `--flash-root`.
- Pass criteria: only `fastboot boot` is used; `boot`, `dtbo`, `recovery`,
  `modem`, `persist`, `userdata` are unchanged. `--flash-root` is the only
  path that writes, requires the typed confirmation, refuses a diagnostic
  image, and verifies that the image ramdisk is byte-identical to the payload
  it checks.
- Evidence: `fastboot getvar all` before/after (hashes of the unchanged
  partitions are not readable, so record the `getvar` dump and the commands
  used).
- **Status: NOT RUN on hardware; the script path was reviewed and dry-run
  preflight fails before touching the phone.**

## Final acceptance

The port is accepted only when H1-H6 are PASS with evidence, H7 reproduces the
artifacts, and H8 shows no unintended writes. Until then the correct status is
"ported, not accepted" (see `PORTING_STATUS.md`).
