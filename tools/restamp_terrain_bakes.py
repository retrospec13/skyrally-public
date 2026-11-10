#!/usr/bin/env python3
"""Restamp terrain bakes after a builder-template change that did NOT touch the terrain code (V1 D1, 2026-10-22).

A bake (build/<key>/terrain_bake.rbxm, tools/bake_terrain.py) is pasted only while its TerrainHash attribute equals
the compiled builder's TERRAIN_HASH (tools/map30/build_plan.terrain_hash). When the template's terrain code is
unchanged, the voxels a fresh bake would hold are byte-identical, so the bake only needs the new stamp. This tool
proves that and rewrites nothing else:
  1. the bake's current hash must equal the hash the OLD template (--old-rev, default HEAD) gives for the terrain block
     embedded in the current builder (old whole-template scheme or the terrain_code scheme), i.e. the bake was current;
  2. the old and new terrain code (build_plan.terrain_code) must be equal once full-line `--` comments are dropped;
  3. inside the rbxm only the 16 hash characters change (chunks are LZ4-decompressed; a patched chunk is written back
     uncompressed, which the binary format allows).
Anything else (terrain code changed, bake already stale, hash not found once) refuses: rebake in Studio instead.
Usage: restamp_terrain_bakes.py [--old-rev REV] [--check]"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import struct
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools" / "map30"))
import build_plan  # noqa: E402

MAGIC = b"<roblox!\x89\xff\r\n\x1a\n"


def lz4_block_decompress(src: bytes, size: int) -> bytes:
    out = bytearray()
    i = 0
    n = len(src)
    while i < n:
        token = src[i]
        i += 1
        lit = token >> 4
        if lit == 15:
            while True:
                b = src[i]
                i += 1
                lit += b
                if b != 255:
                    break
        out += src[i:i + lit]
        i += lit
        if i >= n:
            break
        off = src[i] | (src[i + 1] << 8)
        i += 2
        ml = token & 15
        if ml == 15:
            while True:
                b = src[i]
                i += 1
                ml += b
                if b != 255:
                    break
        ml += 4
        start = len(out) - off
        if off <= 0 or start < 0:
            raise ValueError("bad lz4 offset")
        for k in range(ml):
            out.append(out[start + k])
    if len(out) != size:
        raise ValueError(f"lz4: got {len(out)} bytes, header says {size}")
    return bytes(out)


def read_chunks(blob: bytes) -> tuple[bytes, list[tuple[bytes, bytes]]]:
    if not blob.startswith(MAGIC):
        raise ValueError("not a binary rbxm")
    head = blob[:32]
    pos = 32
    chunks = []
    while pos < len(blob):
        name = blob[pos:pos + 4]
        comp, size, _ = struct.unpack_from("<III", blob, pos + 4)
        pos += 16
        if comp == 0:
            data = blob[pos:pos + size]
            pos += size
        else:
            raw = blob[pos:pos + comp]
            pos += comp
            if raw[:4] == b"\x28\xb5\x2f\xfd":
                raise ValueError("zstd chunk: not supported here, rebake in Studio")
            data = lz4_block_decompress(raw, size)
        chunks.append((name, data))
        if name == b"END\x00":
            break
    return head, chunks


def write_chunks(head: bytes, chunks: list[tuple[bytes, bytes]], originals: bytes, patched: set[int]) -> bytes:
    # Unpatched chunks keep their original (compressed) bytes; patched ones go back uncompressed.
    out = bytearray(head)
    pos = 32
    for idx, (name, data) in enumerate(chunks):
        comp, size, res = struct.unpack_from("<III", originals, pos + 4)
        length = comp if comp else size
        if idx in patched:
            out += name + struct.pack("<III", 0, len(data), 0) + data
        else:
            out += originals[pos:pos + 16 + length]
        pos += 16 + length
    out += originals[pos:]
    return bytes(out)


def code_lines(text: str) -> list[str]:
    return [l.rstrip() for l in text.splitlines() if not l.strip().startswith("--")]


def builder_info(path: Path) -> tuple[str, str, dict]:
    src = path.read_text(encoding="utf-8")
    h = re.search(r'local TERRAIN_HASH = "([0-9a-f]+)"', src)
    blob = re.search(r"JSONDecode\(\[==\[(.*?)\]==\]\)", src, re.S)
    if not (h and blob):
        raise ValueError(f"{path}: no TERRAIN_HASH or DATA")
    data = json.loads(blob.group(1))
    return h.group(1), data["name"], data


def old_hashes(old_tpl: str, data: dict) -> set[str]:
    terrain = json.dumps(data["terrain"], sort_keys=True, separators=(",", ":")).encode("utf-8")
    out = {build_plan.terrain_hash(old_tpl, data)}
    h = hashlib.sha256()  # the pre-V1 scheme: the whole template text
    h.update(old_tpl.encode("utf-8"))
    h.update(b"\0")
    h.update(terrain)
    out.add(h.hexdigest()[:16])
    return out


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--old-rev", default="HEAD", help="git revision holding the template the bakes were made with")
    ap.add_argument("--check", action="store_true", help="report only, write nothing")
    a = ap.parse_args(argv)

    old_tpl = subprocess.run(["git", "show", f"{a.old_rev}:tools/map30/builder_template.luau"], cwd=ROOT,
                             capture_output=True, text=True, check=True).stdout
    new_tpl = (ROOT / "tools" / "map30" / "builder_template.luau").read_text(encoding="utf-8")
    if code_lines(build_plan.terrain_code(old_tpl)) != code_lines(build_plan.terrain_code(new_tpl)):
        print("REFUSE: the template's terrain code changed since", a.old_rev, "- rebake in Studio (tools/bake_terrain.py)")
        return 1

    project = json.loads((ROOT / "default.project.json").read_text())["tree"]
    bakes = {n: v["$path"] for n, v in project["ServerStorage"].get("TerrainBakes", {}).items()
             if isinstance(v, dict) and "$path" in v}
    builders = {k: v["$path"] for k, v in project["ServerScriptService"]["Maps"].items()
                if isinstance(v, dict) and "$path" in v}
    bad = 0
    for key, bpath in sorted(builders.items()):
        new_hash, name, data = builder_info(ROOT / bpath)
        if name not in bakes:
            continue
        path = ROOT / bakes[name]
        blob = path.read_bytes()
        head, chunks = read_chunks(blob)
        allowed = old_hashes(old_tpl, data) | {new_hash}
        found = []
        for idx, (_, payload) in enumerate(chunks):
            for m in re.finditer(rb"TerrainHash\x02\x10\x00\x00\x00([0-9a-f]{16})", payload):
                found.append((idx, m.start(1), m.group(1).decode()))
        if len(found) != 1:
            print(f"REFUSE {key}: TerrainHash found {len(found)} times in {path.name}")
            bad += 1
            continue
        idx, at, cur = found[0]
        if cur == new_hash:
            print(f"ok     {key}: {name} already {new_hash}")
            continue
        if cur not in allowed:
            print(f"REFUSE {key}: bake hash {cur} is not what {a.old_rev}'s template gives ({sorted(allowed - {new_hash})}): stale bake, rebake in Studio")
            bad += 1
            continue
        payload = chunks[idx][1]
        new_payload = payload[:at] + new_hash.encode() + payload[at + 16:]
        assert len(new_payload) == len(payload)
        assert sum(x != y for x, y in zip(payload, new_payload)) <= 16
        chunks[idx] = (chunks[idx][0], new_payload)
        out = write_chunks(head, chunks, blob, {idx})
        # Round trip: the written file decodes to the same chunks.
        _, again = read_chunks(out)
        assert [c[1] for c in again] == [c[1] for c in chunks]
        if a.check:
            print(f"would  {key}: {name} {cur} -> {new_hash}")
        else:
            path.write_bytes(out)
            print(f"stamp  {key}: {name} {cur} -> {new_hash} ({path.relative_to(ROOT)})")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
