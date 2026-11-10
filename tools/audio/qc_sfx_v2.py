#!/usr/bin/env python3
"""Listen-check without ears for assets/audio/sfx_v2: decodes every .ogg the way the engine will, then reports duration,
sample/true peak, RMS, integrated loudness (ffmpeg loudnorm), leading/trailing silence, DC offset, spectral centroid,
energy below 100 Hz / above 8 kHz, a loop-seam score for loops, and checks the brief's limits (peak <= -1 dBFS, short UI
<= 0.25 s, impacts <= 1 s). Writes measure.json and spectrogram contact sheets (qc/contact_N.png).
Usage: qc_sfx_v2.py <sfx_dir>"""
import json
import re
import subprocess
import sys
from pathlib import Path

import imageio_ffmpeg
import numpy as np
from scipy.signal import resample_poly

sys.path.insert(0, str(Path(__file__).resolve().parent))
import synth_sfx_v2 as S  # noqa: E402

FF = imageio_ffmpeg.get_ffmpeg_exe()
SR = 44100


def decode(p):
    raw = subprocess.run([FF, "-v", "error", "-i", str(p), "-f", "f32le", "-ac", "2", "-ar", str(SR), "-"], capture_output=True, check=True).stdout
    return np.frombuffer(raw, dtype=np.float32).reshape(-1, 2).astype(np.float64)


def loudnorm(p):
    r = subprocess.run([FF, "-hide_banner", "-nostats", "-i", str(p), "-af", "loudnorm=I=-16:TP=-1:LRA=11:print_format=json", "-f", "null", "-"], capture_output=True, text=True)
    m = re.search(r"\{[^{}]*\"input_i\"[^{}]*\}", r.stderr, re.S)
    if not m:
        return None
    d = json.loads(m.group(0))
    return {"lufs": float(d["input_i"]), "true_peak_db": float(d["input_tp"]), "lra": float(d["input_lra"])}


def db(v):
    return 20 * np.log10(max(v, 1e-9))


def measure(p, role):
    x = decode(p)
    m = x.mean(axis=1)
    n = len(x)
    dur = n / SR
    peak = db(np.abs(x).max())
    up = resample_poly(x, 4, 1, axis=0)
    tpeak = db(np.abs(up).max())
    rms = db(np.sqrt((x ** 2).mean()))
    lv = np.abs(m)
    thr = lv.max() * 10 ** (-50 / 20)
    on = np.where(lv > thr)[0]
    lead = on[0] / SR * 1000 if len(on) else dur * 1000
    trail = (n - 1 - on[-1]) / SR * 1000 if len(on) else dur * 1000
    spec = np.abs(np.fft.rfft(m * np.hanning(n))) ** 2
    f = np.fft.rfftfreq(n, 1 / SR)
    cen = float((f * spec).sum() / (spec.sum() + 1e-12))
    tot = spec.sum() + 1e-12
    out = {
        "duration_s": round(dur, 3), "peak_dbfs": round(peak, 2), "true_peak_dbfs": round(tpeak, 2), "rms_dbfs": round(rms, 2),
        "lead_silence_ms": round(lead, 1), "tail_silence_ms": round(trail, 1), "dc": round(float(x.mean()), 6),
        "centroid_hz": round(cen), "below_100hz_pct": round(100 * spec[f < 100].sum() / tot, 1), "above_8k_pct": round(100 * spec[f > 8000].sum() / tot, 1),
        "clipped_samples": int((np.abs(x) >= 0.999).sum()),
    }
    ln = loudnorm(p)
    if ln:
        out.update(ln)
    return x, out


def seam_score(x):
    """Loop wrap check: the jump from the last sample to the first, relative to the typical sample-to-sample step (<= 3 is seamless)."""
    m = x.mean(axis=1)
    step = np.abs(np.diff(m)).mean() + 1e-9
    jump = abs(m[0] - m[-1])
    return float(jump / step)


