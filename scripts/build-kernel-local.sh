#!/bin/bash
# Build xnu-8796.141.3 for ARM64/SWEET locally on macOS, without CI.
#
# This is the same build the GitHub workflow runs, with one difference: the
# 13.5 Kernel Debug Kit is expanded into the work directory instead of being
# installed into /Library/Developer/KDKs, so no sudo is needed.
#
#   scripts/build-kernel-local.sh                 # DEVELOPMENT, SWEET
#   KERNEL_CONFIG=RELEASE scripts/build-kernel-local.sh
#   WORK=/Volumes/ssd/xnu-build scripts/build-kernel-local.sh
#
# Requirements: macOS with Xcode 16.x (Xcode 15 also works), Homebrew jq,
# cmake and ninja, plus ~4 GiB free. The first run downloads a ~660 MiB KDK,
# clones the pinned darwin-xnu-build script and Apple's xnu tree. A full build
# takes roughly 10-20 minutes on an Apple-silicon Mac.
#
# The resulting kernel is copied to xnu/out/kernel.development.sweet (ignored
# by git). It contains patches 0082/0083; the script verifies the sunfish
# strings before declaring success.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

WORK=${WORK:-$ROOT/.build/kernel}
MACOS_VERSION=${MACOS_VERSION:-13.5}
KERNEL_CONFIG=${KERNEL_CONFIG:-DEVELOPMENT}
MACHINE_CONFIG=${MACHINE_CONFIG:-SWEET}
KDK_URL=https://github.com/dortania/KdkSupportPkg/releases/download/22G74/Kernel_Debug_Kit_13.5_build_22G74.dmg
KDK_SHA256=29866842eef039812888daea4176ce493be153b0d6d1b88f90753d69ea51b7d4
DXB_REPO=https://github.com/blacktop/darwin-xnu-build
DXB_SHA=663906528d1cd5ea8fde7de6f16de73db9511549

usage() {
	sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'
	exit "${1:-0}"
}

while [ $# -gt 0 ]; do
	case "$1" in
	--work) WORK=$2; shift 2 ;;
	--macos) MACOS_VERSION=$2; shift 2 ;;
	--config) KERNEL_CONFIG=$2; shift 2 ;;
	--machine) MACHINE_CONFIG=$2; shift 2 ;;
	-h|--help) usage 0 ;;
	*) echo "error: unknown argument $1" >&2; usage 1 ;;
	esac
done

case "$(uname -s)" in
Darwin) ;;
*) echo "error: the local kernel build needs macOS and Xcode" >&2; exit 1 ;;
esac

for tool in python3 git curl jq cmake ninja hdiutil pkgutil; do
	command -v "$tool" >/dev/null 2>&1 || {
		if [ "$tool" = jq ] || [ "$tool" = cmake ] || [ "$tool" = ninja ]; then
			echo "error: $tool is missing; run: brew install jq cmake ninja" >&2
		else
			echo "error: $tool is missing" >&2
		fi
		exit 1
	}
done

# Xcode's default toolchain may still point at CommandLineTools (no iig).
DEVELOPER_DIR=${DEVELOPER_DIR:-$(xcode-select -p 2>/dev/null || true)}
if [ -z "${DEVELOPER_DIR:-}" ] || [ ! -x "$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin/iig" ]; then
	for x in /Applications/Xcode*.app; do
		if [ -x "$x/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/iig" ]; then
			DEVELOPER_DIR="$x/Contents/Developer"
			break
		fi
	done
fi
[ -n "${DEVELOPER_DIR:-}" ] && [ -x "$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin/iig" ] || {
	echo "error: no Xcode with iig found; install Xcode or set DEVELOPER_DIR" >&2
	exit 1
}
export DEVELOPER_DIR
xcodebuild -version

mkdir -p "$WORK"
WORK=$(cd "$WORK" && pwd)
echo "work directory: $WORK"

# --- KDK (extracted, not installed) ----------------------------------------
KDKROOT="$WORK/kdk/KDK.pkg/Payload"
if [ ! -d "$KDKROOT/System/Library/KernelSupport" ]; then
	echo "== Kernel Debug Kit 13.5 =="
	[ -f "$WORK/KDK_13.5.dmg" ] || \
		curl -L --fail --retry 2 -o "$WORK/KDK_13.5.dmg" "$KDK_URL"
	actual=$(shasum -a 256 "$WORK/KDK_13.5.dmg" | awk '{print $1}')
	[ "$actual" = "$KDK_SHA256" ] || {
		echo "error: KDK SHA256 is $actual, expected $KDK_SHA256" >&2
		echo "       remove $WORK/KDK_13.5.dmg and retry" >&2
		exit 1
	}
	mnt="$WORK/kdk-mnt"
	mkdir -p "$mnt"
	hdiutil attach -readonly -nobrowse -mountpoint "$mnt" "$WORK/KDK_13.5.dmg" >/dev/null
	trap 'hdiutil detach "$mnt" >/dev/null 2>&1 || true' EXIT
	rm -rf "$WORK/kdk"
	pkgutil --expand-full "$mnt/KernelDebugKit.pkg" "$WORK/kdk"
	hdiutil detach "$mnt" >/dev/null
	trap - EXIT
