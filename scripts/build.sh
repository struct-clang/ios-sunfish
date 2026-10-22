#!/bin/bash
# Build the sunfish ADT, the shim payload and the final boot image.
#
#   scripts/build.sh --kernel xnu/out/kernel.development.sweet
#   scripts/build.sh --shim-only                 # diagnostics, no payload
#
# The kernel binary comes from the GitHub Actions workflow (XNU cannot be
# built with Xcode 16; see PORTING_STATUS.md). --shim-only builds the
# payload-less image that only exercises the display and reports the FDT.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

DEVICE=sunfish
KERNEL=xnu/out/kernel.development.sweet
ADT=
PAYLOAD=shim/out/payload.bin
DTB=${DTB:-dtb/sunfish/dtb}
CMDLINE='debug=0xc serial=3 cpus=6 keepsyms=1 -enable_kprintf_spam -noprogress rd=ufsroot0 unentitled_ios_sim_launch=1 ignition_level=1 wdt_test=no_user_checkin ufsrw=1 rootrw=1 launchd_unsecure_cache=1 wdt=-1 sweetfb_noconsole=1 sweetfb_hz=30'
SHIM_ONLY=0

usage() {
	sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'
	exit "${1:-0}"
}

while [ $# -gt 0 ]; do
	case "$1" in
	--device) DEVICE=$2; shift 2 ;;
	--kernel) KERNEL=$2; shift 2 ;;
	--adt) ADT=$2; shift 2 ;;
	--payload) PAYLOAD=$2; shift 2 ;;
	--dtb) DTB=$2; shift 2 ;;
	--cmdline) CMDLINE=$2; shift 2 ;;
	--shim-only) SHIM_ONLY=1; shift ;;
	-h|--help) usage 0 ;;
	*) echo "error: unknown argument $1" >&2; usage 1 ;;
	esac
done

case "$DEVICE" in
sunfish|sweet) ;;
*) echo "error: --device must be sweet or sunfish" >&2; exit 1 ;;
esac
[ -n "$ADT" ] || ADT=shim/out/$DEVICE.adt
case "$DTB" in
/*) ;;
*) DTB=$ROOT/$DTB ;;
esac
case "$PAYLOAD" in
/*) ;;
*) PAYLOAD=$ROOT/$PAYLOAD ;;
esac

mkdir -p shim/out
[ -f "$DTB" ] || {
	echo "error: stock DTB $DTB is missing." >&2
	echo "       Extract it from the phone's own boot.img:" >&2
	echo "       python3 tools/unpack_bootv2.py backup/boot.img dtb/$DEVICE" >&2
	exit 1
}

if [ "$SHIM_ONLY" = 1 ]; then
	echo "== diagnostic shim (no kernel payload) =="
	(cd shim && DEVICE="$DEVICE" DTB="$DTB" ./build.sh)
	scripts/check-artifacts.sh --shim-only --device "$DEVICE" --dtb "$DTB"
	exit 0
fi

[ -f "$KERNEL" ] || {
	echo "error: kernel $KERNEL not found." >&2
	echo "       Download it from the xnu workflow:" >&2
	echo "       gh run download RUN_ID -n xnu-kernel -D xnu/out" >&2
	echo "       The local Xcode 16 iig cannot build xnu-8796." >&2
	exit 1
}

echo "== ADT ($DEVICE) =="
python3 tools/mkadt.py "$ADT" --highmem --device "$DEVICE"

echo "== payload =="
python3 tools/mkpayload.py "$KERNEL" "$ADT" "$PAYLOAD" --cmdline "$CMDLINE"

echo "== shim + boot image =="
(cd shim && DEVICE="$DEVICE" DTB="$DTB" ./build.sh "$PAYLOAD")

scripts/check-artifacts.sh --device "$DEVICE" --dtb "$DTB" \
	--kernel "$KERNEL" --adt "$ADT" --payload "$PAYLOAD"
