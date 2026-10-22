#!/bin/bash
# Install everything needed to build the sunfish shim, ADT and payload.
# Linux: Debian/Ubuntu apt or Fedora dnf. macOS: Homebrew.
# The XNU kernel is built by CI (macos-15) or by scripts/build-kernel-local.sh
# (macOS with Xcode 16); this script only sets up the local cross toolchain and
# image tools.
set -euo pipefail

need() {
	if ! command -v "$1" >/dev/null 2>&1; then
		echo "error: $1 is still missing" >&2
		exit 1
	fi
}

case "$(uname -s)" in
Linux)
	if command -v apt-get >/dev/null 2>&1; then
		sudo apt-get update
		sudo apt-get install -y \
			gcc-aarch64-linux-gnu binutils-aarch64-linux-gnu \
			python3 device-tree-compiler liblz4-tool cpio gzip xz-utils \
			gh git make unzip
		# optional; only needed to run fastboot from this machine
		sudo apt-get install -y android-tools-fastboot || true
	elif command -v dnf >/dev/null 2>&1; then
		sudo dnf install -y gcc-aarch64-linux-gnu binutils-aarch64-linux-gnu \
			python3 dtc lz4 cpio gzip xz android-tools gh git make unzip
	else
		echo "error: install aarch64-linux-gnu gcc/binutils, python3, dtc, lz4, cpio, gh by hand" >&2
		exit 1
	fi
	CROSS=aarch64-linux-gnu-
	;;
Darwin)
	if ! command -v brew >/dev/null 2>&1; then
		echo "error: install Homebrew first: https://brew.sh" >&2
		exit 1
	fi
	brew install aarch64-elf-gcc dtc lz4 gh make python3
	CROSS=aarch64-elf-
	;;
*)
	echo "error: unsupported host $(uname -s)" >&2
	exit 1
	;;
esac

export CROSS
for tool in "${CROSS}gcc" "${CROSS}objcopy" "${CROSS}nm" "${CROSS}readelf" \
	python3 lz4 cpio; do
	need "$tool"
done
if ! command -v gh >/dev/null 2>&1; then
	echo "warning: gh is missing; you cannot trigger the kernel CI from here" >&2
fi
if ! command -v fastboot >/dev/null 2>&1; then
	echo "warning: fastboot is missing; install Android platform-tools to flash" >&2
fi

echo
echo "cross prefix: ${CROSS}"
"${CROSS}gcc" --version | head -1
python3 --version
echo
echo "Next:"
echo "  1. extract the stock DTB: python3 tools/unpack_bootv2.py backup/boot.img dtb/sunfish"
echo "  2. build the image:       CROSS=${CROSS} scripts/build.sh --kernel <xnu kernel> [--payload-only]"
echo "  3. check the artifacts:   scripts/check-artifacts.sh"
