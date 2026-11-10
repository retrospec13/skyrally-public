"""ISLAND-2 water-battle cove as geometry, for tools/map/tests/test_island2.py (trap audit G1).

Rebuilds the collidable 30MAPS parts the way the builder places them (instance yaw or YXZ Euler, part YXZ Euler,
`C` cylinders along their local Y; `nc` parts skipped) on top of the plan's terrain height grid (bilinear, as
builder_template height()), and answers what a car sees there: the ground under a point (the highest solid top at or
under a ceiling) and whether a solid stands across the car's wall-ray height over that ground. The frame `ship()` is
the galleon hull instance's own (x starboard, y up from the waterline, z toward the stern).

Standard library + numpy only, no Studio. Terrain shells are not modelled (the cove has none: the Plank Dune is in the
height grid)."""
from __future__ import annotations

import math
import re
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[3]
CEILING = 46.0  # a solid whose top is above this is no ground (masts, rigging): the decks top out at 40.6


def car_config() -> dict[str, float]:
    """The numeric CarConfig fields (src/shared/CarConfig.luau), read from the runtime source so the tests follow it."""
    text = (ROOT / "src" / "shared" / "CarConfig.luau").read_text()
    return {k: float(v) for k, v in re.findall(r"^CarConfig\.([A-Z_]+)\s*=\s*(-?[0-9.]+)\b", text, re.M)}


def rot_y(a: float) -> np.ndarray:
    c, s = math.cos(a), math.sin(a)
    return np.array([[c, 0, s], [0, 1, 0], [-s, 0, c]])


def rot_x(a: float) -> np.ndarray:
    c, s = math.cos(a), math.sin(a)
    return np.array([[1, 0, 0], [0, c, -s], [0, s, c]])


def rot_z(a: float) -> np.ndarray:
    c, s = math.cos(a), math.sin(a)
    return np.array([[c, -s, 0], [s, c, 0], [0, 0, 1]])


def yxz(rx: float, ry: float, rz: float) -> np.ndarray:
    """CFrame.fromEulerAnglesYXZ (radians) = Ry * Rx * Rz."""
    return rot_y(ry) @ rot_x(rx) @ rot_z(rz)


def inst_rot(r) -> np.ndarray:
    if isinstance(r, (int, float)):
        return rot_y(math.radians(r))
    if isinstance(r, list):
        return yxz(*[math.radians(v) for v in (list(r) + [0, 0, 0])[:3]])
    return np.eye(3)


class Solid:
    """One collidable part: centre, rotation, half sizes; `vcyl` for an upright cylinder (radial footprint)."""

    __slots__ = ("c", "R", "h", "name", "vcyl", "lo_xz", "hi_xz")

    def __init__(self, c, R, h, name: str, cyl: bool):
        self.c, self.R, self.h, self.name = np.asarray(c, float), R, np.asarray(h, float), name
        self.vcyl = cyl and abs(R[1, 1]) > 0.999
        corners = np.array([[sx, sy, sz] for sx in (-1, 1) for sy in (-1, 1) for sz in (-1, 1)]) * self.h
        w = corners @ R.T + self.c
        self.lo_xz = w[:, [0, 2]].min(0)
        self.hi_xz = w[:, [0, 2]].max(0)

    def columns(self, X: np.ndarray, Z: np.ndarray, grow: float = 0.0):
        """[lo, hi] (world y) of the vertical lines through (X, Z) inside the part, NaN where they miss it. `grow`
        widens the part sideways (local x/z half sizes) so a thin rail is never missed between grid samples."""
        RT = self.R.T
        ox = RT[0, 0] * (X - self.c[0]) + RT[0, 2] * (Z - self.c[2]) - RT[0, 1] * self.c[1]
        oy = RT[1, 0] * (X - self.c[0]) + RT[1, 2] * (Z - self.c[2]) - RT[1, 1] * self.c[1]
        oz = RT[2, 0] * (X - self.c[0]) + RT[2, 2] * (Z - self.c[2]) - RT[2, 1] * self.c[1]
        d = RT[:, 1]  # the world up axis in part space
        hx, hy, hz = self.h[0] + grow, self.h[1], self.h[2] + grow
        if self.vcyl:
            inside = ox * ox + oz * oz <= hx * hx
            ys = -oy / d[1]
            a, b = ys - hy / abs(d[1]), ys + hy / abs(d[1])
            return np.where(inside, a, np.nan), np.where(inside, b, np.nan)
        t0 = np.full(np.shape(X), -1e9)
        t1 = np.full(np.shape(X), 1e9)
        ok = np.ones(np.shape(X), bool)
        for o, dk, hk in ((ox, d[0], hx), (oy, d[1], hy), (oz, d[2], hz)):
            if abs(dk) < 1e-9:
                ok &= np.abs(o) <= hk
            else:
                a, b = (-hk - o) / dk, (hk - o) / dk
                t0 = np.maximum(t0, np.minimum(a, b))
                t1 = np.minimum(t1, np.maximum(a, b))
        ok &= t0 <= t1
        return np.where(ok, t0, np.nan), np.where(ok, t1, np.nan)


