# ios-sunfish

**Apple's iOS 16 on the Google Pixel 4a.**

This is a port of [ios-sweet](https://github.com/dipa-studio/ios-sweet). That project runs Apple's open-source XNU kernel (xnu-8796, iOS 16 generation) with the **unmodified iOS 16.7.16 userland of the iPhone X** on the Redmi Note 10 Pro. The Pixel 4a (`sunfish`) uses the same Qualcomm SM7150 chip. Most of that work therefore carries over, and this repository adds what differs on the Pixel.

> **Status (2026-10-22): the boot chain and the diagnostic display are verified on a real Pixel 4a; XNU, SpringBoard and touch are not.** `fastboot boot` accepts the 64 MiB LZ4-frame/AVB shim image and the panel shows the red shim diagnostics. The sunfish XNU payload and the iOS root have not been booted, so no SpringBoard or touch test has run. The first-boot checklist is in [`docs/SUNFISH.md`](docs/SUNFISH.md); see [`PORTING_STATUS.md`](PORTING_STATUS.md) for what is verified and what is not.

> Experimental bring-up, not a usable phone OS. Apple's security model is mostly switched off. It installs into the `userdata` partition, so **it erases Android's user data**.

## Status

| Area | sweet (Redmi Note 10 Pro) | sunfish (Pixel 4a) |
| --- | --- | --- |
| Boot (`fastboot boot` shim → XNU) | works | shim accepted by the Pixel ABL and the red diagnostics rendered (H1); XNU payload not booted yet |
| CPUs, memory, interrupts, timers | works (8 cores) | same SoC, same code; untested on sunfish |
| UFS storage, iOS root in `userdata` | works | same SoC, same code; untested on sunfish |
| Display | works (video-mode panel) | shim diagnostics work (command-mode panel + MDP autorefresh); iOS rendering untested |
| iOS GUI (SpringBoard, Settings, Control Center) | works | untested: needs the XNU payload and the root |
| Touch | works (Goodix GT9896) | untested; new ST FTM5 driver path, SE7/FIFO or bit-banged I2C |
| Buttons (power, volume) | works | same PMIC wiring, same code |
| USB networking + live kernel log | works | same USB controller, same code |
| Wi-Fi, Bluetooth, cellular, audio, camera, sensors, GPU, SEP | no | no |

The table under "What does not work" in the sweet README applies here too. Rendering is CPU-only, the first boot takes about 4 minutes on the Apple logo, and there are few apps, no App Store, permissive code signing and a stub keystore.

## How it boots

```
Pixel ABL (unlocked bootloader)
  -> fastboot boot shim-boot.img          (temporary; nothing is flashed to boot_a/boot_b)
     -> shim: turns on display autorefresh, reads the live FDT, loads the payload from the ramdisk
        -> XNU Mach-O + generated Apple Device Tree (ADT) + boot-args
           -> XNU -> UFS driver -> HFS+ root in the userdata partition
              -> dyld + shared cache -> launchd -> backboardd + SpringBoard
```

iOS sees an iPhone X (`iPhone10,3`, 1125x2436). The Pixel's 1080x2340 panel shows the centred part of that screen.

## What is different from sweet

Both phones are SM7150. The CPUs, GIC, RAM layout, the splash framebuffer at `0x9c000000`, UFS, USB, the PM6150/PM6150L PMICs, the buttons and the touch I2C bus are shared, so **one kernel binary runs on both**. Only the boot shim and the device tree are built per phone.

| | sweet | sunfish | Where |
| --- | --- | --- | --- |
| Boot image | Xiaomi layout, text offset 0 | **stock Pixel 4a** header: ramdisk `0x01000000`, tags `0x100`, DTB `0x1f00000`; ABL requires Image text offset **`0x80000`**, an **LZ4 frame** kernel and an unsigned 64 MiB AVB footer | `DEVICE=sunfish shim/build.sh` |
| Panel | 1080x2400, video mode | 1080x2340 Samsung sofef01, **command mode**: the display controller only sends a frame when kicked | `shim/disp.c` enables pingpong autorefresh |
| Touch | Goodix GT9896 @ `0x5d` | in-cell **ST FTM5 @ `0x49`** | kernel patch `0082`, `sweet_touch.c` |
| Touch bus | QUP SE7 I2C | SE7 if ABL loaded GENI firmware; otherwise open-drain I2C bit-banged on TLMM 6/7 (pad order auto-detected) | `0082`, `sweettouchbus=0/1/2` |
| Touch power | L11C via RPMh | panel rails (on from ABL) + load switch on PM6150 GPIO4 | `0082`, `sweet_spmi_write()` (limited to that pin) |
| Device tree | `xiaomi,sweet` | `google,sunfish`; the kernel picks board drivers by it | `tools/mkadt.py --device sunfish` |

Details and register-level notes are in [`docs/SUNFISH.md`](docs/SUNFISH.md).

## How to do it yourself

You need a Pixel 4a (`sunfish`, not the 4a 5G) with an **unlockable bootloader**. Carrier-locked models, Verizon's in particular, cannot be unlocked. You also need a Linux PC and a GitHub account for the kernel build. **Everything on `userdata` is lost.** The bootloaders, modem and persist partitions are never touched.

### 0. Unlock and back up

Enable *OEM unlocking* in Android's developer options, then run `fastboot flashing unlock`. This wipes the phone. Keep a copy of the stock `boot.img` from the factory image that matches your build. Partition backups and device dumps stay out of git; `.gitignore` excludes `backup/`, `dtb/` and `recovery/`.

The shim needs the stock DTB:

```sh
python3 tools/unpack_bootv2.py backup/boot.img dtb/sunfish   # -> dtb/sunfish/dtb
```

### 1. Build the kernel

The kernel builds on GitHub's macOS runners with [blacktop/darwin-xnu-build](https://github.com/blacktop/darwin-xnu-build). The workflow fetches xnu-8796 and applies `xnu/patches/` in order. It also stages the pinned open-source libpthread, HFS and BearSSL sources.

```sh
gh workflow run xnu.yml -R YOU/ios-sunfish
gh run download RUN_ID -R YOU/ios-sunfish -n xnu-kernel -D xnu/out
```

The output is `kernel.development.sweet`. The same binary is used for both phones.

### 2. Build the iOS root image

Same as on sweet. Download the iPhone X (iPhone10,3) iOS 16.7.16 (20H392) IPSW from Apple, then on Linux, with `apfs-fuse`, `hfsprogs` and sudo:

```sh
tools/mkiosroot.sh OS.dmg SystemOS.dmg AppOS.dmg ios16-root.img 16G
sudo fsck.hfsplus -fy ios16-root.img
sudo mount -t hfsplus -o loop,force ios16-root.img /mnt/iosroot
sudo python3 tools/sweet-root-tweaks.py /mnt/iosroot
sudo umount /mnt/iosroot
img2simg ios16-root.img ios16-root.simg
```

`mkiosroot.sh` merges the OS volume and both cryptexes into one case-sensitive journaled HFS+ volume. `sweet-root-tweaks.py` applies the bring-up changes; its header explains each one. The device tree builder also needs `/product` from the real iPhone X device tree:

```sh
python3 tools/remotezip.py IPSW_URL DeviceTree.d22ap.im4p research/ipsw-x/dt
ipsw img4 im4p extract research/ipsw-x/dt/Firmware/all_flash/DeviceTree.d22ap.im4p -o research/ipsw-x/d22ap.adt
```

### 3. Build the boot image

Needs Python 3 and an `aarch64` cross compiler; `scripts/setup-build-env.sh` installs the toolchain (`aarch64-linux-gnu-` on Linux, Homebrew `aarch64-elf-` on macOS). No Android `mkbootimg` is required: `tools/mkbootimg_v2.py` writes the header v2 with the stock Pixel offsets.

```sh
# diagnostic image: no kernel, no root. Boot this first.
scripts/build.sh --shim-only
scripts/check-artifacts.sh --shim-only

# full image: kernel + ADT + boot-args
scripts/build.sh --kernel xnu/out/kernel.development.sweet
```

The equivalent manual steps are:

```sh
python3 tools/mkadt.py shim/out/sunfish.adt --highmem --device sunfish
python3 tools/mkpayload.py xnu/out/kernel.development.sweet shim/out/sunfish.adt shim/out/payload.bin \
    --cmdline 'debug=0xc serial=3 cpus=6 keepsyms=1 -enable_kprintf_spam -noprogress rd=ufsroot0 unentitled_ios_sim_launch=1 ignition_level=1 wdt_test=no_user_checkin ufsrw=1 rootrw=1 launchd_unsecure_cache=1 wdt=-1 sweetfb_noconsole=1 sweetfb_hz=30'
DEVICE=sunfish shim/build.sh shim/out/payload.bin          # -> shim/out/shim-boot.img
```

**First time on a Pixel:** boot the shim *without* a payload first (`scripts/build.sh --shim-only`). It draws diagnostics on a red screen. If the lines keep appearing one after another, the display refresh works. The `DISP` lines show which buffer the display controller scans out. See [`docs/SUNFISH.md`](docs/SUNFISH.md#to-check-on-first-boot).

| Boot-arg | Effect |
| --- | --- |
| `rd=ufsroot0 ufsrw=1 rootrw=1` | Root on the `userdata` partition, writable |
| `cpus=6` | Start the six A55 cores (`cpus=8` adds the A76s, `cpus=1` is the safe fallback) |
| `launchd_unsecure_cache=1` | launchd accepts its job cache without AMFI |
| `wdt=-1 wdt_test=no_user_checkin` | No hardware watchdog |
| `sweetfb_noconsole=1` | Stop drawing kernel text over the GUI (the log is kept; panics are drawn) |
| `sweetfb_hz=30` | Rate of the CPU copy into the framebuffer |
| `sweettouch=0`, `sweetkeys=0` | Disable the touch or button driver |
| `sweettouchbus=0/1/2` | Touch bus: auto (default), require QUP SE7/FIFO, force bit-banged I2C |
| `sweetusb=2` | USB networking with the live kernel log (`tools/sweet-usbnet.sh`) |

### 4. Flash the root and boot

```sh
scripts/flash-sunfish.sh                              # non-destructive: fastboot boot only
scripts/flash-sunfish.sh --flash-root ios16-root.simg # DESTRUCTIVE: writes userdata
```

`--flash-root` checks the product (`sunfish`, not the 4a 5G), the unlocked state and that the sparse image fits `userdata`, then asks you to type `ERASE USERDATA`. Nothing else is written, and the script never unlocks the bootloader. The manual equivalent is `fastboot -S 512M flash userdata ios16-root.simg` followed by `fastboot boot shim/out/shim-boot.img`.

To get back to the bootloader, hold Power + Volume down. Android comes back once you flash a factory image (or just format `userdata`).

### 5. Read the kernel log

The kernel keeps a 4 MiB log ring at the end of `userdata`. Boot a recovery with adb root access (TWRP for sunfish) temporarily and pull it:

```sh
fastboot boot recovery/twrp-sunfish.img
tools/sweet-log-pull.sh logs/boot.txt
```

With `sweetusb=2` the log also streams live over USB (`tools/sweet-usbnet.sh logs/live.txt`). `tools/sweet-crash.py` symbolicates crash reports against the shared cache.

## Repository layout

| Path | What |
| --- | --- |
| `shim/` | Bare-metal boot shim packed as an Android boot.img v2 (`DEVICE=sweet` or `sunfish`); `disp.c` is the command-mode display refresh |
| `xnu/patches/` | The XNU patch series, applied in order by CI; `0082` is the sunfish board support |
| `.github/workflows/xnu.yml` | Kernel CI build |
| `scripts/` | `setup-build-env.sh`, `build.sh`, `check-artifacts.sh`, `flash-sunfish.sh` |
| `tools/mkbootimg_v2.py`, `tools/mknewc.py` | Self-contained boot image v2 packer and deterministic cpio writer |
| `tools/mkadt.py` | Generates the Apple Device Tree (`--device sunfish`) |
| `tools/mkpayload.py` | Packs kernel + ADT + boot-args into the shim payload |
| `tools/mkiosroot.sh`, `sweet-root-tweaks.py` | Build the HFS+ iOS root and apply the bring-up changes |
| `tools/sweet-log-pull.sh`, `sweet-usbnet.sh`, `sweet-log.py`, `sweet-crash.py` | Kernel log over recovery or USB, crash symbolication |
| `tools/qemu-sweet.py` | QEMU test boots for kernel-only changes |
| `PORTING_STATUS.md`, `INSTALL_SUNFISH.md`, `TROUBLESHOOTING.md`, `ACCEPTANCE_TESTS.md` | Honest status, first-install procedure, failure diagnosis, hardware test plan |
| `docs/SUNFISH.md` | Pixel 4a hardware differences and the first-boot checklist |
| `NOTES.md` | Engineering log (mostly the sweet bring-up), plus the current handoff |

Many names still say `sweet` (drivers, boot-args, the `SWEET` machine config). They come from the original port and are shared by both phones.

## Kernel patches

| # | What |
| --- | --- |
| 0001–0018 | Toolchain compatibility, machine config, non-PAC arm64, stubs, early framebuffer console, device-tree platform expert, timer, boot CPU |
| 0019–0034 | libpthread, BearSSL, RAM-disk and UFS root, minimal AMFI, HFS+, DMA above 4 GiB |
| 0035–0057 | Entitlements, AppleKeyStore stub, watchdog, crash reports, IOSurface + IOMobileFramebuffer, persistent log, sandbox policy |
| 0058–0071 | HID services, iPhone X identity, keys and touch, display size, battery, SMP, home gesture |
| 0072–0081 | USB device mode, CDC-ECM networking and live log, 8 cores, display power, network trace |
| 0082 | Pixel 4a (`sunfish`): ST FTM5 touch (SE7/FIFO or bit-banged I2C), PM6150 GPIO4 touch power, panel size from the boot framebuffer, `google,sunfish` platform match |
| 0083 | Adreno 618 bring-up probes, steps 1-10 (`adreno=N`), ported from HackiOS; see [`docs/GPU.md`](docs/GPU.md) |

## Key hardware facts (sunfish)

- SoC SM7150-AB: 6x Cortex-A55 + 2x Cortex-A76, GICv3, PSCI over `smc`, 19.2 MHz timer, no pointer authentication.
- RAM: the payload uses the upper bank, `0x100000000` + `0xfcc00000`.
- Panel: 1080x2340 Samsung sofef01 OLED, DSI command mode, continuous splash at `0x9c000000` (a8r8g8b8, stride 4320).
- Touch: ST FTM5 at I²C `0x49` on QUP SE7 (`0xa84000`) if ABL loaded GENI firmware, otherwise bit-banged on TLMM 6/7; reset GPIO 8, IRQ GPIO 9, IRQ route switch GPIO 72, power switch PM6150 GPIO4.
- Boot image: stock Pixel 4a header v2, kernel `0x8000`, ramdisk `0x01000000`, tags `0x100`, DTB `0x1f00000`, page 4096; the Image header must say `text_offset=0x80000`; the kernel must be an **LZ4 frame** and the image must end in an **unsigned AVB footer** padded to 64 MiB (the stock LineageOS image uses the same scheme).
- Buttons: power and volume down on the PM6150 PON block, volume up on PM6150L GPIO2.
- Storage: UFS at `0x1d84000`, `userdata` on LUN 0.

Sources: the device trees and drivers in Google's `msm-4.14` kernel, the mainline `sm7150-google-sunfish.dts`, and `device/google/sunfish`.

## Credits

Built on [ios-sweet](https://github.com/dipa-studio/ios-sweet) and Apple's open-source releases (xnu, IOHIDFamily, libpthread, hfs). Also uses [BearSSL](https://bearssl.org), [blacktop/darwin-xnu-build](https://github.com/blacktop/darwin-xnu-build) and [ipsw](https://github.com/blacktop/ipsw). Hardware details come from Google's and Qualcomm's published kernel sources. iOS itself is Apple's and is not distributed here.
