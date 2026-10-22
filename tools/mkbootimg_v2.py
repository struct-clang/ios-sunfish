#!/usr/bin/env python3
"""Write an Android boot image header v2 (kernel + ramdisk + appended DTB).

Self-contained replacement for AOSP mkbootimg so the shim can be packed on a
machine without the Android tools.  Only the layout used by sweet/sunfish is
implemented; everything is written deterministically.

Header v2 is 1660 bytes and padded to the page size, followed by the page
aligned kernel, ramdisk and DTB.  The sha1 id is over the kernel and ramdisk
blocks with their sizes, as AOSP's mkbootimg does.
"""
import argparse
import hashlib
import os
import struct
import sys

HEADER_V2_SIZE = 1660
ARM64_IMAGE_MAGIC = 0x644d5241  # "ARM\x64" at Image + 0x38


def auto_int(text):
    return int(text, 0)


def need_file(path, what):
    if not os.path.isfile(path):
        sys.exit(f"error: {what} {path} is not a file")
    return open(path, "rb").read()


def pad4k(data, page):
    return data + b"\0" * ((page - len(data) % page) % page)


def encode_os_version(text):
    if not text:
        return 0
    parts = [int(p) for p in text.split(".")]
    if len(parts) != 3 or any(p < 0 or p > 127 for p in parts):
        sys.exit(f"error: --os_version wants A.B.C (0-127), got {text!r}")
    a, b, c = parts
    return (a << 25) | (b << 18) | (c << 11)


def encode_patch_level(text):
    if not text:
        return 0
    try:
        year, month = [int(p) for p in text.split("-")]
    except ValueError:
        sys.exit(f"error: --os_patch_level wants YYYY-MM, got {text!r}")
    if not 2000 <= year <= 2127 or not 1 <= month <= 12:
        sys.exit(f"error: patch level {text!r} out of range")
    return ((year - 2000) << 4) | month


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--kernel", required=True)
    ap.add_argument("--ramdisk", required=True)
    ap.add_argument("--dtb")
    ap.add_argument("--output", "-o", required=True)
    ap.add_argument("--pagesize", type=auto_int, default=4096)
    ap.add_argument("--header_version", type=int, default=2,
                    help="only 2 is implemented")
    ap.add_argument("--kernel_offset", type=auto_int, default=0x8000)
    ap.add_argument("--ramdisk_offset", type=auto_int, default=0x01000000)
    ap.add_argument("--tags_offset", type=auto_int, default=0x100)
    ap.add_argument("--dtb_offset", type=auto_int, default=0x01f00000)
    ap.add_argument("--cmdline", default="")
    ap.add_argument("--name", default="ios-sweet")
    ap.add_argument("--os_version", default="")
    ap.add_argument("--os_patch_level", default="")
    ap.add_argument("--allow-compressed-kernel", action="store_true",
                    help="do not insist on an uncompressed arm64 Image header")
    args = ap.parse_args()

    if args.pagesize < 2048 or args.pagesize & (args.pagesize - 1):
        sys.exit("error: --pagesize must be a power of two >= 2048")
    if args.header_version != 2:
        sys.exit("error: only --header_version 2 is implemented")

    kernel = need_file(args.kernel, "kernel")
    ramdisk = need_file(args.ramdisk, "ramdisk")
    dtb = need_file(args.dtb, "dtb") if args.dtb else b""

    if not args.allow_compressed_kernel:
        if len(kernel) < 0x40 or struct.unpack_from("<I", kernel, 0x38)[0] != ARM64_IMAGE_MAGIC:
            sys.exit("error: kernel is not an uncompressed arm64 Image "
                     "(use --allow-compressed-kernel if this is intended)")
    if dtb and dtb[:4] != b"\xd0\x0d\xfe\xed" and dtb[:4] != b"\xed\xfe\x0d\xd0":
        sys.exit("error: --dtb does not start with the FDT magic")
    if len(args.name) > 16:
        sys.exit("error: --name is limited to 16 bytes")

    cmdline = args.cmdline.encode()[:512]
    extra = b""
    ident = hashlib.sha1()
    ident.update(kernel)
    ident.update(struct.pack("<I", len(kernel)))
    ident.update(ramdisk)
    ident.update(struct.pack("<I", len(ramdisk)))
    # Empty second stage and recovery_dtbo, then the DTB. The stock Pixel
    # id only matches when all five are included.
    ident.update(struct.pack("<I", 0))
    ident.update(struct.pack("<I", 0))
    ident.update(dtb)
    ident.update(struct.pack("<I", len(dtb)))

    os_version = encode_os_version(args.os_version) | encode_patch_level(args.os_patch_level)

    hdr = bytearray(HEADER_V2_SIZE)
    struct.pack_into("<8s10I", hdr, 0, b"ANDROID!",
                     len(kernel), args.kernel_offset,
                     len(ramdisk), args.ramdisk_offset,
                     0, 0,  # second stage
                     args.tags_offset, args.pagesize,
                     2, os_version)
    struct.pack_into("<16s512s32s1024s", hdr, 48,
                     args.name.encode(), cmdline, ident.digest(), extra)
    struct.pack_into("<IQI", hdr, 1632, 0, 0, HEADER_V2_SIZE)  # recovery_dtbo
    struct.pack_into("<IQ", hdr, 1648, len(dtb), args.dtb_offset)  # dtb

    image = (pad4k(bytes(hdr), args.pagesize) +
             pad4k(kernel, args.pagesize) +
             pad4k(ramdisk, args.pagesize) +
             pad4k(dtb, args.pagesize))

    tmp = args.output + ".tmp"
    with open(tmp, "wb") as f:
        f.write(image)
    os.replace(tmp, args.output)

    print(f"wrote {args.output}: {len(image)} bytes "
          f"(kernel={len(kernel)} @{args.kernel_offset:#x}, "
          f"ramdisk={len(ramdisk)} @{args.ramdisk_offset:#x}, "
          f"dtb={len(dtb)} @{args.dtb_offset:#x}, page={args.pagesize})")


if __name__ == "__main__":
    main()