fi
[ -d "$KDKROOT/System/Library/KernelSupport" ] || {
	echo "error: KDK payload not found at $KDKROOT" >&2
	exit 1
}

# --- build script at the pinned revision -----------------------------------
if [ ! -d "$WORK/dxb/.git" ]; then
	echo "== darwin-xnu-build $DXB_SHA =="
	rm -rf "$WORK/dxb"
	git init -q "$WORK/dxb"
	git -C "$WORK/dxb" fetch -q --depth 1 "$DXB_REPO" "$DXB_SHA"
	git -C "$WORK/dxb" checkout -q FETCH_HEAD
fi
have=$(git -C "$WORK/dxb" rev-parse HEAD 2>/dev/null || true)
if [ "$have" != "$DXB_SHA" ]; then
	echo "error: $WORK/dxb is at ${have:-unknown}, expected $DXB_SHA" >&2
	echo "       remove $WORK/dxb and rerun to fetch the pinned revision" >&2
	exit 1
fi

# Our board patches go next to blacktop's. Copy every run so a patch edit is
# picked up; the build applies them with git apply --check, so already-applied
# files are skipped.
cp xnu/patches/*.patch "$WORK/dxb/patches/"
if compgen -G "xnu/patches/*.sh" >/dev/null; then
	cp xnu/patches/*.sh "$WORK/dxb/patches/"
fi

# libfirehose_kernel is arm64e-only; the SWEET kernel is plain arm64.
if ! grep -q 'ARCHS="x86_64 arm64e arm64"' "$WORK/dxb/build.sh"; then
	sed -i '' \
		's/ARCHS="x86_64 arm64e" VALID_ARCHS="x86_64 arm64e"/ARCHS="x86_64 arm64e arm64" VALID_ARCHS="x86_64 arm64e arm64"/' \
		"$WORK/dxb/build.sh"
fi
grep -q 'ARCHS="x86_64 arm64e arm64"' "$WORK/dxb/build.sh" || {
	echo "error: could not enable the arm64 libfirehose slice in $WORK/dxb/build.sh" >&2
	exit 1
}

# build.sh's install_deps wants xcodes and gum even when MACOS_VERSION is set
# (they are only used by the interactive menu). Stubs avoid installing them.
mkdir -p "$WORK/bin"
printf '#!/bin/sh\nexit 0\n' > "$WORK/bin/xcodes"
printf '#!/bin/sh\nexit 1\n' > "$WORK/bin/gum"
chmod +x "$WORK/bin/xcodes" "$WORK/bin/gum"

echo "== building XNU ($KERNEL_CONFIG, $MACHINE_CONFIG) =="
(
	cd "$WORK/dxb"
	PATH="$WORK/bin:/opt/homebrew/bin:/usr/local/bin:$PATH" \
	DEVELOPER_DIR="$DEVELOPER_DIR" \
	MACOS_VERSION="$MACOS_VERSION" \
	KERNEL_CONFIG="$KERNEL_CONFIG" \
	MACHINE_CONFIG="$MACHINE_CONFIG" \
	KDKROOT="$KDKROOT" \
	MAKEFLAGS="${MAKEFLAGS:--k}" \
	/bin/bash build.sh
) 2>&1 | tee "$WORK/build.log"

cfg=$(printf '%s' "$KERNEL_CONFIG" | tr '[:upper:]' '[:lower:]')
mach=$(printf '%s' "$MACHINE_CONFIG" | tr '[:upper:]' '[:lower:]')
kernel="$WORK/dxb/fakeroot/System/Library/Kernels/kernel.$cfg.$mach"
[ -f "$kernel" ] || {
	echo "error: build finished but $kernel is missing; see $WORK/build.log" >&2
	exit 1
}

mkdir -p xnu/out
cp "$kernel" "xnu/out/kernel.$cfg.$mach"
echo
echo "kernel: xnu/out/kernel.$cfg.$mach"
shasum -a 256 "xnu/out/kernel.$cfg.$mach"
for s in 'google,sunfish' 'SWEET TOUCH: selected ST FTM5' \
	'SWEET TOUCH: FTM5 ACK on bit-banged I2C' 'SWEET TOUCH: PM6150 GPIO4' \
	'mounting dirty non-journaled root read-write'; do
	if strings -a "xnu/out/kernel.$cfg.$mach" | grep -qF "$s"; then
		echo "ok:   $s"
	else
		echo "MISSING: $s" >&2
		exit 1
	fi
done
echo
echo "Next: scripts/build.sh --kernel xnu/out/kernel.$cfg.$mach"
