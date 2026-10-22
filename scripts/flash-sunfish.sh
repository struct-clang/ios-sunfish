#!/bin/bash
# Safe Pixel 4a (sunfish) installer.
#
#   scripts/flash-sunfish.sh                 # preflight + temporary `fastboot boot`
#   scripts/flash-sunfish.sh --flash-root IMG  # DESTRUCTIVE: writes userdata
#
# By default nothing is written to the phone: the shim is booted with
# `fastboot boot`, exactly like `fastboot boot image.img`.
#
# --flash-root replaces the userdata partition (the iOS HFS+ root). It asks for
# an interactive confirmation, refuses a non-tty, and also refuses to run if
# the phone is not a plain `sunfish` (the 4a 5G is a different board), if the
# bootloader is locked, or if the image does not fit. It never unlocks the
# bootloader, never flashes boot/recovery/modem/persist, and never erases
# anything on its own.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

IMAGE=shim/out/shim-boot.img
ROOT_IMG=
DTB=${DTB:-dtb/sunfish/dtb}
ADT=shim/out/sunfish.adt
PAYLOAD=shim/out/payload.bin
ASSUME_YES=0

usage() {
	cat <<'EOF'
usage: scripts/flash-sunfish.sh [options]

  --image PATH        boot image to boot (default shim/out/shim-boot.img)
  --payload PATH      payload expected inside a full image
                      (default shim/out/payload.bin; use the debug payload for
                      shim-boot-debug.img)
  --adt PATH          ADT to validate for a full image (default shim/out/sunfish.adt)
  --dtb PATH          stock DTB used by the artifact check (default dtb/sunfish/dtb)
  --flash-root IMG    DESTRUCTIVE: flash IMG to userdata first
  --yes               skip the "type ERASE USERDATA" prompt (still needs a tty)
  -h, --help

Nothing is written to flash unless --flash-root is given.
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
	--image) IMAGE=$2; shift 2 ;;
	--payload) PAYLOAD=$2; shift 2 ;;
	--adt) ADT=$2; shift 2 ;;
	--dtb) DTB=$2; shift 2 ;;
	--flash-root) ROOT_IMG=$2; shift 2 ;;
	--yes) ASSUME_YES=1; shift ;;
	-h|--help) usage; exit 0 ;;
	*) echo "error: unknown argument $1" >&2; usage >&2; exit 1 ;;
	esac
done

fail() { echo "error: $*" >&2; exit 1; }

command -v fastboot >/dev/null 2>&1 || fail "fastboot not found (install Android platform-tools)"
[ -f "$IMAGE" ] || fail "$IMAGE is missing (run scripts/build.sh or scripts/build.sh --shim-only)"

# --- artifact preflight (no phone needed) ----------------------------------
check_tmp=$(mktemp -d)
trap 'rm -rf "$check_tmp"' EXIT
python3 tools/unpack_bootv2.py "$IMAGE" "$check_tmp" >/dev/null \
	|| fail "cannot unpack $IMAGE"
if python3 - "$check_tmp/ramdisk" <<'PY'
import sys
try:
    magic = open(sys.argv[1], 'rb').read(8)
except OSError:
    sys.exit(1)
sys.exit(0 if magic == b'SWEETXNU' else 1)
PY
then
	FULL_IMAGE=1
	[ -f "$PAYLOAD" ] || fail "full image: payload $PAYLOAD is missing"
	[ -f "$ADT" ] || fail "full image: ADT $ADT is missing"
	check_args=(--device sunfish --image "$IMAGE" --dtb "$DTB" --adt "$ADT" --payload "$PAYLOAD")
	echo "artifact: full payload image (ramdisk must match $PAYLOAD)"
else
	FULL_IMAGE=0
	check_args=(--device sunfish --image "$IMAGE" --dtb "$DTB" --shim-only)
	echo "artifact: diagnostic/shim-only image"
fi
scripts/check-artifacts.sh "${check_args[@]}" >/dev/null \
	|| fail "artifact check failed; run scripts/check-artifacts.sh ${check_args[*]} yourself to see why"