class Cove:
    def __init__(self, plan: dict, radius: float = 260.0):
        self.plan = plan
        t = plan["terrain"]
        if "heights" in t:
            self.nx, self.nz, self.cell, self.x0, self.z0 = t["nx"], t["nz"], t.get("cell", 4), t["x0"], t["z0"]
            self.H = np.asarray(t["heights"], float).reshape(self.nz, self.nx)
        else:  # no height grid (DINO-4's cavern is all shells): parts are the only ground
            self.nx, self.nz, self.cell, self.x0, self.z0 = 2, 2, 4, 0.0, 0.0
            self.H = np.full((2, 2), -1e4)
        self.sea = t["water"]["level"] if "water" in t else None
        self.battle = plan["skyrally"]["gameplay"]["modes"]["battle"]
        self.center = np.asarray(self.battle["center"], float)
        # The galleon's own frame for ship(); a map without a galleon (test_battle_reach runs every battle overlay)
        # gets the world frame.
        hull = next((i for i in plan["instances"] if i["pf"] == "GalleonHull"), None)
        self.ship_origin = np.asarray(hull["p"], float) if hull else np.zeros(3)
        self.ship_R = inst_rot(hull.get("r", 0)) if hull else np.eye(3)
        self.solids: list[Solid] = []
        for inst in plan["instances"]:
            ip = np.asarray(inst["p"], float)
            if math.hypot(ip[0] - self.center[0], ip[2] - self.center[2]) > radius:
                continue
            IR = inst_rot(inst.get("r", 0))
            s = inst.get("s", 1.0)
            for spec in plan["prefabs"][inst["pf"]]["parts"]:
                extra = spec[12] if len(spec) > 12 and isinstance(spec[12], dict) else {}
                if extra.get("nc"):
                    continue
                PR = yxz(*[math.radians(v) for v in spec[7:10]])
                c = ip + IR @ (np.asarray(spec[1:4], float) * s)
                self.solids.append(Solid(c, IR @ PR, np.asarray(spec[4:7], float) * s / 2, inst["pf"], spec[0] == "C"))

    # ---------------------------------------------------------------------------------------------- frames
    def ship(self, x: float, y: float, z: float) -> np.ndarray:
        return self.ship_origin + self.ship_R @ np.array([x, y, z], float)

    def ship_dir(self, x: float, z: float) -> np.ndarray:
        return self.ship_R @ np.array([x, 0.0, z], float)

    def to_ship(self, p) -> np.ndarray:
        return self.ship_R.T @ (np.asarray(p, float) - self.ship_origin)

    # ---------------------------------------------------------------------------------------------- queries
    def terrain(self, X, Z):
        X, Z = np.asarray(X, float), np.asarray(Z, float)
        fx = (np.clip(X, self.x0, self.x0 + (self.nx - 1) * self.cell) - self.x0) / self.cell
        fz = (np.clip(Z, self.z0, self.z0 + (self.nz - 1) * self.cell) - self.z0) / self.cell
        ix = np.clip(np.floor(fx).astype(int), 0, self.nx - 2)
        iz = np.clip(np.floor(fz).astype(int), 0, self.nz - 2)
        tx, tz = fx - ix, fz - iz
        H = self.H
        u = H[iz, ix] + (H[iz, ix + 1] - H[iz, ix]) * tx
        v = H[iz + 1, ix] + (H[iz + 1, ix + 1] - H[iz + 1, ix]) * tx
        return u + (v - u) * tz

    def _hits(self, X, Z, grow: float):
        """(solid, index array of the points inside its footprint box) for every solid near any of the points."""
        for s in self.solids:
            lo, hi = s.lo_xz - grow - 0.01, s.hi_xz + grow + 0.01
            idx = np.nonzero((X >= lo[0]) & (X <= hi[0]) & (Z >= lo[1]) & (Z <= hi[1]))[0]
            if idx.size:
                yield s, idx

    def ground(self, X, Z, below=CEILING, grow: float = 0.0):
        """(ground y, name of what it is) arrays: the highest solid top at or under `below` (scalar or array), else
        the terrain."""
        X, Z = np.atleast_1d(np.asarray(X, float)), np.atleast_1d(np.asarray(Z, float))
        below = np.broadcast_to(np.asarray(below, float), X.shape)
        G = self.terrain(X, Z)
        what = np.full(X.shape, "terrain", dtype=object)
        for s, idx in self._hits(X, Z, grow):
            lo, hi = s.columns(X[idx], Z[idx], grow)
            take = ~np.isnan(hi) & (hi <= below[idx]) & (hi > G[idx])
            G[idx[take]] = hi[take]
            what[idx[take]] = s.name
        return G, what

    def walls(self, X, Z, G, lift_lo: float = 0.3, lift_hi: float = 2.2, grow: float = 0.0):
        """Names of solids spanning the band G+lift_lo .. G+lift_hi over each point (None where clear)."""
        X, Z = np.atleast_1d(np.asarray(X, float)), np.atleast_1d(np.asarray(Z, float))
        G = np.broadcast_to(np.asarray(G, float), X.shape)
        out = np.full(X.shape, None, dtype=object)
        for s, idx in self._hits(X, Z, grow):
            lo, hi = s.columns(X[idx], Z[idx], grow)
            g = G[idx]
            hit = ~np.isnan(hi) & (lo < g + lift_hi) & (hi > g + lift_lo)
            for k in idx[hit]:
                if out[k] is None:
                    out[k] = s.name
        return out

    def ship_ground(self, x: float, z: float, below_local: float = CEILING - 20.0):
        w = self.ship(x, 0, z)
        g, what = self.ground(w[0], w[2], below=self.ship_origin[1] + below_local)
        return float(g[0]), str(what[0])

    def raster(self, half: float, step: float = 1.0):
        """Ground and wall masks on a square grid around the arena centre (half-width `half`)."""
        xs = np.arange(self.center[0] - half, self.center[0] + half + step / 2, step)
        zs = np.arange(self.center[2] - half, self.center[2] + half + step / 2, step)
        X, Z = np.meshgrid(xs, zs)
        G, _ = self.ground(X.ravel(), Z.ravel())
        G = G.reshape(X.shape)
        # a part sampled between grid points still blocks: grow every part by half a cell diagonal
        W = self.walls(X.ravel(), Z.ravel(), G.ravel(), grow=step * 0.71).reshape(X.shape) != None  # noqa: E711
        return X, Z, G, W


def flood(ok: np.ndarray, G: np.ndarray, seeds, climb: float = 2.2) -> np.ndarray:
    """4-connected reach over `ok` cells whose ground steps by at most `climb` between neighbours."""
    reach = np.zeros(ok.shape, bool)
    for j, i in seeds:
        if ok[j, i]:
            reach[j, i] = True
    steps = []
    for dj, di in ((1, 0), (-1, 0), (0, 1), (0, -1)):
        src = (slice(max(-dj, 0), ok.shape[0] - max(dj, 0)), slice(max(-di, 0), ok.shape[1] - max(di, 0)))
        dst = (slice(max(dj, 0), ok.shape[0] - max(-dj, 0)), slice(max(di, 0), ok.shape[1] - max(-di, 0)))
        steps.append((src, dst, ok[dst] & (np.abs(G[dst] - G[src]) <= climb)))
    while True:
        before = int(reach.sum())
        for src, dst, can in steps:
            reach[dst] |= reach[src] & can
        if int(reach.sum()) == before:
            return reach