def check(role, meta, out):
    probs = []
    cls = S.ROLES[role][1]
    if out["true_peak_dbfs"] > -1.0:
        probs.append(f"true peak {out['true_peak_dbfs']} > -1 dBFS")
    if out["clipped_samples"]:
        probs.append("clipped samples")
    lim = S.LIMITS.get(cls)
    if cls == "ui" and out["duration_s"] > 0.25:
        probs.append(f"UI {out['duration_s']}s > 0.25s")
    if cls == "impact" and out["duration_s"] > 1.0:
        probs.append(f"impact {out['duration_s']}s > 1.0s")
    if cls != "loop" and out["lead_silence_ms"] > 20:
        probs.append(f"leading silence {out['lead_silence_ms']} ms")
    if cls in ("impact", "item3d") and out["below_100hz_pct"] > 45:
        probs.append(f"{out['below_100hz_pct']}% of energy < 100 Hz (inaudible on phones)")
    if abs(out["dc"]) > 0.002:
        probs.append("DC offset")
    return probs


def sheet(rows, path, title):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    cols = 4
    nrows = (len(rows) + cols - 1) // cols
    fig, axes = plt.subplots(nrows, cols, figsize=(cols * 4.4, nrows * 2.5), squeeze=False)
    fig.suptitle(title, fontsize=11)
    for ax in axes.flat:
        ax.axis("off")
    for ax, (role, x, o) in zip(axes.flat, rows):
        ax.axis("on")
        m = x.mean(axis=1)
        ax.specgram(m, NFFT=1024, Fs=SR, noverlap=768, cmap="magma", vmin=-110, vmax=-20, scale="dB")
        ax.set_ylim(0, 16000)
        ax.set_yticks([0, 4000, 8000, 12000, 16000])
        ax.set_yticklabels(["0", "4k", "8k", "12k", "16k"], fontsize=6)
        ax.tick_params(axis="x", labelsize=6)
        ax.set_title(f"{role}  {o['duration_s']}s  pk {o['true_peak_dbfs']}  {o.get('lufs', 0)} LUFS", fontsize=7)
    fig.tight_layout(rect=(0, 0, 1, 0.97))
    fig.savefig(path, dpi=70)
    plt.close(fig)


# Effective RMS (dBFS) each cue should sit at in the mix BEFORE the SoundGroup, by class and by exception. The existing
# cues are -16 RMS files played at Volume 0.4-0.9 (about -20 effective), the three crude replaced WAVs were -18..-22 RMS
# at 0.58-0.68; gain_db = target - file RMS, and Volume = 10 ^ (gain_db / 20).
TARGET = {"boost": -21.0, "pickup": -22.0, "impact": -19.0, "item3d": -20.0, "jingle": -21.0, "ui": -27.0, "loop": -31.0}
TARGET_ROLE = {"crash_hit": -18.0, "missile_explode": -18.0, "boost_overcharge": -20.0, "finish_tada": -20.0, "countdown_v2": -22.0,
               "place_down": -30.0, "vote_pip": -29.0, "trap_arm": -33.0, "shield_loop": -37.0, "missile_loop": -30.0, "grid_rev": -25.0,
               "wall_scrape": -24.0, "splash_small": -23.0, "land_thud": -21.0, "wall_bump": -21.0, "respawn_pop": -22.0, "pad_zip": -23.0,
               "ring_pass": -23.0, "pod_pop": -22.0, "oil_slip": -23.0, "shield_up": -22.0, "magnet_lock": -22.0, "unlock_fanfare": -20.0,
               "coin_all": -21.0, "lap_ding": -21.0, "wrong_way": -21.0}
