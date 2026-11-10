#!/usr/bin/env python3
"""Zone music and jingles through Higgsfield (sonilo_music for loops, mirelo_text_to_audio for short cues).
Original instrumental prompts only: no artist, game or song names, no melody references (owner rule: the B1 v1
guide copied Mario and was rejected). Idempotent: assets/audio/music_v1/jobs.json records each job; a cue with a
downloaded file is skipped. Usage: gen_music.py [cue ...]   (no args = every cue)"""
import json
import subprocess
import sys
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "assets" / "audio" / "music_v1"
JOBS = OUT / "jobs.json"

LOOP = "instrumental video game background music, seamless loop, no vocals, clean mix, bright and fun"
BOSS_LOOP = "instrumental video game boss race music, seamless loop, no vocals, punchy clean mix, intense but family friendly"
CUES = {
    "music_hub": ("sonilo_music", 90, "sunny tropical island hub theme, cheerful marimba and steel drum melody, acoustic guitar strums, "
                  "light bouncy bass, brushed drums, 112 BPM, warm and inviting, " + LOOP),
    "music_dino": ("sonilo_music", 90, "volcanic cavern racing theme, driving tribal toms and punchy kick, slap bass, bold brass stabs, "
                   "playful marimba lead, 138 BPM, energetic adventure, " + LOOP),
    "music_snow": ("sonilo_music", 90, "snowy mountain racing theme, sleigh bells, glockenspiel and celesta lead, bright pizzicato "
                   "strings, upbeat drums, 140 BPM, crisp and adventurous, " + LOOP),
    "music_island": ("sonilo_music", 90, "pirate cove beach racing theme, calypso steel drums, ukulele, accordion hook, funky bass, "
                     "shaker groove, 132 BPM, sunny and mischievous, " + LOOP),
    "music_forest": ("sonilo_music", 90, "windmill countryside racing theme, pastoral fiddle and tin whistle melody over bouncy banjo "
                     "and stomping drums, 136 BPM, joyful and breezy, " + LOOP),
    "music_space": ("sonilo_music", 90, "neon moon city racing theme, retro synth arpeggios, punchy electronic drums, funky slap bass, "
                    "shimmering pads, 128 BPM, futuristic and playful, " + LOOP),
    "jingle_victory": ("sonilo_music", 12, "short triumphant victory fanfare for a kids racing game, brass and marimba flourish, "
                       "cymbal swell, ends on a bright major chord, no vocals"),
    "jingle_countdown": ("mirelo_text_to_audio", 4, "three short rising arcade countdown beeps then a bright go chime, clean, no voice"),
    # REMARKABLE Batch 1 item 1: boss chase themes (slam in on GO) and the boss roars (3D, from the boss on the intro).
    "music_boss_dino": ("sonilo_music", 90, "volcanic drum and bass boss chase, 174 BPM, rolling breakbeats, deep growling bass, thunderous "
                        "taiko hits, fiery brass stabs, rising tension every eight bars, " + BOSS_LOOP),
    "music_boss_snow": ("sonilo_music", 90, "icy drum and bass boss chase, 172 BPM, crisp breakbeats, glassy bell and celesta arpeggios, "
                        "deep sub bass, howling wind pads, bold horn hook, " + BOSS_LOOP),
    "music_boss_island": ("sonilo_music", 90, "swashbuckling drum and bass boss chase, 170 BPM, breakbeats under an accordion and steel "
                          "drum hook, clanking metal percussion, deep bass, " + BOSS_LOOP),
    "music_boss_forest": ("sonilo_music", 90, "rustic breakbeat boss chase, 170 BPM, stomping folk drums, frantic fiddle runs, buzzing "
                          "synth bass, banjo stabs, " + BOSS_LOOP),
    "music_boss_hub": ("sonilo_music", 90, "stormy electro drum and bass boss chase, 174 BPM, thunderclap snares, crackling electric synth "
                       "lead, brass hits, mechanical clank percussion, " + BOSS_LOOP),
    "roar_cinderwing": ("mirelo_text_to_audio", 3, "giant fiery pterosaur screech-roar, rumbling throat, crackling flame tail, cartoon "
                        "creature sound effect, no voice, no music"),
    "roar_frosthorn": ("mirelo_text_to_audio", 3, "huge owl hoot swelling into a booming icy roar, wind gust and ice crackle tail, cartoon "
                       "creature sound effect, no voice, no music"),
    "roar_clattershell": ("mirelo_text_to_audio", 3, "giant crab claws clacking twice then a deep bubbling bellow, wooden ship creak tail, "
                          "cartoon creature sound effect, no voice, no music"),
    "roar_emberbeetle": ("mirelo_text_to_audio", 3, "huge beetle buzzing roar, droning wings and clicking mandibles, windmill creak tail, "
                         "cartoon creature sound effect, no voice, no music"),
    "roar_thunderwright": ("mirelo_text_to_audio", 3, "big engine revving into a thunderclap with electric crackle and a short mechanical "
                           "horn blast, cartoon sound effect, no voice, no music"),
    # Item 2: a finish jingle for every place (jingle_last is synthesised: synth_sfx.py last_place).
    "jingle_place2": ("sonilo_music", 10, "short proud runner-up fanfare for a kids racing game, brass and marimba, upbeat, ends on a "
                      "hopeful major chord, no vocals"),
    "jingle_place3": ("sonilo_music", 10, "short cheerful jingle, xylophone and bright horns, bouncy, ends on a major chord, no vocals"),
    "jingle_midpack": ("sonilo_music", 8, "short friendly good-try jingle, ukulele and glockenspiel, light and encouraging, ends on a "
                       "gentle chord, no vocals"),
    # Item 3: the final-lap sting.
    "jingle_finallap": ("mirelo_text_to_audio", 3, "two-second orchestral brass fanfare stab over a snare roll, urgent and exciting, bouncy "
                        "adventure racing game style, no vocals"),
    # Spec fallback: the mirelo take of jingle_finallap was a 3 s crescendo cut off at its peak (no stab up front), so
    # the sting is rendered as a short sonilo cue and trimmed to 2.5 s by prep_audio (--max-len 2.5).
    "jingle_finallap_sonilo": ("sonilo_music", 6, "two-second orchestral brass fanfare stab over a snare roll, urgent and exciting, "
                               "bouncy adventure racing game style, no vocals"),
}


