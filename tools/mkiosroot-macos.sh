#!/bin/bash
# Build the SWEET iOS root on macOS, without a Linux host (EXPERIMENTAL).
#
#   mkiosroot-macos.sh OS.dmg SYSTEMOS.dmg APPOS.dmg OUT.img [SIZE]
#
# This is the macOS counterpart of tools/mkiosroot.sh. It does the same steps:
# mount the three DMGs from the iPhone X 20H392 IPSW, format one partitionless
# case-sensitive journaled HFS+ volume (HFSX, label iOSRoot, no partition map),
# copy the OS root and both cryptexes into it, hard-link the dyld shared cache
# and the cryptex-only files, create the logd stores and the system keybag, then
# convert the result to a raw image and (optionally) to a sparse .simg.
#
# Verified on macOS 14.8.8: HFSX create/convert, raw APFS attach,
# tools/img2simg.py, and the real 20H392 OS/SystemOS/AppOS mounts with
# transparent LZBITMAP reads. The full privileged copy/conversion remains an
# end-to-end test; if it fails, use a Lima/QEMU Linux VM and tools/mkiosroot.sh.
#
# Steps that change owner/group need root; run this from a terminal so sudo can
# prompt. Nothing here touches the phone or any disk partition: it only reads
# the IPSW DMGs and writes OUT.img and OUT.simg in the current directory.
set -euo pipefail

usage() { sed -n '2,10p' "$0"; exit 2; }

