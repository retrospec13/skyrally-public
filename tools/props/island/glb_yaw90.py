#!/usr/bin/env python3
"""Turn a GLB prop +90 deg about the up axis in place (pure Python, no Blender), so a front that faced Blender +X
(glTF +X) faces Blender +Y = glTF -Z = Roblox -Z (LookVector). Rotates every POSITION / NORMAL (and TANGENT xyz)
accessor in the binary chunk and fixes accessor min/max. The pivot (base centre at the origin) is unchanged.
glTF mapping for this turn: x' = z, z' = -x.
Usage: glb_yaw90.py <in.glb> <out.glb>"""
import json
import struct
import sys



def main(src, dst):
    data = open(src, "rb").read()
    magic, ver, total = struct.unpack_from("<4sII", data, 0)
    assert magic == b"glTF" and ver == 2
    off = 12
    chunks = []
    while off < total:
        ln, typ = struct.unpack_from("<II", data, off)
        chunks.append([typ, bytearray(data[off + 8: off + 8 + ln])])
        off += 8 + ln
    js = json.loads(bytes(chunks[0][1]).decode("utf-8"))
    binc = chunks[1][1]
    done = set()
    for mesh in js["meshes"]:
        for prim in mesh["primitives"]:
            for attr in ("POSITION", "NORMAL", "TANGENT"):
                ai = prim["attributes"].get(attr)
                if ai is None or ai in done:
                    continue
                done.add(ai)
                acc = js["accessors"][ai]
                assert acc["componentType"] == 5126 and "sparse" not in acc
                bv = js["bufferViews"][acc["bufferView"]]
                ncomp = {"VEC3": 3, "VEC4": 4}[acc["type"]]  # TANGENT w (handedness) is left as is
                stride = bv.get("byteStride", 4 * ncomp)
                base = bv.get("byteOffset", 0) + acc.get("byteOffset", 0)
                n = acc["count"]
                mn = [float("inf")] * 3
                mx = [float("-inf")] * 3
                for i in range(n):
                    o = base + i * stride
                    x, y, z = struct.unpack_from("<fff", binc, o)
                    x, z = z, -x
                    struct.pack_into("<fff", binc, o, x, y, z)
                    for k, v in enumerate((x, y, z)):
                        mn[k] = min(mn[k], v)
                        mx[k] = max(mx[k], v)
                if attr == "POSITION":
                    acc["min"], acc["max"] = mn, mx
    for node in js.get("nodes", []):
        assert "rotation" not in node or node["rotation"] == [0, 0, 0, 1], "node rotation present; refusing"
    jb = json.dumps(js, separators=(",", ":")).encode("utf-8")
    jb += b" " * ((4 - len(jb) % 4) % 4)
    chunks[0][1] = bytearray(jb)
    out = b""
    for typ, body in chunks:
        out += struct.pack("<II", len(body), typ) + bytes(body)
    open(dst, "wb").write(struct.pack("<4sII", b"glTF", 2, 12 + len(out)) + out)
    print("YAW90_OK", dst, "positions/normals rotated:", len(done))


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