def run(args):
    p = subprocess.run(["higgsfield", "--json", *args], capture_output=True, text=True, timeout=1800)
    if p.returncode != 0:
        raise RuntimeError(p.stderr[-800:] or p.stdout[-800:])
    return json.loads(p.stdout)


def find_url(o):
    if isinstance(o, dict):
        for k, v in o.items():
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


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    jobs = json.loads(JOBS.read_text()) if JOBS.exists() else {}
    want = sys.argv[1:] or list(CUES)

    def downloaded(cue):
        return [f for f in OUT.glob(cue + ".*") if f.suffix in (".mp3", ".wav", ".ogg", ".m4a", ".flac")]

    # Two passes: submit every missing job first (they render in parallel), then wait and download each.
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
        model, dur, prompt = CUES[cue]
        done = downloaded(cue)
        if done:
            print("exists", cue, done[0].name)
            continue
        j = jobs.get(cue)
        if not j:
            res = run(["generate", "create", model, "--prompt", prompt, "--duration", str(dur)])
            # The CLI has answered with a dict, a list of dicts and a list of id strings; accept all three.
            first = res[0] if isinstance(res, list) and res else res
            jid = first if isinstance(first, str) else (first.get("id") or first.get("job_id") or (first.get("jobs") or [{}])[0].get("id"))
            j = {"job_id": jid, "model": model, "duration": dur, "prompt": prompt}
            jobs[cue] = j
            JOBS.write_text(json.dumps(jobs, indent=1))
            print("created", cue, jid)
        res = run(["generate", "wait", j["job_id"]])
        url = find_url(res)
        if not url:
            print("NO_URL", cue, json.dumps(res)[:600])
            continue
        ext = Path(url.split("?")[0]).suffix or ".mp3"
        dest = OUT / (cue + ext)
        urllib.request.urlretrieve(url, dest)
        j["file"] = dest.name
        j["bytes"] = dest.stat().st_size
        JOBS.write_text(json.dumps(jobs, indent=1))
        print("done", cue, dest.name, dest.stat().st_size)


if __name__ == "__main__":
    main()
