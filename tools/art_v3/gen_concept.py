#!/usr/bin/env python3
"""Art v3 concept generator: one Higgsfield nano_banana_2 job (1k, 1:1) per asset, with approved-concept style refs.
Usage: gen_concept.py <asset_dir> <prompt_file> <out_name> [ref ...]
Writes <asset_dir>/<out_name>.png and appends job id, credits, refs and prompt to <asset_dir>/concept_jobs.json.
Refs must be approved SkyRally concepts / crops of them or research/art/raiser_*.jpg (never sunshine_*/majora_*)."""
import hashlib
import json
import subprocess
import sys
import urllib.request
from pathlib import Path

d, pf, outn = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
refs = sys.argv[4:]
for r in refs:
    assert "sunshine" not in r and "majora" not in r, r
prompt = pf.read_text().strip()


def hf(args, timeout=900):
    p = subprocess.run(["higgsfield", *args, "--json"], capture_output=True, text=True, timeout=timeout)
    if p.returncode != 0:
        raise SystemExit("HF_FAIL " + p.stderr[:600])
    return json.loads(p.stdout)


def urls(o):
    if isinstance(o, dict):
        for k, v in o.items():
            if isinstance(v, str) and v.startswith("http") and k in ("result_url", "output_url", "url", "raw_url"):
                yield v
            elif k not in ("params", "input_images", "request"):
                yield from urls(v)
    elif isinstance(o, list):
        for v in o:
            yield from urls(v)


args = ["generate", "create", "nano_banana_2", "--prompt", prompt, "--resolution", "1k", "--aspect_ratio", "1:1"]
for r in refs:
    args += ["--image", str(Path(r).resolve())]
c = hf(args, 300)
x = c[0] if isinstance(c, list) else c
job = x if isinstance(x, str) else (x.get("id") or x.get("job_id"))
print("JOB", job, flush=True)
w = hf(["generate", "wait", job, "--timeout", "15m"], 1000)
u = next(urls(w), None)
if not u:
    raise SystemExit("NO_URL " + json.dumps(w)[:600])
out = d / f"{outn}.png"
urllib.request.urlretrieve(u, out)


def find(o, keys):
    if isinstance(o, dict):
        for k, v in o.items():
            if k in keys and isinstance(v, (int, float)):
                return v
            r = find(v, keys)
            if r is not None:
                return r
    elif isinstance(o, list):
        for v in o:
            r = find(v, keys)
            if r is not None:
                return r
    return None


led = d / "concept_jobs.json"
L = json.loads(led.read_text()) if led.exists() else []
L.append({"out": out.name, "job_id": job, "model": "nano_banana_2", "resolution": "1k", "aspect_ratio": "1:1",
          "credits": find(w, ("credits", "cost", "credits_used", "price")), "refs": refs, "prompt": prompt,
          "sha256": hashlib.sha256(out.read_bytes()).hexdigest(), "raw_wait": w})
led.write_text(json.dumps(L, indent=1))
print("DONE", out, flush=True)
