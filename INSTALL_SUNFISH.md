# Installing iOS 16 on the Pixel 4a (sunfish)

This is the end-to-end procedure for the **Pixel 4a 4G** (`sunfish`, SM7150).
It is not for the 4a 5G (`bramble`) and not for any other Pixel.

> **Read this first:** the boot chain and the red diagnostic screen have been
> verified on a Pixel 4a (2026-10-22); XNU, SpringBoard and touch have not.
> Everything from step 5 on is written for the first attempt and is expected to
> need debugging. Every destructive step is marked; nothing is automatic. See
> [`PORTING_STATUS.md`](PORTING_STATUS.md) for what is and is not verified.

## What you need

- Pixel 4a 4G with an **unlockable** bootloader and *OEM unlocking* enabled.
  Verizon models cannot be unlocked.
- The stock `boot.img` that matches the build installed on the phone (factory
  image or a backup). It contains the device tree the shim needs.
- Linux or macOS with `fastboot` and `adb` (Android platform-tools), Python 3,
  and an `aarch64` cross compiler (`scripts/setup-build-env.sh` installs it).
- A GitHub account for the CI kernel build, or macOS with Xcode 16 for a local
  build.
- The iPhone X (iPhone10,3) iOS 16.7.16 (20H392) IPSW and a Linux machine to
  build the HFS+ root image (`tools/mkiosroot.sh`, see the README).
- About an hour, and a USB cable that stays connected.

Everything on `userdata` is lost when you flash the iOS root. The bootloader,
`boot`, `dtbo`, `recovery`, `modem`, `persist` and the other partitions are
never touched by these scripts.

## 0. Keep the phone recoverable

1. Copy the stock `boot.img` off the phone's firmware package (or pull it):

   ```sh
   adb shell su -c 'dd if=/dev/block/by-name/boot of=/sdcard/boot.img'
   adb pull /sdcard/boot.img backup/boot.img
   ```

   Keep `backup/` out of git (it is in `.gitignore`).
2. Note the exact Android build (`adb shell getprop ro.build.display.id`) so you
   can download the matching factory image later.
3. Verify `fastboot devices` sees exactly one phone before every destructive
   step.

## 1. Unlock (only if it is not already unlocked)

Enable *Developer options → OEM unlocking*, then:

```sh
fastboot flashing unlock
```

This wipes Android. **The scripts in this repository never unlock or erase
anything on their own.**

## 2. Build the kernel

Two equivalent paths produce `xnu/out/kernel.development.sweet`.

### CI

The workflow uses `macos-15` (Xcode 16), fetches `xnu-8796.141.3`, installs
the 13.5 KDK, applies `xnu/patches/*.patch` in order and uploads
`kernel.development.sweet`:

```sh
git push fork sunfish-port
gh workflow run xnu.yml -R <you>/ios-sunfish
gh run watch
gh run download <RUN_ID> -n xnu-kernel -D xnu/out
```

### Local macOS build

Xcode 16.2 builds this tree (verified 2026-10-22); no GitHub runner is
required. The script downloads the 13.5 KDK (~660 MiB), expands it into
`.build/kernel` (no `sudo`, no system install), clones the pinned
`blacktop/darwin-xnu-build` revision, copies the board patches and builds:

```sh
scripts/build-kernel-local.sh                 # DEVELOPMENT, SWEET
# optional: WORK=/path/with/space scripts/build-kernel-local.sh
```

It finishes by printing the SHA256 and checking for `google,sunfish`,
`SWEET TOUCH: selected ST FTM5`, `SWEET TOUCH: FTM5 ACK on bit-banged I2C`
and `SWEET TOUCH: PM6150 GPIO4`.

Check either build: patch `0082-sunfish-board-support.patch` must be listed
as applied, and the board strings must be present. If the build skips `0031`
or `0041`, read `PORTING_STATUS.md` before expecting a writable root.

## 3. Extract the stock DTB

```sh
python3 tools/unpack_bootv2.py backup/boot.img dtb/sunfish
# -> dtb/sunfish/dtb (341135 bytes on the tested stock image)
```

`dtb/` is ignored by git; the DTB is device data.

## 4. Build the shim and the boot image

The diagnostic image first (no kernel, no root needed):

```sh
scripts/build.sh --shim-only
scripts/check-artifacts.sh --shim-only
```

This produces `shim/out/shim-boot.img` with the stock v2 header fields
(kernel `0x8000`, ramdisk `0x01000000`, tags `0x100`, DTB `0x1f00000`), an
Image with `text_offset=0x80000`, an **LZ4 frame** kernel and an unsigned AVB
hash footer padded to the 64 MiB boot partition. The check must print `ok` for
every line, including `kernel is LZ4 frame` and `AVB footer present`.

