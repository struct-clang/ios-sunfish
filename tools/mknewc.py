#!/usr/bin/env python3
"""Create a deterministic newc cpio archive (the shim's placeholder ramdisk).

Usage: mknewc.py OUT [DIR]
Without DIR only the TRAILER!!! entry is written, which is the smallest valid
newc archive ABL accepts.  With DIR the tree is added in sorted order with
zeroed timestamps and ownership so repeated builds are byte identical.
"""
import os
import stat
import sys

MAGIC = b"070701"


def entry(name, mode, data, ino, nlink=1):
    name_b = name.encode() + b"\0"
    fields = [ino, mode, 0, 0, nlink, 0, len(data), 0, 0, 0, 0, len(name_b), 0]
    head = MAGIC + b"".join(f"{v:08x}".encode() for v in fields)
    assert len(head) == 110
    out = head + name_b
    out += b"\0" * ((4 - len(out) % 4) % 4)
    out += data
    out += b"\0" * ((4 - len(data) % 4) % 4)
    return out


def walk(root):
    ino = 1
    entries = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames.sort()
        filenames.sort()
        rel = os.path.relpath(dirpath, root)
        if rel != ".":
            st = os.lstat(dirpath)
            entries.append(entry(rel, stat.S_IFDIR | (st.st_mode & 0o7777),
                                 b"", ino))
            ino += 1
        for fn in filenames:
            path = os.path.join(dirpath, fn)
            rel = os.path.relpath(path, root)
            st = os.lstat(path)
            if stat.S_ISLNK(st.st_mode):
                data = os.readlink(path).encode()
                mode = stat.S_IFLNK | 0o777
            elif stat.S_ISREG(st.st_mode):
                data = open(path, "rb").read()
                mode = stat.S_IFREG | (st.st_mode & 0o7777)
            else:
                continue
            entries.append(entry(rel, mode, data, ino))
            ino += 1
    return entries


def main():
    if len(sys.argv) not in (2, 3):
        sys.exit(__doc__)
    out_path = sys.argv[1]
    dirs = sys.argv[2] if len(sys.argv) == 3 else None
    data = b"".join(walk(dirs)) if dirs else b""
    data += entry("TRAILER!!!", 0, b"", 0, nlink=1)
    with open(out_path, "wb") as f:
        f.write(data)
    print(f"wrote {out_path}: {len(data)} bytes")


if __name__ == "__main__":
    main()
