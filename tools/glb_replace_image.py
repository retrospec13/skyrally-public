#!/usr/bin/env python3
"""Replace one embedded image in a GLB (repacks the BIN chunk and fixes bufferView offsets). Mesh and UVs untouched.
Usage: glb_replace_image.py <in.glb> <image_index> <new_image_file> <out.glb>"""
import json
import struct
import sys

src, idx, newf, out = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
data = open(src, "rb").read()
_, _, length = struct.unpack_from("<III", data, 0)
off, js, binc = 12, None, None
while off < length:
    clen, ctype = struct.unpack_from("<II", data, off)
    off += 8
    chunk = data[off:off + clen]
    off += clen
    if ctype == 0x4E4F534A:
        js = json.loads(chunk)
    elif ctype == 0x004E4942:
        binc = chunk
new_blob = open(newf, "rb").read()
target_bv = js["images"][idx]["bufferView"]
js["images"][idx]["mimeType"] = "image/png" if newf.lower().endswith(".png") else "image/jpeg"
views = js["bufferViews"]
order = sorted(range(len(views)), key=lambda i: views[i].get("byteOffset", 0))
nb = bytearray()
for i in order:
    bv = views[i]
    blob = new_blob if i == target_bv else binc[bv.get("byteOffset", 0):bv.get("byteOffset", 0) + bv["byteLength"]]
    while len(nb) % 4:
        nb.append(0)
    bv["byteOffset"] = len(nb)
    bv["byteLength"] = len(blob)
    nb += blob
while len(nb) % 4:
    nb.append(0)
js["buffers"][0]["byteLength"] = len(nb)
jb = json.dumps(js, separators=(",", ":")).encode()
while len(jb) % 4:
    jb += b" "
total = 12 + 8 + len(jb) + 8 + len(nb)
with open(out, "wb") as f:
    f.write(struct.pack("<III", 0x46546C67, 2, total))
    f.write(struct.pack("<II", len(jb), 0x4E4F534A) + jb)
    f.write(struct.pack("<II", len(nb), 0x004E4942) + bytes(nb))
print("wrote", out, total, "bytes")
