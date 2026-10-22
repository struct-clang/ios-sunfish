#!/bin/bash
# Verify the sunfish artifacts before anything is written to a phone.
# Exits non-zero on the first structural problem; prints SHA256 sums at the end.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

DEVICE=sunfish
DTB=dtb/sunfish/dtb
IMAGE=shim/out/shim-boot.img
KERNEL=
ADT=
PAYLOAD=
SHIM_ONLY=0

while [ $# -gt 0 ]; do
	case "$1" in
	--device) DEVICE=$2; shift 2 ;;
	--dtb) DTB=$2; shift 2 ;;
	--image) IMAGE=$2; shift 2 ;;
	--kernel) KERNEL=$2; shift 2 ;;
	--adt) ADT=$2; shift 2 ;;
	--payload) PAYLOAD=$2; shift 2 ;;
	--shim-only) SHIM_ONLY=1; shift ;;
	-h|--help) cat <<'EOF'
usage: scripts/check-artifacts.sh [options]

  --device sweet|sunfish   board the image was built for (default sunfish)
  --dtb PATH               stock DTB the boot image must contain
  --image PATH             boot image (default shim/out/shim-boot.img)
  --kernel PATH            optional Mach-O kernel to sanity check
  --adt PATH               optional ADT to check (compatible, framebuffer)
  --payload PATH           optional shim payload to check
  --shim-only              skip the ADT/payload/kernel checks
EOF
		exit 0 ;;
	*) echo "error: unknown argument $1" >&2; exit 1 ;;
	esac
done

fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok:   $*"; }

[ -f shim/out/Image ] || fail "shim/out/Image is missing (run scripts/build.sh --shim-only)"
[ -f "$IMAGE" ] || fail "$IMAGE is missing"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

python3 tools/unpack_bootv2.py "$IMAGE" "$tmp" >/dev/null
hdr() { sed -n "s/^$1: //p" "$tmp/header.txt"; }

[ "$(hdr header_version)" = 2 ] || fail "boot image is not header v2"
[ "$(hdr page_size)" = 4096 ] || fail "boot image page size is not 4096"
[ "$(hdr kernel_addr)" = 0x8000 ] || fail "kernel_addr $(hdr kernel_addr), expected 0x8000"
[ "$(hdr tags_addr)" = 0x100 ] || fail "tags_addr $(hdr tags_addr), expected 0x100"
case "$DEVICE" in
sunfish) [ "$(hdr ramdisk_addr)" = 0x1000000 ] || fail "ramdisk_addr $(hdr ramdisk_addr), expected 0x1000000" ;;
sweet) [ "$(hdr ramdisk_addr)" = 0x1000000 ] || fail "ramdisk_addr $(hdr ramdisk_addr), expected 0x1000000" ;;
*) fail "unknown device $DEVICE" ;;
esac
[ "$(hdr dtb_addr)" = 0x1f00000 ] || fail "dtb_addr $(hdr dtb_addr), expected 0x1f00000"
ok "boot image header v2 (kernel 0x8000, ramdisk 0x1000000, tags 0x100, dtb 0x1f00000)"

python3 - "$DEVICE" <<'PY' || exit 1
import struct, sys
dev = sys.argv[1]
b = open('shim/out/Image', 'rb').read()
if len(b) < 0x40:
    sys.exit('FAIL: shim/out/Image is too short')
magic = b[0x38:0x3c]
if magic != b'ARM\x64':
    sys.exit(f'FAIL: no arm64 Image magic in shim/out/Image ({magic!r})')
code0, code1, text_off, image_size, flags = struct.unpack_from('<IIQQQ', b, 0)
want = 0x80000 if dev == 'sunfish' else 0
if text_off != want:
    sys.exit(f'FAIL: text_offset {text_off:#x}, expected {want:#x}')
if image_size != len(b):
    sys.exit(f'FAIL: image_size {image_size:#x} != file size {len(b):#x}')
print(f'ok:   Image text_offset={text_off:#x} image_size={image_size:#x} flags={flags:#x}')
PY

