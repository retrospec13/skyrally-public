#!/usr/bin/env python3
"""Write assets/models/hero_car_v3/manifest.json and hero_plane_v3/manifest.json from the Blender split stats.

Frames used in the manifests:
  source        Blender import frame of the Tripo GLB: nose +X, the vehicle's left +Y, up +Z (glTF = (x, z, -y)).
  roblox_mesh   MeshPart local space after Roblox imports the GLB (a 180 deg yaw): (-x, z, y) of source, so the nose is
                on -X, up +Y, the vehicle's left on +Z. MeshPart origin = bbox centre of that part's geometry.
  hull          the builders' hull frame (forward -Z, right +X, up +Y) using the existing body weld
                (CarBuilder: CAR_MESH_OFFSET * CFrame.Angles(0, -90 deg, 0); PlaneBuilder: CFrame.new(0, 0.3, 0) * same yaw)
                and the existing scale (car longest side 10.8 studs, plane max(X, Z) 16.5 studs).
Seat and cockpit numbers are the offline height-map measurements in out/v3 (hmap.py) on the source GLBs.
"""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def r(v, n=4):
    return [round(float(x), n) for x in v]


def to_rm(p):
    """source -> roblox_mesh axes (a direction or a difference of points)."""
    return (-p[0], p[2], p[1])


def roty_m90(v):
    """CFrame.Angles(0, -pi/2, 0) applied to a vector: (x, y, z) -> (-z, y, x)."""
    return (-v[2], v[1], v[0])


class Frame:
    def __init__(self, old_min, old_max, new_min, new_max, scale, weld_offset):
        self.oc = [(a + b) / 2 for a, b in zip(old_min, old_max)]
        self.nmin, self.nmax = new_min, new_max
        self.nc = [(a + b) / 2 for a, b in zip(new_min, new_max)]
        self.s = scale
        self.off = weld_offset
        # bbox of the new body in roblox_mesh axes
        a, b = to_rm(new_min), to_rm(new_max)
        self.rm_min = [min(x, y) for x, y in zip(a, b)]
        self.rm_max = [max(x, y) for x, y in zip(a, b)]
        self.rm_size = [y - x for x, y in zip(self.rm_min, self.rm_max)]

    def hull(self, p):
        d = to_rm([p[i] - self.oc[i] for i in range(3)])
        v = roty_m90([x * self.s for x in d])
        return [v[i] + self.off[i] for i in range(3)]

    def rm_rel(self, p):
        return to_rm([p[i] - self.nc[i] for i in range(3)])

    def frac(self, p):
        q = to_rm(p)
        return [(q[i] - self.rm_min[i]) / self.rm_size[i] for i in range(3)]

    def anchor(self, p, note=None):
        a = {"source": r(p), "roblox_mesh_from_body_centre_raw": r(self.rm_rel(p), 5),
             "fraction_of_body_bbox_roblox_mesh_axes": r(self.frac(p)), "hull_studs": r(self.hull(p), 3)}
        if note:
            a["note"] = note
        return a

    def new_weld_offset(self):
        return r(self.hull(self.nc), 3)


