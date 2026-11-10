#!/usr/bin/env python3
"""Tiny GLB geometry reader (numpy only): positions (file frame), triangle indices, uv. Used for QC measurements."""
import json
import struct
import numpy as np


def load(p):
    b = open(p, "rb").read()
    off = 12
    js = binc = None
    while off < len(b):
        ln, typ = struct.unpack_from("<I4s", b, off)
        d = b[off + 8: off + 8 + ln]
        if typ == b"JSON":
            js = json.loads(d)
        elif typ == b"BIN\x00":
            binc = d
        off += 8 + ln
    P, I = [], []
    base = 0
    for m in js["meshes"]:
        for pr in m["primitives"]:
            def acc(i):
                a = js["accessors"][i]
                bv = js["bufferViews"][a["bufferView"]]
                dt = {5126: np.float32, 5123: np.uint16, 5125: np.uint32}[a["componentType"]]
                n = {"SCALAR": 1, "VEC2": 2, "VEC3": 3}[a["type"]]
                o = bv.get("byteOffset", 0) + a.get("byteOffset", 0)
                return np.frombuffer(binc, dt, a["count"] * n, o).reshape(-1, n)
            P.append(acc(pr["attributes"]["POSITION"]))
            I.append(acc(pr["indices"]).reshape(-1, 3).astype(np.int64) + base)
            base += len(P[-1])
    return np.concatenate(P), np.concatenate(I)