[ -f "$DTB" ] || fail "DTB $DTB is missing (extract it from the phone's boot.img)"
cmp -s "$tmp/dtb" "$DTB" || fail "DTB in the boot image differs from $DTB"
ok "DTB matches $DTB ($(stat -c %s "$DTB" 2>/dev/null || stat -f %z "$DTB") bytes)"

if [ "$SHIM_ONLY" = 0 ] && [ -n "$ADT" ]; then
	[ -f "$ADT" ] || fail "ADT $ADT is missing"
	python3 - "$ADT" "$DEVICE" <<'PY' || exit 1
import os, sys
sys.path.insert(0, 'tools')
import adt
path, dev = sys.argv[1], sys.argv[2]
root, _ = adt.parse(open(path, 'rb').read())
props = {k: v for k, f, v in root.props}
compat = props.get('compatible', b'').split(b'\0')
want = ('google,sunfish' if dev == 'sunfish' else 'xiaomi,sweet').encode()
if want not in compat:
    sys.exit(f'FAIL: {path} root compatible {compat} lacks {want!r}')
def find(node, name):
    return next((c for c in node.children if dict((k, v) for k, f, v in c.props).get('name') == name.encode() + b'\0'), None)
fb = find(root, 'sweet-fbcon')
if fb is None:
    sys.exit(f'FAIL: {path} has no /sweet-fbcon')
p = {k: v for k, f, v in fb.props}
w = int.from_bytes(p['width'], 'little')
h = int.from_bytes(p['height'], 'little')
if (w, h) != (1080, 2340 if dev == 'sunfish' else 2400):
    sys.exit(f'FAIL: {path} framebuffer {w}x{h}')
print(f'ok:   ADT {os.path.basename(path)} {w}x{h} compatible={want.decode()}')
PY
fi

if [ "$SHIM_ONLY" = 0 ] && [ -n "$PAYLOAD" ]; then
	[ -f "$PAYLOAD" ] || fail "payload $PAYLOAD is missing"
	python3 - "$PAYLOAD" <<'PY' || exit 1
import struct, sys
path = sys.argv[1]
b = open(path, 'rb').read()
if b[:8] != b'SWEETXNU':
    sys.exit(f'FAIL: {path} has no SWEETXNU magic')
version, nsegs = struct.unpack_from('<II', b, 8)
if version != 1 or nsegs == 0 or nsegs > 32:
    sys.exit(f'FAIL: {path} bad payload header version={version} nsegs={nsegs}')
virt, entry, adt_off, adt_size, end, phys, mem = struct.unpack_from('<7Q', b, 0x10)
if adt_off + adt_size > len(b) or entry == 0:
    sys.exit(f'FAIL: {path} ADT/entry outside the payload')
cmd = b[0x48:0x48+608].split(b'\0')[0].decode(errors='replace')
print(f'ok:   payload {len(b)} bytes, {nsegs} segments, entry={entry:#x}, ADT={adt_size} bytes')
print(f'      cmdline: {cmd}')
PY
fi

if [ "$SHIM_ONLY" = 0 ] && [ -n "$KERNEL" ]; then
	[ -f "$KERNEL" ] || fail "kernel $KERNEL is missing"
	python3 - "$KERNEL" <<'PY' || exit 1
import struct, sys
b = open(sys.argv[1], 'rb').read(8)
if struct.unpack_from('<I', b, 0)[0] != 0xfeedfacf:
    sys.exit(f'FAIL: {sys.argv[1]} is not a 64-bit Mach-O kernel')
print('ok:   kernel is a 64-bit Mach-O')
PY
fi

echo
shasum -a 256 shim/out/Image "$IMAGE" 2>/dev/null \
	|| sha256sum shim/out/Image "$IMAGE"
[ -z "$PAYLOAD" ] || { shasum -a 256 "$PAYLOAD" 2>/dev/null || sha256sum "$PAYLOAD"; }
[ -z "$ADT" ] || { shasum -a 256 "$ADT" 2>/dev/null || sha256sum "$ADT"; }
echo
echo "All structural checks passed. Hardware still has to prove the rest."
