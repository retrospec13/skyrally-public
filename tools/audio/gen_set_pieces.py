#!/usr/bin/env python3
"""Set-piece SFX through Higgsfield mirelo_text_to_audio (docs/REMARKABLE.md Batch 2 items 13, 21, 22 and 25): the
galleon cannons, the Splashdown gull, the Lost Squeaky Ducks and the Golden Quack horn, the boss defeat gags and the
Moon Monorail. Original prompts only: they describe the sound, never a game, film, artist or existing effect.
Idempotent: assets/audio/set_pieces/jobs.json records each job; a cue with a downloaded file is skipped. Reuses
gen_music's CLI wrapper. Usage: gen_set_pieces.py [cue ...]   (no args = every cue)
Then: tools/audio/prep_set_pieces.sh (prep_audio.py into assets/audio/set_pieces/upload, see docs/ASSETS.md 7)."""
import json
import sys
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from gen_music import find_url, run  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "assets" / "audio" / "set_pieces" / "raw"
JOBS = OUT.parent / "jobs.json"
M = "mirelo_text_to_audio"
NV = ", no voice, no music"
CUES = {
    # item 13: the galleon cannons and the Walk the Plank salute
    # Second takes: the first cannon_boom built up slowly and cut off at its loudest hit, the first duck_squeak and
    # cannon_fuse were near silence (kept as raw/rejected_*_1.mp3; the fuse is synthesised in synth_set_pieces.py).
    "cannon_boom": (M, 3, "one single huge ship cannon shot, an instant loud deep boom right at the start, then a "
                          "long rumbling echo fading out across water, cartoon" + NV),
    # item 13: the Splashdown gull rescue
    "gull_squawk": (M, 2, "one loud cheeky seagull squawk, cartoon" + NV),
    "splash_pluck": (M, 2, "something heavy yanked up out of water, big wet sploosh then dripping, cartoon" + NV),
    # item 22: Lost Squeaky Ducks and the Golden Quack horn
    "duck_squeak": (M, 2, "loud squeaky rubber duck bath toy, squeezed hard twice, two high pitched squeaks, close up" + NV),
    "golden_quack": (M, 2, "cartoon duck quack blown through a big shiny brass horn, bright and silly" + NV),
    # item 21: boss defeat gags (the roars are reused from Batch 1, pitched up into squeaks in code)
    "boss_tumble": (M, 3, "cartoon crash, a big creature tumbling head over heels, bonk, clatter of pots and pans, "
                          "comedic" + NV),
    "wheels_off": (M, 3, "metal wheels popping off a go kart one after another, springy boing boing then a clang, "
                         "comedic" + NV),
    "ice_freeze": (M, 3, "sudden ice freezing crackle and crunch, then a glassy shatter, cartoon" + NV),
    "shell_flip": (M, 2, "giant hollow shell flipping over with a deep clonk and a wobbling wooden spin, comedic" + NV),
    # item 25: the Moon Monorail
    "monorail_chime": (M, 3, "futuristic train departure chime, two soft electronic tones then a rising electric "
                             "hum" + NV),
    "monorail_toot": (M, 2, "cheerful little train horn, two short toots, cartoon" + NV),
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
        try:
            res = run(["generate", "create", model, "--prompt", prompt, "--duration", str(dur)])
        except RuntimeError as e:  # the account's concurrent-job limit: run the script again once these finish
            print("DEFERRED", cue, str(e)[:120], flush=True)
            continue
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
        j = jobs.get(cue)
        if not j:
            continue
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