def car():
    d = ROOT / "assets/models/hero_car_v3"
    st = json.load(open(d / "split_stats.json"))
    P = st["parts"]
    body = P["car_body"]
    # original Tripo car v2 bbox (source frame), from the probe of car_v2.glb
    old_min, old_max = [-0.49804, -0.28474, -0.18885], [0.5, 0.28474, 0.18885]
    s = 10.8 / max(o - n for o, n in zip(old_max, old_min))
    F = Frame(old_min, old_max, body["bbox_min"], body["bbox_max"], s, [0, 0.15, 0])
    piv = st["wheel_pivots_source"]
    wheels = {}
    for key, name in (("front_L", "Wheel_FL"), ("front_R", "Wheel_FR"), ("rear_L", "Wheel_RL"), ("rear_R", "Wheel_RR")):
        axle = key.split("_")[0]
        w = P["wheel_" + axle]
        wheels[name] = F.anchor(piv[key])
        wheels[name].update({
            "file": "wheel_%s.glb" % axle,
            "mesh_rotation_on_wheel_part": "identity" if key.endswith("R") else "CFrame.Angles(0, math.pi, 0)",
            "radius_raw": w["radius_bbox_half"], "radius_max_raw": w["radius_max"],
            "radius_studs": round(w["radius_bbox_half"] * s, 3), "width_studs": round(w["width"] * s, 3),
            "bottom_hull_y_studs": round(F.hull(piv[key])[1] - w["radius_bbox_half"] * s, 3),
        })
    seat_pan = [-0.105, 0.0, -0.016]
    m = {
        "asset": "hero car v3 (split of Tripo car v2, model 111843268690922)",
        "source_glb": "assets/models/hero_car_v2/tripo/car_v2.glb",
        "tool": "win/blender_v3_split.py car (Blender 4.3, merge_vertices import); QC renders win/blender_v3_render.py",
        "frames": {
            "source": "Blender import frame of every GLB here: nose +X, vehicle's left +Y, up +Z (glTF file = (x, z, -y))",
            "roblox_mesh": "after Roblox import (180 deg yaw): (-x, z, y) of source -> nose -X, up +Y, left +Z; MeshPart origin = bbox centre",
            "hull": "CarBuilder hull (forward -Z, right +X, up +Y) with the body welded at CAR_MESH_OFFSET * CFrame.Angles(0, -90 deg, 0) and scaled so the longest side is 10.8 studs",
        },
        "scale": {"game_scale": round(s, 5), "how": "body.Size = body.MeshSize * (10.8 / max(MeshSize)) as today; scale every part by the SAME factor: part.Size = part.MeshSize * (body.Size.X / body.MeshSize.X)",
                  "body_longest_raw_unchanged": True},
        "files": {
            "car_body.glb": {"tris": body["tris"], "frame": "source, unchanged (same rotation as v2: CAR_MESH_ROTATION = CFrame.Angles(0, -90 deg, 0))",
                             "bbox_min_source": body["bbox_min"], "bbox_max_source": body["bbox_max"],
                             "material": "original Tripo material and 4096 px colour/normal/ORM maps (look unchanged)"},
            "wheel_front.glb": {"tris": P["wheel_front"]["tris"], "pivot": "origin = axle centre at tyre mid-width",
                                "axes": "spin axis = X; outboard (hub cap) face toward source -X = roblox_mesh +X (the hull's right); up = Z (roblox Y)",
                                "size_raw_source": P["wheel_front"]["size"], "pivot_offset_from_bbox_centre_source": P["wheel_front"]["pivot_offset_from_bbox_centre"]},
            "wheel_rear.glb": {"tris": P["wheel_rear"]["tris"], "pivot": "origin = axle centre at tyre mid-width",
                               "axes": "spin axis = X; outboard face toward source -X = roblox_mesh +X; up = Z (roblox Y)",
                               "size_raw_source": P["wheel_rear"]["size"], "pivot_offset_from_bbox_centre_source": P["wheel_rear"]["pivot_offset_from_bbox_centre"]},
        },
        "body_weld": {
            "old_CAR_MESH_OFFSET": [0, 0.15, 0],
            "new_CAR_MESH_OFFSET": F.new_weld_offset(),
            "why": "the wheel-less body's bbox centre sits 0.0166 raw higher (the tyres were the lowest geometry); Roblox centres a MeshPart on its bbox",
        },
        "wheels": wheels,
        "wheel_notes": [
            "Front and rear wheels differ (front r 0.097 raw / %.2f studs, rear r 0.1125 raw / %.2f studs), so there is one GLB per axle." % (P["wheel_front"]["radius_bbox_half"] * s, P["wheel_rear"]["radius_bbox_half"] * s),
            "Each GLB is the right-side wheel. Left wheels reuse it yawed 180 deg about the vertical (the wheel is symmetric about its own vertical mid-plane: max deviation %.4f raw = %.3f studs, checked in Blender)." % (st["checks"]["wheel_rear_R_yaw180_vs_L_max_dev"], st["checks"]["wheel_rear_R_yaw180_vs_L_max_dev"] * s),
            "Visual hub centres differ from CarConfig.WHEELS (probe positions, unchanged): front visual (+-%.2f, %.2f, %.2f) vs probe (+-2.75, -0.55, -3.3); rear visual (+-%.2f, %.2f, %.2f) vs probe (+-2.85, -0.55, 3.2). The bottoms of the visual tyres sit at hull y %.2f / %.2f, matching RIDE_HEIGHT 1.9." % (
                wheels["Wheel_FR"]["hull_studs"][0], wheels["Wheel_FR"]["hull_studs"][1], wheels["Wheel_FR"]["hull_studs"][2],
                wheels["Wheel_RR"]["hull_studs"][0], wheels["Wheel_RR"]["hull_studs"][1], wheels["Wheel_RR"]["hull_studs"][2],
                wheels["Wheel_FR"]["bottom_hull_y_studs"], wheels["Wheel_RR"]["bottom_hull_y_studs"]),
            "Recommended rig: keep Wheel_* Motor6Ds (CarController already sets Transform for spin/steer) but put C0 at the visual hub centre above, and weld the wheel MeshPart to the Wheel_* part with C0 = that rotation (identity / yaw 180). Spin about the part's X.",
            "The axle stubs stay on the body (capped, dark); the wheel's inner face is capped dark too.",
        ],
        "seat": {
            "open_cockpit": True,
            "seat_pan_centre": F.anchor(seat_pan, "seat cushion surface where a seated driver's hips rest, just ahead of the seat back; put the hip joint ~0.3 stud above it"),
            "seat_back_face_x_source": -0.13,
            "cockpit_opening_source": {"x": [-0.13, 0.025], "half_width_y": 0.105, "studs": [round(0.155 * s, 2), round(0.21 * s, 2)]},
            "rim_top_z_source": 0.04, "seat_back_top_z_source": 0.12, "rear_headrest_hump_top_z_source": 0.185,
            "steering_wheel_centre_source": [-0.005, 0.0, 0.095], "footwell_floor_z_source": -0.048,
            "head_clear": {
                "z_source": 0.12, "fraction_z_roblox_y": r([F.frac([0, 0, 0.12])[1]])[0], "hull_y_studs": round(F.hull([0, 0, 0.12])[1], 3),
                "note": "open top, nothing overhead: above the seat-back top (z 0.12) a head is clear anywhere over the cockpit; the rear headrest hump (z 0.185) is behind the seat back, x < -0.21",
            },
            "fit_note": "Cockpit inner width %.2f studs fits a default R15 torso (2.0); arms (span 3.9) sit above the rim (rim is only %.2f studs above the pan) so they clear it; legs run forward under the cowl and are hidden. A seated R15 head top lands ~3.3 studs above the pan, i.e. the driver reads clearly at scale 1; 0.8 to 0.9 avatar scale keeps the kart proportion closer to the concept." % (0.21 * s, (0.04 + 0.016) * s),
        },
        "caveats": [
            "Wheels were cut from the baked Tripo mesh by geometry (16-gon tyres at the four lower corners, joined to the body only by axles); no procedural replacement was needed.",
            "Wheel vertices were welded within 0.003 raw (0.03 stud) to close Tripo's open tread seams; shading of the wheels is smoother than the v2 bake by a hair.",
            "Front tyre is 0.0025 raw out of round: its bbox centre is 0.0025 raw above the axle (0.027 stud). Spin about the Motor6D at the axle, not about the MeshPart centre, or offset the weld by pivot_offset_from_bbox_centre.",
            "Every GLB embeds the full 4096 px Tripo maps. The wheels use the SAME UV atlas as the body, so the integrator can clone the body's SurfaceAppearance onto the wheel MeshParts and skip the parts' own texture uploads.",
            "Roblox import is assumed to yaw GLBs 180 deg (memory: boss-rig-import-yaw-180; consistent with v2's measured nose on -X). Verify in Studio that the imported body's MeshSize is about (0.998, 0.344, 0.546).",
        ],
        "qc_renders": sorted(p.name for p in d.glob("qc_*.png")),
    }
    json.dump(m, open(d / "manifest.json", "w"), indent=1)
    return m


