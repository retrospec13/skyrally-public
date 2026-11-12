#!/usr/bin/env python3
"""Real-time-ish clips of the own Studio window for TEST_LIST "clip" evidence.

    rec = clip.start("l72_survival", 60)   # win/clip_rec.js grabs frames on the PC while the test runs
    ...                                      # drive the test (real input)
    mp4 = clip.finish(rec)                   # ffmpeg on the PC at the measured frame rate, 1280 wide -> out/clips/

Standalone: clip.py <tag> <seconds> records while something else plays."""
import json
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import lane  # noqa: E402

FFMPEG = r"%LOCALAPPDATA%\Microsoft\WinGet\Packages\Gyan.FFmpeg_Microsoft.Winget.Source_8wekyb3d8bbwe\ffmpeg-8.1.1-full_build\bin\ffmpeg.exe"


def frame_pattern(pc_dir, timing):
    """ffmpeg input pattern for the recorded frames. V5-3: win/clip_rec.js names frames by their real format and writes
    it to timing.json as "ext"; screen_capture answers JPEG, and the old fixed f_%05d.png made ffmpeg fail with
    "Invalid PNG signature 0xFFD8FFE0". A timing.json without "ext" is the old recorder's (frames named .png);
    start() always uploads the current recorder, so that only matters for re-encoding an old directory."""
    ext = str(timing.get("ext") or "png").lower().lstrip(".")
    if ext not in ("jpg", "png"):
        raise ValueError(f"unknown clip frame format {ext!r}")
    return f"{pc_dir}\\f_%05d.{ext}"


def start(tag, seconds):
    lane.put(lane.ROOT / "tools/windows/clip_rec.js", "win/clip_rec.js")
    pc_dir = f"{lane.PCWIN}\\out\\clips\\{tag}"
    lane.ssh(f"cmd /c \"if exist {pc_dir} rmdir /s /q {pc_dir}\"", check=False)
    proc = subprocess.Popen(["ssh", "-o", "BatchMode=yes", "-i", lane.KEY, lane.HOST,
                             f"set SKY_PLACE={lane.PLACE}&& node {lane.PCWIN}\\win\\clip_rec.js {pc_dir} {seconds}"],
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    return {"tag": tag, "proc": proc, "pc_dir": pc_dir}


def finish(rec, timeout=600):
    out, _ = rec["proc"].communicate(timeout=timeout)
    tag, pc_dir = rec["tag"], rec["pc_dir"]
    timing_local = lane.OUT / f"clip_{tag}_timing.json"
    lane.get(f"out/clips/{tag}/timing.json", timing_local)
    timing = json.loads(timing_local.read_text())
    fps = max(0.5, timing["fps"])
    mp4 = f"{lane.PCWIN}\\out\\clips\\{tag}.mp4"
    lane.ssh(f"cmd /c \"\"{FFMPEG}\" -y -v error -framerate {fps:.3f} -i {frame_pattern(pc_dir, timing)} "
             f"-vf scale=1280:-2 -c:v libx264 -pix_fmt yuv420p -crf 26 {mp4}\"", timeout=timeout)
    local = lane.OUT / "clips" / f"{tag}.mp4"
    local.parent.mkdir(parents=True, exist_ok=True)
    lane.get(f"out/clips/{tag}.mp4", local)
    print(out.strip().splitlines()[-1] if out.strip() else "", "->", local)
    return local


if __name__ == "__main__":
    finish(start(sys.argv[1], int(sys.argv[2])))
