#!/usr/bin/env python3
"""T-138: make a big but valid movie from a short one, sparse on disk.

  bigmovie.py <seed> <out> <gib> <layout>

layout `tail` (default; what phone cameras / Android MediaMuxer write): ftyp, mdat, then a 64-bit `free` box up to the
size, then moov at the very end, so a thumbnailer has to read the last bytes of the file first. The seed must have
moov after mdat (avconvert --disableFastStart), so no chunk offset changes.
layout `faststart`: the seed as is (moov first) followed by the `free` box.
"""
import struct
import sys

seed, out, gib = sys.argv[1], sys.argv[2], float(sys.argv[3])
layout = sys.argv[4] if len(sys.argv) > 4 else "tail"
data = open(seed, "rb").read()
total = int(gib * 1024 ** 3)

boxes = []
o = 0
while o < len(data):
    size, kind = struct.unpack(">I4s", data[o:o + 8])
    if size == 1:
        size = struct.unpack(">Q", data[o + 8:o + 16])[0]
    elif size == 0:
        size = len(data) - o
    boxes.append((kind, data[o:o + size]))
    o += size

if layout == "tail":
    kinds = [k for k, _ in boxes]
    if kinds.index(b"moov") < kinds.index(b"mdat"):
        sys.exit("tail layout needs a seed with moov after mdat (avconvert --disableFastStart)")
    head = b"".join(b for k, b in boxes if k != b"moov")
    moov = b"".join(b for k, b in boxes if k == b"moov")
else:
    head, moov = data, b""

pad = total - len(head) - len(moov)
with open(out, "wb") as f:
    f.write(head)
    f.write(struct.pack(">I", 1) + b"free" + struct.pack(">Q", pad))
    f.seek(len(head) + pad)  # leaves a hole: no disk blocks for the padding
    f.write(moov)
    f.truncate(total)
