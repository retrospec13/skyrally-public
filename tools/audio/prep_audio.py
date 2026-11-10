#!/usr/bin/env python3
"""Make a generated cue game-ready: decode (any ffmpeg format), optional seamless loop (the last `xfade` seconds are
crossfaded onto the head and cut, so the Looped Sound wraps without a seam), loudness to a target RMS with a peak
ceiling, then OGG Vorbis (Roblox accepts ogg/mp3, not the m4a the generator returns).
Usage: prep_audio.py <in> <out.ogg> [--loop] [--xfade 2.5] [--rms -19] [--trim-silence] [--trim-rel DB] [--end S]
                    [--cut-fade] [--align] [--max-len S] [--fade-out S]
  --trim-rel DB  trim leading/trailing audio quieter than (peak - DB) instead of the fixed -50 dBFS
  --end S        cut the source at S seconds first (drop a generated "ending" tag before looping)
  --cut-fade     cut a trailing fade-out (the generator ends loops on a fade, which would crossfade into the head)
  --align        with --loop: move the cut end (up to 3 s earlier) so the crossfaded tail lands on the head's beat
  --max-len S    keep at most S seconds (after trimming), with --fade-out S of fade at the end (stingers)
  --lead-rel DB  start 0.1 s before the first 20 ms window within DB of the loudest one (a roar's hit lands at once)
  --tail S       fade the last S seconds (a generated one-shot that stops dead at its render length)"""
import argparse
import subprocess
import tempfile
from pathlib import Path

import imageio_ffmpeg
import numpy as np

FF = imageio_ffmpeg.get_ffmpeg_exe()
SR = 44100


def decode(path: Path) -> np.ndarray:
    raw = subprocess.run([FF, "-v", "error", "-i", str(path), "-f", "f32le", "-ac", "2", "-ar", str(SR), "-"],
                         capture_output=True, check=True).stdout
    return np.frombuffer(raw, dtype=np.float32).reshape(-1, 2).copy()


def encode(x: np.ndarray, out: Path):
    with tempfile.NamedTemporaryFile(suffix=".f32") as t:
        t.write(np.ascontiguousarray(x, dtype=np.float32).tobytes())
        t.flush()
        subprocess.run([FF, "-v", "error", "-y", "-f", "f32le", "-ac", "2", "-ar", str(SR), "-i", t.name,
                        "-c:a", "libvorbis", "-q:a", "5", str(out)], check=True)


def trim_silence(x: np.ndarray, thresh_db: float = -50) -> np.ndarray:
    level = np.abs(x).max(axis=1)
    on = np.where(level > 10 ** (thresh_db / 20))[0]
    return x[on[0]: on[-1] + 1] if len(on) else x


def window_db(m: np.ndarray, win: int) -> np.ndarray:
    n = len(m) // win
    return 20 * np.log10(np.sqrt(np.mean(m[: n * win].reshape(n, win) ** 2, axis=1)) + 1e-9)


def cut_fade(x: np.ndarray) -> np.ndarray:
    """Cut at the end of the last 0.1 s window that is within 6 dB of the median level."""
    win = int(SR * 0.1)
    lv = window_db(x.mean(axis=1), win)
    keep = np.where(lv >= np.median(lv) - 6)[0]
    return x[: (keep[-1] + 1) * win] if len(keep) else x


def flux(m: np.ndarray, hop: int = 256) -> np.ndarray:
    n = len(m) // hop - 1
    frames = np.lib.stride_tricks.sliding_window_view(m, hop * 2)[:: hop][:n]
    spec = np.log1p(np.abs(np.fft.rfft(frames * np.hanning(hop * 2), axis=1)))
    f = np.maximum(0, np.diff(spec, axis=0)).sum(axis=1)
    return (f - f.mean()) / (f.std() + 1e-9)