def plane():
    d = ROOT / "assets/models/hero_plane_v3"
    st = json.load(open(d / "split_stats.json"))
    P = st["parts"]
    body = P["plane_body"]
    old_min, old_max = [-0.44912, -0.5, -0.17710], [0.44912, 0.5, 0.17515]
    # PlaneBuilder: 16.5 / max(raw X, raw Z) in roblox_mesh axes = max(source x span, source y span)
    s = 16.5 / max(old_max[0] - old_min[0], old_max[1] - old_min[1])
    F = Frame(old_min, old_max, body["bbox_min"], body["bbox_max"], s, [0, 0.3, 0])
    pp = st["prop_pivot_source"]
    dc = st["blur_disc_centre_source"]
    seat_pan = [0.01, 0.0, 0.031]
    m = {
        "asset": "hero plane v3 (split of Tripo plane v2 badge, model 107580586112839)",
        "source_glb": "assets/models/hero_plane_v2/tripo/plane_v2_badge.glb (copied from the PC deploy tree)",
        "tool": "win/blender_v3_split.py plane (Blender 4.3, merge_vertices import); blur texture tools/make_prop_blur.py; QC renders win/blender_v3_render.py",
        "frames": {
            "source": "Blender import frame of every GLB here: nose +X, left +Y (wingspan along Y), up +Z (glTF file = (x, z, -y))",
            "roblox_mesh": "after Roblox import (180 deg yaw): (-x, z, y) of source -> nose -X, up +Y, left +Z; MeshPart origin = bbox centre",
            "hull": "PlaneBuilder hull (forward -Z, right +X, up +Y) with the body welded at CFrame.new(0, 0.3, 0) * CFrame.Angles(0, -90 deg, 0), scaled 16.5 / max(raw X, raw Z)",
        },
        "scale": {"game_scale": round(s, 5), "how": "body as today (16.5 / max(MeshSize.X, MeshSize.Z); the wingspan is still the max, unchanged); every part: part.Size = part.MeshSize * (body.Size.Z / body.MeshSize.Z)"},
        "files": {
            "plane_body.glb": {"tris": body["tris"], "frame": "source, unchanged (same -90 deg yaw weld as v2)",
                               "bbox_min_source": body["bbox_min"], "bbox_max_source": body["bbox_max"],
                               "material": "original Tripo material + 4096 px maps; the cream shroud ring stays on the body (static duct, as in concept 01)"},
            "plane_prop.glb": {"tris": P["plane_prop"]["tris"], "pivot": "origin = prop hub on the spin axis (bbox centre)",
                               "axes": "spin axis = X; spinner tip toward source +X (= roblox_mesh -X, same as the nose): give it the body's rotation, CFrame.Angles(0, -90 deg, 0), and spin about its local X",
                               "size_raw_source": P["plane_prop"]["size"], "blade_radius_raw": 0.08, "radius_max_raw": P["plane_prop"]["radius_max"]},
            "prop_blur_disc.glb": {"tris": P["prop_blur_disc"]["tris"], "pivot": "origin = disc centre", "axes": "disc normal = X (same rotation as the prop)",
                                   "radius_raw": P["prop_blur_disc"]["radius"], "thickness_raw": 0.003,
                                   "uv": "planar, disc centre at (0.5, 0.5), rim at the UV square's inscribed circle; two back-to-back faces so it reads from front and behind",
                                   "texture": "prop_blur.png"},
            "prop_blur.png": {"size": [256, 256], "mode": "RGBA", "content": "soft radial streaks in varnished wood/cream, two blade trails, clear centre (spinner) and soft rim; mean alpha 0.35 over the blade annulus",
                              "generator": "tools/make_prop_blur.py"},
        },
        "body_weld": {
            "old": "CFrame.new(0, 0.3, 0) * CFrame.Angles(0, math.rad(-90), 0)",
            "new_position": F.new_weld_offset(),
            "why": "without the spinner the body's bbox ends at the ring (x 0.4276 instead of 0.4491); Roblox centres the MeshPart on its bbox, so the weld moves %.3f stud aft to keep the body where it was" % (F.new_weld_offset()[2]),
        },
        "prop": {
            "pivot": F.anchor(pp, "prop MeshPart CFrame position (spin axis passes through it along hull Z)"),
            "blade_radius_studs": round(0.08 * s, 3), "shroud_inner_radius_studs": round(0.085 * s, 3),
            "blur_disc_centre": F.anchor(dc, "blade plane; disc radius %.3f studs" % (0.084 * s)),
            "replaces": "PlaneBuilder PropSpinner/PropBlade1/PropBlade2 (hull (0, 0, -7.2/-7.25)); FlightController.stepSpinningPropeller and AIRacers can CFrame this one part instead of three",
            "notes": [
                "Tripo fused the paddle tips into the shroud ring; the paddles were cut free and trimmed flat at |y| = 0.080 raw (0.08 stud clearance to the ring), and the scars in the ring and the shaft socket on the nose plate were capped with the surrounding colour.",
                "Suggested runtime: show the solid prop below ~25% throttle, cross-fade to the blur disc (Transparency driven by speed) above it.",
            ],
        },
        "seat": {
            "open_cockpit": True,
            "canopy": "none: open cockpit behind the wooden cowl, seat with a low back, turtle deck behind",
            "seat_pan_centre": F.anchor(seat_pan, "seat cushion surface where the pilot's hips rest, just ahead of the seat back"),
            "cockpit_opening_source": {"x": [-0.01, 0.045], "half_width_y": 0.045, "studs": [round(0.055 * s, 2), round(0.09 * s, 2)]},
            "rim_top_z_source": 0.055, "seat_back_top_z_source": 0.105, "turtle_deck_top_z_source": 0.114, "cowl_top_z_source": 0.09,
            "head_clear": {
                "z_source": 0.114, "fraction_z_roblox_y": r([F.frac([0, 0, 0.114])[1]])[0], "hull_y_studs": round(F.hull([0, 0, 0.114])[1], 3),
                "note": "open top: above the turtle-deck/seat-back top (z 0.114) the head is clear; nothing overhead",
            },
            "fit_note": "The opening is only %.2f x %.2f studs (length x width) and %.2f stud deep: a default R15 (torso 2.0 wide) does not fit at scale 1. Seat the avatar at ~0.6 to 0.65 scale (torso 1.2 to 1.3 wide) or accept the torso clipping the rim; legs go forward under the cowl and stay hidden." % (0.055 * s, 0.09 * s, (0.055 - 0.031) * s),
        },
        "caveats": [
            "The source mesh already has open seams in the shroud ring (thin light notches at its top right, visible in qc_nose); they are unchanged from v2.",
            "Every GLB embeds the full 4096 px Tripo maps; the prop shares the body's UV atlas, so its SurfaceAppearance can be cloned from the body.",
            "Studio measured the in-game plane model at 16.5 x 6.7 x 16.4 (whole model incl. the hull and the old prop parts); the GLB's own ratio is 0.898 : 0.352 : 1.0 (X : Y : Z roblox_mesh). Verify the imported body's MeshSize before trusting the hull numbers.",
            "Roblox import is assumed to yaw GLBs 180 deg (consistent with v2's measured nose on -X).",
        ],
        "qc_renders": sorted(p.name for p in d.glob("qc_*.png")),
    }
    json.dump(m, open(d / "manifest.json", "w"), indent=1)
    return m


if __name__ == "__main__":
    c = car()
    p = plane()
    print(json.dumps({"car_wheels": {k: v["hull_studs"] for k, v in c["wheels"].items()}, "car_seat": c["seat"]["seat_pan_centre"],
                      "car_weld": c["body_weld"]["new_CAR_MESH_OFFSET"], "plane_prop": p["prop"]["pivot"], "plane_seat": p["seat"]["seat_pan_centre"],
                      "plane_weld": p["body_weld"]["new_position"]}, indent=1))
