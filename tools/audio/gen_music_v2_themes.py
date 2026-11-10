#!/usr/bin/env python3
"""Music v2 THEMES (music_hub, music_dino, music_snow, music_space): critic-driven rewrite of the v1 prompts
(evidence/L24/audio_critic_music.md). Original instrumental prompts only: no artist, game or song names, no melody references.
Does NOT upload or commit. (The jingle cues live in the sibling tools/audio/gen_music_v2.py; both share assets/audio/music_v2/
but this script keeps its own jobs_themes.json and file names <cue>_r<round>_t<k>.)
Usage:
  gen_music_v2_themes.py gen <round> [cue ...]   submit 3 takes per cue (retries on the 8-concurrent-job limit), download to takes/
  gen_music_v2_themes.py prep <round> [cue ...]  loop-prep every take into upload/ (flags in PREP) and write roles_themes_r<round>.json
Then: python3 tools/audio_critic.py music_v2_themes_r<round> assets/audio/music_v2/roles_themes_r<round>.json"""
import json
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "assets" / "audio" / "music_v2"
JOBS = OUT / "jobs_themes.json"
DUR = 64
TAIL = ("instrumental video game music, no vocals, no singing, no choir, starts immediately at full energy within the first two seconds, "
        "no slow intro, no ambient intro, no breakdown with drums dropping out, steady groove all the way through, "
        "ends on a bar boundary that flows straight back into the first bar so it loops seamlessly, no fade-out, no final chord, "
        "no ring-out ending, clean punchy mid-range mix that reads on phone speakers")

ROLES = {
    "music_hub": "HUB-0 tropical island hub where players explore between portals; plays for minutes so it must stay pleasant and catchy; warm steel drums/marimba/ukulele, about 118 BPM; must loop seamlessly (NOTE: this file is a loop-prepped excerpt; judge the end-to-start wrap as a loop seam, not as a finished song ending)",
    "music_dino": "DINO-4 volcanic canyon plane race loop; driving drums, brass hook, about 145 BPM; 3-lap race loops twice; must loop seamlessly (NOTE: this file is a loop-prepped excerpt; judge the end-to-start wrap as a loop seam, not as a finished song ending)",
    "music_snow": "SNOW-1 frosty mountain plane race loop; sleigh bells, glockenspiel/celesta hook over driving drums, about 145 BPM; 3-lap race loops twice; must loop seamlessly (NOTE: this file is a loop-prepped excerpt; judge the end-to-start wrap as a loop seam, not as a finished song ending)",
    "music_space": "SPACE-4 neon moon city car race loop, the final world; retro synth arpeggios, punchy electronic drums, funky bass, about 132 BPM; 3-lap race loops twice; must loop seamlessly (NOTE: this file is a loop-prepped excerpt; judge the end-to-start wrap as a loop seam, not as a finished song ending)",
}

# Round 2 (after the round-1 critic: all takes scored hook 3-6, intros dragged 13-25 s, stop-time breaks, requested bells/steel drums often missing).
# Shorter, concrete prompts in the critic's own wording: constant percussion, one simple repeating 4-bar hook, no breaks.
TAIL2 = ("Clean, dry, punchy mix with clear instrument separation for small speakers. Instant start on the first beat, no intro, no drum stops, "
         "no breakdown, no key change, consistent high energy, seamless loop, no fade out, no vocals.")