def align_end(x: np.ndarray, L: int, search_s: float = 3.0) -> np.ndarray:
    """Choose the cut end n (within search_s before the current end) whose crossfade tail x[n-L:n] best matches the
    onset pattern of the head x[0:L], so the loop seam keeps the beat instead of flamming two drum patterns."""
    hop = 256
    m = x.mean(axis=1)
    fl = flux(m, hop)
    head = fl[: L // hop]
    hl = len(head)
    best, best_n = -1e9, len(x)
    last = len(fl)
    for end in range(last, max(hl, last - int(search_s * SR / hop)), -1):
        tail = fl[end - hl: end]
        if len(tail) < hl:
            break
        c = float(np.dot(head, tail))
        if c > best:
            best, best_n = c, end * hop
    print(f"ALIGN cut {len(x) / SR:.2f}s -> {best_n / SR:.2f}s score={best / hl:.2f}")
    return x[:best_n]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("inp")
    ap.add_argument("out")
    ap.add_argument("--loop", action="store_true")
    ap.add_argument("--xfade", type=float, default=2.5)
    ap.add_argument("--rms", type=float, default=-19.0)
    ap.add_argument("--trim-silence", action="store_true")
    ap.add_argument("--trim-rel", type=float, default=None)
    ap.add_argument("--end", type=float, default=None)
    ap.add_argument("--cut-fade", action="store_true")
    ap.add_argument("--align", action="store_true")
    ap.add_argument("--max-len", type=float, default=None)
    ap.add_argument("--fade-out", type=float, default=0.25)
    ap.add_argument("--lead-rel", type=float, default=None)
    ap.add_argument("--tail", type=float, default=0.0)
    a = ap.parse_args()
    x = decode(Path(a.inp))
    if a.end:
        x = x[: int(a.end * SR)]
    if a.trim_silence:
        x = trim_silence(x)
    if a.trim_rel is not None:
        peak_db = 20 * np.log10(np.abs(x).max() + 1e-9)
        x = trim_silence(x, peak_db - a.trim_rel)
    if a.lead_rel is not None:
        win = int(SR * 0.02)
        lv = window_db(x.mean(axis=1), win)
        first = int(np.argmax(lv >= lv.max() - a.lead_rel))
        x = x[max(0, first * win - int(SR * 0.1)):]
    if a.cut_fade:
        x = cut_fade(x)
    if a.max_len and len(x) > int(a.max_len * SR):
        x = x[: int(a.max_len * SR)].copy()
        F = int(a.fade_out * SR)
        x[-F:] *= np.linspace(1, 0, F, dtype=np.float32)[:, None] ** 2
    if a.tail > 0 and not a.loop:
        F = min(len(x), int(a.tail * SR))
        x = x.copy()
        x[-F:] *= np.linspace(1, 0, F, dtype=np.float32)[:, None] ** 2
    if a.loop:
        L = int(a.xfade * SR)
        if a.align:
            x = align_end(x, L)
        n = len(x)
        head, tail = x[:L], x[n - L:]
        t = np.linspace(0, 1, L, dtype=np.float32)[:, None]
        # equal-power crossfade: the wrap from y[-1] (= x[n-L-1]) to y[0] (~ x[n-L]) is continuous
        y = x[: n - L].copy()
        y[:L] = head * np.sin(t * np.pi / 2) + tail * np.cos(t * np.pi / 2)
        x = y
    rms = float(np.sqrt(np.mean(x ** 2)) + 1e-9)
    x = x * (10 ** (a.rms / 20) / rms)
    peak = float(np.abs(x).max())
    if peak > 0.89:  # about -1 dBFS ceiling; soft knee instead of a hard clip
        x = np.tanh(x / 0.89) * 0.89
    encode(x, Path(a.out))
    print(f"PREP {a.out} seconds={len(x) / SR:.2f} rms_db={20 * np.log10(np.sqrt(np.mean(x ** 2)) + 1e-9):.1f} "
          f"peak_db={20 * np.log10(np.abs(x).max() + 1e-9):.1f} loop={a.loop}")


if __name__ == "__main__":
    main()
