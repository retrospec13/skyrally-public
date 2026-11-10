#!/usr/bin/env python3
"""Music v2 (jingles): original instrumental prompts, 3 Higgsfield sonilo_music takes per cue per round, prepped with
prep_audio.py, then a critic role file. Reproducible: prompts and prep flags live here. No uploads, no commits.
Usage: gen_music_v2.py [--round N] [cue ...]      (no cues = all jingle cues)
Outputs: assets/audio/music_v2/takes/<cue>_r<R>t<T>.<ext>, upload/<cue>_r<R>t<T>.ogg, jobs.json, roles_jingles_r<R>.json"""
import argparse
import json
import subprocess
import sys
import time
import time
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "assets" / "audio" / "music_v2"
JOBS = OUT / "jobs.json"
PREP = ROOT / "tools" / "audio" / "prep_audio.py"
STYLE = ("original instrumental video game jingle, no vocals, crisp transients, dry punchy clean mix for small speakers, "
         "starts with full energy on the very first beat, no slow intro, ends on a clean final chord with a natural tail")

# cue -> {round: (duration_s, prompt)}, prep flags
CUES = {
    "jingle_victory": {
        "dur": 12, "role": "1st-place finish jingle, plays once over the podium, about 8-10 seconds, triumphant brass and marimba flourish ending on a bright major chord",
        "prep": ["--trim-silence", "--rms", "-17", "--max-len", "10.5", "--fade-out", "0.6"],
        1: "triumphant 1st-place victory fanfare for a bright kids kart and plane racing game, 145 BPM, F major. Punchy bright brass section "
           "and bouncy marimba, funky slap bass, snappy acoustic drums. Opens instantly with a drum fill and brass hit, then a highly "
           "memorable syncopated 4-bar celebratory brass and marimba hook, cymbal swell, finishing on a bright major chord stinger. " + STYLE,
        2: "joyous 1st-place winner fanfare for a family friendly arcade racing game, 150 BPM, C major. Unison brass and xylophone play a "
           "singable 4-bar rising hook with a cheeky syncopated rhythm, answered by a marimba run; bouncy bass, tight snare, tambourine, "
           "big bright cymbal finish on a major chord. Starts at full energy immediately. " + STYLE,
    },
    "jingle_place2": {
        "dur": 9, "role": "2nd-place finish jingle, proud but smaller than the winner jingle, about 5-7 seconds, upbeat and encouraging 'so close', not grand",
        "prep": ["--trim-silence", "--rms", "-17", "--max-len", "7", "--fade-out", "0.5"],
        1: "proud runner-up fanfare for a bright kids racing game, 135 BPM, G major. Bright brass and cheerful marimba, slap bass, crisp "
           "drums, a catchy syncopated 2-bar hook then a hopeful major chord stinger, upbeat and encouraging, no choir, no pads. " + STYLE,
        2: "cheerful second-place jingle for an arcade racer, 138 BPM, D major. Trumpet and marimba trade a short bouncy 2-bar hook, "
           "walking bass, snare roll into a bright major seventh chord hit. Proud but modest. " + STYLE,
    },
    "jingle_place3": {
        "dur": 7, "role": "3rd-place finish jingle, shorter and smaller than 2nd place, about 4-5 seconds, cheerful bronze-medal, playful",
        "prep": ["--trim-silence", "--rms", "-17", "--max-len", "5", "--fade-out", "0.5"],
        1: "short cheerful third-place bronze jingle for a bright kids racing game, 130 BPM, C major. Bright horns and xylophone play a bouncy "
           "1-bar hook twice, light bass and snappy drums, finishing on a clean resolved major chord. " + STYLE,
        2: "quick playful bronze-medal jingle for an arcade racer, 132 BPM, A major. Marimba and muted trumpet bounce through a catchy 1-bar "
           "motif and a resolving cadence, bass pops, rimshot, final bright chord. Small and sweet. " + STYLE,
    },
    "jingle_midpack": {
        "dur": 7, "role": "4th to second-last place finish jingle, encouraging 'nice try, keep going', 5-7 seconds",
        "prep": ["--trim-silence", "--rms", "-17", "--max-len", "7", "--fade-out", "0.5"],
        1: "encouraging nice-try finish jingle for a kart racing game, 125 BPM, F major. Punchy slap bass, bright FM synth brass, vibrant "
           "marimba lead, crisp drums with a tight snare, a catchy syncopated 3-bar melody then a decisive full-band final chord. "
           "Upbeat and bouncy, no ukulele, no acoustic guitar, no handclaps. " + STYLE,
        2: "upbeat keep-going finish jingle for an arcade racer, 128 BPM, Bb major. Marimba and brass trade a bouncy 2-bar riff, walking "
           "slap bass, shaker and snare, confident resolving chord at the end. Friendly and driven. " + STYLE,
    },
    "jingle_finallap": {
        "dur": 6, "role": "final-lap surge sting, 2-3 seconds, brass stab in the first 100 ms plus snare, urgent and exciting, signals one lap left",
        "prep": ["--trim-rel", "40", "--max-len", "2.8", "--fade-out", "0.6", "--rms", "-16"],
        1: "urgent final-lap sting, 160 BPM, C minor to C major. A loud brass section stab hits on the very first beat with a cymbal, then a "
           "tight snare roll and rapid ascending brass run, ending on a bright orchestra-hit chord. Powerful, punchy, exciting. " + STYLE,
        2: "short racing alarm fanfare, 165 BPM. Instant full-band brass stab at time zero, snare drum rolls and a rising brass figure, "
           "finishing with a sharp major chord hit and cymbal. Bold, driving, no pads. " + STYLE,
    },
}


