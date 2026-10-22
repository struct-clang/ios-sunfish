#!/usr/bin/env python3
"""Convert a raw disk image to an Android sparse image (portable img2simg).

  img2simg.py RAW.IMG OUT.SIMG [--block-size N] [--verify]

The root image (16 GiB, mostly zeros) is flashed as a sparse image so
`fastboot -S` never has to hold 16 GiB in RAM. Linux gets this from
`img2simg`; this script does the same with the Python standard library so a
macOS build of the root image needs no Android SDK tools.

Sparse format (AOSP system/core/libsparse): a 28-byte file header followed by
12-byte chunk headers and their data. Zero runs become FILL chunks, everything
else a RAW chunk. --verify decodes the output and compares it with the input.
"""
import argparse
import hashlib
import os
import struct
import sys

SPARSE_MAGIC = 0xED26FF3A
CHUNK_RAW = 0xCAC1
CHUNK_FILL = 0xCAC2
FILE_HDR_SZ = 28
CHUNK_HDR_SZ = 12
# Keep individual chunks small; fastboot's libsparse also writes ~1 MiB runs.
MAX_CHUNK_BLOCKS = 256


def blocks_of(data, block):
    """Yield (is_zero, block_bytes) for every whole block in data."""
    for off in range(0, len(data), block):
        b = data[off:off + block]
        yield b.count(0) == len(b), b


def convert(raw_path, out_path, block, verify):
    size = os.path.getsize(raw_path)
    if size == 0 or size % block:
        sys.exit(f"{raw_path}: size {size} is not a multiple of the block size {block}")
    total_blocks = size // block

    chunks = []  # built as a streaming write; count keeps the header honest
    with open(raw_path, "rb") as fin, open(out_path, "wb") as fout:
        fout.write(struct.pack("<IHHHHIIII", SPARSE_MAGIC, 1, 0, FILE_HDR_SZ,
                               CHUNK_HDR_SZ, block, total_blocks, 0, 0))
        total_chunks = 0
        batch_blocks = (1 << 20) // block  # ~1 MiB batches
        pending = []  # (is_zero, bytes) runs

        def emit(is_zero, chunks_data):
            nonlocal total_chunks
            for off in range(0, len(chunks_data), block * MAX_CHUNK_BLOCKS):
                part = chunks_data[off:off + block * MAX_CHUNK_BLOCKS]
                n = len(part) // block
                if is_zero:
                    # FILL: chunk_sz counts blocks, total_sz is the 4-byte pattern
                    fout.write(struct.pack("<HHII", CHUNK_FILL, 0, n, 4))
                    fout.write(struct.pack("<I", 0))
                else:
                    fout.write(struct.pack("<HHII", CHUNK_RAW, 0, n, n * block))
                    fout.write(part)
                total_chunks += 1

        def flush():
            for is_zero, chunks_data in pending:
                emit(is_zero, chunks_data)
            pending.clear()

        while True:
            data = fin.read(batch_blocks * block)
            if not data:
                break
            if len(data) % block:
                sys.exit(f"{raw_path}: truncated read (partial block)")
            offset = 0
            for is_zero, b in blocks_of(data, block):
                if pending and pending[-1][0] == is_zero:
                    pending[-1] = (is_zero, pending[-1][1] + b)
                else:
                    pending.append((is_zero, b))
                offset += 1
                # Bound memory: flush once the pending run gets large.
                if len(pending) > 4096:
                    flush()
            flush()

        if not pending:
            flush()
        # Rewrite the header with the real chunk count.
        fout.seek(0)
        fout.write(struct.pack("<IHHHHIIII", SPARSE_MAGIC, 1, 0, FILE_HDR_SZ,
                               CHUNK_HDR_SZ, block, total_blocks, total_chunks, 0))

    print(f"{out_path}: {os.path.getsize(out_path)} bytes, "
          f"{total_blocks} blocks, {total_chunks} chunks")

    if verify:
        check_sparse(raw_path, out_path, block)


def check_sparse(raw_path, simg_path, block):
    """Decode the sparse image and compare byte-for-byte with the raw input."""
    h1, h2, h3, fhsz, chsz, blk, total, nchunks, _ = struct.unpack(
        "<IHHHHIIII", open(simg_path, "rb").read(28))
    if (h1, h2, h3, fhsz, chsz, blk) != (SPARSE_MAGIC, 1, 0, FILE_HDR_SZ, CHUNK_HDR_SZ, block):
        sys.exit("verify: bad sparse header")
    digest = hashlib.sha256()
    left = total
    with open(simg_path, "rb") as f:
        f.seek(fhsz)
        for i in range(nchunks):
            ctype, _, nblocks, total_size = struct.unpack("<HHII", f.read(12))
            if nblocks > left:
                sys.exit("verify: chunk overruns the image")
            if ctype == CHUNK_RAW:
                if total_size != nblocks * block:
                    sys.exit("verify: bad RAW chunk size")
                digest.update(f.read(total_size))
            elif ctype == CHUNK_FILL:
                if total_size != 4:
                    sys.exit("verify: bad FILL chunk size")
                fill = f.read(4) * (nblocks * block // 4)
                digest.update(fill)
            else:
                sys.exit(f"verify: unsupported chunk type 0x{ctype:x}")
            left -= nblocks
    if left:
        sys.exit(f"verify: {left} blocks missing")
    import hashlib as _h
    want = _h.sha256()
    with open(raw_path, "rb") as f:
        while True:
            d = f.read(1 << 20)
            if not d:
                break
            want.update(d)
    if digest.hexdigest() != want.hexdigest():
        sys.exit("verify: expanded image does not match the raw image")
    print("verify: expanded image matches the raw image")


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("raw")
    ap.add_argument("simg")
    ap.add_argument("--block-size", type=int, default=4096)
    ap.add_argument("--verify", action="store_true",
                    help="decode the output and compare it with the input")
    args = ap.parse_args()
    convert(args.raw, args.simg, args.block_size, args.verify)


if __name__ == "__main__":
    main()
