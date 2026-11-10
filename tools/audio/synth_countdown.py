#!/usr/bin/env python3
"""Countdown cue synthesised in code (original, licence-free): beeps at 0, 1, 2 s and a bright GO chord at 3 s, so
Music plays it exactly 3 s before workspace.RaceGoTime and each beep lands on a 3-2-1 numeral.
Usage: synth_countdown.py <out.ogg>"""
import subprocess
import sys
import tempfile

import imageio_ffmpeg
import numpy as np

SR = 44100
t_total = 4.2
x = np.zeros(int(SR * t_total), dtype=np.float32)


def tone(start, dur, freqs, amp, decay):
    n = int(SR * dur)
    t = np.arange(n) / SR
    env = np.exp(-t * decay) * np.minimum(1, t / 0.004)
    sig = sum(np.sin(2 * np.pi * f * t) + 0.25 * np.sin(4 * np.pi * f * t) for f in freqs) / len(freqs)
    i = int(SR * start)
    x[i:i + n] += (amp * env * sig).astype(np.float32)


for k in range(3):
    tone(k * 1.0, 0.22, [880.0], 0.45, 14)
tone(3.0, 1.1, [1046.5, 1318.5, 1568.0], 0.5, 3.2)
x = np.stack([x, x], axis=1)
with tempfile.NamedTemporaryFile(suffix=".f32") as f:
    f.write(x.tobytes())
    f.flush()
    subprocess.run([imageio_ffmpeg.get_ffmpeg_exe(), "-v", "error", "-y", "-f", "f32le", "-ac", "2", "-ar", str(SR), "-i", f.name,
                    "-c:a", "libvorbis", "-q:a", "5", sys.argv[1]], check=True)
print("SYNTH", sys.argv[1])