if [ -n "$ROOT_IMG" ] && [ "$FULL_IMAGE" = 0 ]; then
	fail "refusing --flash-root with a diagnostic image; build the full payload and pass --image shim/out/shim-boot-payload.img"
fi

# --- device preflight ------------------------------------------------------
devices=$(fastboot devices | awk 'NF {print $1}')
[ -n "$devices" ] || fail "no fastboot device; hold Power+Volume down and reconnect USB"
[ "$(printf '%s\n' "$devices" | wc -l | tr -d ' ')" = 1 ] \
	|| fail "more than one fastboot device is connected; unplug the others"

product=$(fastboot getvar product 2>&1 | sed -n 's/^product: *//p' | tr -d '\r')
[ "$product" = sunfish ] || fail "device product is '$product', not sunfish (the 4a 5G is not supported)"

unlocked=$(fastboot getvar unlocked 2>&1 | sed -n 's/^unlocked: *//p' | tr -d '\r')
[ "$unlocked" = yes ] || fail "bootloader is locked; unlock it yourself in Developer options + fastboot flashing unlock"

echo "device: sunfish, bootloader unlocked"

if [ -n "$ROOT_IMG" ]; then
	[ -f "$ROOT_IMG" ] || fail "root image $ROOT_IMG is missing"
	python3 - "$ROOT_IMG" <<'PY' || exit 1
import os, struct, sys
path = sys.argv[1]
size = os.path.getsize(path)
with open(path, 'rb') as f:
    head = f.read(32)
if head[:4] == struct.pack('<I', 0xed26ff3a):
    blk, total = struct.unpack_from('<II', head, 12)
    expanded = blk * total
    print(f"root image: sparse, {size} bytes on disk, {expanded} bytes expanded")
else:
    expanded = size
    print(f"root image: raw, {size} bytes")
if expanded < 1024 * 1024 * 1024:
    sys.exit(f"error: {expanded} bytes is far too small for an iOS root image")
PY
	p=$(fastboot getvar partition-size:userdata 2>&1 | sed -n 's/^partition-size:userdata: *//p' | tr -d '\r')
	[ -n "$p" ] || fail "cannot read the userdata partition size"
	want=$(python3 -c "print(int('$p', 0))")
	have=$(python3 - "$ROOT_IMG" <<'PY'
import os, struct, sys
path = sys.argv[1]
with open(path, 'rb') as f:
    head = f.read(20)
if head[:4] == struct.pack('<I', 0xed26ff3a):
    print(struct.unpack_from('<I', head, 12)[0] * struct.unpack_from('<I', head, 16)[0])
else:
    print(os.path.getsize(path))
PY
)
	[ "$have" -le "$want" ] || fail "root image ($have bytes) does not fit userdata ($want bytes)"
	echo "userdata: $want bytes, image needs $have bytes"

	echo
	echo "THIS ERASES ANDROID USER DATA (photos, apps, keys)."
	echo "It writes $ROOT_IMG to the userdata partition."
	echo "The bootloader, recovery, modem, persist and DTBO are not touched."
	if [ "$ASSUME_YES" = 0 ]; then
		[ -t 0 ] || fail "refusing an unattended destructive flash; run it interactively"
		printf 'Type ERASE USERDATA to continue: '
		read -r answer
		[ "$answer" = "ERASE USERDATA" ] || fail "aborted"
	else
		[ -t 0 ] || fail "--yes still needs a terminal for the final check"
		printf 'Confirm once more: type ERASE USERDATA: '
		read -r answer
		[ "$answer" = "ERASE USERDATA" ] || fail "aborted"
	fi
	echo "flashing userdata (this takes several minutes)..."
	fastboot -S 512M flash userdata "$ROOT_IMG"
	fastboot getvar partition-size:userdata >/dev/null 2>&1 || true
fi

echo "booting $IMAGE (temporary; nothing written to flash)..."
fastboot boot "$IMAGE"
cat <<'EOF'

If the phone stays on a red Android logo or reboots into Android:
  - the red logo is the shim working; look for the DISP/SHIM lines
  - a reboot usually means ABL rejected the image (see TROUBLESHOOTING.md)
To get back to the bootloader: hold Power+Volume down.
Nothing was flashed unless --flash-root was used.
EOF
