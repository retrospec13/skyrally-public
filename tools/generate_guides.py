#!/usr/bin/env python3
"""Generate 2D build guides with the existing Higgsfield workflow (nano_banana_2, 2k, 16:9) from a guide-set manifest.
Usage: generate_guides.py <guide_set_dir> [job ...]
Idempotent: a job with a recorded job_id is only waited/downloaded, never re-created (accepted art is never
regenerated). Records job ids, credits and sha256 in <dir>/jobs.json and writes an 844x475 phone preview."""
import hashlib
import json
import subprocess
import sys
import urllib.request
from pathlib import Path

from PIL import Image

D = Path(sys.argv[1]).resolve()
only = set(sys.argv[2:])
manifest = json.loads((D / "manifest.json").read_text())
ledger_p = D / "jobs.json"
ledger = json.loads(ledger_p.read_text()) if ledger_p.exists() else {}
(D / "logs").mkdir(exist_ok=True)
(D / "qa_phone").mkdir(exist_ok=True)


def hf(args, log, timeout=900):
    p = subprocess.run(["higgsfield", *args, "--json"], capture_output=True, text=True, timeout=timeout, cwd=D)
    (D / "logs" / f"{log}.log").write_text(p.stdout + "\n" + p.stderr)
    if p.returncode != 0:
        raise RuntimeError(f"higgsfield {args[:2]} failed for {log}: {p.stderr[:400]}")
    return json.loads(p.stdout)


def urls(d):
    if isinstance(d, dict):
        for k, v in d.items():
            if isinstance(v, str) and v.startswith("http") and k in ("result_url", "output_url", "url", "raw_url"):
                yield v
            elif k not in ("params", "input_images", "request"):
                yield from urls(v)
    elif isinstance(d, list):
        for v in d:
            yield from urls(v)


for name, spec in manifest["jobs"].items():
    if only and name not in only:
        continue
    rec = ledger.get(name, {})
    out = D / f"{name}.png"
    if out.exists() and rec.get("sha256"):
        print("exists", name)
        continue
    if not rec.get("job_id"):
        args = ["generate", "create", manifest["model"], "--prompt", (D / spec["prompt_file"]).read_text().strip(),
                "--resolution", manifest["resolution"], "--aspect_ratio", manifest["aspect_ratio"]]
        for r in spec["refs"]:
            args += ["--image", str((D / r).resolve())]
        d = hf(args, f"{name}_create", timeout=300)
        x = d[0] if isinstance(d, list) else d
        rec = {"job_id": x if isinstance(x, str) else (x.get("id") or x.get("job_id")), "model": manifest["model"], "refs": spec["refs"],
               "prompt_file": spec["prompt_file"]}
        ledger[name] = rec
        ledger_p.write_text(json.dumps(ledger, indent=1))
    w = hf(["generate", "wait", rec["job_id"], "--timeout", "15m"], f"{name}_wait", timeout=1000)
    u = next(urls(w), None)
    if not u:
        raise RuntimeError(f"no result url for {name}")
    urllib.request.urlretrieve(u, out)
    rec["sha256"] = hashlib.sha256(out.read_bytes()).hexdigest()
    rec["url"] = u
    im = Image.open(out)
    rec["size"] = list(im.size)
    im.convert("RGB").resize((844, 475)).save(D / "qa_phone" / f"{name}_844x475.png")
    ledger_p.write_text(json.dumps(ledger, indent=1))
    print("done", name, rec["size"], rec["sha256"][:12])