[[ $# -ge 4 ]] || usage
os=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
sysos=$(cd "$(dirname "$2")" && pwd)/$(basename "$2")
appos=$(cd "$(dirname "$3")" && pwd)/$(basename "$3")
out=$(cd "$(dirname "$4")" && pwd)/$(basename "$4")
size=${5:-16G}
[[ -f $os && -f $sysos && -f $appos ]] || { echo "input DMG missing" >&2; exit 1; }
[[ ! -e $out ]] || { echo "refusing to overwrite $out" >&2; exit 1; }
[[ ! -e ${out%.img}.simg ]] || { echo "refusing to overwrite ${out%.img}.simg" >&2; exit 1; }

for tool in hdiutil rsync python3 sudo diskutil; do
	command -v "$tool" >/dev/null 2>&1 || { echo "missing host tool: $tool" >&2; exit 1; }
done
if ! rsync --version | head -1 | grep -q 'version 3'; then
	echo "note: using $(rsync --version | head -1)"
	echo "      (brew install rsync gives 3.x; 2.6.9 is expected to work here)"
fi

work=$(mktemp -d)
mounts=()
umount_all() {
	[[ ${#mounts[@]} -eq 0 ]] && return 0
	local m
	for m in "${mounts[@]}"; do
		if ! hdiutil detach "$m" >/dev/null 2>&1; then
			diskutil unmount force "$m" >/dev/null 2>&1 || true
		fi
	done
}
cleanup() { umount_all; rm -rf "$work"; }
trap cleanup EXIT

# Attach an image and print every mount point; fall back to the raw-disk hint
# for the cryptex DMGs, which are partitionless raw APFS.
attach_image() {
	local img=$1 mode=$2
	local ro=()
	[[ $mode == ro ]] && ro=(-readonly)
	local out
	if ! out=$(hdiutil attach -nobrowse -owners on ${ro[@]+"${ro[@]}"} -plist "$img" 2>/dev/null); then
		out=$(hdiutil attach -nobrowse -owners on ${ro[@]+"${ro[@]}"} -plist \
			-imagekey diskimage-class=CRawDiskImage "$img")
	fi
	printf '%s' "$out" | python3 -c '
import plistlib, sys
d = plistlib.loads(sys.stdin.buffer.read())
for e in d.get("system-entities", []):
    mp = e.get("mount-point")
    if mp:
        print(mp)
'
}

# Attach a source DMG and return the directory that holds the filesystem root:
# the volume usually contains it in a "root" subdirectory.
pick_root() {
	local img=$1 label=$2 mps m
	mps=$(attach_image "$img" ro)
	[[ -n $mps ]] || { echo "$label: hdiutil mounted no volume from $img" >&2; exit 1; }
	while IFS= read -r m; do mounts+=("$m"); done <<<"$mps"
	while IFS= read -r m; do
		if [[ -d $m/root ]]; then
			echo "$label: $m/root" >&2; echo "$m/root"; return 0
		fi
	done <<<"$mps"
	while IFS= read -r m; do
		if [[ -d $m/System || -d $m/private ]]; then
			echo "$label: $m" >&2; echo "$m"; return 0
		fi
	done <<<"$mps"
	echo "$label: no iOS root found in $mps" >&2
	exit 1
}

os_root=$(pick_root "$os" OS)
sysos_root=$(pick_root "$sysos" SystemOS)
appos_root=$(pick_root "$appos" AppOS)

# One partitionless, case-sensitive HFS+ volume (HFSX), 16 GiB by default.
hdiutil create -size "$size" -fs HFSX -volname iOSRoot -layout NONE \
	-type SPARSE "$work/root.sparseimage" >/dev/null
dest=$(attach_image "$work/root.sparseimage" rw | head -n1)
[[ -d $dest ]] || { echo "could not mount the destination image" >&2; exit 1; }
mounts+=("$dest")
echo "destination: $dest"

# The Linux path uses mkfs.hfsplus -J; macOS formats without a journal, so add
# one (non-fatal: patch 0029 mounts a dirty non-journaled root read-write).
if ! sudo diskutil enableJournal "$dest"; then
	echo "WARNING: could not enable journaling; continuing" >&2
fi

copy() {
	local rel=${2#"$dest"}
	echo "copying $1 -> ${rel:-/}"
	sudo mkdir -p "$2"
	sudo rsync -aH --numeric-ids "$1/" "$2/"
}
copy "$os_root" "$dest"
copy "$sysos_root" "$dest/private/preboot/Cryptexes/OS"
copy "$appos_root" "$dest/private/preboot/Cryptexes/App"

# Shared cache where dyld looks at ignition level 1: hard links, no extra space.
dsc=private/preboot/Cryptexes/OS/System/Library/Caches/com.apple.dyld
sudo mkdir -p "$dest/System/Library/Caches/com.apple.dyld"
for f in "$dest/$dsc"/*; do
	sudo ln "$f" "$dest/System/Library/Caches/com.apple.dyld/${f##*/}"
done

# dyld does not search the cryptexes at ignition level 1: hard-link every
# cryptex file that has no counterpart in the OS root to its root path.
for c in OS App; do
	(cd "$dest/private/preboot/Cryptexes/$c" &&
		sudo find . ! -type d ! -path './System/Library/Caches/com.apple.dyld/*') |
	while IFS= read -r f; do
		f=${f#./}
		if ! sudo test -e "$dest/$f" && ! sudo test -L "$dest/$f"; then
			sudo mkdir -p "$dest/$(dirname "$f")"
			src="$dest/private/preboot/Cryptexes/$c/$f"
			# HFS+ cannot hard-link symlinks: copy those.
			if sudo test -L "$src"; then sudo cp -P "$src" "$dest/$f"; else sudo ln "$src" "$dest/$f"; fi
			echo "linked $c:/$f"
		fi
	done
done

# logd's stores, normally made at restore: owner _logd (272), mode, .migrated.
db="$dest/private/var/db"
sudo install -d -o 272 -g 272 -m 0751 "$db/diagnostics"
sudo install -d -o 272 -g 272 -m 0755 "$db/uuidtext" "$db/diagnostics/timesync"
for d in diagnostics uuidtext diagnostics/timesync; do
	sudo install -o 272 -g 272 -m 0644 /dev/null "$db/$d/.migrated"
done

# System keybag for the built-in AppleKeyStore (no passcode).
sudo install -d -m 0700 -o 0 -g 0 "$dest/private/var/keybags"
{
	printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
		'<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
		'<plist version="1.0"><dict><key>KeyBagKeys</key><data>U1dFRVQ=</data></dict></plist>'
} >"$work/systembag.kb"
sudo install -m 0600 -o 0 -g 0 "$work/systembag.kb" "$dest/private/var/keybags/systembag.kb"

# Bring-up tweaks: launchd/plist edits, containers, activation ark, preferences.
# Portable Python; needs root because it chowns to root/mobile/_logd.
if [[ ${MKIOSROOT_SKIP_TWEAKS:-0} == 1 ]]; then
	echo "note: MKIOSROOT_SKIP_TWEAKS=1, skipping sweet-root-tweaks.py (synthetic tests only)"
else
	sudo python3 "$(dirname "$0")/sweet-root-tweaks.py" "$dest"
fi

df -h "$dest"

# Unmount everything, then turn the sparse image into a raw one.
umount_all
hdiutil convert "$work/root.sparseimage" -format UDTO -o "$work/root.raw" >/dev/null
mv "$work/root.raw.cdr" "$out"
ls -l "$out"

# Sparse image for fastboot (Android sparse format; --verify round-trips it).
python3 "$(dirname "$0")/img2simg.py" "$out" "${out%.img}.simg" --verify
