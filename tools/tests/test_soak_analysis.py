import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import soak_analysis as sa  # noqa: E402


def sample(step, phase, mem=500.0, inst=10000, cmem=800.0, errors=0, map_="dino4", cycle=1, **extra):
    s = {"step": step, "cycle": cycle, "map": map_, "phase": phase,
         "server": {"memMb": mem, "instances": inst, "wsInstances": inst - 100, "errors": errors, "sendKbps": 5.0},
         "clients": {"Solo": {"memMb": cmem, "instances": inst, "p95Ms": 16.0, "errors": 0}}}
    s.update(extra)
    return s


def run(n_steps, mem_fn, maps=("dino4", "snow1")):
    out = [sample(0, "baseline", mem=mem_fn(0))]
    for i in range(1, n_steps + 1):
        m = maps[(i - 1) % len(maps)]
        out.append(sample(i, "race", mem=mem_fn(i) + 50, map_=m, cycle=(i - 1) // len(maps) + 1))
        out.append(sample(i, "hub", mem=mem_fn(i), map_=m, cycle=(i - 1) // len(maps) + 1, home=True))
    return out


class DetectTests(unittest.TestCase):
    def test_flat_series_is_ok(self):
        r = sa.detect([500, 501, 500, 502, 500, 501], 30, 0.05)
        self.assertEqual(r["status"], "ok")

    def test_steady_growth_is_a_leak(self):
        r = sa.detect([500 + 10 * i for i in range(10)], 30, 0.05)
        self.assertEqual(r["status"], "leak")
        self.assertGreaterEqual(r["monoFrac"], 0.75)

    def test_sawtooth_that_returns_is_not_a_leak(self):
        r = sa.detect([500, 560, 500, 560, 500, 560, 500, 560], 30, 0.05)
        self.assertEqual(r["status"], "ok")

    def test_growth_under_threshold_is_ok(self):
        r = sa.detect([500 + i for i in range(10)], 30, 0.05)
        self.assertEqual(r["status"], "ok")

    def test_warmup_is_dropped(self):
        vals = [100, 300, 500, 500, 501, 501, 502, 502]
        self.assertEqual(sa.detect(vals, 30, 0.05, warm=0)["status"], "leak")
        self.assertEqual(sa.detect(vals, 30, 0.05, warm=2)["status"], "ok")

    def test_too_few_points_is_insufficient(self):
        self.assertEqual(sa.detect([1, 2, 3], 1, 0.0)["status"], "insufficient")

    def test_missing_values_are_skipped(self):
        r = sa.detect([None, 500, 500, 500, 500, 500], 30, 0.05)
        self.assertEqual(r["n"], 5)


class AnalyzeTests(unittest.TestCase):
    def test_flat_run_passes(self):
        res = sa.analyze(run(12, lambda i: 500 + (i % 2)), maps=["dino4", "snow1"])
        self.assertEqual(res["verdict"], "PASS", res["findings"])

    def test_leaking_server_memory_fails_and_names_the_series(self):
        res = sa.analyze(run(12, lambda i: 500 + 12 * i), maps=["dino4", "snow1"])
        self.assertEqual(res["verdict"], "FAIL")
        self.assertTrue(any(f["type"] == "leak" and f["series"] == "hub/server/memMb" for f in res["findings"]))

    def test_errors_fail_the_run(self):
        samples = run(12, lambda i: 500)
        samples[3]["server"]["errors"] = 2
        samples[3]["server"]["errorTail"] = ["boom"]
        res = sa.analyze(samples, maps=["dino4", "snow1"])
        self.assertEqual(res["verdict"], "FAIL")
        self.assertEqual(res["errors"]["server"], 2)
        self.assertIn("boom", res["errors"]["lines"][0])

    def test_failed_step_fails(self):
        samples = run(12, lambda i: 500)
        samples.append({"step": 13, "phase": "failed", "map": "snow1", "note": "race did not load"})
        res = sa.analyze(samples, maps=["dino4", "snow1"])
        self.assertTrue(any(f["type"] == "failed_step" for f in res["findings"]))
        self.assertEqual(res["verdict"], "FAIL")

    def test_short_run_is_inconclusive_not_pass(self):
        res = sa.analyze(run(2, lambda i: 500), maps=["dino4", "snow1"])
        self.assertEqual(res["verdict"], "INCONCLUSIVE")

    def test_no_client_replies_is_inconclusive_not_pass(self):
        samples = run(12, lambda i: 500)
        for s in samples:
            s["clients"] = {}
            s["clientsMissing"] = ["Solo"]
        res = sa.analyze(samples, maps=["dino4", "snow1"])
        self.assertEqual(res["verdict"], "INCONCLUSIVE")

    def test_an_occasional_missing_reply_still_passes(self):
        samples = run(12, lambda i: 500)
        samples[5]["clientsMissing"] = ["Solo"]
        res = sa.analyze(samples, maps=["dino4", "snow1"])
        self.assertEqual(res["verdict"], "PASS", res["findings"])

    def test_per_map_race_series_catches_a_map_specific_leak(self):
        def mem(i):
            return 500
        samples = run(16, mem, maps=["dino4", "snow1"])
        n = 0
        for s in samples:
            if s["phase"] == "race" and s["map"] == "snow1":
                s["server"]["memMb"] = 500 + 40 * n
                n += 1
        res = sa.analyze(samples, maps=["dino4", "snow1"])
        self.assertTrue(any(f["series"] == "race:snow1/server/memMb" for f in res["findings"] if f["type"] == "leak"))

    def test_client_leak_is_attributed_to_the_client(self):
        samples = run(12, lambda i: 500)
        for s in samples:
            if s["phase"] == "hub":
                s["clients"]["Solo"]["memMb"] = 800 + 15 * s["step"]
        res = sa.analyze(samples, maps=["dino4", "snow1"])
        self.assertTrue(any(f.get("series") == "hub/client:Solo/memMb" for f in res["findings"]))

    def test_markdown_renders_verdict_and_tables(self):
        samples = run(12, lambda i: 500)
        rep = {"meta": {"mode": "solo", "commit": "abc", "utc": "now"}, "config": {"cycles": 6}, "samples": samples,
               "analysis": sa.analyze(samples, maps=["dino4", "snow1"])}
        md = sa.markdown(rep)
        self.assertIn("**Verdict: PASS**", md)
        self.assertIn("## Leak table", md)
        self.assertIn("hub/server/memMb", md)


if __name__ == "__main__":
    unittest.main()
