#!/usr/bin/env python3
"""Independent listening critic for SkyRally's music and cues (TEST_LIST L24; a different model family from the one that
generated them). Sends each audio file with its intended role to an audio-capable OpenRouter model and writes one
markdown report with per-track scores, defects heard (AI warble, clipping, seams, vocals) and a keep/fix/regenerate
call with a better original prompt (no artist, game or song names).
Usage: audio_critic.py <report_name> <role-file.json> [model]
role-file: [{"key": "music_dino", "path": "assets/audio/music_v1/upload/music_dino.ogg", "role": "DINO-4 lava canyon race loop"}]"""
import base64
import json
import sys
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import lane  # noqa: E402

PROMPT = """You are an independent music supervisor and audio director for a Roblox adventure racer (planes and cars) in the
spirit of late-90s kart/plane adventure racers: bright, playful, family friendly, readable on phone speakers. The owner says
music and sound are among the most important parts of the game and wants tracks that feel OG for the genre or trending, so
players remember them and remark on them. Every track must be original (no recognisable melody from any existing song or game).

Listen to this file. Its intended role: {role}.
Reply in concise markdown:
1. Scores 1-10, one line each: hook/memorability, fit to the role and zone, energy for racing (or the cue's job), production and
   mix quality, loopability (seam, clean ending), distinctiveness versus generic AI stock music, phone-speaker readability.
2. Defects heard, with timestamps: AI artefacts (warble, smeared transients, phasing, garbled pseudo-vocals), clipping or pumping,
   abrupt cut, silence, tempo drift, sections that drag, anything resembling a famous melody.
3. Verdict: KEEP, FIX (say exactly what edit: trim, loop point, EQ, layer) or REGENERATE (write a better original generation
   prompt: instruments, BPM, key mood, structure with a 4-bar hook, no artist/game/song names).
Be specific and critical."""


def ask(model, path, role):
    data = base64.b64encode(Path(path).read_bytes()).decode("ascii")
    fmt = Path(path).suffix.lstrip(".").lower()
    content = [{"type": "text", "text": PROMPT.format(role=role)},
               {"type": "input_audio", "input_audio": {"data": data, "format": fmt}}]
    payload = {"model": model, "max_tokens": 3000, "messages": [{"role": "user", "content": content}]}
    req = urllib.request.Request("https://openrouter.ai/api/v1/chat/completions", data=json.dumps(payload).encode(),
                                 headers={"Authorization": f"Bearer {lane.critic_key()}", "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=600) as resp:
        res = json.loads(resp.read().decode())
    return res.get("model", model), res["choices"][0]["message"].get("content", ""), res.get("usage", {})


def main():
    name, roles = sys.argv[1], json.loads(Path(sys.argv[2]).read_text())
    model = sys.argv[3] if len(sys.argv) > 3 else "google/gemini-4-argon"
    out = lane.ROOT / "evidence" / "L24" / f"audio_critic_{name}.md"
    out.parent.mkdir(parents=True, exist_ok=True)
    parts = [f"# Audio critic: {name}\n- Model: `{model}` (independent of the generator)\n"]
    for r in roles:
        try:
            used, msg, usage = ask(model, lane.ROOT / r["path"], r["role"])
        except Exception as e:  # keep going; record the failure in the report
            used, msg, usage = model, f"CRITIC ERROR: {e}", {}
        parts.append(f"\n## {r['key']}\n- File: `{r['path']}`\n- Role: {r['role']}\n- Model: `{used}`, usage `{json.dumps(usage)}`\n\n{msg}\n")
        print(f"== {r['key']}\n{msg[:1500]}\n", flush=True)
        out.write_text("".join(parts))
    print(out)


if __name__ == "__main__":
    main()