PROMPTS = {  # cue -> list of rounds (round 1 = index 0)
    "music_hub": [
        "upbeat tropical island adventure theme, 118 BPM, D major, bright and playful. Steel drums play a catchy syncopated 4-bar hook "
        "that opens the track on beat one and returns every 8 bars, bouncy slap bass, congas, shakers and woodblock calypso groove, "
        "warm marimba counter-melody, strummed ukulele offbeats, short bright brass stabs, whistling synth accent. "
        "Structure: 4-bar hook, 8-bar main melody, 4-bar hook again, 8-bar bridge keeping the percussion groove, back to the hook. " + TAIL,
        "Upbeat late-90s adventure game tropical island hub music, 118 BPM, G major. Playful, nostalgic and sunny. Warm steel drums play one catchy syncopated 4-bar hook that repeats, "
        "wooden marimba counter-melodies, rhythmic ukulele strumming, bouncy fretless bass, crisp congas and shakers. Steady exploratory groove, no brass, no pauses. " + TAIL2,
    ],
    "music_dino": [
        "high-energy volcanic canyon plane race theme, 145 BPM, D minor, adventurous and playful. Opens with a punchy kick and tom groove on beat one, "
        "fast tribal congas and toms, driving breakbeat drums, punchy slap bass, bold brass section playing a memorable 4-bar hook that returns every 8 bars, "
        "marimba stabs answering the brass, rumbling low drum accents. "
        "Structure: 4-bar brass hook, 8-bar driving verse with bass riff, 4-bar brass hook again, 8-bar energetic chorus, back to the hook. " + TAIL,
        "Upbeat late-90s arcade adventure racing music, volcanic canyon, 145 BPM, D minor, heroic and playful. Driving rock drums with tribal tom fills and congas, punchy slap bass, "
        "a bright memorable 4-bar brass fanfare hook right at the start that repeats, answered by playful xylophone and marimba runs. " + TAIL2,
    ],
    "music_snow": [
        "upbeat frosty mountain plane race theme, 145 BPM, G major, crisp bright and adventurous. Sleigh bells jingle on every beat from the first bar, "
        "glockenspiel and celesta play a catchy 4-bar hook that opens the track and returns every 8 bars, punchy driving acoustic breakbeat drums, "
        "bouncy slap bass, bright pizzicato strings, cheerful brass answer phrases. "
        "Structure: 4-bar bell hook, 8-bar high-energy melody with fast bassline, 4-bar hook again, 8-bar soaring string section, back to the hook. " + TAIL,
        "Upbeat late-90s kart racer soundtrack, snowy mountain level, 145 BPM, G major, bright frosty and adventurous. Constant rhythmic sleigh bells on every beat, "
        "driving pop-rock drums, bouncy synth bass, one super catchy simple repeating 4-bar melody on sparkling glockenspiel and celesta doubled by a bright synth lead. " + TAIL2,
    ],
    "music_space": [
        "neon moon city night race theme, 132 BPM, A minor, futuristic and playful. Retro analog synth arpeggios play a catchy 4-bar hook from the very first beat "
        "and return every 8 bars, punchy four-on-the-floor electronic drums with snappy claps, funky slap bass groove, shimmering pad swells, bright lead synth answer phrases. "
        "Structure: 4-bar arpeggio hook, 8-bar funky verse with bass groove, 4-bar hook again, 8-bar lead synth chorus, back to the hook. " + TAIL,
        "Upbeat late-90s arcade racing music, neon space city, 132 BPM, A minor, high-energy and playful. Tight punchy electronic drums with four-on-the-floor kick and claps, "
        "slap-style funky synth bass, bright retro bell and synth arpeggios, a brassy memorable 4-bar synth lead hook that repeats. " + TAIL2,
    ],
}
PREP = ["--cut-fade", "--loop", "--align", "--xfade", "2.5", "--rms", "-19"]


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


def load():
    return json.loads(JOBS.read_text()) if JOBS.exists() else {}


def save(j):
    JOBS.write_text(json.dumps(j, indent=1))


def retry(fn, tries=40):
    for i in range(tries):
        try:
            return fn()
        except RuntimeError as e:
            if "rate_limit" not in str(e):
                raise
            time.sleep(30)
    raise RuntimeError("rate limit never cleared")


def gen(rnd, cues):
    jobs = load()
    keys = [(c, f"{c}_r{rnd}_t{k}") for c in cues for k in (1, 2, 3)]
    for c, key in keys:
        if key not in jobs:
            prompt = PROMPTS[c][rnd - 1]
            jid = retry(lambda: jid_of(run(["generate", "create", "sonilo_music", "--prompt", prompt, "--duration", str(DUR)])))
            jobs[key] = {"job_id": jid, "model": "sonilo_music", "duration": DUR, "prompt": prompt, "round": rnd}
            save(jobs)
            print("created", key, jid, flush=True)
    for c, key in keys:
        if jobs[key].get("file"):
            continue
        url = find_url(run(["generate", "wait", jobs[key]["job_id"]]))
        if not url:
            print("NO_URL", key)
            continue
        dest = OUT / "takes" / (key + (Path(url.split("?")[0]).suffix or ".mp3"))
        urllib.request.urlretrieve(url, dest)
        jobs[key]["file"] = dest.name
        save(jobs)
        print("done", key, dest.name, flush=True)


def prep(rnd, cues):
    jobs, roles = load(), []
    for c in cues:
        for k in (1, 2, 3):
            key = f"{c}_r{rnd}_t{k}"
            j = jobs.get(key)
            if not j or not j.get("file"):
                continue
            out = OUT / "upload" / (key + ".ogg")
            subprocess.run([sys.executable, str(ROOT / "tools/audio/prep_audio.py"), str(OUT / "takes" / j["file"]), str(out), *PREP], check=True)
            j["prep_flags"], j["prepped"] = " ".join(PREP), out.name
            roles.append({"key": key, "path": str(out.relative_to(ROOT)), "role": ROLES[c]})
    save(jobs)
    rf = OUT / f"roles_themes_r{rnd}.json"
    rf.write_text(json.dumps(roles, indent=1))
    print(rf, len(roles))


if __name__ == "__main__":
    a = sys.argv[1:]
    (OUT / "takes").mkdir(parents=True, exist_ok=True)
    (OUT / "upload").mkdir(exist_ok=True)
    cues = a[2:] or list(ROLES)
    gen(int(a[1]), cues) if a[0] == "gen" else prep(int(a[1]), cues)
