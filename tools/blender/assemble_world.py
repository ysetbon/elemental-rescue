"""Skyfall Isles - assemble the whole world in Blender.

    ~/bpy-venv/bin/python tools/blender/assemble_world.py

Builds every asset (same code + seeds as build_sky_assets.py), places them per the
world layout with LINKED duplicates for the repeated pieces, then writes
  models/sky/skyfall_world.glb          the whole map as one file (Godot loads it at the origin)
  tools/blender/skyfall_isles.blend     the same scene for editing / inspection
  tools/blender/previews/world_top.png, world_persp.png
Node names under the scene root are a contract with src/sky_builder.gd - see the
tree printed at the end.
"""
import json
import math
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import bpy  # noqa: E402
from mathutils import Matrix, Vector  # noqa: E402

import build_sky_assets as B  # noqa: E402
import sky_lib as L  # noqa: E402
from sky_lib import P, S, yaw_for  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
WORLD_GLB = os.path.join(L.OUT_DIR, "skyfall_world.glb")
BLEND = os.path.join(HERE, "skyfall_isles.blend")

# ---- layout (mirrors src/ sky layout) ------------------------------------------------
HOME_ANG = {"fire": 210.0, "water": 330.0, "grass": 90.0}
HOME_ASSET = {"fire": "isle_home_fire", "water": "isle_home_water", "grass": "isle_home_leaf"}
WILD = {"w30": (30.0, "isle_wild_windmill"), "w150": (150.0, "isle_wild_ruin"), "w270": (270.0, "isle_wild_crystal")}
ISLES = {"heart": (0.0, 0.0, 26.0, "isle_heart")}        # id -> (angle, dist, radius, asset)
for el, a in HOME_ANG.items():
    ISLES["h_" + el] = (a, 120.0, 22.0, HOME_ASSET[el])
for wid, (a, asset_name) in WILD.items():
    ISLES[wid] = (a, 95.0, 16.0, asset_name)
for a in (30, 150, 270):
    ISLES["i%d" % a] = (float(a), 140.0, 7.0, "islet_small_a")
for el, a in HOME_ANG.items():
    ISLES["ih_" + el] = (a, 160.0, 6.0, "islet_small_b")
BRIDGES = [("w30", "h_grass"), ("h_grass", "w150"), ("w150", "h_fire"), ("h_fire", "w270"), ("w270", "h_water"),
           ("h_water", "w30"), ("w30", "heart"), ("w150", "heart"), ("w270", "heart"),
           ("w30", "i30"), ("w150", "i150"), ("w270", "i270"),
           ("h_fire", "ih_fire"), ("h_water", "ih_water"), ("h_grass", "ih_grass")]
SEEDS = {"seed_0_a": (-92.43, -42.97), "seed_0_b": (-24.24, -3.60), "seed_1_a": (92.43, -42.97), "seed_1_b": (24.24, -3.60)}
PAD_OFF = {"fire": -32.0, "water": 0.0, "grass": 32.0}
PAD_ASSET = {"fire": "shortcut_vent_up", "water": "shortcut_lift_up", "grass": "shortcut_vine_up"}
GATE_R = 24.5


def isle_center(iid):
    a, d, r, _ = ISLES[iid]
    return P(a, d, 0.0)


# ---- scene helpers -------------------------------------------------------------------
def empty(name, parent=None, loc=None):
    e = bpy.data.objects.new(name, None)
    e.empty_display_size = 1.0
    bpy.context.scene.collection.objects.link(e)
    if parent is not None:
        e.parent = parent
    if loc is not None:
        e.location = loc
    return e


PROTO = {}


def proto(asset_name):
    """Build an asset once; its objects become hidden prototypes that instances share mesh data with."""
    if asset_name not in PROTO:
        before = set(bpy.data.objects)
        L.reseed(B.seed_of(asset_name))
        B.ASSETS[asset_name]()
        objs = [o for o in bpy.data.objects if o not in before]
        for o in objs:
            o["proto_name"] = o.name
            o.name = "proto__%s__%s" % (asset_name, o.name)
        PROTO[asset_name] = objs
    return PROTO[asset_name]