Then boot it **temporarily**:

```sh
scripts/flash-sunfish.sh
```

Nothing is written to flash; this is `fastboot boot`. Expected result:

- a red screen with yellow and white text (`SHIM`, `DISP SRC`, `DISP PP`, FDT
  lines). This was observed on the phone on 2026-10-22;
- the lines appear one after another, because the shim prints as it probes;
- the screen keeps updating. If it freezes after the first frame, the command
  mode autorefresh did not take (see `TROUBLESHOOTING.md`).

If the phone reboots into Android instead, ABL rejected the image. Record the
last screen and read `TROUBLESHOOTING.md` before trying anything else.

## 5. Build the real payload

```sh
scripts/build.sh --kernel xnu/out/kernel.development.sweet
```

This creates `shim/out/sunfish.adt` (`google,sunfish`, 1080x2340),
`shim/out/payload.bin` (kernel + ADT + boot arguments) and the boot image with
the payload as its ramdisk. The default boot arguments are:

```
debug=0xc serial=3 cpus=6 keepsyms=1 -enable_kprintf_spam -noprogress
rd=ufsroot0 unentitled_ios_sim_launch=1 ignition_level=1
wdt_test=no_user_checkin ufsrw=1 rootrw=1 launchd_unsecure_cache=1
wdt=-1 sweetfb_noconsole=1 sweetfb_hz=30
```

The root is taken from the internal UFS `userdata` partition, not from a RAM
disk. Do not add `rd=md0` unless you built the root as a payload segment.

Boot it with `scripts/flash-sunfish.sh` (still non-destructive).

## 6. Flash the iOS root (destructive)

Build the HFSX image exactly as for sweet (iPhone X 16.7.16, 16 GiB, see the
README), then:

```sh
scripts/flash-sunfish.sh --flash-root /path/to/ios16-root.simg
```

The script checks the product, the unlocked state, the sparse image size
against `partition-size:userdata`, and asks you to type `ERASE USERDATA`.
Then it boots the shim.

Expected boot sequence on the phone:

1. red shim diagnostics, then the payload is loaded and XNU starts;
2. the Apple logo phase (CPU rendering, can take minutes on the first boot);
3. UFS line `"userdata" on LUN 0`, HFS+ mounts the iOS root;
4. launchd, backboardd, SpringBoard.

The acceptance criteria and the exact evidence to capture are in
[`ACCEPTANCE_TESTS.md`](ACCEPTANCE_TESTS.md).

## 7. Touch-specific notes

The FTM5 is on I2C `0x49`, reset GPIO 8, IRQ GPIO 9, switch GPIO 72; power is
the PM6150 GPIO4 load switch. The kernel first tries the shared QUP SE7/FIFO
path. If the Pixel ABL did not load GENI firmware into SE7 (the current
assumption), it falls back to bit-banged I2C on TLMM 6/7 and auto-detects the
SDA/SCL order. The log tells you which path ran:

```
SWEET TOUCH: SE7 firmware unusable; using bit-banged I2C
SWEET TOUCH: FTM5 ACK on bit-banged I2C sda=6 scl=7
SWEET TOUCH: FTM5 scan mode active err=0 (unlock=0)
```

Override with boot arguments if needed:

| Boot arg | Effect |
| --- | --- |
| `sweettouchbus=0` | auto (default) |
| `sweettouchbus=1` | require the SE7/FIFO path; fail if the firmware is absent |
| `sweettouchbus=2` | force bit-banged I2C |

Add `sweettouch=0` to disable the touch driver entirely for a boot that only
tests the display.

## 8. Logs

- `sweetusb=2` (add it to the `--cmdline`) streams the kernel log over USB;
  `tools/sweet-usbnet.sh logs/live.txt` receives it.
- Otherwise the 4 MiB persistent ring at the end of `userdata` survives a
  reboot; pull it from TWRP with `tools/sweet-log-pull.sh logs/boot.txt`.

## 9. Going back to Android

Download the factory image for the build you noted in step 0 and flash it with
`flash-all.sh` (or restore the `boot`/`userdata` backups). Nothing in this
repository modified the bootloader, so an unlocked Pixel 4a always comes back
this way.

## Current status

The boot chain (steps 0-4) has been exercised on a real Pixel 4a on
2026-10-22: the stock, repacked-stock and payload-less shim images boot via
`fastboot boot`, and the shim renders the red diagnostic screen. The XNU
payload (step 5), the root flash (step 6) and the touch/SpringBoard tests have
**not** been run. Treat every expected result from step 5 on as a hypothesis
and record what actually happens.
