#!/usr/bin/env python3
"""World Moments SFX through Higgsfield mirelo_text_to_audio (docs/REMARKABLE.md items 10 and 11): the sauropod's
inhale and honking sneeze, the hub fountain jet and the Cinderwing hatchling's squawk. Original prompts only: they
describe the sound, never a game, film, artist or existing effect. Idempotent: assets/audio/world_moments/jobs.json
records each job; a cue with a downloaded file is skipped. Reuses gen_music's CLI wrapper.
Usage: gen_world_moments.py [cue ...]   (no args = every cue)
Then: prep each into assets/audio/world_moments/upload/<cue>.ogg with tools/audio/prep_audio.py (see docs/ASSETS.md 7)."""
import json
import sys
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from gen_music import find_url, run  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "assets" / "audio" / "world_moments" / "raw"
JOBS = OUT.parent / "jobs.json"
M = "mirelo_text_to_audio"
CUES = {
    "sneeze_inhale": (M, 2, "huge creature taking a long wheezing inhale through the nose, rising in pitch, cartoon, "
                            "comedic tension, no voice, no music"),
    "sneeze_honk": (M, 2, "giant cartoon sneeze like a deep honking trumpet blast with a wet spray, comedic, "
                          "no voice, no music"),
    "ans_fountain": (M, 2, "water fountain jet bursting upward then splashing down, no music"),
    "hatch_squawk": (M, 2, "tiny baby dragon chick squawk, squeaky and cheeky, small wings flapping, cartoon, "
                           "no voice, no music"),
}


def downloaded(cue):
    return [f for f in OUT.glob(cue + ".*") if f.suffix in (".mp3", ".wav", ".ogg", ".m4a", ".flac")]


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    jobs = json.loads(JOBS.read_text()) if JOBS.exists() else {}
    want = sys.argv[1:] or list(CUES)
    for cue in want:
        model, dur, prompt = CUES[cue]
        if downloaded(cue) or jobs.get(cue):
            continue
        res = run(["generate", "create", model, "--prompt", prompt, "--duration", str(dur)])
        first = res[0] if isinstance(res, list) and res else res
        jid = first if isinstance(first, str) else (first.get("id") or first.get("job_id") or (first.get("jobs") or [{}])[0].get("id"))
        jobs[cue] = {"job_id": jid, "model": model, "duration": dur, "prompt": prompt}
        JOBS.write_text(json.dumps(jobs, indent=1))
        print("created", cue, jid, flush=True)
    for cue in want:
        done = downloaded(cue)
        if done:
            print("exists", cue, done[0].name)
            continue
        j = jobs[cue]
        res = run(["generate", "wait", j["job_id"]])
        url = find_url(res)
        if not url:
            print("NO_URL", cue, json.dumps(res)[:400])
            continue
        ext = Path(url.split("?")[0]).suffix or ".mp3"
        dest = OUT / (cue + ext)
        with urllib.request.urlopen(url, timeout=120) as r:
            dest.write_bytes(r.read())
        j["file"] = dest.name
        j["bytes"] = dest.stat().st_size
        JOBS.write_text(json.dumps(jobs, indent=1))
        print("downloaded", cue, dest.name, j["bytes"], flush=True)


if __name__ == "__main__":
    main()
