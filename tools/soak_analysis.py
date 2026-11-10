#!/usr/bin/env python3
"""Soak analysis (audit T1-12): leak detection and the JSON + markdown report for tools/soak.py. Pure Python, no Studio:
`python3 tools/soak.py analyze <soak.json>` re-reads any saved run, and tools/tests/test_soak_analysis.py covers it.

Input: the sample records server/QASoak produces, one per sample point:
  {step, cycle, map, phase: baseline|race|results|hub|skipped|failed, t, loadSecs?, timedOut?, home?,
   server: {memMb, instances, wsInstances, wsChildren, mapRoots, players, heartbeatMs, sendKbps, recvKbps, errors,
            warnings, errorTail, tag_<MemoryTag>...},
   clients: {<player name>: {memMb, instances, wsInstances, meanMs, p95Ms, worstMs, sendKbps, recvKbps, errors, ...}},
   clientsMissing: [names]}

Leak rule (monotonic growth): for one metric series (after the warm-up points that fill map caches) a LEAK needs ALL of
  - at least MIN_POINTS points left,
  - growth (median of the last two points minus median of the first two) >= the metric's absolute threshold AND
    >= its relative threshold times the starting level,
  - a positive least-squares slope,
  - at least MONO_FRAC of the steps not going down by more than the noise floor (a sawtooth that returns is not a leak).
Series: HUB (the state after each return to the hub, all maps interleaved) and RACE per map (the same map's race sample
once per cycle, needs >= WARM+MIN_POINTS cycles). Errors and failed steps fail a run too; too few points is INCONCLUSIVE.
"""
import json
import statistics
from collections import defaultdict

MIN_POINTS = 4
MONO_FRAC = 0.75

# metric -> (abs growth, relative growth, kind). kind "level" = a leak when it grows; "latency" = a creep to report.
THRESHOLDS = {
    "memMb": (30.0, 0.05, "level"),
    "instances": (300.0, 0.02, "level"),
    "wsInstances": (300.0, 0.02, "level"),
    "wsChildren": (20.0, 0.10, "level"),
    "mapRoots": (2.0, 0.0, "level"),
    "tag_Signals": (2.0, 0.10, "level"),
    "tag_Script": (10.0, 0.05, "level"),
    "tag_LuaHeap": (10.0, 0.05, "level"),
    "tag_Instances": (5.0, 0.10, "level"),
    "tag_PhysicsParts": (5.0, 0.10, "level"),
    "tag_GraphicsTerrain": (10.0, 0.10, "level"),
    "tag_TerrainVoxels": (10.0, 0.10, "level"),
    "tag_GraphicsMeshParts": (30.0, 0.05, "level"),
    "tag_GraphicsTexture": (40.0, 0.05, "level"),
    "tag_Sounds": (15.0, 0.10, "level"),
    "heartbeatMs": (2.0, 0.25, "latency"),
    "p95Ms": (4.0, 0.20, "latency"),
}
# Reported, never judged (connection and traffic figures vary with what is on screen).
INFO_METRICS = ["sendKbps", "recvKbps", "players"]
MAX_ERRORS = 0  # error lines allowed over the whole run (server + clients); warnings are only counted


def detect(values, abs_t, rel_t, warm=0, min_points=MIN_POINTS, mono_frac=MONO_FRAC):
    """One series -> {status: ok|leak|insufficient, n, first, last, growth, slope, monoFrac}."""
    vals = [float(v) for v in values if isinstance(v, (int, float)) and v >= 0]
    vals = vals[warm:]
    out = {"n": len(vals)}
    if len(vals) < min_points:
        out["status"] = "insufficient"
        return out
    first = statistics.median(vals[:2])
    last = statistics.median(vals[-2:])
    growth = last - first
    n = len(vals)
    xm = (n - 1) / 2.0
    ym = sum(vals) / n
    den = sum((i - xm) ** 2 for i in range(n)) or 1.0
    slope = sum((i - xm) * (v - ym) for i, v in enumerate(vals)) / den
    noise = max(abs_t * 0.02, 0.0)
    steps = [vals[i + 1] - vals[i] for i in range(n - 1)]
    mono = sum(1 for d in steps if d >= -noise) / len(steps)
    leak = growth >= abs_t and growth >= rel_t * max(first, 0.0) and slope > 0 and mono >= mono_frac
    out.update(first=round(first, 2), last=round(last, 2), growth=round(growth, 2), slope=round(slope, 3),
               monoFrac=round(mono, 2), status="leak" if leak else "ok")
    return out


