#!/usr/bin/env python3
"""route.py parity with builder_dino4.luau and SplineUtils.sampleAtStation.
Run: python3 -m unittest discover -s tools/map/tests -v"""
import math
import unittest

import fixtures  # noqa: F401  (puts tools/map and tools/course on sys.path)
import route


def close(a, b, tol=1e-9):
    return all(abs(x - y) <= tol for x, y in zip(a, b))


class BuilderParity(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.nodes = fixtures.builder_dino4_nodes()
        cls.route = route.solve(cls.nodes, 5450, 0.0, 3.5, 24, 9)

    def test_node_count(self):
        self.assertEqual(len(self.nodes), 20)

    def test_waypoints_and_length(self):
        self.assertEqual(len(self.route.waypoints), 181)
        self.assertLess(abs(self.route.length - 5450), 0.01)
        self.assertAlmostEqual(self.route.flex_scale, 0.7447, places=4)

    def test_closing_waypoint(self):
        first, last = self.route.waypoints[0], self.route.waypoints[-1]
        self.assertEqual(last.pos, first.pos)
        self.assertEqual(last.bank, first.bank)
        self.assertEqual(last.station, self.route.length)
        self.assertEqual(last.tangent, first.tangent)

    def test_stations_monotonic_chord_sum(self):
        wps = self.route.waypoints
        self.assertEqual(wps[0].station, 0.0)
        for a, b in zip(wps, wps[1:]):
            self.assertGreater(b.station, a.station)
            self.assertAlmostEqual(b.station - a.station, route.mag(route.sub(b.pos, a.pos)), places=9)

    def test_last_evaluated_waypoints_kept(self):
        # The Luau loop keeps the waypoints of the final mid, not the best one seen
        scale, length = self.route.evaluations[-1]
        self.assertEqual(len(self.route.evaluations), 24)
        self.assertEqual(scale, self.route.flex_scale)
        self.assertEqual(length, self.route.length)

    def test_wraparound_neighbours(self):
        s = self.route.flex_scale
        adj = [route.add(n.pos, route.mul(n.flex, s)) for n in self.nodes]
        wps = self.route.waypoints
        # Segment 1 uses (last, 1, 2, 3); the last segment uses (19, 20, 1, 2) in Luau's 1-based terms
        self.assertTrue(close(wps[1].pos, route.catmull_rom(adj[-1], adj[0], adj[1], adj[2], 1 / 9)))
        self.assertTrue(close(wps[19 * 9 + 4].pos, route.catmull_rom(adj[18], adj[19], adj[0], adj[1], 4 / 9)))
        self.assertTrue(close(wps[0].pos, adj[0]))

    def test_bank_lerp_per_segment(self):
        wps = self.route.waypoints
        for i in range(20):
            b1, b2 = self.nodes[i].bank, self.nodes[(i + 1) % 20].bank
            for s in range(9):
                self.assertAlmostEqual(wps[i * 9 + s].bank, b1 + (b2 - b1) * s / 9, places=12)

    def test_tangents_unit_and_forward(self):
        wps = self.route.waypoints
        for i in range(len(wps) - 1):
            self.assertAlmostEqual(route.mag(wps[i].tangent), 1.0, places=12)
            chord = route.unit(route.sub(wps[i + 1].pos, wps[i].pos))
            self.assertTrue(close(wps[i].tangent, chord, 1e-12))


class PortParity(unittest.TestCase):
    """tools/course/dino4_spline_port.py (older nodes) is an independent numpy port of the same loop."""

    def test_same_waypoints_as_port(self):
        import dino4_spline_port as port
        nodes = [route.Node(tuple(map(float, p)), float(b), tuple(map(float, f))) for p, b, f in port.N]
        r = route.solve(nodes, 5450)
        self.assertEqual(r.flex_scale, port.SCALE)
        self.assertAlmostEqual(r.length, port.LEN, places=6)
        self.assertEqual(len(r.waypoints), len(port.WPS))
        for w, pw in zip(r.waypoints, port.WPS):
            self.assertTrue(close(w.pos, pw[0], 1e-9))
            self.assertAlmostEqual(w.bank, pw[1], places=12)
            self.assertAlmostEqual(w.station, pw[2], places=6)


class StationFrame(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.route = route.solve(fixtures.builder_dino4_nodes(), 5450)

    def test_frame_orthonormal(self):
        for st in (0, 37.5, 1000, 2718.3, 5449.9):
            f = self.route.frame_at(st)
            self.assertAlmostEqual(route.mag(f.right), 1.0, places=12)
            self.assertAlmostEqual(route.mag(f.up), 1.0, places=12)
            self.assertAlmostEqual(f.right[1], 0.0, places=12)  # horizontal
            self.assertAlmostEqual(route.dot(f.right, f.tangent), 0.0, places=12)
            self.assertAlmostEqual(route.dot(f.up, f.tangent), 0.0, places=12)
            self.assertGreater(f.up[1], 0.0)

    def test_start_faces_minus_z_with_right_plus_x(self):
        f = self.route.frame_at(0)
        self.assertTrue(close(f.pos, (0.0, 140.0, 0.0)))
        self.assertLess(f.tangent[2], -0.99)
        self.assertGreater(f.right[0], 0.99)

    def test_interpolation_and_wrap(self):
        wps = self.route.waypoints
        a, b = wps[10], wps[11]
        mid = (a.station + b.station) / 2
        pos, tan, bank = route.sample_at_station(wps, self.route.length, mid)
        self.assertTrue(close(pos, route.lerp(a.pos, b.pos, 0.5), 1e-9))
        self.assertAlmostEqual(bank, (a.bank + b.bank) / 2, places=9)
        self.assertTrue(close(tan, route.unit(route.sub(b.pos, a.pos)), 1e-12))
        # station % length like the Luau, negative stations wrap to the end of the loop
        p_len, _, _ = route.sample_at_station(wps, self.route.length, self.route.length)
        self.assertTrue(close(p_len, wps[0].pos, 1e-9))
        p_neg, _, _ = route.sample_at_station(wps, self.route.length, -14)
        p_end, _, _ = route.sample_at_station(wps, self.route.length, self.route.length - 14)
        self.assertTrue(close(p_neg, p_end, 1e-9))

    def test_cframe_look_is_tangent(self):
        f = self.route.frame_at(1234)
        c = f.cframe(f.offset(3, 5))
        right, up, look = (c[3], c[6], c[9]), (c[4], c[7], c[10]), (-c[5], -c[8], -c[11])
        self.assertTrue(close(look, f.tangent, 1e-12))
        self.assertTrue(close(route.cross(right, up), route.mul(look, -1), 1e-12))  # right-handed
        self.assertTrue(close(c[:3], route.add(route.add(f.pos, route.mul(f.right, 3)), route.mul(f.up, 5)), 1e-9))


class Degenerate(unittest.TestCase):
    def test_duplicate_points_keep_a_tangent(self):
        nodes = [route.Node((0.0, 0.0, 0.0), 0.0), route.Node((0.0, 0.0, 0.0), 0.0),
                 route.Node((100.0, 0.0, -100.0), 0.0), route.Node((0.0, 0.0, -200.0), 0.0),
                 route.Node((-100.0, 0.0, -100.0), 0.0)]
        r = route.solve(nodes, 100, 0, 0, 1, 1)  # one sample per segment: waypoints 1 and 2 coincide
        for w in r.waypoints:
            self.assertFalse(any(math.isnan(v) for v in w.tangent))
            self.assertAlmostEqual(route.mag(w.tangent), 1.0, places=9)


if __name__ == "__main__":
    unittest.main()
