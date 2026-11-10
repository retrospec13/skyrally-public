#!/usr/bin/env python3
"""Extract or replace the (single) base-colour image inside a GLB. Rebuilds the BIN chunk with 4-byte alignment.
Usage: glbtex.py extract <in.glb> <out.jpg|png>
       glbtex.py replace <in.glb> <image> <out.glb>   (mime from the image extension)"""
import json
import struct
import sys


def read(p):
    b = open(p, "rb").read()
    assert b[:4] == b"glTF"
    off = 12
    js = binc = None
    while off < len(b):
        ln, typ = struct.unpack_from("<I4s", b, off)
        data = b[off + 8: off + 8 + ln]
        if typ == b"JSON":
            js = json.loads(data)
        elif typ == b"BIN\x00":
            binc = data
        off += 8 + ln
    return js, binc


def write(p, js, views_data):
    out = bytearray()
    for i, d in enumerate(views_data):
        while len(out) % 4:
            out += b"\x00"
        js["bufferViews"][i]["byteOffset"] = len(out)
        js["bufferViews"][i]["byteLength"] = len(d)
        out += d
    while len(out) % 4:
        out += b"\x00"
    js["buffers"] = [{"byteLength": len(out)}]
    j = json.dumps(js, separators=(",", ":")).encode()
    while len(j) % 4:
        j += b" "
    total = 12 + 8 + len(j) + 8 + len(out)
    with open(p, "wb") as f:
        f.write(struct.pack("<4sII", b"glTF", 2, total))
        f.write(struct.pack("<I4s", len(j), b"JSON")); f.write(j)
        f.write(struct.pack("<I4s", len(out), b"BIN\x00")); f.write(out)


if __name__ == "__main__":
    mode = sys.argv[1]
    js, binc = read(sys.argv[2])
    views = [binc[v.get("byteOffset", 0): v.get("byteOffset", 0) + v["byteLength"]] for v in js["bufferViews"]]
    img = js["images"][0]
    if mode == "extract":
        open(sys.argv[3], "wb").write(views[img["bufferView"]])
        print(img.get("mimeType"), len(views[img["bufferView"]]))
    else:
        data = open(sys.argv[3], "rb").read()
        views[img["bufferView"]] = data
        img["mimeType"] = "image/png" if sys.argv[3].lower().endswith(".png") else "image/jpeg"
        write(sys.argv[4], js, views)
        print("REPLACED", len(data))