def _get(sample, path):
    cur = sample
    for p in path:
        if not isinstance(cur, dict) or p not in cur:
            return None
        cur = cur[p]
    return cur


def analyze(samples, maps=None, thresholds=None):
    """-> {verdict, findings, series, perMap, errors, steps, traffic}. verdict PASS | FAIL | INCONCLUSIVE."""
    th = dict(THRESHOLDS)
    if thresholds:
        th.update({k: tuple(v) for k, v in thresholds.items()})
    maps = maps or sorted({s.get("map") for s in samples if s.get("phase") in ("race", "hub") and s.get("map")})
    hub = [s for s in samples if s.get("phase") in ("baseline", "hub")]
    race = [s for s in samples if s.get("phase") == "race"]
    findings, series = [], {}

    def players_of(group):
        names = []
        for s in group:
            for n in (s.get("clients") or {}):
                if n not in names:
                    names.append(n)
        return names

    def judge(label, group, warm):
        names = players_of(group)
        sources = [("server", ("server",))] + [("client:" + n, ("clients", n)) for n in names]
        for src, base in sources:
            metrics = set()
            for s in group:
                d = _get(s, base)
                if isinstance(d, dict):
                    metrics.update(k for k in d if k in th)
            for m in sorted(metrics):
                abs_t, rel_t, kind = th[m]
                res = detect([_get(s, base + (m,)) for s in group], abs_t, rel_t, warm)
                res["kind"] = kind
                key = "%s/%s/%s" % (label, src, m)
                series[key] = res
                if res["status"] == "leak":
                    findings.append({"type": "leak" if kind == "level" else "creep", "series": key, **{k: res[k] for k in ("first", "last", "growth", "slope", "monoFrac")}})

    judge("hub", hub, warm=len(maps) + 1 if maps else 1)
    per_map = {}
    for m in maps:
        group = [s for s in race if s.get("map") == m]
        per_map[m] = len(group)
        judge("race:" + m, group, warm=1)

    # Errors, failed steps, missing client replies.
    err_server = err_client = warn_total = 0
    err_lines = []
    for s in samples:
        sv = s.get("server") or {}
        err_server += int(sv.get("errors") or 0)
        warn_total += int(sv.get("warnings") or 0)
        err_lines += [("server @%s step %s: %s" % (s.get("phase"), s.get("step"), l)) for l in (sv.get("errorTail") or [])]
        for n, c in (s.get("clients") or {}).items():
            err_client += int(c.get("errors") or 0)
            warn_total += int(c.get("warnings") or 0)
            err_lines += [("%s @%s step %s: %s" % (n, s.get("phase"), s.get("step"), l)) for l in (c.get("errorTail") or [])]
    if err_server + err_client > MAX_ERRORS:
        findings.append({"type": "errors", "server": err_server, "client": err_client})
    failed = [s for s in samples if s.get("phase") == "failed"]
    skipped = [s for s in samples if s.get("phase") == "skipped"]
    for s in failed:
        findings.append({"type": "failed_step", "step": s.get("step"), "map": s.get("map"), "note": s.get("note")})
    for s in samples:
        if s.get("phase") == "hub" and (s.get("home") is False):
            findings.append({"type": "hub_not_reached", "step": s.get("step"), "map": s.get("map")})
        if s.get("clientsMissing"):
            findings.append({"type": "client_reply_missing", "step": s.get("step"), "phase": s.get("phase"), "clients": s["clientsMissing"]})
    timed = [s for s in samples if s.get("phase") == "hub" and s.get("timedOut")]

    judged = [v for v in series.values() if v["status"] != "insufficient"]
    hard = [f for f in findings if f["type"] in ("leak", "errors", "failed_step", "hub_not_reached")]
    # Clients were expected (a reply went missing) but no client series could be judged: the client half of the soak
    # (frame times, client memory) never ran, so a server-only PASS would overstate it.
    clients_expected = any(s.get("clientsMissing") for s in samples)
    clients_judged = any(k.split("/")[1].startswith("client:") for k, v in series.items() if v["status"] != "insufficient")
    if hard:
        verdict = "FAIL"
    elif not judged or (clients_expected and not clients_judged):
        verdict = "INCONCLUSIVE"
    else:
        verdict = "PASS"

    traffic = defaultdict(lambda: defaultdict(list))
    for s in samples:
        ph = s.get("phase")
        for m in ("sendKbps", "recvKbps"):
            v = _get(s, ("server", m))
            if isinstance(v, (int, float)) and v >= 0:
                traffic[ph][m].append(v)
    traffic_out = {ph: {m: round(statistics.mean(v), 2) for m, v in d.items() if v} for ph, d in traffic.items()}

    return {
        "verdict": verdict, "findings": findings, "series": series, "perMap": per_map,
        "steps": {"samples": len(samples), "failed": len(failed), "skipped": len(skipped), "resultsTimedOut": len(timed)},
        "errors": {"server": err_server, "client": err_client, "warnings": warn_total, "lines": err_lines[:30]},
        "traffic": traffic_out,
    }


