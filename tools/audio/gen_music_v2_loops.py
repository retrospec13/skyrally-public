#!/usr/bin/env python3
"""Music v2, zone and boss loops (critic-driven rewrite) through Higgsfield sonilo_music. Original instrumental prompts
only: no artist, game or song names, no melody references. Three takes per cue per round. Bookkeeping in
assets/audio/music_v2/jobs_loops.json (key = <cue>_r<round>_t<take>); raw takes land in assets/audio/music_v2/takes/.
Prep (loop, loudness) is tools/audio/prep_music_v2_loops.sh; critic roles are written by that script.
Usage: gen_music_v2_loops.py <round> [cue ...]   (no cues = every cue with a prompt for that round)"""
import json
import subprocess
import sys
import time
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "assets" / "audio" / "music_v2"
TAKES = OUT / "takes"
JOBS = OUT / "jobs_loops.json"
N_TAKES = 3

TAIL = ("Starts instantly on beat one with full energy, no intro, no riser, no silence. A clear catchy four-bar melodic hook "
        "that returns several times. Steady groove with no breakdown into silence. Constant key, no modulation. Loops "
        "seamlessly: the last bar flows back into the first, no final chord, no fade-out, no ending. No vocals, no spoken "
        "words, no shouts. Clean bright mix that reads on phone speakers.")