LICENCE = "original: synthesised in code (numpy/scipy, tools/audio/synth_sfx_v2.py), no samples or models; no third-party rights"
REPLACES = {
    "boost_kick": "SoundJuice.SOUND_IDS.BoostWhoosh (crude 10-18 WAV, 91840597129266 family)",
    "pod_pickup": "SoundJuice PickupChime (BoostWhoosh pitched 1.28-1.42)",
    "crash_hit": "SoundJuice.SOUND_IDS.CrashThud (crude 10-18 WAV)",
    "lap_ding": "SoundJuice.SOUND_IDS.LapFanfare (crude 10-18 WAV) for laps",
    "finish_tada": "SoundJuice.SOUND_IDS.LapFanfare for Finish / token award",
    "countdown_v2": "AudioAssets.jingle_countdown (3 sine beeps + chord, same 4.2 s timing)",
    "respawn_pop": "trick_whoosh pitched 0.9 (stand-in)",
    "wrong_way": "style_v1 leash_warn (plain beep, -13 dBFS peak)",
    "pod_pop": "payoffs confetti_pop (podium cue reused for the pod)",
    "missile_launch": "BoostWhoosh via SoundJuice 'medium' Boost (stand-in)",
    "trap_drop": "pickup chime 'Checkpoint' (stand-in)",
    "shield_up": "pickup chime 'Checkpoint' (stand-in)",
}


def write_lists(d, res):
    out = []
    for role, (fn, cls, rms, ceil, mono, loopx, event, _gain, notes) in S.ROLES.items():
        o = res[role]
        tgt = TARGET_ROLE.get(role, TARGET[cls])
        gain = round(tgt - o["rms_dbfs"], 1)
        out.append({
            "role": role, "file": f"{role}.ogg", "event": event, "licence": LICENCE, "gain_db": gain,
            "notes": notes + f" Suggested Sound.Volume {min(1.0, round(10 ** (gain / 20), 2))} (gain_db re the file; effective RMS target {tgt} dBFS).",
            "volume": min(1.0, round(10 ** (gain / 20), 2)), "class": cls, "spatial": "3D" if mono else "2D", "loop": loopx is not None,
            "channels": 1 if mono else 2, "duration_s": o["duration_s"], "true_peak_dbfs": o["true_peak_dbfs"], "rms_dbfs": o["rms_dbfs"],
            "lufs": o.get("lufs"), "replaces": REPLACES.get(role),
        })
    (d / "upload_list.json").write_text(json.dumps(out, indent=1) + "\n")


def main():
    d = Path(sys.argv[1])
    res = {}
    rows = []
    bad = 0
    for role in S.ROLES:
        p = d / f"{role}.ogg"
        x, o = measure(p, role)
        cls = S.ROLES[role][1]
        if S.ROLES[role][5] is not None:
            o["loop_seam_ratio"] = round(seam_score(x), 2)
            if o["loop_seam_ratio"] > 4:
                pass
        probs = check(role, S.ROLES[role], o)
        if o.get("loop_seam_ratio", 0) > 4:
            probs.append(f"loop seam ratio {o['loop_seam_ratio']}")
        o["problems"] = probs
        res[role] = o
        rows.append((role, x, o))
        bad += bool(probs)
        print(f"{role:18s} {o['duration_s']:5.2f}s pk {o['peak_dbfs']:6.2f} tp {o['true_peak_dbfs']:6.2f} rms {o['rms_dbfs']:6.1f} lufs {o.get('lufs', float('nan')):6.1f} "
              f"cen {o['centroid_hz']:5d} lo {o['below_100hz_pct']:4.1f}% hi {o['above_8k_pct']:4.1f}% {'; '.join(probs)}")
    (d / "measure.json").write_text(json.dumps(res, indent=1))
    write_lists(d, res)
    q = d / "qc"
    q.mkdir(exist_ok=True)
    for i in range(0, len(rows), 12):
        sheet(rows[i:i + 12], q / f"contact_{i // 12 + 1}.png", f"sfx_v2 spectrograms {i // 12 + 1} (0-16 kHz, dB)")
    print("PROBLEMS:", bad)


if __name__ == "__main__":
    main()