def instance(asset_name, parent, names=None, loc=None, rot_z=0.0, scale=None, root_name=None, only=None):
    """Linked-duplicate an asset's objects under `parent`.
    Root-level asset objects keep their own local transform relative to `parent` unless the asset has a single
    main mesh being placed (loc/rot/scale apply to an intermediate transform = the main mesh object itself)."""
    objs = proto(asset_name)
    names = names or {}
    out = {}
    copies = {}
    for o in objs:
        pn = o["proto_name"]
        if only is not None and pn not in only:
            continue
        c = o.copy()                      # shares mesh data
        bpy.context.scene.collection.objects.link(c)
        c.name = names.get(pn, pn)
        copies[o] = c
        out[pn] = c
    for o, c in copies.items():
        if o.parent in copies:
            c.parent = copies[o.parent]
        else:
            c.parent = parent
        c.matrix_parent_inverse = Matrix.Identity(4)
    return out


def place(ob, loc=None, rot_z=None, scale=None):
    if loc is not None:
        ob.location = loc
    if rot_z is not None:
        ob.rotation_euler = (0.0, 0.0, rot_z)
    if scale is not None:
        ob.scale = scale


def tile_segments(asset_name, parent, p0, p1, base_name, seg_len=4.0):
    """Tile a +Z-forward segment asset between two Blender points (stretched slightly to fit)."""
    d = p1 - p0
    length = d.length
    n = max(1, int(round(length / seg_len)))
    sim_dir = math.degrees(math.atan2(-d.y, d.x))
    made = []
    for i in range(n):
        c = instance(asset_name, parent, names={asset_name: base_name})[asset_name]
        place(c, p0 + d * ((i + 0.5) / n), yaw_for(sim_dir), (1.0, length / (seg_len * n), 1.0))
        made.append(c)
    return made


# ---- build the world -----------------------------------------------------------------
def assemble():
    L.reset_scene()
    # build every prototype first, while no world node can steal an asset's object name
    for an in (["bridge_plank_segment", "sky_stream_segment", "vine_bridge_segment", "thermal_vent", "seed_gap_marker",
                "spire_tiers", "bell_platform", "sky_bell", "spire_ramp", "spire_lantern_gate"]
               + list(PAD_ASSET.values()) + [v[3] for v in ISLES.values()]):
        proto(an)
    root_isles = empty("isles")
    for iid, (a, d, r, asset_name) in ISLES.items():
        node = "isle_" + iid
        e = empty(node, root_isles, isle_center(iid))
        instance(asset_name, e, names={asset_name: node + "_mesh"})

    root_br = empty("bridges")
    for (ia, ib) in BRIDGES:
        ca, cb = isle_center(ia), isle_center(ib)
        dirv = (cb - ca).normalized()
        tile_segments("bridge_plank_segment", root_br, ca + dirv * ISLES[ia][2], cb - dirv * ISLES[ib][2], "plank")

    root_st = empty("route_stream")
    tile_segments("sky_stream_segment", root_st, P(330, 98.0), P(330, 26.0), "stream_seg")
    root_vn = empty("route_vine")
    tile_segments("vine_bridge_segment", root_vn, P(90, 98.0), P(90, 26.0), "vine_seg")

    root_v = empty("vents")
    fire_c = isle_center("h_fire")
    place(instance("thermal_vent", root_v, names={"thermal_vent": "vent_home"})["thermal_vent"], fire_c + P(30, 17.0))
    place(instance("thermal_vent", root_v, names={"thermal_vent": "vent_heart"})["thermal_vent"], P(210, 23.0))

    root_s = empty("seeds")
    for name, (x, z) in SEEDS.items():
        place(instance("seed_gap_marker", root_s, names={"seed_gap_marker": name})["seed_gap_marker"], S(x, z, 0.0))

    spire = empty("spire")
    instance("spire_tiers", spire)
    plat = instance("bell_platform", spire, only=("bell_platform",))["bell_platform"]
    place(plat, Vector((0, 0, 30.0)))
    instance("bell_platform", plat, only=("ring_inlay",))
    bell = empty("sky_bell", spire, Vector((0, 0, 30.0)))
    instance("sky_bell", bell)
    for k in range(5):
        run = B.RAMP_RUN[k]
        rmid = B.TIER_R[k] + run * 0.5
        chord = 2.0 * rmid * math.sin(math.radians(B.RAMP_ARC * 0.5))
        r = instance("spire_ramp", spire, names={"spire_ramp": "ramp_%d" % k})["spire_ramp"]
        place(r, P(B.RAMP_A[k], B.TIER_R[k] + run, B.TIER_H * k), yaw_for(B.RAMP_A[k]), (chord / 4.0, run / 3.0, 1.0))
    g = instance("spire_lantern_gate", spire, names={"spire_lantern_gate": "gate"}, only=("spire_lantern_gate",))["spire_lantern_gate"]
    place(g, P(B.RAMP_A[0], GATE_R, 0.0), yaw_for(B.RAMP_A[0]))
    instance("spire_lantern_gate", g, only=("lantern_1", "lantern_2", "lantern_3"))
    for k in range(5):
        for el in ("fire", "water", "grass"):
            ang = B.RAMP_A[k] + 180.0 + PAD_OFF[el]
            an = PAD_ASSET[el]
            pad = instance(an, spire, names={an: "pad_%d_%s" % (k, el)}, only=(an,))[an]
            place(pad, P(ang, B.TIER_R[k] + 1.8, B.TIER_H * k), yaw_for(ang))
            if el == "water":
                instance(an, pad, names={"flow": "flow_%d" % k}, only=("flow",))

    # prototypes are no longer needed (instances keep the mesh data alive)
    for objs in PROTO.values():
        for o in objs:
            bpy.data.objects.remove(o, do_unlink=True)
    for o in bpy.data.objects:
        if o.name.startswith("col_"):
            o.hide_render = True
            o.display_type = "WIRE"
    return [o for o in bpy.data.objects]


