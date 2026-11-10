#!/usr/bin/env python3
"""Independent image-bearing visual critic per launch map (TEST_LIST L61; a different model family from the builder).
Sends the map's concept guide plus the visual tour frames (tools/visual_tour.py: gameplay from the chase camera and
three beauty shots) to an OpenRouter vision model and writes evidence/L61/critic_<key>.md: scores, what matches the
concept, and a prioritised fix list aimed at what a player sees from the chase camera on a phone.
Usage: visual_critic.py <key> [model]   (key: dino4 snow1 island2 forest1 space4 hub0)"""
import base64
import json
import sys
import urllib.request
from io import BytesIO
from pathlib import Path

from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parent))
import lane  # noqa: E402

CONCEPT = {
    "dino4": "assets/concepts/skyrally_mockups_v1/04_dino4_controls.png",
    "hub0": "assets/concepts/map_proposals_20/04_HUB0_CENTRAL_ISLAND.png",
    "snow1": "assets/concepts/map_proposals_20/05_SNOW1_EVERFROST_PEAK.png",
    "island2": "assets/concepts/map_proposals_20/10_ISLAND2_CRESCENT_ISLAND.png",
    "forest1": "assets/concepts/map_proposals_20/13_FOREST1_WINDMILL_PLAINS.png",
    "space4": "assets/concepts/map_proposals_20/20_SPACE4_STAR_CITY.png",
}
NAMES = {"dino4": "DINO-4 Dino Ridge (lava canyon, planes)", "hub0": "HUB-0 Central Island (hub, cars)",
         "snow1": "SNOW-1 Frostpeak (planes)", "island2": "ISLAND-2 Sunreef Isles galleon beach (cars)",
         "forest1": "FOREST-1 Windmill Vale (planes)", "space4": "SPACE-4 Neon Moon (cars)"}

PROMPT = """You are an independent senior art director and game-feel critic for a Roblox adventure racer in the
spirit of late-90s kart/plane adventure racers (stylised, bright, readable on a phone, homage not copy). The studio's
goal is REMARKABILITY: players should talk about how good and surprising it looks and feels.

Image 1 is the approved 2D concept guide for {name}. The other images are in-engine captures: gameplay frames from
the chase camera (a real-input pilot flying/driving the race) and three free-camera beauty shots along the course.

Write a concise markdown report:
1. Scores 1-10 with one line each: overall visual quality, match to the concept's composition and mood, colour and
   lighting, route readability at speed, environment density and set dressing, VFX and juice, phone readability of HUD.
2. What already works (max 5 bullets).
3. A prioritised fix list (max 12 items, most impactful first). Each item: what is wrong as seen in which image,
   why it matters to a player, and a concrete fix a Roblox developer can implement (lighting values, materials,
   prop placement, colour, fog/atmosphere, post-processing, VFX, camera). Flag anything that looks like graybox,
   placeholder, untextured, broken, floating, z-fighting or clipping.
4. Three "remarkable moment" ideas specific to this map's look (cheap, surprising, visual).
Be specific and critical; do not praise generically."""


def jpeg_data_url(p: Path, max_w: int = 1280) -> str:
    im = Image.open(p).convert("RGB")
    if im.width > max_w:
        im = im.resize((max_w, int(max_w * im.height / im.width)))
    buf = BytesIO()
    im.save(buf, "JPEG", quality=82)
    return "data:image/jpeg;base64," + base64.b64encode(buf.getvalue()).decode("ascii")


def main():
    key = sys.argv[1]
    model = sys.argv[2] if len(sys.argv) > 2 else "openai/gpt-5.4"
    tour = lane.OUT / "tour" / key
    frames = sorted(tour.glob("*.png"))
    race = [f for f in frames if "_race" in f.name]
    beauty = [f for f in frames if "_beauty" in f.name]
    # Up to six gameplay frames spread over the run, plus every beauty shot.
    pick = [race[int(i * (len(race) - 1) / 5)] for i in range(6)] if len(race) >= 6 else race
    images = [lane.ROOT / CONCEPT[key]] + pick + beauty
    content = [{"type": "text", "text": PROMPT.format(name=NAMES[key])}]
    content += [{"type": "image_url", "image_url": {"url": jpeg_data_url(p)}} for p in images]
    payload = {"model": model, "max_tokens": 6000, "messages": [{"role": "user", "content": content}]}
    req = urllib.request.Request("https://openrouter.ai/api/v1/chat/completions", data=json.dumps(payload).encode(),
                                 headers={"Authorization": f"Bearer {lane.critic_key()}", "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=300) as resp:
        res = json.loads(resp.read().decode())
    msg = res["choices"][0]["message"].get("content", "")
    out = lane.ROOT / "evidence" / "L61" / f"critic_{key}.md"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(f"# Visual critic: {NAMES[key]}\n- Model: `{res.get('model', model)}` (independent of the builder)\n"
                   f"- Images: concept `{CONCEPT[key]}` + {len(pick)} gameplay + {len(beauty)} beauty captures "
                   f"(`out/tour/{key}/`, tools/visual_tour.py)\n- Usage: `{json.dumps(res.get('usage', {}))}`\n\n{msg}\n")
    print(out)
    print(msg[:3000])


if __name__ == "__main__":
    main()