def _row(cells):
    return "| " + " | ".join(str(c) for c in cells) + " |"


def markdown(report):
    a = report["analysis"]
    meta = report.get("meta", {})
    cfg = report.get("config", {})
    out = ["# Soak report", "",
           "**Verdict: %s**" % a["verdict"], "",
           "- mode `%s`, commit `%s`, %s" % (meta.get("mode"), meta.get("commit"), meta.get("utc")),
           "- config: %s" % json.dumps(cfg),
           "- samples %(samples)s, failed steps %(failed)s, skipped maps %(skipped)s, results timeouts %(resultsTimedOut)s" % a["steps"],
           "- errors: server %(server)s, client %(client)s, warnings %(warnings)s" % a["errors"], ""]
    out.append("## Findings")
    if not a["findings"]:
        out.append("None.")
    for f in a["findings"]:
        out.append("- " + json.dumps(f))
    out += ["", "## Leak table (monotonic growth after warm-up)", "",
            _row(["series", "status", "n", "first", "last", "growth", "slope/step", "monotone"]),
            _row(["---"] * 8)]
    for k, v in sorted(a["series"].items(), key=lambda kv: (kv[1]["status"] == "ok", kv[0])):
        out.append(_row([k, v["status"].upper() if v["status"] != "ok" else "ok", v["n"], v.get("first", "-"), v.get("last", "-"),
                         v.get("growth", "-"), v.get("slope", "-"), v.get("monoFrac", "-")]))
    out += ["", "## Per-step table", "",
            _row(["step", "cycle", "map", "phase", "loadS", "srv MB", "srv inst", "srv ws", "client MB", "client p95 ms", "errors"]),
            _row(["---"] * 11)]
    for s in report.get("samples", []):
        sv = s.get("server") or {}
        cl = list((s.get("clients") or {}).values())
        c0 = cl[0] if cl else {}
        errs = int(sv.get("errors") or 0) + sum(int(c.get("errors") or 0) for c in cl)
        out.append(_row([s.get("step"), s.get("cycle"), s.get("map"), s.get("phase"), s.get("loadSecs", ""),
                         sv.get("memMb", ""), sv.get("instances", ""), sv.get("wsInstances", ""),
                         c0.get("memMb", ""), c0.get("p95Ms", ""), errs]))
    out += ["", "## Remote traffic (server kbps, mean per phase)", ""]
    for ph, d in a["traffic"].items():
        out.append("- %s: %s" % (ph, json.dumps(d)))
    out += ["", "## Error lines (first 30)", ""]
    out += ["- " + l for l in a["errors"]["lines"]] or ["None."]
    out += ["", "Thresholds: see tools/soak_analysis.py THRESHOLDS (abs growth, relative growth), MIN_POINTS %d, MONO_FRAC %.2f." % (MIN_POINTS, MONO_FRAC), ""]
    return "\n".join(out)