def export_world(objs):
    bpy.ops.object.select_all(action="DESELECT")
    for o in objs:
        o.hide_set(False)
        o.select_set(True)
    bpy.context.view_layer.objects.active = objs[0]
    L.gltf_export(WORLD_GLB, apply=False)     # keep node transforms + shared meshes


def glb_json(path):
    with open(path, "rb") as f:
        f.read(12)
        ln, _ = struct.unpack("<II", f.read(8))
        return json.loads(f.read(ln))


def print_tree(objs):
    kids = {}
    for o in objs:
        kids.setdefault(o.parent, []).append(o)

    def rec(o, depth):
        ch = sorted(kids.get(o, []), key=lambda x: x.name)
        groups = {}
        for c in ch:
            base = c.name.split(".")[0]
            groups.setdefault(base, []).append(c)
        for base, lst in groups.items():
            if len(lst) > 1 and all(not kids.get(c) for c in lst):
                print("  " * depth + "%s  x%d (.001 ...)" % (base, len(lst)))
            else:
                for c in lst:
                    print("  " * depth + c.name + ("" if c.type == "MESH" else "  [empty]"))
                    rec(c, depth + 1)
    rec(None, 0)


def render_views(objs):
    cam = L.setup_render(1280, 720)
    sc = bpy.context.scene
    meshes = [o for o in objs if o.type == "MESH" and not o.hide_render]
    # top view (orthographic, sim x right / z down like the radar)
    cam.data.type = "ORTHO"
    cam.data.ortho_scale = 360.0 * 1280.0 / 720.0
    cam.location = (0, 0, 400)
    cam.rotation_euler = (0, 0, 0)
    cam.data.clip_start = 1.0
    cam.data.clip_end = 1000.0
    sc.render.filepath = os.path.join(L.PREVIEW_DIR, "world_top.png")
    bpy.ops.render.render(write_still=True)
    cam.data.type = "PERSP"
    L.frame_camera(cam, meshes, az_deg=250.0, el_deg=20.0, fov_deg=50.0, margin=0.62, focus=(0, 0, 6))
    sc.render.filepath = os.path.join(L.PREVIEW_DIR, "world_persp.png")
    bpy.ops.render.render(write_still=True)
    # a closer hero shot of the spire
    spire_m = [o for o in meshes if o.name.startswith(("tier_", "ramp_", "pad_", "gate", "bell", "yoke", "isle_heart"))]
    L.frame_camera(cam, spire_m, az_deg=285.0, el_deg=16.0, fov_deg=45.0, margin=0.8, focus=(0, 0, 14))
    sc.render.filepath = os.path.join(L.PREVIEW_DIR, "world_spire.png")
    bpy.ops.render.render(write_still=True)


def main():
    objs = assemble()
    export_world(objs)
    tris = sum(sum(len(p.vertices) - 2 for p in o.data.polygons) for o in objs if o.type == "MESH" and not o.name.startswith("col_"))
    gj = glb_json(WORLD_GLB)
    print("WORLD GLB: %.1f kB, nodes %d, meshes %d, materials %s, tris (instanced, no col_) %d" % (
        os.path.getsize(WORLD_GLB) / 1024.0, len(gj["nodes"]), len(gj["meshes"]),
        [m["name"] for m in gj.get("materials", [])], tris))
    print("NODE TREE:")
    print_tree(objs)
    if "--no-render" not in sys.argv:
        render_views(objs)
    bpy.ops.wm.save_as_mainfile(filepath=BLEND, compress=True)
    print("BLEND: %.1f kB" % (os.path.getsize(BLEND) / 1024.0))


if __name__ == "__main__":
    main()
