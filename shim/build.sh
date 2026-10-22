#!/bin/bash
# Build the shim and wrap it in a boot.img v2 that mirrors the stock header.
#   DEVICE=sweet   (default) Redmi Note 10 Pro, stock DTB from dtb/boot_unpacked/dtb
#   DEVICE=sunfish Pixel 4a,  stock DTB from dtb/sunfish/dtb
# DTB=path overrides the stock DTB location.
#
# Toolchain: CROSS=<prefix> (default: first of aarch64-linux-gnu-,
# aarch64-elf-, aarch64-none-elf- found in PATH), or override CC/OBJCOPY/NM/
# READELF individually. HOSTCC builds the framebuffer layout test.
# The boot image is packed by tools/mkbootimg_v2.py, so no Android tools are
# needed and the header layout is the same on macOS and Linux.
set -euo pipefail
# Absolute payload path before entering shim/, so both
#   shim/build.sh shim/out/payload.bin      (from the repo root)
#   ./build.sh out/payload.bin              (from shim/)
# work.
PAYLOAD=${1:-}
if [ -n "$PAYLOAD" ]; then
	case "$PAYLOAD" in
	/*) ;;
	*)	d=$(dirname "$PAYLOAD")
		[ -d "$d" ] || { echo "error: payload directory $d not found" >&2; exit 1; }
		PAYLOAD=$(cd "$d" && pwd)/$(basename "$PAYLOAD")
		;;
	esac
fi
cd "$(dirname "$0")"
DEVICE=${DEVICE:-sweet}
ROOT=$(cd .. && pwd)

if [ -z "${CROSS:-}" ]; then
	for c in aarch64-linux-gnu- aarch64-elf- aarch64-none-elf-; do
		if command -v "${c}gcc" >/dev/null 2>&1; then
			CROSS=$c
			break
		fi
	done
fi
if [ -z "${CROSS:-}" ] && { [ -z "${CC:-}" ] || [ -z "${OBJCOPY:-}" ] || [ -z "${NM:-}" ] || [ -z "${READELF:-}" ]; }; then
	echo "error: no aarch64 cross toolchain found (looked for aarch64-linux-gnu-, aarch64-elf-, aarch64-none-elf-)" >&2
	echo "       brew install aarch64-elf-gcc   (macOS) / apt install gcc-aarch64-linux-gnu (Linux)" >&2
	exit 1
fi
CC=${CC:-${CROSS:-}gcc}
OBJCOPY=${OBJCOPY:-${CROSS:-}objcopy}
NM=${NM:-${CROSS:-}nm}
READELF=${READELF:-${CROSS:-}readelf}
HOSTCC=${HOSTCC:-cc}
for tool in "$CC" "$OBJCOPY" "$NM" "$READELF"; do
	if ! command -v "$tool" >/dev/null 2>&1; then
		echo "error: $tool not found (set CROSS, or CC/OBJCOPY/NM/READELF)" >&2
		echo "       e.g. brew install aarch64-elf-gcc" >&2
		exit 1
	fi
done

CFLAGS="-O2 -ffreestanding -nostdlib -fno-pic -fno-pie -mgeneral-regs-only -mstrict-align -fno-stack-protector -Wall -Wextra"
case "$DEVICE" in
sweet)
	# 1080x2400 video-mode panel; Xiaomi/PixelOS boot.img layout.
	DTB=${DTB:-../dtb/boot_unpacked/dtb}
	MKBOOTIMG_LAYOUT="--kernel_offset 0x8000 --ramdisk_offset 0x1000000 --tags_offset 0x100 --dtb_offset 0x1f00000"
	;;
sunfish)
	# 1080x2340 command-mode panel (disp.c). Offsets are the ones in the
	# stock Pixel 4a boot.img header (RAMDISK_ADDR 0x01000000, TAGS 0x100),
	# not the LineageOS BoardConfig values. Pixel ABL also rejects an Image
	# header text_offset other than 0x80000.
	CFLAGS="$CFLAGS -DFB_H=2340 -DCMD_MODE_PANEL -DTEXT_OFFSET=0x80000"
	DTB=${DTB:-../dtb/sunfish/dtb}
	MKBOOTIMG_LAYOUT="--kernel_offset 0x8000 --ramdisk_offset 0x01000000 --tags_offset 0x100 --dtb_offset 0x1f00000"
	;;
*)
	echo "error: unknown DEVICE=$DEVICE (sweet or sunfish)" >&2
	exit 1
	;;
esac
OBJS="start shim console mmu fdt loader ufs disp"
mkdir -p out
# Keep out/payload.bin and out/*.adt: scripts/build.sh creates them here.
rm -f out/*.o out/Image out/shim.elf out/shim-boot.img out/host_test out/ramdisk.bin
rm -rf out/boot-check
for f in start.S shim.c console.c mmu.c fdt.c loader.c ufs.c disp.c; do
	$CC $CFLAGS -c $f -o out/${f%.*}.o
done
# The image runs wherever ABL puts it with no relocation pass: only the
# header's image_size (start.o, linked at 0) may be an absolute address.
abs=$($READELF -r $(for o in $OBJS; do [ $o = start ] || echo out/$o.o; done) | grep -c ABS64 || true)
[ "$abs" = 0 ] || { echo "error: $abs absolute relocations in C objects" >&2; exit 1; }
$CC $CFLAGS -static -nostdlib -T shim.ld -Wl,--build-id=none -Wl,-N \
	-Wl,--no-warn-rwx-segments \
	$(for o in $OBJS; do echo out/$o.o; done) -o out/shim.elf
$OBJCOPY -O binary out/shim.elf out/Image
# ABL copies the file; pad to image_size so .bss/stacks exist as zeroed bytes.
size=$($NM out/shim.elf | python3 -c 'import sys
for line in sys.stdin:
	f = line.split()
	if len(f) == 3 and f[2] == "_end":
		print(int(f[0], 16)); break
else:
	sys.exit("error: _end not found")')
truncate -s "$size" out/Image
# Ramdisk: an xnu payload (tools/mkpayload.py) if given as the first
# argument, else the smallest valid newc archive, which ABL accepts and the
# shim reports on.
if [ -n "$PAYLOAD" ]; then
	[ -f "$PAYLOAD" ] || { echo "error: payload $PAYLOAD not found" >&2; exit 1; }
	cp "$PAYLOAD" out/ramdisk.bin
else
	python3 "$ROOT/tools/mknewc.py" out/ramdisk.bin
fi
[ -f "$DTB" ] || { echo "error: stock DTB $DTB missing (see README: unpack the stock boot.img)" >&2; exit 1; }
# The boot image os_version/os_patch_level are informational (AVB rollback
# lives in vbmeta, not here); use the values from the phone's own boot.img.
# shellcheck disable=SC2086 # MKBOOTIMG_LAYOUT is a list of arguments
python3 "$ROOT/tools/mkbootimg_v2.py" --header_version 2 \
	--kernel out/Image --ramdisk out/ramdisk.bin --dtb "$DTB" \
	$MKBOOTIMG_LAYOUT --pagesize 4096 \
	--os_version 17.0.0 --os_patch_level 2026-10 \
	--cmdline "console=null" -o out/shim-boot.img
if [ "$DEVICE" = sunfish ]; then
	# The Pixel ABL refuses to boot an image without an AVB footer, even in
	# the unlocked state ("Error verifying the received boot.img:
	# Unsupported"). The stock LineageOS boot.img uses an unsigned footer
	# (algorithm NONE), so do the same; no Google key is needed. The image
	# is padded to the boot partition size, as avbtool expects.
	BOOT_PARTITION_SIZE=${BOOT_PARTITION_SIZE:-67108864}
	AVB_SALT=${AVB_SALT:-4fb1e4d36a10bec75e63f86e57ddf58d92394b26b9e1e1cd3e0e341aad1dc838}
	python3 "$ROOT/tools/avbtool.py" add_hash_footer \
		--image out/shim-boot.img --partition_name boot \
		--partition_size "$BOOT_PARTITION_SIZE" \
		--algorithm NONE --salt "$AVB_SALT"
	printf 'AVB footer       algorithm NONE, partition %s\n' "$BOOT_PARTITION_SIZE"
fi
# Prove the header we wrote matches the stock field layout.
python3 "$ROOT/tools/unpack_bootv2.py" out/shim-boot.img out/boot-check >/dev/null
for key in kernel_addr ramdisk_addr tags_addr dtb_addr page_size header_version; do
	printf '%-16s %s\n' "$key" "$(sed -n "s/^$key: //p" out/boot-check/header.txt)"
done
# Host render of the console layout.
HOST_DEFS=$(echo "$CFLAGS" | grep -o -- '-DFB_H=[0-9]*' || true)
$HOSTCC -O1 -Wall $HOST_DEFS -o out/host_test console.c host_test.c
./out/host_test
echo "DEVICE=$DEVICE"
ls -l out/Image out/shim-boot.img
shasum -a 256 out/Image out/shim-boot.img 2>/dev/null || sha256sum out/Image out/shim-boot.img
