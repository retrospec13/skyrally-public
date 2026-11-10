#!/usr/bin/env python3
"""Soundscape cues through Higgsfield (docs/REMARKABLE.md Batch 2): zone ambience beds (item 12, mirelo, 20 s each),
the Storm Cup theme and the four battle themes (item 26, sonilo, 90 s loops) and the end-of-battle air horn (item 26,
mirelo). Engine voices, the fly-by whoosh, the backfire pop and the clock ticks are synthesised in code
(tools/audio/synth_soundscape.py), so they are not here.
Original prompts only: they describe genre, instruments, tempo, mood or the sound itself, never an artist, game, song,
melody or existing effect. Idempotent: assets/audio/soundscape_v1/jobs.json records each job; a cue with a downloaded
file is skipped. Reuses gen_music's CLI wrapper.
Usage: gen_soundscape.py [cue ...]   (no args = every cue)
Then: tools/audio/prep_soundscape.sh (prep into assets/audio/soundscape_v1/upload, see docs/ASSETS.md 7)."""
import json
import sys
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from gen_music import find_url, run  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "assets" / "audio" / "soundscape_v1" / "raw"
JOBS = OUT.parent / "jobs.json"
M = "mirelo_text_to_audio"
S = "sonilo_music"
AMB = ", ambience, no music"
BATTLE_LOOP = "instrumental video game arena battle music, seamless loop, no vocals, punchy clean mix, cheeky and family friendly"
STORM_LOOP = "instrumental video game championship race music, seamless loop, no vocals, punchy clean mix, epic but family friendly"
CUES = {
    # Item 12: one ambience bed per zone (looped 20 s, crossfaded on ActiveZone), plus the Storm Cup's rain layer.
    "amb_dino": (M, 20, "deep volcanic cavern, lava bubbling, low rumble, distant rock cracks" + AMB),
    "amb_snow": (M, 20, "high mountain wind, soft gusts, ice creaks" + AMB),
    "amb_island": (M, 20, "gentle surf, distant seagulls, wooden ship creak" + AMB),
    "amb_forest": (M, 20, "breeze in leaves, songbirds, slow windmill creak" + AMB),
    "amb_space": (M, 20, "soft electric hum, distant hover traffic, gentle beeps" + AMB),
    "amb_hub": (M, 20, "light surf, fountain splash, distant birds" + AMB),
    "amb_storm": (M, 20, "steady night rain, distant rolling thunder, gusty wind" + AMB),
    # Item 26: the Storm Cup race theme and one theme per battle kind (survival SNOW-1, egg DINO-4, water ISLAND-2,
    # hoard FOREST-1).
    "music_stormcup": (S, 90, "stormy night championship racing theme, 152 BPM, thunderous taiko and rock drums, pulsing synth "
                              "bass, heroic brass melody, urgent string ostinato, electric guitar power chords, thunderclap "
                              "hits, " + STORM_LOOP),
    "music_battle_survival": (S, 90, "frosty arena brawl theme, 128 BPM, bouncy brass and tuba over a funky breakbeat, sleigh "
                                     "bells, playful pizzicato strings, cheeky and combative, " + BATTLE_LOOP),
    "music_battle_egg": (S, 90, "prehistoric egg scramble battle theme, 132 BPM, tribal toms and bongos, slap bass, "
                                "cartoony bassoon and xylophone runs, sneaky and playful, " + BATTLE_LOOP),
    "music_battle_water": (S, 90, "rowdy naval cannon battle theme, 126 BPM, swinging sea shanty groove, accordion, tuba "
                                  "and steel drum, splashy cymbals, comic and boisterous, " + BATTLE_LOOP),
    "music_battle_hoard": (S, 90, "barnyard treasure scramble battle theme, 140 BPM, frantic banjo and fiddle hoedown over "
                                  "funky drums, nasal reed synth lead, mischievous, " + BATTLE_LOOP),
    # Item 26: the buzzer when a battle clock (or the Storm Cup lobby clock) runs out.
    "sfx_airhorn": (M, 3, "one loud stadium air horn blast held for about one and a half seconds, then silence, arena "
                          "sound effect, no voice, no music"),
    # Take 2: take 1 rendered a 0.3 s blip at -18 dB peak (kept as raw/sfx_airhorn.mp3, rejected).
    "sfx_airhorn_2": (M, 3, "very loud continuous handheld air horn blast lasting the full three seconds, harsh brassy "
                            "honk, sports arena end of game buzzer, sound effect, no voice, no music"),
}


def downloaded(cue):
    return [f for f in OUT.glob(cue + ".*") if f.suffix in (".mp3", ".wav", ".ogg", ".m4a", ".flac")]


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    jobs = json.loads(JOBS.read_text()) if JOBS.exists() else {}
    want = sys.argv[1:] or list(CUES)
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
        with urllib.request.urlopen(url, timeout=180) as r:
            dest.write_bytes(r.read())
        j["file"] = dest.name
        j["bytes"] = dest.stat().st_size
        JOBS.write_text(json.dumps(jobs, indent=1))
        print("downloaded", cue, dest.name, j["bytes"], flush=True)


if __name__ == "__main__":
    main()