# round -> cue -> (duration seconds, prompt)
CUES = {
    1: {
        "music_stormcup": (60, "Epic yet playful arcade racing championship theme for a stormy night race, 150 BPM, E minor. Punchy "
                           "slap bass, tight live drum kit with a driving four-on-the-floor kick, big taiko hits on the downbeats, "
                           "bright brass section stabs, rhythm guitar power chords, and a sharp memorable synth lead carrying the "
                           "four-bar hook, with distant thunder-like cymbal swells. Heroic, competitive and fun. " + TAIL),
        "music_boss_snow": (60, "Icy drum and bass boss chase, 172 BPM, F minor. A heavy rolling breakbeat from the first beat, deep "
                            "sub bass with a growling mid bass, aggressive low brass stabs, and a bold four-bar hook on bright "
                            "bells, glockenspiel and a crisp synth lead with frosty shimmer. Urgent, mischievous, family friendly "
                            "boss battle. " + TAIL),
        "music_boss_island": (60, "Swashbuckling drum and bass boss chase, 170 BPM, C minor. Fast breakbeat from the first beat, "
                              "bouncing bass, rapid steel drum and marimba runs, punchy brass stabs, clanking metal percussion, "
                              "and a quirky urgent accordion-and-synth four-bar hook. Frantic, comical yet tense, family friendly "
                              "giant crab boss chase. " + TAIL),
        "music_boss_hub": (60, "Stormy final boss climax, electro drum and bass, 174 BPM, E harmonic minor. Thunderous breakbeat and "
                           "snare from the first beat, driving distorted synth bass, dramatic orchestral brass stabs, timpani, "
                           "crackling electric synth and a piercing heroic lead playing an ultra-catchy four-bar hook. Dark, "
                           "urgent, epic but family friendly, the climax of an adventure. " + TAIL),
    },
    # Forest: the prep fix (loop of the v1 take) topped out at hook 6, so regenerate. Island passed with the prep fix alone.
    2: {
        "music_forest": (60, "Breezy, joyful flying-over-farmland arcade racing theme, 140 BPM, G major. Bouncy upright bass, tight "
                         "snappy drum kit with a hand-clap backbeat, strummed banjo and acoustic guitar rhythm, bright "
                         "glockenspiel sparkles, and a bright whistle-and-fiddle lead playing a simple singable four-bar hook "
                         "built from short repeated notes and a rising leap, with a light retro synth layer under the melody "
                         "for a playful arcade edge. Sunny, windmill meadows, soaring. " + TAIL),
    },
    # Round 2 (bosses and Storm Cup): round 1 takes opened with an 11-20 s build and ended mid-phrase, so the prompts now
    # forbid any build and name the hook on the first beat; critic notes fed the instrument choices.
    2: {
        "music_forest": (60, 'Breezy, joyful flying-over-farmland arcade racing theme, 140 BPM, G major. Bouncy upright bass, tight snappy drum kit with a hand-clap backbeat, strummed banjo and acoustic guitar rhythm, bright glockenspiel sparkles, and a bright whistle-and-fiddle lead playing a simple singable four-bar hook built from short repeated notes and a rising leap, with a light retro synth layer under the melody for a playful arcade edge. Sunny, windmill meadows, soaring.' + " " + TAIL),  # forest round 2, run earlier on its own
        "music_stormcup": (45, "Upbeat late-90s arcade racing championship music for a stormy night, 150 BPM, E minor, no key changes. "
                           "Full band plays the main hook from the very first second: punchy slap bass, tight acoustic drums, bright "
                           "brass section and a sharp memorable synth lead playing a bold four-bar hook that repeats, with rain-like "
                           "shaker and thunder cymbal accents. Energetic, playful, competitive. No build-up section, no breakdown. " + TAIL),
        "music_boss_snow": (45, "174 BPM drum and bass boss race music, F minor, mischievous and icy but playful. The full drum break, "
                            "mid-range reese bass and a bright xylophone-and-bells synth lead playing a catchy repeating four-bar "
                            "hook all begin together on the very first beat, no build-up section. Crisp acoustic-style drum "
                            "transients, clean mix, bass with upper harmonics for phone speakers. " + TAIL),
        "music_boss_island": (45, "Fast frantic playful boss chase for a kart racer, 168 BPM, C minor. Opens with the full band on beat "
                              "one: driving bouncy bassline, rapid-fire marimba and steel drum runs, punchy brass stabs, and a quirky "
                              "urgent accordion and synth lead playing a memorable four-bar hook that repeats. Relentless, comical yet "
                              "tense momentum, no build-up section and no breakdown. " + TAIL),
        "music_boss_hub": (45, "174 BPM high-energy drum and bass final boss racing music, E minor, dramatic and urgent yet playful. Crisp "
                           "punchy breakbeat drums, clean mid-range reese bass, a bright arcade lead synth and staccato orchestral brass "
                           "hits, all playing from the very first beat with an iconic catchy four-bar melodic hook, no build-up section "
                           "and no breakdown. Tight clean mix with clear midrange for small speakers. " + TAIL),
    },
    # Round 3 (forest, second regeneration after the round 2 pseudo-vocal artefact and weak hook).
    3: {
        "music_forest": (45, "Fast joyful countryside flying race theme, 144 BPM, D major. All instruments play from the very first beat: "
                         "stomping kick and snare with tambourine, walking acoustic bass, strummed acoustic guitar, bright banjo, and a "
                         "clear fiddle lead playing a simple catchy four-bar hook made of repeated notes that repeats like a chorus. "
                         "Windmill meadows, sunny and breezy. Strictly instrumental, no humming, no chanting. No build-up, no breakdown. " + TAIL),
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
    rnd = int(sys.argv[1])
    TAKES.mkdir(parents=True, exist_ok=True)
    jobs = json.loads(JOBS.read_text()) if JOBS.exists() else {}
    want = sys.argv[2:] or list(CUES[rnd])
    keys = [(f"{c}_r{rnd}_t{t}", c) for c in want for t in range(1, N_TAKES + 1)]
    for key, cue in keys:
        if key in jobs:
            continue
        dur, prompt = CUES[rnd][cue]
        while True:  # the account allows 8 concurrent jobs shared with other lanes: wait and retry
            try:
                jid = jid_of(run(["generate", "create", "sonilo_music", "--prompt", prompt, "--duration", str(dur)]))
                break
            except RuntimeError as e:
                if "rate_limit" not in str(e):
                    raise
                time.sleep(30)
        jobs[key] = {"job_id": jid, "model": "sonilo_music", "duration": dur, "prompt": prompt, "round": rnd}
        JOBS.write_text(json.dumps(jobs, indent=1))
        print("created", key, jid, flush=True)

    def fetch(key):
        j = jobs[key]
        if j.get("file") and (TAKES / j["file"]).exists():
            return key
        url = find_url(run(["generate", "wait", j["job_id"]]))
        if not url:
            print("NO_URL", key)
            return key
        dest = TAKES / (key + (Path(url.split("?")[0]).suffix or ".m4a"))
        urllib.request.urlretrieve(url, dest)
        j["file"], j["bytes"] = dest.name, dest.stat().st_size
        JOBS.write_text(json.dumps(jobs, indent=1))
        print("done", key, dest.name, flush=True)
        return key

    with ThreadPoolExecutor(4) as ex:
        list(ex.map(fetch, [k for k, _ in keys]))


if __name__ == "__main__":
    main()