def run(args):
    p = subprocess.run(["higgsfield", "--json", *args], capture_output=True, text=True, timeout=1800)
    if p.returncode != 0:
        raise RuntimeError(p.stderr[-800:] or p.stdout[-800:])
    return json.loads(p.stdout)


def find_url(o):
    if isinstance(o, dict):
        for v in o.values():
            if isinstance(v, str) and v.startswith("http") and any(e in v.split("?")[0].lower() for e in (".mp3", ".wav", ".ogg", ".m4a", ".flac")):
                return v
            u = find_url(v)
            if u:
                return u
    elif isinstance(o, list):
        for v in o:
            u = find_url(v)
            if u:
                return u
    return None


def jid_of(res):
    first = res[0] if isinstance(res, list) and res else res
    return first if isinstance(first, str) else (first.get("id") or first.get("job_id") or (first.get("jobs") or [{}])[0].get("id"))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--round", type=int, default=1)
    ap.add_argument("cues", nargs="*")
    a = ap.parse_args()
    want = a.cues or list(CUES)
    (OUT / "takes").mkdir(parents=True, exist_ok=True)
    (OUT / "upload").mkdir(exist_ok=True)
    jobs = json.loads(JOBS.read_text()) if JOBS.exists() else {}
    keys = [(c, t, f"{c}_r{a.round}t{t}") for c in want for t in (1, 2, 3)]
    for c, t, k in keys:
        if k in jobs:
            continue
        spec = CUES[c]
        prompt = spec[a.round]
        while True:  # the account allows 8 concurrent jobs shared with other lanes: back off and retry
            try:
                jid = jid_of(run(["generate", "create", "sonilo_music", "--prompt", prompt, "--duration", str(spec["dur"])]))
                break
            except RuntimeError as e:
                if "rate_limit" not in str(e):
                    raise
                time.sleep(45)
        jobs[k] = {"job_id": jid, "model": "sonilo_music", "duration": spec["dur"], "prompt": prompt, "prep": spec["prep"]}
        JOBS.write_text(json.dumps(jobs, indent=1))
        print("created", k, jid, flush=True)
    roles = []
    for c, t, k in keys:
        j = jobs[k]
        if "file" not in j:
            url = find_url(run(["generate", "wait", j["job_id"]]))
            if not url:
                print("NO_URL", k)
                continue
            dest = OUT / "takes" / (k + (Path(url.split("?")[0]).suffix or ".mp3"))
            urllib.request.urlretrieve(url, dest)
            j["file"] = dest.name
            JOBS.write_text(json.dumps(jobs, indent=1))
        up = OUT / "upload" / (k + ".ogg")
        subprocess.run([sys.executable, str(PREP), str(OUT / "takes" / j["file"]), str(up), *j["prep"]], check=True)
        roles.append({"key": k, "path": str(up.relative_to(ROOT)), "role": CUES[c]["role"]})
    rf = OUT / f"roles_jingles_r{a.round}.json"
    old = json.loads(rf.read_text()) if rf.exists() else []
    seen = {r["key"] for r in roles}
    rf.write_text(json.dumps([r for r in old if r["key"] not in seen] + roles, indent=1))
    print(rf)


if __name__ == "__main__":
    main()
