"""Skyfall Isles - build every world / prop / mode asset in Blender and export GLBs.

    ~/bpy-venv/bin/python tools/blender/build_sky_assets.py            # everything
    ~/bpy-venv/bin/python tools/blender/build_sky_assets.py sky_bell   # a subset
    ... --no-preview   skips the preview renders

Previews render with EEVEE on Mesa's software GL; a bare container needs
`apt-get install -y libegl1 libegl-mesa0 libgl1-mesa-dri libgles2` for that (the GLB
export itself needs no GPU - use --no-preview without those packages).

One function per asset (registered with @asset). Each builds its objects into an
empty scene; main() exports models/sky/<name>.glb and renders previews/<name>.png.
See sky_lib.py for the coordinate / colour conventions shared with the Godot code.
"""
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import bpy  # noqa: E402
from mathutils import Vector, noise  # noqa: E402

import sky_lib as L  # noqa: E402
from sky_lib import (P, S, Part, blob, box, box_z0, col_cylinder, cone, cyl, hx, icosphere, join, lathe,  # noqa: E402
                     leaf, make_object, mix, mul, paint_faces, prism, rock, strip_on_ground, top_disc, tube, tuft)

ASSETS = {}
PREVIEW_OPTS = {}

# spire contract (mirrors src/ - SPIRE_OUTER_R / SPIRE_RAMP_A0 / STEP)
TIER_R = [20.0, 16.0, 12.0, 8.5, 5.0]
TIER_H = 6.0
RAMP_A = [300.0, 12.0, 84.0, 156.0, 228.0]
RAMP_RUN = [4.2, 3.0, 3.0, 2.6, 2.6]
RAMP_ARC = 22.0


def asset(fn=None, **preview):
    def reg(f):
        ASSETS[f.__name__] = f
        PREVIEW_OPTS[f.__name__] = preview
        return f
    return reg(fn) if fn else reg


def rnd(a, b):
    return L.rng.uniform(a, b)


def nz2(x, y, f=0.2, seed=0.0):
    return noise.noise(Vector((x * f + seed, y * f - seed, seed * 0.37)))


# =====================================================================================
#  small shared props
# =====================================================================================
def brazier(h=1.5):
    """Stone post + bowl + flame (glow)."""
    post = cyl(0.22, 0.16, 0.0, h * 0.75, 6).paint(0x4A4048, z0=0, z1=h, lo=0.7)
    bowl = lathe([(0.18, h * 0.75), (0.5, h * 0.95), (0.55, h), (0.4, h)], 8, True, True).paint(0x3A3238, top=0x1A1418)
    fl = join(cone(0.34, h, h + 0.75, 6), icosphere(0.26, 0).move(0, 0, h + 0.12))
    fl.paint(lambda c, n: mix(L.LAVA_A, L.LAVA_B, min(1.0, max(0.0, (c.z - h) / 0.7))), glow=True, jit=0.08)
    return join(post, bowl, fl)


def lantern(scale=1.0, col=0xFFD27A):
    """Tiny hanging lantern: cap + glowing body + base. Origin at its top hook."""
    s = scale
    cap = cone(0.22 * s, -0.16 * s, 0.0, 5).paint(L.WOOD_B)
    body = prism(5, 0.15 * s, 0.17 * s, -0.5 * s, -0.16 * s).paint(col, glow=True, jit=0.05)
    base = cyl(0.19 * s, 0.14 * s, -0.56 * s, -0.5 * s, 5).paint(L.WOOD_B)
    return join(cap, body, base)


def lantern_post(h=2.2, col=0xFFD27A, wood=L.WOOD_B):
    post = cyl(0.11, 0.08, 0.0, h, 5).paint(wood, z0=0, z1=h, lo=0.75)
    arm = box(0.5, 0.08, 0.08, (0.22, 0, h - 0.05)).paint(wood)
    lan = lantern(1.0, col).move(0.42, 0, h - 0.1)
    return join(post, arm, lan)


def mushroom(h=0.6, cap=0xD9634A, glow=False):
    stem = cyl(h * 0.16, h * 0.11, 0.0, h * 0.7, 6).paint(0xEFE6D2, z0=0, z1=h, lo=0.8)
    c = lathe([(h * 0.5, h * 0.62), (h * 0.55, h * 0.72), (h * 0.34, h * 0.95), (0.0, h * 1.04)], 7, True, False)
    c.paint(cap, glow=glow, top=None if glow else mix(cap, 0xFFFFFF, 0.25), jit=0.07)
    return join(stem, c)


def basalt_cluster(n=7, spread=1.6, hmax=4.5, col=0x39323C, top=0x55485A):
    out = Part()
    for i in range(n):
        a = rnd(0, math.tau)
        d = spread * math.sqrt(rnd(0.0, 1.0))
        h = hmax * rnd(0.25, 1.0) * (1.0 - 0.45 * d / spread)
        r = rnd(0.42, 0.7)
        c = prism(6, r, r * 0.96, 0.0, h, phase=rnd(0, 1)).move(math.cos(a) * d, math.sin(a) * d, 0)
        c.paint(col, top=top, z0=0, z1=hmax, lo=0.7, jit=0.08)
        out.add(c)
    return out


def coral_clump(n=6, hmax=2.2, spread=1.2):
    out = Part()
    cols = [L.CORAL_A, L.CORAL_B, 0xE66A8A, 0xF2A65A, 0xB58AE0]
    for i in range(n):
        a = rnd(0, math.tau)
        d = spread * math.sqrt(rnd(0, 1))
        base = Vector((math.cos(a) * d, math.sin(a) * d, 0))
        h = hmax * rnd(0.4, 1.0)
        col = cols[i % len(cols)]
        lean = Vector((rnd(-0.3, 0.3), rnd(-0.3, 0.3), 0))
        trunk = tube([base, base + lean * 0.5 + Vector((0, 0, h * 0.55)), base + lean + Vector((0, 0, h))],
                     [0.24, 0.18, 0.11], 5)
        trunk.paint(col, z0=0, z1=hmax, lo=0.72, hi=0xFFF2E0, jit=0.07)
        out.add(trunk)
        for k in range(2):
            b0 = base + lean * 0.5 + Vector((0, 0, h * rnd(0.4, 0.65)))
            bd = Vector((rnd(-1, 1), rnd(-1, 1), rnd(0.6, 1.2))).normalized() * h * rnd(0.3, 0.5)
            br = tube([b0, b0 + bd * 0.6, b0 + bd], [0.13, 0.1, 0.06], 4)
            br.paint(col, z0=0, z1=hmax, lo=0.72, hi=0xFFF2E0, jit=0.07)
            out.add(br)
    return out


def crystal_cluster(n=7, hmax=5.0, spread=1.5, col_a=0x2FB7C2, col_b=0xD8FBFF):
    out = Part()
    for i in range(n):
        a = rnd(0, math.tau)
        d = spread * math.sqrt(rnd(0, 1))
        h = hmax * rnd(0.3, 1.0) * (1.0 - 0.4 * d / spread)
        r = h * rnd(0.11, 0.17) + 0.12
        c = prism(6, r, r * 0.8, -0.3, h * 0.78, tip=h * 0.22, phase=rnd(0, 1))
        c.paint(lambda cen, n_, h=h: mix(col_a, col_b, min(1.0, max(0.0, cen.z / max(h, 0.1))) ** 1.4), glow=True, jit=0.1)
        tilt = rnd(4, 26) * min(1.0, d / max(spread, 0.1) + 0.25)
        c.roty(tilt).rotz(math.degrees(a))
        c.move(math.cos(a) * d, math.sin(a) * d, 0)
        out.add(c)
    for i in range(4):
        a = rnd(0, math.tau)
        rk = rock(rnd(0.4, 0.8), 1, 0.3, 0.6).move(math.cos(a) * spread * 1.05, math.sin(a) * spread * 1.05, 0.1)
        rk.paint(0x4A5060, jit=0.08)
        out.add(rk)
    return out


def column(h=4.0, r=0.42, broken=False, col=L.STONE_A):
    base = box_z0(r * 2.6, r * 2.6, 0.3).paint(L.STONE_B)
    sh = lathe([(r * 1.05, 0.3), (r, 0.6), (r * 0.9, h)], 8, False, broken).paint(col, z0=0, z1=5, lo=0.78, jit=0.05)
    out = join(base, sh)
    if broken:
        # jagged top
        pass
    else:
        out.add(box_z0(r * 2.5, r * 2.5, 0.28, z=h).paint(L.STONE_B))
    return out


def pebbles(r_max, n, a_skip=(), col=L.ROCK_B, r_min=0.0, size=(0.15, 0.4)):
    out = Part()
    for _ in range(n):
        a = rnd(0, 360)
        if L.near_lane(a, a_skip, 9):
            continue
        d = rnd(r_min, r_max)
        rk = rock(rnd(*size), 0, 0.3, 0.6).move(P(a, d, 0.05))
        rk.paint(col, jit=0.1)
        out.add(rk)
    return out


def scatter_tufts(r_min, r_max, n, lanes=(), col=L.GRASS_B, h=0.5):
    out = Part()
    for _ in range(n):
        a = rnd(0, 360)
        if L.near_lane(a, lanes, 8):
            continue
        out.add(tuft(3, h, col).move(P(a, rnd(r_min, r_max), 0)))
    return out


def lane_dirt(a, r, lanes, r_isle, width_m=2.6):
    """0..1 how much a top-face at (a, r) lies on one of the landing lanes."""
    best = 0.0
    for l in lanes:
        lat = abs(math.sin(math.radians(L.ang_diff(a, l)))) * r
        if abs(L.ang_diff(a, l)) < 60 and lat < width_m:
            best = max(best, 1.0 - lat / width_m)
    return best


# =====================================================================================
#  isles
# =====================================================================================
@asset(el_deg=24, az_deg=60)
def isle_heart():
    """Heart Isle: r 26, paved ring r 20..26 around the (separate) Sky Spire."""
    R = 26.0
    seg = 72
    radii = [0, 9, 16, 19.4, 20.0, 20.5, 21.6, 23.2, 24.8, 25.4, 26.0]
    top, info = top_disc(radii, seg)
    acc = {210: L.FIRE_EL, 330: L.WATER_EL, 90: L.LEAF_EL, 300: 0xE9B84A, 30: L.WOOD_A, 150: L.WOOD_A, 270: L.WOOD_A}

    def fn(rm, a):
        idx = int(a / (360.0 / seg))
        if rm < 19.4:
            return mul(L.STONE_B, 0.78)
        if rm < 20.0:
            return mul(L.STONE_B, 0.92)
        if rm < 20.5 or 24.8 < rm < 25.4:
            return mix(L.TEAL, 0x7FD6D9, 0.25 if idx % 2 else 0.0)
        if rm > 25.4:
            return mul(L.STONE_B, 0.95)
        ring_i = 0 if rm < 21.6 else (1 if rm < 23.2 else 2)
        c = L.STONE_A if (idx + ring_i) % 2 == 0 else mix(L.STONE_A, L.STONE_B, 0.7)
        for l, col in acc.items():
            d = abs(L.ang_diff(a, l))
            if d < 6.5 and rm > 21.6:
                c = mix(c, col, 0.55 if d < 3.5 else 0.3)
        return c
    paint_faces(top, info, fn, jit=0.035)
    body = L.island_body(R, 45.0, seg, seed=1.3, lip=1.5, lip_col=mul(L.STONE_B, 0.85), levels=9)
    deco = Part()
    # lamp obelisks just outside the walkable rim, between the landings
    for a in (20, 60, 140, 180, 260):      # 20/140/260 (not 0/120/240): clear of the task-isle bridge rails at 5/125/245
        ob = join(prism(4, 0.42, 0.3, -0.3, 2.3, tip=0.5, phase=0.78).paint(L.STONE_B, z0=0, z1=2.5, lo=0.75),
                  icosphere(0.24, 0).move(0, 0, 3.05).paint(0x8FE9EC, glow=True))
        deco.add(ob.move(P(a, 26.9, 0)))
    for _ in range(9):
        a = rnd(0, 360)
        deco.add(rock(rnd(0.5, 1.1), 1, 0.3, 0.7).move(P(a, 27.0 + rnd(0, 0.6), -0.2)).paint(L.ROCK_B, jit=0.08))
    # drifting rocks around the isle
    for a, d, z, s in ((20, 31, -6, 1.6), (130, 30.5, -10, 2.2), (205, 32, -4, 1.2), (255, 30, -13, 1.9), (330, 31.5, -8, 1.4)):
        rk = rock(s, 1, 0.35, 1.1).move(P(a, d, z)).paint(L.ROCK_A, top=L.GRASS_A, jit=0.08)
        deco.add(rk)
    make_object("isle_heart", join(top, body, deco))


def _home_top(radii, seg, fn, exact):
    top, info = top_disc(radii, seg, jitter=0.28, exact=exact)
    paint_faces(top, info, fn, jit=0.05)
    return top


@asset(el_deg=26, az_deg=75)
def isle_home_fire():
    """Ember Crag: obsidian mesa, lava cracks, basalt columns, braziers. r 22."""
    R = 22.0
    lanes = [78.6, 341.4, 210.0, 30.0]

    def fn(rm, a):
        if rm < 5.2:
            return mix(0x40363F, 0x4E424A, 0.5 + 0.5 * nz2(rm, a, 0.3))
        if 5.6 < rm < 6.0:
            return (mix(L.FIRE_EL, L.LAVA_B, 0.25), "glow")
        if rm < 6.0:
            return 0x2A2228
        v = nz2(math.cos(math.radians(a)) * rm, math.sin(math.radians(a)) * rm, 0.16, 3.0)
        c = mix(L.OBSIDIAN, 0x45343C, 0.5 + 0.5 * v)
        ld = lane_dirt(a, rm, lanes, R)
        return mix(c, 0x5A4A50, 0.45 * ld)
    top = _home_top([0, 5.2, 5.6, 6.0, 9, 13, 17, 20, R], 48, fn, (5.2, 5.6, 6.0))
    body = L.island_body(R, 34.0, 48, seed=4.2, lip=1.2, lip_col=0x3A3038,
                         rock_cols=(0x2B2630, 0x3A2F35, 0x4A3A3C), levels=8, glow_veins=(L.LAVA_A, 8))
    deco = Part()
    # lava cracks: flush glowing ribbons wandering from the sanctum toward the rim
    for i in range(11):
        a = 360.0 * i / 11 + rnd(-10, 10)
        d = rnd(6.6, 8.0)
        pts, ws = [], []
        while d < R - 0.6:
            pts.append(P(a, d))
            ws.append(0.42 * (1.0 - d / (R + 6)) + 0.1)
            a += rnd(-9, 9)
            d += rnd(1.6, 2.6)
        if len(pts) >= 2:
            cr = strip_on_ground([(p.x, p.y) for p in pts], ws, 0.03)
            cr.paint(lambda c, n: mix(L.LAVA_A, L.LAVA_B, rnd(0.0, 0.7)), glow=True, jit=0.05)
            deco.add(cr)
            if len(pts) > 3 and i % 2 == 0:     # a side branch
                j = len(pts) // 2
                b0 = pts[j]
                ba = L.sim_angle_of(b0) + rnd(14, 24) * (1 if i % 4 == 0 else -1)
                bp = [b0, P(ba, b0.length + 1.6), P(ba + rnd(-6, 6), b0.length + 3.2)]
                br = strip_on_ground([(p.x, p.y) for p in bp], [0.26, 0.2, 0.08], 0.03)
                br.paint(L.LAVA_A, glow=True, jit=0.08)
                deco.add(br)
    # a small lava pool
    pool = Part()
    cen = P(160, 12.5, 0.035)
    ringp = [cen + Vector((math.cos(t) * rnd(1.5, 2.3), math.sin(t) * rnd(1.3, 2.0), 0)) for t in [math.tau * k / 9 for k in range(9)]]
    c_i = pool.vert(cen)
    ids = [pool.vert(q) for q in ringp]
    for k in range(9):
        pool.face((c_i, ids[k], ids[(k + 1) % 9]), toward=(0, 0, 1))
    pool.paint(lambda c, n: mix(L.LAVA_A, L.LAVA_B, rnd(0.2, 0.9)), glow=True, jit=0.04)
    deco.add(pool)
    for q in ringp[::2]:
        deco.add(rock(rnd(0.3, 0.5), 0, 0.3, 0.6).move(q.x, q.y, 0.05).paint(0x2A2228))
    # basalt column clusters in the free sectors (collision helpers below)
    for a, d, n, hm in ((135, 17.5, 9, 5.2), (270, 17.5, 9, 4.6), (180, 18.3, 6, 3.4)):
        deco.add(basalt_cluster(n, 1.7 if n > 6 else 1.3, hm).move(P(a, d)))
    # braziers flanking each landing and the vent pad
    for l, off, d in ((78.6, 11, 20.8), (341.4, 11, 20.8), (210, 11, 20.8), (30, 13, 19.6)):
        for s in (-1, 1):
            deco.add(brazier().move(P(l + s * off, d)))
    # jagged obsidian shards around the rim (outside the walkable disc)
    for i in range(16):
        a = 360.0 * i / 16 + rnd(-8, 8)
        if L.near_lane(a, lanes[:3], 9):
            continue
        h = rnd(1.0, 3.2)
        sh = prism(4, rnd(0.35, 0.6), 0.2, -0.6, h * 0.6, tip=h * 0.4, phase=rnd(0, 1))
        sh.roty(rnd(8, 28)).rotz(-a)
        sh.move(P(a, R + 0.75))
        sh.paint(0x2B2630, top=0x5A4660, jit=0.1)
        deco.add(sh)
    make_object("isle_home_fire", join(top, body, deco))
    col_cylinder("col_basalt_a", 135, 17.5, 2.5)
    col_cylinder("col_basalt_b", 270, 17.5, 2.5)
    col_cylinder("col_basalt_c", 180, 18.3, 1.9)


@asset(el_deg=26, az_deg=215)
def isle_home_water():
    """Tide Atoll: sandy ring, lagoon band, coral, a waterfall off the rim. r 22."""
    R = 22.0
    lanes = [198.6, 101.4, 330.0, 150.0]

    def fn(rm, a):
        idx = int(a / 7.5)
        if rm < 5.2:
            return mix(L.SAND, 0xF4EAC8, 0.5)
        if 5.6 < rm < 6.0:
            return (mix(L.WATER_EL, 0xCFE6FF, 0.2), "glow")
        if rm < 9.0:
            return mix(L.SAND, 0xD9C79A, 0.3 + 0.3 * nz2(rm, a, 0.4))
        if rm < 15.0:
            shallow = rm < 10.5 or rm > 13.5
            c = mix(L.WATER_A, L.WATER_B, (0.55 if shallow else 0.12) + (0.14 if (idx + int(rm)) % 2 else 0.0))
            return mix(c, 0x9FE0E6, 0.25 if shallow else 0.0)
        # outer beach; water channels to the waterfall (250) and the sky stream (150)
        if abs(L.ang_diff(a, 250)) < 6.5:
            return mix(L.WATER_A, L.WATER_B, 0.35)
        if abs(L.ang_diff(a, 150)) < 8.0:
            return mix(L.WATER_A, L.WATER_B, 0.3 if idx % 2 else 0.45)
        c = mix(L.SAND, 0xCDB88A, 0.25 + 0.3 * nz2(rm, a, 0.5, 2.0))
        if rm < 16.8:
            c = mix(c, 0xB9A77C, 0.45)      # wet sand by the lagoon
        return c
    top = _home_top([0, 5.2, 5.6, 6.0, 9.0, 10.5, 12.0, 13.5, 15.0, 18.5, R], 48, fn,
                    (5.2, 5.6, 6.0, 9.0, 15.0))
    body = L.island_body(R, 34.0, 48, seed=7.7, lip=1.1, lip_col=mul(L.SAND, 0.92),
                         rock_cols=(0x9A8A72, 0xB9A98A, 0xD6C6A0), levels=8)
    deco = Part()
    for a, d, n, hm in ((40, 17.2, 8, 3.6), (290, 17.6, 7, 3.0)):
        deco.add(coral_clump(n, hm, 1.5).move(P(a, d)))
    # little corals, shells and rocks around the rim
    for i in range(14):
        a = 360.0 * i / 14 + rnd(-9, 9)
        if L.near_lane(a, lanes + [250.0], 10):
            continue
        deco.add(coral_clump(2, rnd(0.5, 0.9), 0.3).move(P(a, R - rnd(0.2, 0.9))))
    for _ in range(10):
        a = rnd(0, 360)
        if L.near_lane(a, lanes, 8):
            continue
        st = Part()
        c = st.vert((0, 0, 0.05))
        pts = []
        for k in range(10):
            rr = 0.34 if k % 2 == 0 else 0.14
            pts.append(st.vert((math.cos(math.tau * k / 10) * rr, math.sin(math.tau * k / 10) * rr, 0.02)))
        for k in range(10):
            st.face((c, pts[k], pts[(k + 1) % 10]), toward=(0, 0, 1))
        st.paint([0xF08A7A, 0xF2A65A, 0xE66A8A][int(rnd(0, 3))], jit=0.05)
        deco.add(st.rotz(rnd(0, 360)).move(P(a, rnd(15.8, 20.5))))
    for _ in range(8):
        a = rnd(0, 360)
        deco.add(rock(rnd(0.5, 1.0), 1, 0.3, 0.6).move(P(a, R + rnd(0.5, 1.1), -0.15)).paint(0xB9A98A, top=0xD6C6A0))
    # lily pads + foam flecks on the lagoon
    for _ in range(12):
        a = rnd(0, 360)
        lp = cyl(rnd(0.25, 0.5), 0.0, 0.03, 0.035, 6, caps=False)
        lp.paint(mix(0xDFF3FF, L.WATER_B, rnd(0, 0.5)), jit=0.03)
        deco.add(lp.move(P(a, rnd(10.0, 14.2))))
    make_object("isle_home_water", join(top, body, deco))
    # the waterfall: its own object so the game can scroll it
    wf = Part()
    a0 = 250.0
    rad = Vector((math.cos(math.radians(a0)), -math.sin(math.radians(a0)), 0))
    side = Vector((-rad.y, rad.x, 0))
    prof = [(20.6, 0.04), (22.3, 0.0), (23.3, -0.9), (23.9, -3.5), (24.2, -7.5), (24.4, -12.0), (24.5, -17.0), (24.5, -22.0), (24.4, -26.0)]
    rows = []
    vv = 0.0
    prev = None
    for (d, z) in prof:
        cen = rad * d + Vector((0, 0, z))
        if prev is not None:
            vv += (cen - prev).length / 4.0
        prev = cen
        row = []
        for k, u in enumerate((0.0, 0.33, 0.67, 1.0)):
            bulge = 0.35 * math.sin(math.pi * u) * (0.0 if z > -0.5 else 1.0)
            w = 2.0 + (0.5 if z < -10 else 0.0)
            row.append((wf.vert(cen + side * ((u - 0.5) * 2.0 * w) + rad * bulge), (u, vv)))
        rows.append(row)
    for j in range(len(rows) - 1):
        for k in range(3):
            a, b, c, d2 = rows[j][k], rows[j][k + 1], rows[j + 1][k + 1], rows[j + 1][k]
            wf.face((a[0], b[0], c[0], d2[0]), toward=rad + Vector((0, 0, 0.6)), uv=[a[1], b[1], c[1], d2[1]])
    wf.paint(lambda c, n: mix(L.WATER_A, 0xE8F6FF, min(1.0, max(0.0, -c.z / 26.0)) * 0.7 + rnd(0, 0.15)), jit=0.03, sun=0.0, shade=0.0)
    make_object("waterfall", wf)
    col_cylinder("col_coral_a", 40, 17.2, 2.0)
    col_cylinder("col_coral_b", 290, 17.6, 1.8)


@asset(el_deg=20, az_deg=300, dist_scale=1.0)
def isle_home_leaf():
    """Canopy Grove: one giant tree, roots, mushroom stools, lanterns. r 22."""
    R = 22.0
    lanes = [318.6, 221.4, 90.0, 270.0]

    def fn(rm, a):
        if rm < 5.2:
            return mix(0xB9C79A, 0xCBD6A8, 0.5 + 0.5 * nz2(rm, a, 0.5))
        if 5.6 < rm < 6.0:
            return (0xD9F2A8, "glow")
        x, y = math.cos(math.radians(a)) * rm, math.sin(math.radians(a)) * rm
        v = nz2(x, y, 0.14, 5.0)
        c = mix(L.GRASS_A, L.GRASS_B, 0.5 + 0.5 * v)
        if nz2(x, y, 0.3, 9.0) > 0.25:
            c = mix(c, 0x6E9A52, 0.6)       # moss patches
        ld = lane_dirt(a, rm, lanes, R, 2.2)
        return mix(c, 0xB59A6A, 0.6 * ld)
    top = _home_top([0, 5.2, 5.6, 6.0, 9, 13, 17, 20, R], 48, fn, (5.2, 5.6, 6.0))
    body = L.island_body(R, 34.0, 48, seed=2.9, lip=1.2, lip_col=mul(L.GRASS_A, 0.9),
                         rock_cols=(0x7A6A55, 0x97836A, 0xB09A7A), levels=8)
    deco = Part()
    T = P(20, 12)      # trunk foot
    off5 = Vector((5.1, 1.7, 0.0))

    def bark(a, z):
        return 1.0 + 0.10 * noise.noise(Vector((math.cos(a) * 1.3, math.sin(a) * 1.3, z * 0.25)) + off5)
    trunk = lathe([(3.5, 0.0), (2.75, 0.9), (2.4, 2.2), (2.15, 6.0), (1.95, 10.0), (1.7, 13.5)], 10, False, True, rf=bark)
    trunk.paint(L.WOOD_B, z0=0, z1=13, lo=0.72, hi=L.WOOD_A, jit=0.08)
    deco.add(trunk.move(T))
    for k in range(8):       # roots
        a = math.tau * k / 8 + rnd(-0.25, 0.25)
        ln = rnd(3.2, 5.0)
        d = Vector((math.cos(a), math.sin(a), 0))
        pts = [T + d * 2.2 + Vector((0, 0, 1.0)), T + d * (2.2 + ln * 0.4) + Vector((0, 0, 0.42)),
               T + d * (2.2 + ln * 0.75) + Vector((rnd(-.4, .4), rnd(-.4, .4), 0.16)), T + d * (2.2 + ln) + Vector((0, 0, -0.1))]
        deco.add(tube(pts, [0.62, 0.42, 0.26, 0.1], 5).paint(L.WOOD_B, top=0x7FA055, jit=0.08))
    # boughs + canopy blobs (kept >= 7 m above the walkable ground)
    canopy = [(Vector((0, 0, 16.5)), 6.4), (Vector((-6.5, -1.5, 13.6)), 5.2), (Vector((5.0, 4.0, 13.8)), 4.8),
              (Vector((-2.0, 6.5, 14.2)), 5.0), (Vector((2.5, -6.5, 13.8)), 4.9), (Vector((-9.5, 5.5, 12.9)), 4.0),
              (Vector((-10.5, -6.0, 12.6)), 3.8)]
    for cen, rad in canopy:
        c0 = T + cen
        b = blob(rad, 2, 0.2, 0.62).move(c0)
        b.paint(lambda c, n: mix(L.LEAF_A, L.LEAF_C, min(1.0, max(0.0, n.z * 0.6 + 0.45))), z0=c0.z - rad * 0.6, z1=c0.z + rad * 0.6, lo=0.68, jit=0.07)
        deco.add(b)
        s0 = T + Vector((0, 0, rnd(9.5, 12.5)))
        deco.add(tube([s0, (s0 + c0) * 0.5 + Vector((0, 0, 0.8)), c0 - Vector((0, 0, rad * 0.25))], [0.75, 0.5, 0.3], 5, False)
                 .paint(L.WOOD_B, jit=0.07))
    # hanging lanterns under the canopy
    for cen, hang in ((Vector((-6.5, -1.5, 0)), 8.2), (Vector((4.5, 3.5, 0)), 7.8), (Vector((-2.0, 6.0, 0)), 8.0),
                      (Vector((2.5, -6.0, 0)), 7.9), (Vector((-9.5, 5.0, 0)), 7.6), (Vector((-10.0, -5.5, 0)), 7.5),
                      (Vector((-4.0, -5.0, 0)), 8.3)):
        top_p = T + cen + Vector((0, 0, 11.6))
        hp = T + cen + Vector((0, 0, hang))
        deco.add(tube([top_p, hp], 0.035, 3, False).paint(L.WOOD_B))
        deco.add(lantern(1.5, [0xFFD27A, 0xFFE9A8, 0xBFF2A0][int(rnd(0, 3))]).move(hp))
    # mushroom stools by the trunk + glow-caps on the rim
    for a, d, h, c in ((60, 3.9, 0.9, 0xD9634A), (110, 4.2, 0.6, 0xE9A24A), (200, 4.0, 0.75, 0xD9634A), (290, 4.3, 0.55, 0xE9A24A),
                       (330, 3.8, 1.0, 0xD9634A)):
        aa = math.radians(a)
        deco.add(mushroom(h, c).move(T + Vector((math.cos(aa) * d, math.sin(aa) * d, 0))))
    for i in range(18):
        a = 360.0 * i / 18 + rnd(-7, 7)
        if L.near_lane(a, lanes, 10):
            continue
        deco.add(mushroom(rnd(0.35, 0.7), 0x9FF0D0, glow=True).move(P(a, R - rnd(0.3, 1.0))))
    for l in (318.6, 221.4, 90.0, 270.0):
        for s in (-1, 1):
            lp = lantern_post(2.3, 0xFFE9A8).rotz(-(l + 180))
            deco.add(lp.move(P(l + s * 10.5, 20.9)))
    deco.add(scatter_tufts(6.8, 21.0, 46, lanes, L.GRASS_B, 0.55))
    # flowers
    for _ in range(26):
        a = rnd(0, 360)
        if L.near_lane(a, lanes, 7):
            continue
        fl = cone(0.13, 0.25, 0.4, 5).rotx(180).move(0, 0, 0.65)
        fl.paint([0xFFF2B0, 0xF7B6D2, 0xFFFFFF][int(rnd(0, 3))], jit=0.05)
        st = tube([(0, 0, 0), (0, 0, 0.3)], 0.025, 3, False).paint(L.LEAF_A)
        deco.add(join(fl, st).move(P(a, rnd(7, 21))))
    # vines dangling below the rim
    for i in range(10):
        a = rnd(0, 360)
        ln = rnd(3, 8)
        pts = [P(a, R + 0.9, -0.3), P(a + rnd(-2, 2), R + 1.2, -ln * 0.5), P(a + rnd(-3, 3), R + 0.8, -ln)]
        deco.add(tube(pts, [0.14, 0.1, 0.04], 4, False).paint(L.LEAF_A, jit=0.1))
    make_object("isle_home_leaf", join(top, body, deco))
    col_cylinder("col_trunk", 20, 12, 2.6, 6.0)


# ------------------------------------------------------------------ wild isles
@asset(el_deg=22, az_deg=250)
def isle_wild_windmill():
    R = 16.0
    lanes = [30.0, 138.6, 210.0, 281.4]

    def fn(rm, a):
        x, y = math.cos(math.radians(a)) * rm, math.sin(math.radians(a)) * rm
        c = mix(L.GRASS_A, L.GRASS_B, 0.5 + 0.5 * nz2(x, y, 0.18, 1.0))
        if (a > 300 or a < 12) and rm > 6.0:
            c = mix(0xD9C36A, 0xE6D48A, 0.5 + 0.5 * nz2(x, y, 0.6, 4.0))      # wheat patch
        ld = lane_dirt(a, rm, lanes, R, 2.3)
        return mix(c, 0xB59A6A, 0.65 * ld)
    top, info = top_disc([0, 4, 8, 12, 14.5, R], 40, jitter=0.25)
    paint_faces(top, info, fn, jit=0.05)
    body = L.island_body(R, 26.0, 40, seed=11.1, lip=1.0, lip_col=mul(L.GRASS_A, 0.9), levels=7)
    deco = Part()
    Tc = P(85, 9)
    tower = lathe([(2.35, 0.0), (2.2, 0.7), (1.95, 4.8), (1.75, 8.2)], 10, False, False)
    tower.paint(lambda c, n: L.STONE_A if int(c.z / 0.9) % 2 == 0 else mix(L.STONE_A, L.STONE_B, 0.8), z0=0, z1=8.2, lo=0.78, jit=0.06)
    roof = lathe([(2.25, 8.1), (1.2, 9.6), (0.0, 11.0)], 10, True, False).paint(0xB5533C, z0=8, z1=11, lo=0.75, hi=0xE08A5A, jit=0.07)
    band = lathe([(2.0, 4.6), (2.05, 4.9), (1.95, 5.0)], 10, False, False).paint(L.WOOD_B)
    tw = join(tower, roof, band)
    face_dir = 265.0                                  # toward the isle centre
    fd = Vector((math.cos(math.radians(face_dir)), -math.sin(math.radians(face_dir)), 0))
    sd = Vector((-fd.y, fd.x, 0))
    door = box(1.1, 0.3, 1.9, (0, 0, 0.95)).paint(L.WOOD_B, jit=0.04)
    door.rotz(math.degrees(math.atan2(sd.y, sd.x))).move(fd * 2.22)
    win = box(0.6, 0.3, 0.8, (0, 0, 6.0)).paint(0x3A3340, jit=0.02)
    win.rotz(math.degrees(math.atan2(sd.y, sd.x))).move(fd * 1.82)
    axle = tube([Vector((0, 0, 7.2)) + fd * 1.5, Vector((0, 0, 7.2)) + fd * 2.5], 0.2, 6).paint(L.WOOD_B)
    tw.add(door).add(win).add(axle)
    deco.add(tw.move(Tc))
    # hay bales + sacks + a fence by the tower (inside the collision circle)
    for a, d in ((40, 3.2), (150, 3.3), (95, 3.4)):
        aa = math.radians(a)
        hb = cyl(0.55, 0.55, 0.0, 0.8, 8).rotx(90).rotz(rnd(0, 180)).move(0, 0, 0.55)
        hb.paint(0xE0C56A, jit=0.08)
        deco.add(hb.move(Tc + Vector((math.cos(aa) * d, math.sin(aa) * d, 0))))
    for i in range(7):
        a = 20 + i * 9
        deco.add(box_z0(0.14, 0.14, 0.9).paint(L.WOOD_A).move(P(a, 15.4)))
        if i < 6:
            p0, p1 = P(a, 15.4, 0.65), P(a + 9, 15.4, 0.65)
            deco.add(tube([p0, p1], 0.05, 4, False).paint(L.WOOD_A))
    # wheat tufts
    for _ in range(46):
        a = (300 + rnd(0, 70)) % 360
        if L.near_lane(a, lanes, 9):
            continue
        deco.add(tuft(3, 0.75, 0xE6D48A).move(P(a, rnd(6.5, 15.3))))
    deco.add(scatter_tufts(2.0, 15.2, 24, lanes, L.GRASS_B, 0.45))
    deco.add(pebbles(15.5, 10, lanes, L.ROCK_B, 3.0))
    make_object("isle_wild_windmill", join(top, body, deco))
    # sails: own object, origin at the hub, hub axis = local Y (Godot local Z)
    hub = Tc + Vector((0, 0, 7.2)) + fd * 2.55
    sails = Part()
    sails.add(cyl(0.32, 0.26, -0.25, 0.25, 8).rotx(90).paint(L.WOOD_B))
    for k in range(4):
        bl = Part()
        bl.add(box(0.16, 0.12, 5.3, (0, 0, 2.75)).paint(L.WOOD_B))
        for j in range(5):                              # cloth panels on a ladder frame
            z0 = 1.0 + j * 0.86
            cl = Part()
            cl.poly([(0.1, 0.02, z0), (1.25, 0.06, z0 + 0.05), (1.25, 0.06, z0 + 0.78), (0.1, 0.02, z0 + 0.74)])
            cl.paint(0xF4EAD4 if j % 2 == 0 else 0xE6D6B4, jit=0.04, sun=0.02)
            bl.add(cl)
            bl.add(box(1.3, 0.07, 0.07, (0.62, 0.04, z0)).paint(L.WOOD_A))
        bl.add(box(1.3, 0.07, 0.07, (0.62, 0.04, 5.3)).paint(L.WOOD_A))
        bl.add(box(0.07, 0.07, 4.35, (1.25, 0.06, 3.13)).paint(L.WOOD_A))
        sails.add(bl.roty(90.0 * k + 20.0))
    # local +Y of the object must point along -fd (blades in front, facing the isle centre): rotate about Z
    rot = math.atan2(-(-fd.x), -fd.y)
    make_object("sails", sails, location=hub, rotation=(0.0, 0.0, rot))
    col_cylinder("col_mill", 85, 9, 2.6, 5.0)


@asset(el_deg=24, az_deg=280)
def isle_wild_ruin():
    R = 16.0
    lanes = [41.4, 150.0, 258.6, 330.0]

    def fn(rm, a):
        x, y = math.cos(math.radians(a)) * rm, math.sin(math.radians(a)) * rm
        g = mix(L.GRASS_A, 0x7E9A62, 0.5 + 0.5 * nz2(x, y, 0.2, 6.0))
        idx = int(a / 9.0) + int(rm / 2.0)
        if rm < 8.0 and nz2(x, y, 0.35, 2.0) > -0.25:
            return L.STONE_A if idx % 2 == 0 else mix(L.STONE_A, L.STONE_B, 0.8)
        ld = lane_dirt(a, rm, lanes, R, 2.2)
        return mix(g, mix(L.STONE_B, 0xB59A6A, 0.5), 0.6 * ld)
    top, info = top_disc([0, 4, 8, 12, 14.5, R], 40, jitter=0.25)
    paint_faces(top, info, fn, jit=0.05)
    body = L.island_body(R, 26.0, 40, seed=15.4, lip=1.0, lip_col=mul(L.GRASS_A, 0.88), levels=7)
    deco = Part()
    A = P(95, 9)
    # arch: two tall columns + lintel, a broken pair, fallen drums
    c1 = column(4.6, 0.46).move(A + Vector((-1.3, 0.2, 0)))
    c2 = column(4.6, 0.46).move(A + Vector((1.3, -0.2, 0)))
    lint = box(3.9, 1.0, 0.6, (0, 0, 5.2)).paint(L.STONE_B, top=L.STONE_A).rotz(-9).move(A)
    ped = Part()
    ped.poly([(-1.7, 0.42, 5.5), (1.7, 0.42, 5.5), (0, 0.42, 6.5)], toward=(0, 1, 0))
    ped.poly([(-1.7, -0.42, 5.5), (1.7, -0.42, 5.5), (0, -0.42, 6.5)], toward=(0, -1, 0))
    ped.poly([(-1.7, 0.42, 5.5), (0, 0.42, 6.5), (0, -0.42, 6.5), (-1.7, -0.42, 5.5)], toward=(-1, 0, 1))
    ped.poly([(1.7, 0.42, 5.5), (0, 0.42, 6.5), (0, -0.42, 6.5), (1.7, -0.42, 5.5)], toward=(1, 0, 1))
    ped.paint(L.STONE_A, jit=0.05).rotz(-9).move(A)
    c3 = column(2.6, 0.44, broken=True).move(A + Vector((-1.0, 2.1, 0)))
    c4 = column(1.4, 0.44, broken=True).move(A + Vector((1.6, 1.9, 0)))
    deco.add(c1).add(c2).add(lint).add(ped).add(c3).add(c4)
    for (dx, dy, rz) in ((0.3, 1.2, 30), (-2.0, -1.3, 80)):
        dr = cyl(0.42, 0.42, -0.5, 0.5, 8).rotx(90).rotz(rz).move(A + Vector((dx, dy, 0.42)))
        deco.add(dr.paint(L.STONE_A, jit=0.06))
    B = P(205, 10)
    deco.add(column(3.9, 0.42).move(B + Vector((-0.8, 0, 0))))
    deco.add(column(2.0, 0.42, broken=True).move(B + Vector((0.8, 0.3, 0))))
    fallen = cyl(0.4, 0.36, 0.0, 2.6, 8).rotx(90).rotz(40).move(B + Vector((0.2, 1.3, 0.4)))
    deco.add(fallen.paint(L.STONE_A, jit=0.06))
    # low broken wall + floor slabs around the rim, ivy
    for a0, n in ((0, 4), (182, 3), (290, 3)):
        for i in range(n):
            a = a0 + i * 6.5
            h = rnd(0.5, 1.5)
            blk = box_z0(1.5, 0.7, h).rotz(-(a + 90)).move(P(a, 14.6))
            deco.add(blk.paint(L.STONE_B, top=L.STONE_A, z0=0, z1=1.5, lo=0.8, jit=0.07))
    for _ in range(9):
        a = rnd(0, 360)
        sl = box_z0(rnd(0.8, 1.4), rnd(0.8, 1.2), 0.08).rotz(rnd(0, 90)).move(P(a, rnd(8.5, 13.5)))
        deco.add(sl.paint(L.STONE_B, jit=0.08))
    deco.add(scatter_tufts(8.2, 15.3, 36, lanes, 0x8FB06A, 0.5))
    deco.add(pebbles(15.5, 12, lanes, L.STONE_B, 3.0))
    make_object("isle_wild_ruin", join(top, body, deco))
    col_cylinder("col_ruin_a", 0, 0, 2.8, 5.0, center=A + Vector((0.1, 0.7, 0)))
    col_cylinder("col_ruin_b", 0, 0, 1.8, 4.0, center=B + Vector((0.0, 0.4, 0)))


@asset(el_deg=24, az_deg=30)
def isle_wild_crystal():
    R = 16.0
    lanes = [18.6, 90.0, 161.4, 270.0]

    def fn(rm, a):
        x, y = math.cos(math.radians(a)) * rm, math.sin(math.radians(a)) * rm
        v = nz2(x, y, 0.2, 8.0)
        c = mix(0x4A5568, 0x64728C, 0.5 + 0.5 * v)
        ld = lane_dirt(a, rm, lanes, R, 2.2)
        return mix(c, 0x8A93A8, 0.55 * ld)
    top, info = top_disc([0, 4, 8, 12, 14.5, R], 40, jitter=0.25)
    paint_faces(top, info, fn, jit=0.05)
    body = L.island_body(R, 26.0, 40, seed=21.8, lip=1.0, lip_col=0x56607A,
                         rock_cols=(0x4A5060, 0x5C6274, 0x747A8C), levels=7, glow_veins=(0x4FD8E0, 6))
    deco = Part()
    for i in range(9):                          # flush glowing seams in the slate
        a = 360.0 * i / 9 + rnd(-12, 12)
        d = rnd(2.5, 6.0)
        pts, ws = [], []
        while d < R - 0.8 and len(pts) < 5:
            pts.append(P(a, d))
            ws.append(rnd(0.14, 0.3))
            a += rnd(-12, 12)
            d += rnd(1.4, 2.4)
        if len(pts) >= 2:
            ws[-1] = 0.05
            deco.add(strip_on_ground([(q.x, q.y) for q in pts], ws, 0.03).paint(mix(0x2FB7C2, 0x9FF3F5, rnd(0.2, 0.8)), glow=True))
    deco.add(crystal_cluster(9, 6.0, 1.7).move(P(220, 9)))
    deco.add(crystal_cluster(6, 3.6, 1.1).move(P(320, 10)))
    for i in range(14):                         # shards along the rim
        a = 360.0 * i / 14 + rnd(-8, 8)
        if L.near_lane(a, lanes, 10):
            continue
        h = rnd(0.6, 1.6)
        sh = prism(5, h * 0.16, h * 0.1, -0.2, h * 0.7, tip=h * 0.3).roty(rnd(5, 25)).rotz(rnd(0, 360))
        sh.paint(lambda c, n: mix(0x2FB7C2, 0xD8FBFF, rnd(0.2, 0.8)), glow=True)
        deco.add(sh.move(P(a, R + rnd(0.2, 0.8), -0.1)))
    for i in range(7):                          # crystals hanging underneath
        a = rnd(0, 360)
        h = rnd(2.0, 4.5)
        sh = prism(6, h * 0.14, h * 0.1, 0, h * 0.7, tip=h * 0.3).rotx(180 + rnd(-15, 15))
        sh.paint(lambda c, n: mix(0x2FB7C2, 0xD8FBFF, rnd(0.1, 0.6)), glow=True)
        deco.add(sh.move(P(a, rnd(5, 12), -rnd(7, 12))))
    deco.add(pebbles(15.4, 16, lanes, 0x5C6274, 2.0, (0.2, 0.5)))
    make_object("isle_wild_crystal", join(top, body, deco))
    col_cylinder("col_crystal_a", 220, 9, 2.6, 5.0)
    col_cylinder("col_crystal_b", 320, 10, 1.8, 3.0)


def _islet(name, R, depth, seed, style):
    def fn(rm, a):
        x, y = math.cos(math.radians(a)) * rm, math.sin(math.radians(a)) * rm
        v = 0.5 + 0.5 * nz2(x, y, 0.3, seed)
        if style == "rock":
            return mix(mix(L.ROCK_B, L.ROCK_C, v), L.GRASS_A, 0.5 if nz2(x, y, 0.5, seed + 3) > 0.1 else 0.0)
        if style == "moss":
            return mix(0x6E9A52, 0x9DBB70, v)
        return mix(L.GRASS_A, L.GRASS_B, v)
    top, info = top_disc([0, R * 0.45, R * 0.8, R], 24, jitter=0.2)
    paint_faces(top, info, fn, jit=0.06)
    lipc = {"rock": mul(L.ROCK_B, 0.95), "moss": 0x66904C}.get(style, mul(L.GRASS_A, 0.9))
    body = L.island_body(R, depth, 24, seed=seed, lip=0.7, lip_col=lipc, levels=4)
    deco = Part()
    deco.add(scatter_tufts(0.5, R - 0.4, 14 if style != "rock" else 7, (), L.GRASS_B, 0.4))
    deco.add(pebbles(R - 0.3, 7 if style != "rock" else 12, (), L.ROCK_B, 0.5))
    if style == "grass":
        for _ in range(9):
            a = rnd(0, 360)
            fl = cone(0.11, 0.2, 0.33, 5).rotx(180).move(0, 0, 0.53).paint([0xFFF2B0, 0xF7B6D2, 0xFFFFFF][int(rnd(0, 3))])
            deco.add(fl.move(P(a, rnd(1, R - 0.6))))
    if style == "moss":
        for _ in range(6):
            a = rnd(0, 360)
            deco.add(mushroom(rnd(0.25, 0.4), 0xE9A24A).move(P(a, rnd(1.5, R - 0.6))))
    make_object(name, join(top, body, deco))


@asset(el_deg=24)
def islet_small_a():
    _islet("islet_small_a", 7.0, 10.0, 31.0, "grass")


@asset(el_deg=24)
def islet_small_b():
    _islet("islet_small_b", 6.0, 9.0, 37.0, "rock")


@asset(el_deg=24)
def islet_small_c():
    _islet("islet_small_c", 5.0, 8.0, 43.0, "moss")


# =====================================================================================
#  bridges, routes, pickups, molecules
# =====================================================================================
@asset(el_deg=30, az_deg=40)
def bridge_plank_segment():
    """Rope-and-plank bridge, 4 m wide, tiles every 4 m along Godot Z (Blender Y)."""
    p = Part()
    for i in range(8):
        y = -2.0 + 0.25 + i * 0.5
        pl = box(3.96 + rnd(-0.06, 0.06), 0.44, 0.1, (rnd(-0.03, 0.03), 0, -0.05)).rotz(rnd(-1.2, 1.2)).move(0, y, 0)
        pl.paint(mix(L.WOOD_A, L.WOOD_B, rnd(0.0, 0.55)), top=mix(L.WOOD_A, 0xC9A774, rnd(0.2, 0.6)), jit=0.05)
        p.add(pl)
    for x in (-1.55, 1.55):
        p.add(box(0.2, 4.0, 0.16, (x, 0, -0.18)).paint(L.WOOD_B, jit=0.03))
    for x in (-2.06, 2.06):
        p.add(box_z0(0.17, 0.17, 1.3, x, 0, -0.22).paint(L.WOOD_B, z0=-0.2, z1=1.1, lo=0.75))
        p.add(box_z0(0.24, 0.24, 0.07, x, 0, 1.08).paint(L.WOOD_A))
        ys = [-2.0, -1.0, 0.0, 1.0, 2.0]
        for hs, r in (([0.74, 0.86, 1.0, 0.86, 0.74], 0.045), ([0.3, 0.38, 0.48, 0.38, 0.3], 0.035)):
            p.add(tube([(x, ys[k], hs[k]) for k in range(5)], r, 4, False).paint(0xD9C7A0, jit=0.05))
        for y in (-1.0, 1.0):
            p.add(tube([(x, y, 0.38), (x, y, 0.86)], 0.025, 3, False).paint(0xD9C7A0))
            p.add(tube([(x, y, -0.05), (x, y, 0.38)], 0.025, 3, False).paint(0xD9C7A0))
    lan = lantern(1.0, 0xFFD27A).move(2.06, 0, 1.75)
    p.add(tube([(2.06, 0, 1.15), (2.06, 0, 1.75)], 0.03, 3, False).paint(L.WOOD_B))
    p.add(lan)
    make_object("bridge_plank_segment", p)


@asset(el_deg=40)
def thermal_vent():
    """Fire's glowing grate pad, r 1.5."""
    p = Part()
    p.add(lathe([(1.5, -0.1), (1.5, 0.1), (1.3, 0.2), (1.08, 0.2), (1.02, 0.04)], 14, False, False)
          .paint(0x3A3238, top=0x55485A, jit=0.07))
    d, info = top_disc([0, 0.5, 1.02], 14, z=0.04)
    paint_faces(d, info, lambda rm, a: (mix(L.LAVA_B, L.LAVA_A, min(1.0, rm / 0.9)), "glow"), jit=0.06)
    p.add(d)
    for i in range(5):
        x = -0.8 + i * 0.4
        ln = 2.0 * math.sqrt(max(0.05, 1.04 - x * x))
        p.add(box(0.09, ln, 0.07, (x, 0, 0.19)).paint(0x231E24, jit=0.03))
    for y in (-0.45, 0.45):
        p.add(box(1.85, 0.09, 0.07, (0, y, 0.17)).paint(0x231E24, jit=0.03))
    for i in range(7):
        a = 360.0 * i / 7 + rnd(-10, 10)
        p.add(rock(rnd(0.22, 0.36), 0, 0.3, 0.7).move(P(a, 1.55, 0.08)).paint(0x2B2630, top=0x4A3A44))
    for i in range(4):
        a = 45 + 90 * i
        p.add(prism(4, 0.16, 0.1, 0.0, 0.45, tip=0.2).move(P(a, 1.38, 0.1)).paint(0x3A3238, top=L.LAVA_A))
    make_object("thermal_vent", p)


@asset(el_deg=35, az_deg=30)
def sky_stream_segment():
    """Water ribbon, 6 m wide, tiles every 4 m along Godot Z. UV: U across, V along."""
    p = Part()
    nx, ny = 8, 8
    grid = []

    def zf(x, y):
        return 0.03 - 0.2 * (x / 3.0) ** 2 + 0.05 * math.sin(math.tau * y / 4.0 + x * 1.7) + 0.03 * math.sin(math.tau * y / 2.0 - x * 2.3)
    for j in range(ny + 1):
        y = -2.0 + 4.0 * j / ny
        row = []
        for i in range(nx + 1):
            x = -3.0 + 6.0 * i / nx
            row.append((p.vert((x, y, zf(x, y))), ((x + 3.0) / 6.0, (2.0 - y) / 4.0)))
        grid.append(row)
    for j in range(ny):
        for i in range(nx):
            a, b, c, d = grid[j][i], grid[j][i + 1], grid[j + 1][i + 1], grid[j + 1][i]
            fi = p.face((a[0], b[0], c[0], d[0]), toward=(0, 0, 1), uv=[a[1], b[1], c[1], d[1]])
            xm = abs(-3.0 + 6.0 * (i + 0.5) / nx) / 3.0
            col = mix(mix(L.WATER_A, L.WATER_B, 0.15 + 0.2 * ((i + j) % 2)), 0xF2FBFF, max(0.0, xm - 0.55) * 1.9)
            p.col[fi] = [col] * 4
    for s in (-1, 1):                    # thin skirts + underside
        for j in range(ny):
            y0, y1 = -2.0 + 4.0 * j / ny, -2.0 + 4.0 * (j + 1) / ny
            u = 0.0 if s < 0 else 1.0
            fi = p.poly([(3.0 * s, y0, zf(3.0 * s, y0)), (3.0 * s, y1, zf(3.0 * s, y1)), (2.7 * s, y1, -0.5), (2.7 * s, y0, -0.5)],
                        toward=(s, 0, -0.2), uv=[(u, (2 - y0) / 4), (u, (2 - y1) / 4), (u, (2 - y1) / 4), (u, (2 - y0) / 4)])
            p.col[fi] = [mul(L.WATER_A, 0.82)] * 4
    fi = p.poly([(-2.7, -2, -0.5), (2.7, -2, -0.5), (2.7, 2, -0.5), (-2.7, 2, -0.5)], toward=(0, 0, -1),
                uv=[(0.05, 1), (0.95, 1), (0.95, 0), (0.05, 0)])
    p.col[fi] = [mul(L.WATER_A, 0.7)] * 4
    make_object("sky_stream_segment", p)


@asset(el_deg=35, az_deg=30)
def vine_bridge_segment():
    """Leaf-only braided vine walkway, ~2.4 m wide, tiles every 4 m along Godot Z."""
    p = Part()
    for j in range(8):                   # woven leafy mat
        y0, y1 = -2.0 + j * 0.5, -1.5 + j * 0.5
        for i in range(3):
            x0, x1 = -1.2 + i * 0.8, -0.4 + i * 0.8
            fi = p.poly([(x0, y0, -0.07), (x1, y0, -0.07), (x1, y1, -0.07), (x0, y1, -0.07)], toward=(0, 0, 1))
            p.col[fi] = [mul(mix(L.LEAF_A, 0x4E7A36, 0.5 if (i + j) % 2 else 0.0), rnd(0.9, 1.05))] * 4
        fi = p.poly([(-1.2, y0, -0.09), (1.2, y0, -0.09), (1.2, y1, -0.09), (-1.2, y1, -0.09)], toward=(0, 0, -1))
        p.col[fi] = [mul(0x4E7A36, 0.7)] * 4
    for x0, ph, col in ((-0.95, 0.0, 0x6E8A3E), (0.0, 2.1, 0x7A6A3E), (0.95, 4.2, 0x6E8A3E)):
        pts = []
        for k in range(9):
            y = -2.0 + 0.5 * k
            pts.append((x0 + 0.22 * math.sin(math.tau * y / 4.0 + ph), y, -0.13 + 0.05 * math.cos(math.tau * y / 2.0 + ph)))
        p.add(tube(pts, 0.15, 5, False).paint(col, top=mix(col, 0xB6C97A, 0.4), jit=0.08))
    for y in (-1.5, -0.5, 0.5, 1.5):
        p.add(tube([(-1.25, y, -0.04), (0, y, 0.0), (1.25, y, -0.04)], 0.05, 3, False).paint(0x8A7A4A))
    for k in range(12):
        s = -1 if k % 2 else 1
        y = -1.85 + k * 0.33
        lf = leaf(rnd(0.5, 0.75), rnd(0.25, 0.36), rnd(0.15, 0.3)).rotz(rnd(-35, 35) + (0 if s > 0 else 180))
        lf.paint(mix(L.LEAF_B, L.LEAF_C, rnd(0, 1)), jit=0.08)
        p.add(lf.move(1.15 * s, y, -0.02))
    for (x, y) in ((1.25, -0.9), (-1.25, 0.9)):
        fl = cone(0.12, 0.0, 0.14, 5).rotx(180).move(x, y, 0.2).paint(0xFFF2B0, glow=True)
        p.add(fl)
    make_object("vine_bridge_segment", p)


@asset(el_deg=22)
def seed_gap_marker():
    """A sprouting seed pod marking a growable gap."""
    p = Part()
    p.add(lathe([(0.75, -0.05), (0.62, 0.06), (0.3, 0.1)], 8, False, False).paint(0x6E5236, top=0x8A6A46, jit=0.08))
    pod = lathe([(0.0, -0.1), (0.3, 0.02), (0.43, 0.22), (0.37, 0.46), (0.2, 0.62), (0.0, 0.68)], 7, False, False)
    pod.paint(lambda c, n: 0xB98A4E if int((math.atan2(c.y, c.x) + math.pi) / (math.tau / 7)) % 2 else 0xA2743E, z0=0, z1=0.7, lo=0.75, jit=0.05)
    p.add(pod)
    stem = [(0, 0, 0.62), (0.04, 0.0, 0.82), (0.12, 0.02, 0.98), (0.16, 0.02, 1.08)]
    p.add(tube(stem, [0.06, 0.05, 0.04, 0.03], 5, False).paint(L.LEAF_B))
    p.add(leaf(0.5, 0.26, 0.05).roty(-28).move(0.1, 0.02, 0.95).paint(L.LEAF_C, jit=0.05))
    p.add(leaf(0.42, 0.24, 0.05).roty(-34).rotz(170).move(0.1, 0.02, 0.9).paint(L.LEAF_B, jit=0.05))
    p.add(icosphere(0.09, 0).move(0.17, 0.02, 1.14).paint(0xE9FFB0, glow=True))
    for i in range(3):
        a = 120 * i + 30
        p.add(leaf(0.34, 0.2, 0.1).rotz(a).move(P(-a, 0.45, 0.08)).paint(L.LEAF_A, jit=0.08))
    make_object("seed_gap_marker", p)


@asset(el_deg=18)
def smog_cloud():
    """CO2 smog cloud: three lobes, ~3.6 m wide, centred ~1.6 m up."""
    p = Part()
    for (c, r, sq) in (((0.0, 0.0, 1.72), 1.05, 0.82), ((-1.02, 0.18, 1.42), 0.82, 0.8), ((0.98, -0.12, 1.46), 0.8, 0.8)):
        b = blob(r, 2, 0.2, sq).move(*c)
        b.paint(lambda cen, n: mix(L.SMOG_B, 0x8D879B, min(1.0, max(0.0, 0.5 + 0.55 * n.z))), z0=0.8, z1=2.6, lo=0.8, jit=0.05, sun=0.03)
        p.add(b)
    make_object("smog_cloud", p)


@asset(el_deg=18)
def breeze_bubble():
    """O2 breeze bubble r 0.8 centred 1.5 m up, with a little swirl."""
    p = Part()
    prof = [(0.8 * math.sin(math.pi * k / 6), 1.5 - 0.8 * math.cos(math.pi * k / 6)) for k in range(7)]
    prof[0] = (0.0, 0.7)
    prof[-1] = (0.0, 2.3)
    p.add(lathe(prof, 10, False, False).paint(lambda c, n: mix(0xBFEFF6, 0xFFFFFF, min(1.0, max(0.0, 0.45 + 0.6 * n.z))), jit=0.03, sun=0.03))
    pts = []
    for k in range(13):
        t = k / 12.0
        a = t * math.tau * 1.4
        r = 0.93 - 0.1 * t
        pts.append((math.cos(a) * r, math.sin(a) * r, 1.1 + 0.85 * t))
    p.add(tube(pts, [0.02] + [0.055] * 11 + [0.02], 3, False).paint(0xFFFFFF, glow=True, jit=0.02))
    for (x, y, z, s) in ((0.35, -0.6, 1.95, 0.12), (0.55, -0.45, 1.75, 0.07)):
        p.add(icosphere(s, 0).move(x, y, z).paint(0xFFFFFF, glow=True))
    make_object("breeze_bubble", p)


@asset(el_deg=18)
def meteor_shard():
    """Black disguise shard (~1.1 m) with faint violet veins."""
    p = Part()
    for (x, y, h, r, tilt, rz) in ((0, 0, 1.12, 0.3, 10, 20), (0.3, 0.12, 0.7, 0.2, 26, 130), (-0.26, -0.1, 0.55, 0.17, 24, 250)):
        sh = prism(5, r, r * 0.62, 0.0, h * 0.62, tip=h * 0.38, phase=rnd(0, 1))
        sh.paint(0x1C1A24, top=0x3A3350, z0=0, z1=1.1, lo=0.8, jit=0.1)
        v = tube([(r * 0.9, 0, 0.05), (r * 0.82, 0.03, h * 0.35), (r * 0.6, 0, h * 0.62), (0.04, 0, h * 0.97)], [0.03, 0.035, 0.03, 0.012], 3, False)
        v.paint(0x9B7BFF, glow=True)
        sh.add(v).add(v.copy().rotz(140))
        p.add(sh.roty(tilt).rotz(rz).move(x, y, 0))
    for i in range(4):
        a = 90 * i + 30
        p.add(rock(rnd(0.14, 0.22), 0, 0.3, 0.6).move(P(a, 0.42, 0.06)).paint(0x25222C))
    make_object("meteor_shard", p)


@asset(el_deg=14)
def sun_mote():
    """Floating sun crystal + star-burst halo. Near white: tinted per element in game."""
    p = Part()
    p.add(lathe([(0.0, 1.05), (0.27, 1.4), (0.0, 1.75)], 6, False, False).paint(lambda c, n: mix(0xFFF3CF, 0xFFFFFF, rnd(0, 1)), glow=True, jit=0.03))
    for i in range(3):
        a = 120 * i + 15
        o = lathe([(0.0, -0.11), (0.07, 0.0), (0.0, 0.11)], 4, False, False).paint(0xFFFFFF, glow=True)
        p.add(o.move(P(a, 0.5, 1.4 + 0.12 * (i - 1))))
    c = Vector((0, 0, 1.4))
    for ax in ("x", "y", "z"):               # star rays in three planes
        for k in range(4):
            a = math.tau * k / 4 + (math.pi / 4 if ax == "z" else 0.0)
            ln = 0.95 if k % 2 == 0 or ax == "z" else 0.75
            w = 0.05
            d2 = Vector((math.cos(a), math.sin(a)))
            if ax == "x":
                d, s = Vector((0, d2.x, d2.y)), Vector((0, -d2.y, d2.x))
            elif ax == "y":
                d, s = Vector((d2.x, 0, d2.y)), Vector((-d2.y, 0, d2.x))
            else:
                d, s = Vector((d2.x, d2.y, 0)), Vector((-d2.y, d2.x, 0))
            fi = p.poly([c + d * 0.3, c + d * 0.48 + s * w, c + d * ln, c + d * 0.48 - s * w])
            p.col[fi] = [(1.0, 0.98, 0.9)] * 4
            p.mat[fi] = 1
    ringp, info = top_disc([0.56, 0.61], 14, z=1.4)
    paint_faces(ringp, info, lambda rm, a: (0xFFFFFF, "glow"), jit=0.0)
    p.add(ringp)
    make_object("sun_mote", p)


@asset(el_deg=18)
def spark_orb():
    """Spark orb (r 0.22) with three socket gems (children, lit one per mote)."""
    orb = make_object("spark_orb", icosphere(0.22, 1).paint(lambda c, n: mix(0xFFF6DC, 0xFFFFFF, rnd(0, 1)), glow=True, jit=0.02))
    for i in range(3):
        g = lathe([(0.0, -0.085), (0.06, 0.0), (0.0, 0.085)], 4, False, False).paint(0xFFFFFF, glow=True, jit=0.02)
        make_object("socket_%d" % (i + 1), g, location=P(120.0 * i, 0.38, 0.0), parent=orb)


@asset(el_deg=20, az_deg=40)
def smog_sea_front():
    """Billowy cloud-wall segment along X (-8..8); copies placed end to end tile."""
    p = Part()
    for (x, y, z, r, sq) in ((-6.0, 0.3, 2.0, 3.0, 1.15), (-2.0, -0.5, 2.7, 3.2, 1.1), (2.0, 0.4, 1.9, 3.0, 1.2), (6.0, -0.3, 2.5, 3.1, 1.1)):
        b = blob(r, 2, 0.16, sq, freq=0.5).scale(1.0, 0.8, 1.0).move(x, y, z)
        b.paint(lambda cen, n: mix(L.SMOG_B, 0x8F8AA0, min(1.0, max(0.0, 0.45 + 0.6 * n.z))), z0=-1.0, z1=6.0, lo=0.62, jit=0.05, sun=0.04)
        p.add(b)
    for (x, y, z, r) in ((-4.0, -1.2, 4.6, 1.5), (4.0, 1.1, 4.4, 1.6)):
        b = blob(r, 1, 0.2, 0.9).move(x, y, z)
        b.paint(0x8F8AA0, z0=3.0, z1=6.0, lo=0.8, jit=0.05)
        p.add(b)
    make_object("smog_sea_front", p)


# =====================================================================================
#  the Sky Spire
# =====================================================================================
def band(p, a0, a1, r0, z0, r1, z1, toward=None):
    """One quad of a ring between (r0,z0) and (r1,z1) spanning sim angles a0..a1."""
    am = math.radians((a0 + a1) * 0.5)
    if toward is None:
        toward = Vector((math.cos(am), -math.sin(am), 0))
    elif toward == "in":
        toward = -Vector((math.cos(am), -math.sin(am), 0))
    elif toward == "up":
        toward = Vector((0, 0, 1))
    return p.poly([P(a0, r0, z0), P(a1, r0, z0), P(a1, r1, z1), P(a0, r1, z1)], toward=toward)


def tier_part(k, seg=None, niches=True, lamps=True):
    """Tier k (1..5): drum wall, terrace top at h = 6k and its parapet (gap at the down ramp)."""
    R = TIER_R[k - 1]
    z0, z1 = TIER_H * (k - 1), TIER_H * k
    seg = seg or [64, 56, 48, 40, 32][k - 1]
    gap_a = RAMP_A[k - 1]
    r_in = (TIER_R[k] - 0.6) if k < 5 else 0.0
    par_h = 0.6 if k < 5 else 0.3
    light = 0.86 + 0.14 * (k - 1) / 4.0
    p = Part()
    step = 360.0 / seg

    def put(fi, col, jit=0.035, glow=False):
        c = L.as_rgb(col)
        kk = (1.0 + rnd(-jit, jit)) * (1.0 if glow else light)
        n = p._normal(p.f[fi])
        s = 0.0 if glow else n.dot(L.SUN_DIR) * 0.08
        c = (min(1, c[0] * (kk + s * 1.2)), min(1, c[1] * (kk + s * 0.4)), min(1, c[2] * (kk - s * 1.3)))
        p.col[fi] = [c] * len(p.f[fi])
        p.mat[fi] = 1 if glow else 0

    for i in range(seg):
        a0, a1 = i * step, (i + 1) * step
        am = (a0 + a1) * 0.5
        in_gap = abs(L.ang_diff(am, gap_a)) < 12.0
        # plinth
        put(band(p, a0, a1, R + 0.2, z0, R + 0.2, z0 + 0.45), mul(L.STONE_B, 0.86))
        put(band(p, a0, a1, R + 0.2, z0 + 0.45, R, z0 + 0.62), mul(L.STONE_B, 0.95))
        # lower wall (niches every 4th segment)
        base = L.STONE_A if i % 2 == 0 else mix(L.STONE_A, L.STONE_B, 0.75)
        niche = niches and i % 4 == 1 and not in_gap and abs(L.ang_diff(am, RAMP_A[k - 1])) > 16
        if niche:
            zi0, zi1 = z0 + 0.9, z0 + 2.65
            ai0, ai1 = a0 + step * 0.16, a1 - step * 0.16
            dpt = 0.35
            put(band(p, a0, a1, R, z0 + 0.62, R, zi0), base)
            put(band(p, a0, a1, R, zi1, R, z0 + 2.8), base)
            put(band(p, a0, ai0, R, zi0, R, zi1), base)
            put(band(p, ai1, a1, R, zi0, R, zi1), base)
            put(band(p, ai0, ai1, R - dpt, zi0, R - dpt, zi1), 0x6F6558, 0.02)
            put(band(p, ai0, ai1, R, zi0, R - dpt, zi0, toward="up"), mul(L.STONE_B, 0.8))
            put(band(p, ai0, ai1, R - dpt, zi1, R, zi1, toward=(0, 0, -1)), mul(L.STONE_B, 0.6))
            for (aa, sgn) in ((ai0, 1), (ai1, -1)):
                am_r = math.radians(aa)
                tang = Vector((-math.sin(am_r), -math.cos(am_r), 0)) * sgn
                fi = p.poly([P(aa, R, zi0), P(aa, R - dpt, zi0), P(aa, R - dpt, zi1), P(aa, R, zi1)], toward=tang)
                put(fi, mul(L.STONE_B, 0.72))
            if lamps:
                lam = prism(4, 0.13, 0.13, 0.0, 0.42, tip=0.16, phase=0.78).move(P(am, R - dpt * 0.5, zi0 + 0.02))
                lam.paint(0xFFD98A, glow=True, jit=0.04)
                p.add(lam)
        else:
            put(band(p, a0, a1, R, z0 + 0.62, R, z0 + 2.8), base)
        # teal inlay strip, upper wall rows
        put(band(p, a0, a1, R, z0 + 2.8, R, z0 + 3.1), mix(L.TEAL, 0x58BFC6, 0.3 if i % 2 else 0.0), 0.02)
        put(band(p, a0, a1, R, z0 + 3.1, R, z0 + 4.3), mix(L.STONE_A, L.STONE_B, 0.75) if i % 2 == 0 else L.STONE_A)
        put(band(p, a0, a1, R, z0 + 4.3, R, z1 - 0.5), base)
        # cornice
        put(band(p, a0, a1, R, z1 - 0.5, R + 0.14, z1 - 0.36), mul(L.STONE_A, 1.03))
        put(band(p, a0, a1, R + 0.14, z1 - 0.36, R + 0.14, z1), mul(L.STONE_A, 1.05))
        # terrace floor
        zt = z1 if k < 5 else z1 - 0.1         # tier 5's cap hides under bell_platform
        if k < 5:
            rm = (r_in + R - 0.3) * 0.5
            put(band(p, a0, a1, r_in, zt, rm, zt, toward="up"), L.STONE_A if i % 2 else mix(L.STONE_A, L.STONE_B, 0.6))
            put(band(p, a0, a1, rm, zt, R - 0.3, zt, toward="up"), mix(L.STONE_A, L.STONE_B, 0.6) if i % 2 else L.STONE_A)
        else:
            fi = p.poly([P(0, 0, zt), P(a0, R - 0.3, zt), P(a1, R - 0.3, zt)], toward=(0, 0, 1))
            put(fi, L.STONE_A)
        # parapet (or open floor strip where the ramp arrives)
        if in_gap:
            put(band(p, a0, a1, R - 0.3, z1, R + 0.14, z1, toward="up"), mix(L.STONE_A, L.TEAL, 0.25))
        else:
            put(band(p, a0, a1, R - 0.3, z1, R - 0.3, z1 + par_h, toward="in"), mul(L.STONE_A, 0.96))
            put(band(p, a0, a1, R - 0.3, z1 + par_h, R + 0.14, z1 + par_h, toward="up"), mul(L.STONE_A, 1.08))
            put(band(p, a0, a1, R + 0.14, z1, R + 0.14, z1 + par_h), mul(L.STONE_A, 1.0))
            for (aa, nb_am, sgn) in ((a0, am - step, -1), (a1, am + step, 1)):
                if abs(L.ang_diff(nb_am, gap_a)) < 12.0:        # end cap toward the gap
                    am_r = math.radians(aa)
                    tang = Vector((-math.sin(am_r), -math.cos(am_r), 0)) * sgn
                    fi = p.poly([P(aa, R - 0.3, z1), P(aa, R + 0.14, z1), P(aa, R + 0.14, z1 + par_h), P(aa, R - 0.3, z1 + par_h)], toward=tang)
                    put(fi, mul(L.STONE_A, 0.9))
    return p


@asset(el_deg=22, az_deg=330)
def spire_tiers():
    """Five stacked stone drums tier_1..tier_5 (terrace tops at h = 6k) + col_tier_k."""
    for k in range(1, 6):
        make_object("tier_%d" % k, tier_part(k))
    for k in range(1, 6):
        c = cyl(TIER_R[k - 1], TIER_R[k - 1], TIER_H * (k - 1), TIER_H * k, 16).paint(0xFF00FF, jit=0.0)
        ob = make_object("col_tier_%d" % k, c, hide_render=True)
        ob.display_type = "WIRE"


def ramp_part():
    """Steep stone stair: foot at y=0,z=0 climbing toward Blender +Y (Godot -Z) to y=3, z=6. x -2..2."""
    p = Part()
    n = 12
    xs = [-1.75, -0.6, 0.6, 1.75]
    for j in range(n):
        y0, y1 = j * 0.25, (j + 1) * 0.25
        zb, zt = j * 0.5, (j + 1) * 0.5
        for i in range(3):
            runner = i == 1
            fi = p.poly([(xs[i], y0, zb), (xs[i + 1], y0, zb), (xs[i + 1], y0, zt), (xs[i], y0, zt)], toward=(0, -1, 0))
            p.col[fi] = [mul(mix(L.TEAL, 0x2FA7B0, 0.4) if runner else L.STONE_B, rnd(0.8, 0.9))] * 4
            fi = p.poly([(xs[i], y0, zt), (xs[i + 1], y0, zt), (xs[i + 1], y1, zt), (xs[i], y1, zt)], toward=(0, 0, 1))
            p.col[fi] = [mul(mix(L.TEAL, 0x58BFC6, 0.5) if runner else (L.STONE_A if j % 2 else mix(L.STONE_A, L.STONE_B, 0.5)), rnd(0.96, 1.04))] * 4
    for s in (-1, 1):                     # stringers (solid to the floor)
        x0, x1 = 1.75 * s, 2.0 * s
        prof = [(-0.12, 0.0), (3.0, 0.0), (3.0, 6.6), (-0.12, 0.75)]
        fo = p.poly([(x1, y, z) for (y, z) in prof], toward=(s, 0, 0))
        fi_ = p.poly([(x0, y, z) for (y, z) in prof], toward=(-s, 0, 0))
        ft = p.poly([(x0, -0.12, 0.75), (x1, -0.12, 0.75), (x1, 3.0, 6.6), (x0, 3.0, 6.6)], toward=(0, -0.5, 1))
        ff = p.poly([(x0, -0.12, 0.0), (x1, -0.12, 0.0), (x1, -0.12, 0.75), (x0, -0.12, 0.75)], toward=(0, -1, 0))
        for f, c in ((fo, mul(L.STONE_B, 0.92)), (fi_, mul(L.STONE_B, 0.85)), (ft, mul(L.STONE_A, 1.05)), (ff, L.STONE_B)):
            p.col[f] = [c] * 4
        post = box_z0(0.36, 0.36, 1.25, 1.87 * s, -0.25, 0.0).paint(L.STONE_B, top=L.STONE_A, z0=0, z1=1.2, lo=0.8)
        p.add(post)
        p.add(icosphere(0.2, 0).move(1.87 * s, -0.25, 1.45).paint(0x8FE9EC, glow=True))
    return p


@asset(el_deg=20, az_deg=60)
def spire_ramp():
    make_object("spire_ramp", ramp_part())


def gate_parts():
    """(static gate Part, [lantern Parts], [lantern positions])."""
    p = Part()
    for s in (-1, 1):
        p.add(box_z0(1.1, 1.2, 0.35, 2.45 * s, 0, 0).paint(L.STONE_B))
        p.add(box_z0(0.9, 1.0, 1.75, 2.45 * s, 0, 0.35).paint(L.STONE_A, z0=0, z1=2.1, lo=0.82, jit=0.04))
        p.add(box_z0(1.0, 1.1, 0.2, 2.45 * s, 0, 1.9).paint(mul(L.STONE_A, 1.05)))
        # outer buttress towers carrying the side lanterns
        p.add(box_z0(0.95, 1.1, 3.3, 3.35 * s, 0, 0, taper=0.82).paint(L.STONE_B, z0=0, z1=3.3, lo=0.8, jit=0.05))
        p.add(box_z0(1.0, 1.15, 0.22, 3.35 * s, 0, 3.3).paint(mul(L.STONE_A, 1.05)))
        p.add(box(0.5, 0.06, 1.4, (3.35 * s, -0.56, 1.7)).paint(L.TEAL, jit=0.03))
    nv = 9
    for i in range(nv):                   # voussoir ring: inner r 2.0, outer 2.9, centred at h 2.1
        t0, t1 = math.pi * i / nv, math.pi * (i + 1) / nv
        key = i == nv // 2
        ro = 3.15 if key else 2.9
        col = mix(L.TEAL, 0x58BFC6, 0.3) if key else (L.STONE_A if i % 2 else mix(L.STONE_A, L.STONE_B, 0.7))

        def pt(r, t, y):
            return (math.cos(t) * r, y, 2.1 + math.sin(t) * r)
        tm = (t0 + t1) * 0.5
        out_d = (math.cos(tm), 0, math.sin(tm))
        blk = Part()
        blk.poly([pt(2.0, t0, -0.5), pt(ro, t0, -0.5), pt(ro, t1, -0.5), pt(2.0, t1, -0.5)], toward=(0, -1, 0))
        blk.poly([pt(2.0, t0, 0.5), pt(ro, t0, 0.5), pt(ro, t1, 0.5), pt(2.0, t1, 0.5)], toward=(0, 1, 0))
        blk.poly([pt(ro, t0, -0.5), pt(ro, t0, 0.5), pt(ro, t1, 0.5), pt(ro, t1, -0.5)], toward=out_d)
        blk.poly([pt(2.0, t0, -0.5), pt(2.0, t0, 0.5), pt(2.0, t1, 0.5), pt(2.0, t1, -0.5)], toward=(-out_d[0], 0, -out_d[2]))
        if key:
            blk.poly([pt(2.9, t0, -0.5), pt(ro, t0, -0.5), pt(ro, t0, 0.5), pt(2.9, t0, 0.5)], toward=(1, 0, 0))
            blk.poly([pt(2.9, t1, -0.5), pt(ro, t1, -0.5), pt(ro, t1, 0.5), pt(2.9, t1, 0.5)], toward=(-1, 0, 0))
        blk.paint(col, jit=0.04)
        p.add(blk)
    lan_pos = [Vector((-3.35, 0, 3.52)), Vector((0, 0, 5.25)), Vector((3.35, 0, 3.52))]
    lans = []
    for _ in range(3):
        lp = Part()
        lp.add(box_z0(0.5, 0.5, 0.08).paint(0x6A4F22))
        for (x, y) in ((-0.2, -0.2), (0.2, -0.2), (0.2, 0.2), (-0.2, 0.2)):
            lp.add(box_z0(0.05, 0.05, 0.62, x, y, 0.08).paint(0x6A4F22))
        lp.add(lathe([(0.36, 0.7), (0.0, 1.05)], 4, True, False, phase=math.pi / 4).paint(0x8A6A2E, top=L.BRONZE))
        lp.add(prism(4, 0.21, 0.21, 0.1, 0.68, phase=math.pi / 4).paint(lambda c, n: mix(0xFFC24A, 0xFFF0B8, rnd(0, 1)), glow=True, jit=0.04))
        lans.append(lp)
    return p, lans, lan_pos


@asset(el_deg=14, az_deg=70)
def spire_lantern_gate():
    """Spire door: arch 4 m wide / 4 m tall, passage along Godot Z, lantern_1..3 separate."""
    p, lans, pos = gate_parts()
    make_object("spire_lantern_gate", p)
    for i in range(3):
        make_object("lantern_%d" % (i + 1), lans[i], location=pos[i])


def _pad_ring(col, top):
    return lathe([(1.3, -0.05), (1.3, 0.1), (1.12, 0.16), (0.95, 0.16), (0.9, 0.05)], 12, False, False).paint(col, top=top, jit=0.06)


@asset(el_deg=16, az_deg=55)
def shortcut_vent_up():
    """Fire shortcut: pad r 1.3 + stone chimney against the wall (Godot z = -1.8), 6 m."""
    p = Part()
    p.add(_pad_ring(0x3A3238, 0x55485A))
    d, info = top_disc([0, 0.45, 0.9], 12, z=0.05)
    paint_faces(d, info, lambda rm, a: (mix(L.LAVA_B, L.LAVA_A, min(1.0, rm / 0.8)), "glow"), jit=0.06)
    p.add(d)
    for i in range(4):
        x = -0.6 + i * 0.4
        p.add(box(0.08, 1.7 * math.sqrt(max(0.1, 1 - (x / 0.95) ** 2)), 0.06, (x, 0, 0.15)).paint(0x231E24))
    ch = lathe([(0.62, 0.0), (0.62, 0.5), (0.54, 0.62), (0.5, 5.3), (0.62, 5.45), (0.62, 6.0)], 4, True, False, phase=math.pi / 4)
    ch.paint(lambda c, n: 0x4A3F46 if int(c.z / 0.8) % 2 == 0 else 0x3A3238, z0=0, z1=6, lo=0.78, hi=0x6A5560, jit=0.06)
    p.add(ch.move(0, 1.36, 0))
    for z in (2.0, 3.8):
        p.add(box(0.86, 0.86, 0.14, (0, 1.36, z)).paint(0x231E24))
    mouth = Part()                        # glowing furnace mouth facing the pad
    pts = [(-0.26, 0.92, 0.2), (0.26, 0.92, 0.2), (0.26, 0.93, 0.95), (0.0, 0.94, 1.25), (-0.26, 0.93, 0.95)]
    mouth.poly(pts, toward=(0, -1, 0))
    mouth.paint(lambda c, n: mix(L.LAVA_A, L.LAVA_B, 0.5), glow=True)
    p.add(mouth)
    p.add(strip_on_ground([(0, 0.2), (0, 0.6), (0, 0.95)], [0.3, 0.26, 0.3], 0.03).paint(L.LAVA_A, glow=True))
    top = lathe([(0.44, 6.0), (0.44, 6.02)], 4, False, True, phase=math.pi / 4).paint(L.LAVA_B, glow=True).move(0, 1.36, 0)
    p.add(top)
    fl = cone(0.3, 6.0, 6.75, 5).move(0, 1.36, 0)
    fl.paint(lambda c, n: mix(L.LAVA_A, L.LAVA_B, min(1.0, max(0.0, (c.z - 6.0) / 0.6))), glow=True)
    p.add(fl)
    for z in (1.6, 3.0, 4.4):             # ember chevrons up the flue (which way it blows)
        ar = Part()
        ar.poly([(-0.2, 0.985, z), (0.0, 0.985, z + 0.26), (0.2, 0.985, z), (0.0, 0.985, z + 0.1)], toward=(0, -1, 0))
        ar.paint(L.LAVA_B, glow=True)
        p.add(ar)
    make_object("shortcut_vent_up", p)


@asset(el_deg=16, az_deg=55)
def shortcut_lift_up():
    """Water shortcut: basin pad + an up-flowing water column (`flow`, UV V 0..3 upward)."""
    p = Part()
    p.add(lathe([(1.3, -0.05), (1.3, 0.28), (1.1, 0.28), (1.04, 0.1)], 12, False, False).paint(L.STONE_B, top=L.STONE_A, jit=0.05))
    d, info = top_disc([0, 0.55, 1.04], 12, z=0.14)
    paint_faces(d, info, lambda rm, a: mix(L.WATER_A, L.WATER_B, 0.2 + 0.6 * rm), jit=0.04)
    p.add(d)
    for z in (2.0, 4.0):
        p.add(box(1.3, 0.5, 0.3, (0, 1.58, z)).paint(L.STONE_B, top=L.STONE_A))
        p.add(box(0.16, 0.5, 0.3, (-0.6, 1.2, z)).paint(L.STONE_B))
        p.add(box(0.16, 0.5, 0.3, (0.6, 1.2, z)).paint(L.STONE_B))
    p.add(box(1.5, 0.85, 0.5, (0, 1.38, 5.78)).paint(L.STONE_A, top=mul(L.STONE_A, 1.05), jit=0.04))
    p.add(box(0.5, 0.08, 0.3, (0, 0.93, 5.78)).paint(L.TEAL))
    p.add(box(1.0, 0.5, 0.55, (0, 1.55, 0.3)).paint(L.STONE_B, top=L.STONE_A))
    make_object("shortcut_lift_up", p)
    f = Part()
    seg = 8
    zs = [0.1, 0.5, 1.2, 2.0, 2.8, 3.6, 4.4, 5.2, 5.6]
    rs = [0.85, 0.52, 0.42, 0.46, 0.4, 0.45, 0.4, 0.44, 0.5]
    rows = []
    for j, z in enumerate(zs):
        yc = 0.9 if j == 0 else 1.28
        rows.append([(f.vert((math.cos(math.tau * i / seg) * rs[j], yc + math.sin(math.tau * i / seg) * rs[j] * 0.8, z)), (i / seg, z / 2.0)) for i in range(seg + 1)])
    for j in range(len(zs) - 1):
        for i in range(seg):
            a, b, c, d2 = rows[j][i], rows[j][i + 1], rows[j + 1][i + 1], rows[j + 1][i]
            am = math.tau * (i + 0.5) / seg
            fi = f.face((a[0], b[0], c[0], d2[0]), toward=(math.cos(am), math.sin(am), 0), uv=[a[1], b[1], c[1], d2[1]])
            f.col[fi] = [mix(L.WATER_A, 0xE8F6FF, 0.2 + 0.5 * ((i + j) % 2) * 0.6 + 0.25 * (j / len(zs)))] * 4
    make_object("flow", f)


@asset(el_deg=16, az_deg=55)
def shortcut_vine_up():
    """Leaf shortcut: woven-root pad + trellis with a thick climbing vine, 6 m."""
    p = Part()
    d, info = top_disc([0, 0.6, 1.3], 10, z=0.05)
    paint_faces(d, info, lambda rm, a: 0x6E5A36 if int(a / 36 + rm) % 2 else 0x7F8A46, jit=0.07)
    p.add(d)
    p.add(lathe([(1.34, -0.05), (1.3, 0.05)], 10, False, False).paint(0x5A4A2E))
    for k in range(3):
        pts = [P(120 * k + t * 200, 0.25 + t * 1.05, 0.1 - 0.04 * t) for t in (0.0, 0.25, 0.5, 0.75, 1.0)]
        p.add(tube(pts, [0.13, 0.12, 0.1, 0.08, 0.05], 4, False).paint(0x7A6A3E, top=0x9A8A4E, jit=0.08))
    for x in (-0.72, 0.72):
        p.add(box_z0(0.1, 0.1, 6.0, x, 1.7, 0).paint(L.WOOD_B, z0=0, z1=6, lo=0.8))
    for i in range(7):
        p.add(box(1.6, 0.07, 0.08, (0, 1.68, 0.5 + i * 0.9)).paint(L.WOOD_A, jit=0.06))
    pts, rs = [], []
    n = 15
    for k in range(n):
        z = 6.0 * k / (n - 1)
        pts.append((0.5 * math.sin(z * 1.35), 1.46 - 0.14 * math.cos(z * 2.7), z))
        rs.append(0.22 - 0.11 * k / (n - 1))
    pts[0] = (0.0, 0.95, 0.05)
    p.add(tube(pts, rs, 6, True).paint(0x6E8A3E, top=0x8FAE55, z0=0, z1=6, lo=0.8, jit=0.07))
    for k in range(1, n):
        q = Vector(pts[k])
        s = 1 if k % 2 else -1
        lf = leaf(rnd(0.5, 0.7), rnd(0.28, 0.36), 0.2).rotz(-90 + s * rnd(30, 70)).move(q.x + 0.1 * s, q.y - 0.12, q.z)
        p.add(lf.paint(mix(L.LEAF_B, L.LEAF_C, rnd(0, 1)), jit=0.08))
    for k in (4, 8, 12):
        q = Vector(pts[k])
        p.add(icosphere(0.11, 0).move(q.x, q.y - 0.28, q.z + 0.1).paint(0xE9FFB0, glow=True))
    p.add(icosphere(0.16, 0).move(pts[-1][0], pts[-1][1], 6.1).paint(0xE9FFB0, glow=True))
    make_object("shortcut_vine_up", p)


def bell_parts(seg=20):
    """(yoke, bell_body (local to its pivot), clapper (local to its hinge)), pivot, hinge offset."""
    y = Part()
    for s in (-1, 1):
        for fy in (-0.5, 0.5):
            y.add(box_z0(0.5, 0.42, 0.22, 1.7 * s, fy, 0).paint(L.STONE_B, top=L.STONE_A))
            y.add(tube([(1.7 * s, fy, 0.2), (1.7 * s, 0.0, 3.95)], 0.12, 4, True).paint(L.WOOD_B, z0=0, z1=4, lo=0.78, hi=L.WOOD_A, jit=0.05))
        y.add(tube([(1.7 * s, -0.36, 1.2), (1.7 * s, 0.36, 1.2)], 0.07, 4, True).paint(L.WOOD_A))
        y.add(box(0.26, 0.4, 0.4, (2.12 * s, 0, 3.98)).paint(L.BRONZE, top=0xE0B050))
    y.add(box(4.1, 0.3, 0.34, (0, 0, 3.98)).paint(L.WOOD_B, top=L.WOOD_A, jit=0.04))
    y.add(tube([(-1.62, 0, 3.4), (1.62, 0, 3.4)], 0.06, 5, False).paint(0x3A3238))
    for s in (-1, 1):                     # hangers from the beam down to the axle
        y.add(box(0.1, 0.14, 0.5, (0.72 * s, 0, 3.6)).paint(0x3A3238))
    b = Part()
    b.add(box(1.3, 0.26, 0.3, (0, 0, -0.02)).paint(L.WOOD_A, top=0xC9A774, jit=0.04))
    b.add(cyl(0.12, 0.16, -0.26, -0.12, 6).paint(L.BRONZE))
    prof = [(0.0, -0.58), (0.40, -0.64), (0.50, -1.1), (0.70, -1.5), (0.88, -1.78), (0.95, -1.84), (1.03, -1.8),
            (0.82, -1.5), (0.62, -1.15), (0.52, -0.75), (0.44, -0.42), (0.28, -0.27), (0.0, -0.24)]
    body = lathe(prof, seg, False, False)

    def bcol(c, n):
        r = math.hypot(c.x, c.y)
        if n.dot(Vector((c.x, c.y, 0))) < 0 and r > 0.05:
            return mul(L.BRONZE, 0.55)                          # inside of the bell
        if -1.62 < c.z < -1.4:
            return mix(L.BRONZE, L.TEAL, 0.55)                  # verdigris band
        return mix(L.BRONZE, 0xE9C060, min(1.0, max(0.0, (c.z + 1.8) / 1.6)))
    body.paint(bcol, jit=0.05, sun=0.1)
    b.add(body)
    c = Part()
    c.add(tube([(0, 0, 0), (0, 0, -1.02)], 0.035, 4, False).paint(0x3A3238))
    c.add(icosphere(0.17, 1).move(0, 0, -1.1).paint(0x4A4048, top=0x6A5F68))
    return y, b, c, Vector((0, 0, 3.4)), Vector((0, 0, -0.62))


@asset(el_deg=12, az_deg=65)
def sky_bell():
    """Bronze bell under a yoke. Nodes: yoke, bell_body (pivot at the yoke), clapper (child)."""
    y, b, c, piv, hinge = bell_parts()
    make_object("yoke", y)
    bb = make_object("bell_body", b, location=piv)
    make_object("clapper", c, location=hinge, parent=bb)


def platform_parts(seg=40):
    p = Part()
    d, info = top_disc([0, 1.2, 3.2, 3.5, 5.0], seg)

    def fn(rm, a):
        i = int(a / (360.0 / seg))
        if 3.2 < rm < 3.5:
            return mul(L.STONE_B, 0.6)
        if rm < 1.2:
            return mix(L.TEAL, 0x58BFC6, 0.3 if i % 2 else 0.0)
        if rm < 3.2:
            return L.STONE_A if i % 2 else mix(L.STONE_A, 0xF2E9D6, 0.6)
        return mix(L.STONE_A, L.STONE_B, 0.7) if (i // 2) % 2 else L.STONE_A
    paint_faces(d, info, fn, jit=0.03)
    p.add(d)
    p.add(lathe([(4.88, -0.4), (5.0, -0.3), (5.0, 0.0)], seg, True, False).paint(L.STONE_B, jit=0.04))
    for sx in (-1.7, 1.7):
        for sy in (-0.5, 0.5):
            p.add(box_z0(0.72, 0.6, 0.1, sx, sy, 0).paint(L.STONE_B, top=mul(L.STONE_A, 1.04)))
    r, info = top_disc([3.2, 3.5], seg, z=0.02)
    paint_faces(r, info, lambda rm, a: (mix(0xDFFCFF, 0x7FE3E8, 0.3 if int(a / 9) % 2 else 0.0), "glow"), jit=0.02)
    return p, r


@asset(el_deg=30, az_deg=40)
def bell_platform():
    """Tier-5 cap, r 5, top at h 0; `ring_inlay` (r 3.2..3.5) separate so it can glow."""
    p, r = platform_parts()
    make_object("bell_platform", p)
    make_object("ring_inlay", r)


@asset(el_deg=16, az_deg=330)
def sky_spire():
    """Visual-only spire for the other Skyfall games: drums + ramps + bell, one mesh."""
    p = Part()
    for k in range(1, 6):
        p.add(tier_part(k, seg=[32, 28, 24, 20, 16][k - 1], niches=(k <= 3), lamps=False))
    for k in range(5):
        run = RAMP_RUN[k]
        rmid = TIER_R[k] + run * 0.5
        chord = 2.0 * rmid * math.sin(math.radians(RAMP_ARC * 0.5))
        rp = ramp_part().scale(chord / 4.0, run / 3.0, 1.0).rotz(math.degrees(L.yaw_for(RAMP_A[k])))
        p.add(rp.move(P(RAMP_A[k], TIER_R[k] + run, TIER_H * k)))
    plat, inlay = platform_parts(24)
    p.add(plat.move(0, 0, 30.0)).add(inlay.move(0, 0, 30.0))
    y, b, c, piv, hinge = bell_parts(12)
    p.add(y.move(0, 0, 30.0)).add(b.move(piv + Vector((0, 0, 30.0)))).add(c.move(piv + hinge + Vector((0, 0, 30.0))))
    make_object("sky_spire", p)


# =====================================================================================
#  quest props
# =====================================================================================
GOLD = 0xD9A441


@asset(el_deg=14, az_deg=60)
def helper_cage():
    """Round rescue cage: base disc r 1.3 (top h 0.15), domed top ring at h 2.4 with a finial.
    `bars` (vertical bars + hoop + padlock) is a separate object so the game can open the cage."""
    p = Part()
    p.add(lathe([(1.36, 0.0), (1.3, 0.1), (1.22, 0.15)], 16, False, False).paint(L.STONE_B, top=L.STONE_A, jit=0.06))
    d, info = top_disc([0, 0.65, 1.22], 16, z=0.15)
    paint_faces(d, info, lambda rm, a: (mix(L.WOOD_A, 0xC9A774, 0.35) if int(a / 22.5) % 2 else L.WOOD_A) if rm > 0.65 else mix(L.WOOD_A, L.WOOD_B, 0.5), jit=0.06)
    p.add(d)
    ringp = lathe([(1.04, 2.32), (1.22, 2.32), (1.22, 2.47), (1.04, 2.47), (1.04, 2.32)], 16, False, False)
    p.add(ringp.paint(L.WOOD_B, top=L.WOOD_A, jit=0.05))
    for k in range(6):                    # dome ribs up to the finial
        a = math.tau * k / 6 + 0.26
        pts = []
        for t in (0.0, 0.4, 0.75, 1.0):
            th = t * math.pi * 0.5
            r = 1.13 * math.cos(th)
            pts.append((math.cos(a) * r, math.sin(a) * r, 2.45 + 0.62 * math.sin(th)))
        p.add(tube(pts, [0.05, 0.045, 0.04, 0.035], 3, False).paint(GOLD, jit=0.06, sun=0.1))
    p.add(lathe([(0.0, 2.98), (0.24, 3.02), (0.2, 3.1), (0.0, 3.14)], 8, False, False).paint(L.WOOD_B, top=L.WOOD_A))
    p.add(prism(4, 0.06, 0.04, 3.12, 3.3, tip=0.16, phase=0.78).paint(GOLD, jit=0.04))
    p.add(icosphere(0.09, 0).move(0, 0, 3.28).paint(0xFFE9A8, glow=True))
    make_object("helper_cage", p)
    b = Part()
    n = 12
    for k in range(n):
        a = math.tau * (k + 0.5) / n
        x, y = math.cos(a) * 1.13, math.sin(a) * 1.13
        b.add(tube([(x, y, 0.15), (x, y, 2.33)], 0.04, 4, False).paint(GOLD, z0=0.15, z1=2.33, lo=0.8, jit=0.06, sun=0.1))
    hoop = lathe([(1.1, 1.2), (1.17, 1.2), (1.17, 1.3), (1.1, 1.3), (1.1, 1.2)], n, False, False, phase=math.pi / n)
    b.add(hoop.paint(mul(GOLD, 0.9), jit=0.05, sun=0.1))
    # padlock on the Godot +Z (Blender -Y) side
    b.add(box(0.26, 0.12, 0.22, (0, -1.24, 1.12)).paint(mul(GOLD, 1.08), top=0xF2CF72, jit=0.03))
    b.add(tube([(-0.08, -1.24, 1.22), (-0.08, -1.24, 1.36), (0.08, -1.24, 1.36), (0.08, -1.24, 1.22)], 0.028, 4, False).paint(0x8A6A2E))
    b.add(box(0.05, 0.02, 0.08, (0, -1.305, 1.11)).paint(0x3A3238, jit=0.0))
    make_object("bars", b)


@asset(el_deg=16, az_deg=65)
def task_stone():
    """Waist-high carved pedestal with a slanted tablet facing Godot +Z. `rune` (glyph + floating
    diamond, sky_glow, near white - tinted at runtime) is a separate object."""
    p = Part()
    p.add(box_z0(0.96, 0.96, 0.18).paint(L.STONE_B, top=L.STONE_A, jit=0.05))
    p.add(box_z0(0.72, 0.72, 0.36, 0, 0, 0.18).paint(L.STONE_A, z0=0, z1=1.2, lo=0.82, jit=0.05))
    p.add(box_z0(0.77, 0.77, 0.1, 0, 0, 0.54).paint(L.TEAL, top=0x58BFC6, jit=0.03))
    p.add(box_z0(0.72, 0.72, 0.3, 0, 0, 0.64).paint(mix(L.STONE_A, L.STONE_B, 0.5), z0=0, z1=1.2, lo=0.82, jit=0.05))
    p.add(box_z0(0.9, 0.9, 0.13, 0, 0, 0.94).paint(L.STONE_A, top=mul(L.STONE_A, 1.05), jit=0.04))
    # lectern tablet: low edge toward -Y (Godot +Z), high edge at the back
    w = 0.42
    lo_p, hi_p = (-0.42, 1.12), (0.3, 1.4)              # (y, z) of the tablet face edge
    prof = [(-0.42, 1.07), (0.4, 1.07), (0.4, 1.36), hi_p, lo_p]
    t = Part()
    t.poly([(-w, y, z) for (y, z) in prof], toward=(-1, 0, 0))
    t.poly([(w, y, z) for (y, z) in prof], toward=(1, 0, 0))
    for i in range(len(prof)):
        (y0, z0), (y1, z1) = prof[i], prof[(i + 1) % len(prof)]
        nrm = Vector((0, z1 - z0, -(y1 - y0)))
        t.poly([(-w, y0, z0), (w, y0, z0), (w, y1, z1), (-w, y1, z1)], toward=nrm if nrm.length > 0 else (0, 0, 1))
    t.orient_outward(Vector((0, 0, 1.2)))
    t.paint(lambda c, n: mul(L.STONE_A, 1.06) if (n.z > 0.5 and n.y < -0.1) else L.STONE_B, jit=0.04)
    p.add(t)
    for (x, y, s) in ((0.52, -0.38, 0.16), (-0.5, 0.42, 0.2), (-0.56, -0.3, 0.12)):
        p.add(rock(s, 0, 0.3, 0.7).move(x, y, 0.06).paint(L.STONE_B, jit=0.08))
    make_object("task_stone", p)
    # glyph laid on the tablet face (u = x, v = up the slope, n = face normal)
    v = Vector((0, hi_p[0] - lo_p[0], hi_p[1] - lo_p[1])).normalized()
    u = Vector((1, 0, 0))
    nrm = u.cross(v)
    if nrm.z < 0:
        nrm = -nrm
    cen = Vector((0, (lo_p[0] + hi_p[0]) * 0.5, (lo_p[1] + hi_p[1]) * 0.5)) + nrm * 0.012
    r = Part()

    def gp(a, b_):
        return cen + u * a + v * b_
    for k in range(6):                    # hexagon outline
        a0, a1 = math.tau * k / 6, math.tau * (k + 1) / 6
        r.poly([gp(math.cos(a0) * 0.2, math.sin(a0) * 0.2), gp(math.cos(a1) * 0.2, math.sin(a1) * 0.2),
                gp(math.cos(a1) * 0.26, math.sin(a1) * 0.26), gp(math.cos(a0) * 0.26, math.sin(a0) * 0.26)], toward=nrm)
    r.poly([gp(0, 0.13), gp(0.08, 0), gp(0, -0.13), gp(-0.08, 0)], toward=nrm)
    for s in (-1, 1):
        r.poly([gp(0.32 * s, 0.03), gp(0.38 * s, 0.03), gp(0.38 * s, -0.03), gp(0.32 * s, -0.03)], toward=nrm)
        r.poly([gp(-0.03, 0.3 * s), gp(0.03, 0.3 * s), gp(0.03, 0.345 * s), gp(-0.03, 0.345 * s)], toward=nrm)
    r.add(lathe([(0.0, 1.73), (0.12, 1.9), (0.0, 2.07)], 4, False, False))
    r.paint(lambda c, n: mix(0xFFFFFF, 0xFFF6DC, rnd(0, 1)), glow=True, jit=0.02)
    make_object("rune", r)


@asset(el_deg=12, az_deg=40)
def wind_chime():
    """Floating wind-chime pickup centred at h 1.3. All sky_glow, near white (tinted at runtime)."""
    p = Part()
    p.add(lathe([(0.0, 1.6), (0.07, 1.67), (0.0, 1.74)], 4, False, False))                  # tiny star
    for a in (0, 90):
        st = Part()
        st.poly([(-0.13, 0, 1.67), (0, 0, 1.69), (0.13, 0, 1.67), (0, 0, 1.65)])
        p.add(st.rotz(a))
    p.add(tube([(0, 0, 1.6), (0, 0, 1.5)], 0.012, 3, False))
    p.add(lathe([(0.2, 1.48), (0.28, 1.48), (0.28, 1.53), (0.2, 1.53), (0.2, 1.48)], 8, False, False))
    for a in (0, 90):
        p.add(box(0.44, 0.035, 0.035, (0, 0, 1.505)).rotz(a))
    for k, ln in enumerate((0.52, 0.36, 0.44, 0.28)):
        a = math.tau * k / 4 + math.pi / 4
        x, y = math.cos(a) * 0.24, math.sin(a) * 0.24
        p.add(prism(5, 0.04, 0.04, 1.44 - ln, 1.44).move(x, y, 0))
        p.add(tube([(x, y, 1.44), (x, y, 1.49)], 0.01, 3, False))
    p.add(tube([(0, 0, 1.5), (0, 0, 1.08)], 0.01, 3, False))
    p.add(cyl(0.07, 0.07, 1.14, 1.17, 6))                                                   # striker
    sail = Part()
    sail.poly([(0, 0, 1.08), (0.09, 0, 0.98), (0, 0, 0.88), (-0.09, 0, 0.98)])
    p.add(sail)
    p.paint(lambda c, n: mix(0xFFFFFF, 0xFFF6DC, rnd(0, 1)), glow=True, jit=0.03)
    make_object("wind_chime", p)


@asset(el_deg=10, az_deg=75)
def sun_key():
    """Chunky upright key (~1 m): sun-ray disc bow on top, teeth at the bottom, centred at h 1.3.
    All sky_glow, near white (tinted at runtime)."""
    p = Part()
    bz = 1.56
    bow = lathe([(0.1, -0.04), (0.21, -0.04), (0.21, 0.04), (0.1, 0.04), (0.1, -0.04)], 10, False, False).rotx(90).move(0, 0, bz)
    p.add(bow)
    for k in range(8):                    # sun rays around the bow
        a = math.tau * k / 8
        if abs(math.sin(a) + 1.0) < 0.01:
            continue                       # the shaft takes the place of the bottom ray
        ray = cone(0.055, 0.0, 0.14 if k % 2 == 0 else 0.1, 4).roty(90)      # points along +X
        ray.roty(-math.degrees(a))
        p.add(ray.move(math.cos(a) * 0.215, 0, bz + math.sin(a) * 0.215))
    p.add(box(0.16, 0.11, 0.06, (0, 0, 1.32)))
    p.add(box(0.09, 0.09, 0.56, (0, 0, 1.06)))
    p.add(box(0.2, 0.08, 0.08, (0.12, 0, 0.84)))
    p.add(box(0.13, 0.08, 0.07, (0.09, 0, 0.97)))
    p.add(box(0.06, 0.08, 0.06, (0.2, 0, 0.9)))
    p.paint(lambda c, n: mix(0xFFFFFF, 0xFFF3CF, rnd(0, 1)), glow=True, jit=0.03)
    make_object("sun_key", p)


@asset(el_deg=40, az_deg=30)
def sun_seal():
    """Flat floor seal, r 2.2, top at h 0.06: carved rings + 8 sun rays. `seal_glow` (ring r 1.7..2.0
    + centre sun, sky_glow near white) is a separate object."""
    seg = 16
    d, info = top_disc([0, 0.5, 0.56, 1.1, 1.16, 1.7, 2.0, 2.06, 2.2], seg, z=0.06, phase_deg=-11.25)

    def fn(rm, a):
        i = int(((a + 11.25) % 360.0) / 22.5)
        if rm < 0.5:
            return mul(L.STONE_B, 0.82)
        if rm in (0.53, 1.13, 2.03) or abs(rm - 0.53) < 0.01 or abs(rm - 1.13) < 0.01 or abs(rm - 2.03) < 0.01:
            return mul(L.STONE_B, 0.62)                         # carved grooves
        if rm < 1.7:
            return mix(L.STONE_A, L.STONE_B, 0.75 if (i + (0 if rm < 1.1 else 1)) % 2 else 0.95)
        if rm < 2.0:
            return mul(L.STONE_B, 0.7)                          # bed of the glow ring
        return L.STONE_A if i % 2 else mix(L.STONE_A, L.STONE_B, 0.6)
    paint_faces(d, info, fn, jit=0.035)
    p = Part()
    p.add(d)
    p.add(lathe([(2.24, 0.0), (2.2, 0.06)], seg, False, False, phase=math.radians(11.25)).paint(L.STONE_B, jit=0.05))
    for k in range(8):                    # eight carved sun rays (long / short alternating)
        a = 45.0 * k
        tip = 1.66 if k % 2 == 0 else 1.4
        ray = Part()
        ray.poly([P(a - 11, 0.6, 0.072), P(a + 11, 0.6, 0.072), P(a, tip, 0.072)], toward=(0, 0, 1))
        ray.paint(0xF2DDA4 if k % 2 == 0 else 0xE6CC92, jit=0.03, sun=0.0, shade=0.0)
        p.add(ray)
    make_object("sun_seal", p)
    g = Part()
    rg, info = top_disc([1.7, 2.0], seg, z=0.08, phase_deg=-11.25)
    g.add(rg)
    sun, info2 = top_disc([0, 0.3], 8, z=0.08)
    g.add(sun)
    for k in range(8):
        a = 45.0 * k + 22.5
        g.poly([P(a - 9, 0.34, 0.08), P(a + 9, 0.34, 0.08), P(a, 0.5, 0.08)], toward=(0, 0, 1))
    g.paint(lambda c, n: mix(0xFFFFFF, 0xFFF6DC, rnd(0, 1)), glow=True, jit=0.02)
    make_object("seal_glow", g)


# =====================================================================================
#  task isles (r 9.5, 49 m from the spire axis) with their sub-towers
#  Authored in world orientation like every isle: "front" faces Heart Isle.
# =====================================================================================
TASK_R = 9.5
TASK_ANG = {"isle_roost": 5.0, "isle_beacon": 125.0, "isle_shrine": 245.0}


def _dirv(a_deg):
    a = math.radians(a_deg)
    return Vector((math.cos(a), -math.sin(a), 0.0))


def _task_isle(name, seed, top_fn, lip_col, rock_cols):
    top, info = top_disc([0, 3.0, 6.0, 8.2, TASK_R], 28, jitter=0.2)
    paint_faces(top, info, top_fn, jit=0.05)
    body = L.island_body(TASK_R, 16.0, 28, seed=seed, lip=0.8, lip_col=lip_col, rock_cols=rock_cols, levels=5)
    return join(top, body)


def _scatter(n, r0, r1, make, keep):
    """Scatter small no-collision dressing where keep(a_sim, d) allows it."""
    out = Part()
    for _ in range(n):
        a, d = rnd(0, 360), rnd(r0, r1)
        if keep(a, d):
            out.add(make().move(P(a, d, 0)))
    return out


def bird(col=0xF4F1E8, wing=0x9FB7D9):
    b = icosphere(0.15, 0).scale(1.35, 0.9, 0.95).move(0, 0, 0.16).paint(col, top=wing, jit=0.05)
    h = icosphere(0.09, 0).move(0.17, 0, 0.3).paint(col, jit=0.04)
    bk = cone(0.035, 0.0, 0.1, 4).roty(90).move(0.24, 0, 0.3).paint(0xF2A23C, jit=0.0)
    tl = Part()
    tl.poly([(-0.16, -0.07, 0.2), (-0.16, 0.07, 0.2), (-0.36, 0, 0.27)])
    tl.paint(wing, jit=0.04)
    return join(b, h, bk, tl)


def mini_cage():
    """Small hanging cage, hook at the origin, ~0.85 m tall."""
    p = Part()
    p.add(cone(0.3, -0.28, -0.05, 6))
    p.add(cyl(0.29, 0.29, -0.85, -0.8, 6))
    for k in range(6):
        a = math.tau * k / 6
        p.add(tube([(math.cos(a) * 0.27, math.sin(a) * 0.27, -0.8), (math.cos(a) * 0.27, math.sin(a) * 0.27, -0.28)], 0.02, 3, False))
    p.add(tube([(0, 0, -0.05), (0, 0, 0.0)], 0.02, 3, False))
    return p.paint(GOLD, jit=0.06, sun=0.1)


@asset(el_deg=16, az_deg=140)
def isle_roost():
    """Roost Rock (5 deg): a watchtower / aviary 3.5 m behind the isle centre."""
    ang = TASK_ANG["isle_roost"]
    front, back = ang + 180.0, ang
    cage_spots = [P(ang + 90.0, 4.6), P(ang - 90.0, 4.6)]      # Godot stands two real cages here
    T = P(back, 3.5)

    def top_fn(rm, a):
        x, y = math.cos(math.radians(a)) * rm, math.sin(math.radians(a)) * rm
        c = mix(L.GRASS_A, L.GRASS_B, 0.5 + 0.5 * nz2(x, y, 0.25, 12.0))
        if nz2(x, y, 0.4, 3.0) > 0.3:
            c = mix(c, L.ROCK_C, 0.6)
        ld = lane_dirt(a, rm, [front], TASK_R, 2.0)
        return mix(c, 0xB59A6A, 0.6 * ld)
    isle = _task_isle("isle_roost", 51.0, top_fn, mul(L.GRASS_A, 0.9), (L.ROCK_A, L.ROCK_B, L.ROCK_C))
    t = Part()
    base = lathe([(1.9, 0.0), (1.78, 0.5), (1.5, 4.6), (1.58, 5.0)], 10, False, False)
    base.paint(lambda c, n: L.STONE_A if int(c.z / 0.85) % 2 == 0 else mix(L.STONE_A, L.STONE_B, 0.8), z0=0, z1=5, lo=0.78, jit=0.06)
    t.add(base)
    t.add(lathe([(1.5, 4.95), (2.3, 5.2), (2.3, 5.38), (0.0, 5.38)], 10, True, False).paint(L.WOOD_B, top=L.WOOD_A, jit=0.05))
    for k in range(0, 10, 2):             # gallery rail
        a = math.tau * k / 10
        t.add(box_z0(0.1, 0.1, 0.75, math.cos(a) * 2.2, math.sin(a) * 2.2, 5.38).paint(L.WOOD_A))
    t.add(tube([(math.cos(math.tau * k / 10) * 2.2, math.sin(math.tau * k / 10) * 2.2, 6.13) for k in range(11)], 0.05, 4, False).paint(L.WOOD_A))
    for k in range(6):                    # open aviary frame
        a = math.tau * k / 6 + 0.3
        t.add(box_z0(0.16, 0.16, 2.3, math.cos(a) * 1.3, math.sin(a) * 1.3, 5.38).paint(L.WOOD_B, z0=5.3, z1=7.7, lo=0.8))
    t.add(lathe([(1.45, 7.55), (1.45, 7.75)], 6, True, False, phase=0.3).paint(L.WOOD_B))
    roof = lathe([(2.15, 7.6), (1.2, 8.7), (0.0, 9.6)], 10, True, False)
    t.add(roof.paint(0xB5533C, z0=7.6, z1=9.6, lo=0.75, hi=0xE08A5A, jit=0.07))
    t.add(prism(4, 0.07, 0.05, 9.5, 9.72, phase=0.78).paint(L.WOOD_B))
    t.add(icosphere(0.13, 0).move(0, 0, 9.82).paint(0xFFE9A8, glow=True))
    # door + window facing the isle centre (front)
    fd = _dirv(front)
    sd_deg = math.degrees(math.atan2(-fd.x, fd.y)) + 90.0
    t.add(box(1.0, 0.3, 1.8, (0, 0, 0.9)).rotz(math.degrees(math.atan2(fd.y, fd.x)) + 90.0).move(fd * 1.72).paint(L.WOOD_B, jit=0.04))
    t.add(box(0.5, 0.3, 0.7, (0, 0, 3.4)).rotz(math.degrees(math.atan2(fd.y, fd.x)) + 90.0).move(fd * 1.5).paint(0x3A3340, jit=0.02))
    # perch bar across the aviary with birds
    t.add(tube([(-1.2, 0, 6.5), (1.2, 0, 6.5)], 0.05, 4, False).rotz(40).paint(L.WOOD_A))
    t.add(bird().rotz(120).move(0.45, 0.38, 6.5))
    t.add(bird(0xF7D36A, 0xE9A24A).rotz(250).move(-0.5, -0.42, 6.5))
    t.add(bird(0xB6D2F8, 0x6D9CE9).rotz(200).move(math.cos(math.tau * 0.3) * 2.2, math.sin(math.tau * 0.3) * 2.2, 6.18))
    # arms with hanging cages / lanterns (all well above head height)
    hang = [("cage", 50.0), ("lantern", 140.0), ("cage", 230.0), ("lantern", 320.0)]
    for kind, a_deg in hang:
        a = math.radians(a_deg)
        d = Vector((math.cos(a), math.sin(a), 0))
        t.add(tube([d * 1.3 + Vector((0, 0, 7.45)), d * 3.3 + Vector((0, 0, 7.3))], 0.08, 4, True).paint(L.WOOD_B, jit=0.05))
        t.add(tube([d * 1.35 + Vector((0, 0, 6.6)), d * 2.4 + Vector((0, 0, 7.36))], 0.05, 4, False).paint(L.WOOD_A))
        tip = d * 3.2 + Vector((0, 0, 7.3))
        hook = tip - Vector((0, 0, 0.9))
        t.add(tube([tip, hook], 0.02, 3, False).paint(0x3A3238))
        t.add((mini_cage() if kind == "cage" else lantern(1.6, 0xFFE9A8)).move(hook))
        if kind == "cage":
            t.add(bird(0xF4F1E8, 0xF2A23C).scale(0.8).rotz(a_deg).move(d * 2.2 + Vector((0, 0, 7.42))))
    # sacks + a perch stump hugging the tower (inside the collision circle)
    for a_deg, s in ((95.0, 0.36), (265.0, 0.3)):
        a = math.radians(a_deg)
        t.add(rock(s, 0, 0.2, 1.0).move(math.cos(a) * 1.95, math.sin(a) * 1.95, s * 0.8).paint(0xD9C7A0, jit=0.05))
    deco = Part()
    deco.add(t.move(T))

    def keep(a, d):
        q = P(a, d)
        if L.near_lane(a, [front], 16) and d > 1.0:
            return False
        if (q - T).length < 2.6:
            return False
        return all((q - c).length > 2.5 for c in cage_spots)
    deco.add(_scatter(34, 1.0, 9.2, lambda: tuft(3, 0.45, L.GRASS_B), keep))
    deco.add(_scatter(11, 1.0, 9.3, lambda: rock(rnd(0.12, 0.3), 0, 0.3, 0.6).move(0, 0, 0.05).paint(L.ROCK_B, jit=0.1), keep))
    for _ in range(12):                   # a few feathers / seeds near the tower
        a, d = rnd(0, 360), rnd(2.2, 3.6)
        q = T + Vector((math.cos(math.radians(a)) * d, math.sin(math.radians(a)) * d, 0.03))
        if all((q - c).length > 2.5 for c in cage_spots) and q.length < 9.0:
            deco.add(leaf(0.3, 0.1, 0.0).rotz(rnd(0, 360)).move(q).paint(0xF4F1E8, jit=0.03))
    for i in range(6):                    # rim rocks outside the walkable disc
        a = 60.0 * i + rnd(-15, 15)
        if L.near_lane(a, [front], 22):
            continue
        deco.add(rock(rnd(0.4, 0.8), 0, 0.3, 0.7).move(P(a, TASK_R + rnd(0.5, 0.8), -0.15)).paint(L.ROCK_B, top=L.GRASS_A, jit=0.08))
    make_object("isle_roost", join(isle, deco))
    col_cylinder("col_roost", 0, 0, 2.0, 6.0, center=T)


@asset(el_deg=14, az_deg=260)
def isle_beacon():
    """Beacon Isle (125 deg): a lighthouse on the isle centre. `beacon_lamp` (lantern-room light)
    and `beacon_ring` (stand here, 4.4 m in front) are separate near-white sky_glow nodes."""
    ang = TASK_ANG["isle_beacon"]
    front = ang + 180.0

    def top_fn(rm, a):
        x, y = math.cos(math.radians(a)) * rm, math.sin(math.radians(a)) * rm
        c = mix(L.ROCK_B, L.ROCK_C, 0.5 + 0.5 * nz2(x, y, 0.25, 31.0))
        if nz2(x, y, 0.35, 7.0) > 0.15 and rm > 3.0:
            c = mix(c, L.GRASS_A, 0.75)
        if rm < 3.0:
            return L.STONE_A if int(a / 25.7) % 2 else mix(L.STONE_A, L.STONE_B, 0.7)       # paved apron
        ld = lane_dirt(a, rm, [front], TASK_R, 2.2)
        return mix(c, mix(L.STONE_A, L.STONE_B, 0.5), 0.75 * ld)
    isle = _task_isle("isle_beacon", 57.0, top_fn, mul(L.ROCK_B, 0.92), (L.ROCK_A, L.ROCK_B, L.ROCK_C))
    t = Part()
    t.add(lathe([(2.2, 0.0), (2.2, 0.4), (2.0, 0.6)], 12, False, False).paint(L.STONE_B, top=L.STONE_A, jit=0.05))
    shaft = lathe([(2.0, 0.6), (1.86, 3.1), (1.7, 5.6), (1.55, 8.1), (1.4, 10.6)], 12, False, False)
    shaft.paint(lambda c, n: 0xF2EBDD if int((c.z - 0.6) / 2.5) % 2 == 0 else 0xC8553D, z0=0, z1=11, lo=0.8, jit=0.05)
    t.add(shaft)
    t.add(lathe([(1.4, 10.55), (2.05, 10.85), (2.05, 11.05), (0.0, 11.05)], 12, True, False).paint(0x4A4048, top=0x6A5F68, jit=0.05))
    for k in range(0, 12, 2):
        a = math.tau * k / 12
        t.add(box_z0(0.07, 0.07, 0.7, math.cos(a) * 1.95, math.sin(a) * 1.95, 11.05).paint(0x3A3238))
    t.add(tube([(math.cos(math.tau * k / 12) * 1.95, math.sin(math.tau * k / 12) * 1.95, 11.75) for k in range(13)], 0.04, 4, False).paint(0x3A3238))
    t.add(lathe([(1.2, 11.05), (1.2, 11.35)], 8, False, True).paint(L.STONE_B, top=L.STONE_A))
    for k in range(8):                    # lantern-room mullions
        a = math.tau * k / 8
        t.add(box_z0(0.09, 0.09, 2.0, math.cos(a) * 1.15, math.sin(a) * 1.15, 11.35).paint(0x3A3238))
    roof = lathe([(1.55, 13.3), (1.5, 13.45), (0.9, 14.3), (0.0, 15.0)], 8, True, False)
    t.add(roof.paint(0xC8553D, z0=13.3, z1=15.0, lo=0.75, hi=0xE9967A, jit=0.06))
    t.add(prism(4, 0.06, 0.04, 14.9, 15.5, tip=0.2, phase=0.78).paint(0x3A3238))
    t.add(icosphere(0.14, 0).move(0, 0, 15.45).paint(0xFFE9A8, glow=True))
    fd = _dirv(front)
    rz = math.degrees(math.atan2(fd.y, fd.x)) + 90.0
    t.add(box(1.25, 0.4, 2.15, (0, 0, 1.07)).rotz(rz).move(fd * 1.95).paint(L.STONE_B, jit=0.04))       # door frame
    t.add(box(0.9, 0.42, 1.8, (0, 0, 0.9)).rotz(rz).move(fd * 1.99).paint(L.WOOD_B, jit=0.04))
    t.add(box(0.12, 0.44, 0.12, (0.28, 0, 0.95)).rotz(rz).move(fd * 2.0).paint(GOLD, jit=0.0))
    t.add(box(1.5, 0.7, 0.12, (0, 0, 0.06)).rotz(rz).move(fd * 2.45).paint(L.STONE_A, jit=0.04))          # door step
    for (h, off) in ((4.3, 0.0), (7.6, 0.0)):
        r_at = 1.86 - (h - 3.1) * 0.064
        t.add(box(0.5, 0.3, 0.8, (0, 0, h)).rotz(rz).move(fd * (r_at - 0.02)).paint(0x3A3340, jit=0.02))
    bd = _dirv(ang + 70.0)
    t.add(box(0.5, 0.3, 0.8, (0, 0, 5.9)).rotz(math.degrees(math.atan2(bd.y, bd.x)) + 90.0).move(bd * 1.66).paint(0x3A3340, jit=0.02))
    deco = Part()
    deco.add(t)
    ring_c = P(front, 4.4)

    def keep(a, d):
        q = P(a, d)
        if L.near_lane(a, [front], 18):
            return False
        return d > 2.9 and (q - ring_c).length > 2.7
    deco.add(_scatter(40, 3.0, 9.2, lambda: tuft(3, 0.4, 0x9DB070), keep))
    deco.add(_scatter(12, 3.0, 9.3, lambda: rock(rnd(0.14, 0.34), 0, 0.3, 0.6).move(0, 0, 0.05).paint(L.ROCK_B, jit=0.1), keep))
    for i in range(7):
        a = 51.4 * i + rnd(-12, 12)
        if L.near_lane(a, [front], 22):
            continue
        deco.add(rock(rnd(0.5, 0.95), 0, 0.3, 0.75).move(P(a, TASK_R + rnd(0.5, 0.9), -0.15)).paint(L.ROCK_A, top=L.ROCK_C, jit=0.08))
    make_object("isle_beacon", join(isle, deco))
    lamp = Part()
    lamp.add(lathe([(0.0, -0.95), (0.85, -0.5), (1.0, 0.0), (0.85, 0.5), (0.0, 0.95)], 8, False, False))
    for k in range(4):                    # flat flare fins so the lamp reads from far away
        a = math.tau * k / 4 + math.pi / 4
        d = Vector((math.cos(a), math.sin(a), 0))
        lamp.poly([d * 1.0 + Vector((0, 0, 0.22)), d * 2.7, d * 1.0 - Vector((0, 0, 0.22))])
        s = Vector((-d.y, d.x, 0)) * 0.22
        lamp.poly([d * 1.0 + s, d * 2.7, d * 1.0 - s])
    lamp.paint(lambda c, n: mix(0xFFFFFF, 0xFFF6DC, rnd(0, 1)), glow=True, jit=0.02)
    make_object("beacon_lamp", lamp, location=Vector((0, 0, 12.35)))
    rg, info = top_disc([1.9, 2.2], 20, z=0.0)
    paint_faces(rg, info, lambda rm, a: (0xFFFFFF if int(a / 18) % 2 else 0xFFF6DC, "glow"), jit=0.0)
    make_object("beacon_ring", rg, location=Vector((ring_c.x, ring_c.y, 0.05)))
    col_cylinder("col_beacon", 0, 0, 2.2, 6.0, center=Vector((0, 0, 0)))


@asset(el_deg=18, az_deg=20)
def isle_shrine():
    """Sun Shrine (245 deg): altar on the centre, sun-disc arch behind it, five pillars around
    r 6.5 (front approach open). `altar_glow` = the sun disc + altar glyph (sky_glow, near white)."""
    ang = TASK_ANG["isle_shrine"]
    front, back = ang + 180.0, ang
    pillar_angs = [back, back - 55.0, back + 55.0, back - 110.0, back + 110.0]

    def top_fn(rm, a):
        x, y = math.cos(math.radians(a)) * rm, math.sin(math.radians(a)) * rm
        i = int(a / (360.0 / 28))
        if rm < 3.0:
            return 0xEAD9AE if i % 2 == 0 else 0xDCC79A                                      # sun-court paving
        if rm < 6.0:
            c = 0xE2D2A8 if i % 2 else 0xD3C096
            return mix(c, L.GRASS_A, 0.55 if nz2(x, y, 0.4, 14.0) > 0.25 else 0.0)
        c = mix(L.GRASS_A, 0xB9BC7A, 0.5 + 0.5 * nz2(x, y, 0.25, 9.0))
        ld = lane_dirt(a, rm, [front], TASK_R, 2.2)
        return mix(c, 0xDCC79A, 0.8 * ld)
    isle = _task_isle("isle_shrine", 63.0, top_fn, mul(L.GRASS_A, 0.9), (0x9A8A72, 0xB9A98A, 0xD6C6A0))
    deco = Part()
    # altar
    al = Part()
    al.add(lathe([(1.18, 0.0), (1.18, 0.2), (0.98, 0.3)], 8, False, False, phase=math.pi / 8).paint(L.STONE_B, top=L.STONE_A, jit=0.05))
    al.add(lathe([(0.82, 0.3), (0.76, 0.5)], 8, False, False, phase=math.pi / 8).paint(L.STONE_A, jit=0.05))
    al.add(lathe([(0.78, 0.5), (0.78, 0.62)], 8, False, False, phase=math.pi / 8).paint(L.TEAL, jit=0.03))
    al.add(lathe([(0.76, 0.62), (0.8, 0.84)], 8, False, False, phase=math.pi / 8).paint(L.STONE_A, jit=0.05))
    al.add(lathe([(0.8, 0.84), (1.02, 0.88), (1.02, 1.0)], 8, True, True, phase=math.pi / 8).paint(L.STONE_B, top=mul(L.STONE_A, 1.05), jit=0.04))
    deco.add(al)
    # sun-disc arch behind the altar (local frame: x = lateral, legs at x = +-1.9)
    arch = Part()
    for s in (-1, 1):
        arch.add(box_z0(0.82, 0.82, 0.3, 1.9 * s, 0, 0).paint(L.STONE_B))
        arch.add(box_z0(0.6, 0.6, 3.75, 1.9 * s, 0, 0.3, taper=0.88).paint(L.STONE_A, z0=0, z1=4.2, lo=0.8, jit=0.05))
        arch.add(box_z0(0.72, 0.72, 0.2, 1.9 * s, 0, 4.05).paint(mul(L.STONE_A, 1.05)))
    nv = 7
    for i in range(nv):
        t0, t1 = math.pi * i / nv, math.pi * (i + 1) / nv
        key = i == nv // 2
        ro = 2.5 if key else 2.25

        def pt(r, th, y):
            return (math.cos(th) * r, y, 4.25 + math.sin(th) * r)
        tm = (t0 + t1) * 0.5
        od = (math.cos(tm), 0, math.sin(tm))
        blk = Part()
        blk.poly([pt(1.6, t0, -0.3), pt(ro, t0, -0.3), pt(ro, t1, -0.3), pt(1.6, t1, -0.3)], toward=(0, -1, 0))
        blk.poly([pt(1.6, t0, 0.3), pt(ro, t0, 0.3), pt(ro, t1, 0.3), pt(1.6, t1, 0.3)], toward=(0, 1, 0))
        blk.poly([pt(ro, t0, -0.3), pt(ro, t0, 0.3), pt(ro, t1, 0.3), pt(ro, t1, -0.3)], toward=od)
        blk.poly([pt(1.6, t0, -0.3), pt(1.6, t0, 0.3), pt(1.6, t1, 0.3), pt(1.6, t1, -0.3)], toward=(-od[0], 0, -od[2]))
        blk.paint(mix(L.TEAL, 0x58BFC6, 0.3) if key else (L.STONE_A if i % 2 else mix(L.STONE_A, L.STONE_B, 0.7)), jit=0.04)
        arch.add(blk)
    arch.add(prism(4, 0.14, 0.1, 6.72, 6.84, tip=0.14, phase=0.78).paint(GOLD))
    arch_c = P(back, 3.0)
    deco.add(arch.copy().at_sim(back, 3.0, face=back + 90.0))
    # pillars around r 6.5, front approach left open
    for pa in pillar_angs:
        col_p = column(3.2, 0.36)
        col_p.add(lathe([(0.2, 3.48), (0.42, 3.62), (0.36, 3.7)], 6, True, True).paint(GOLD, top=0x6A4F22))
        col_p.add(cone(0.24, 3.7, 4.15, 5).paint(lambda c, n: mix(0xFFC24A, 0xFFF0B8, min(1.0, max(0.0, (c.z - 3.7) / 0.4))), glow=True))
        deco.add(col_p.move(P(pa, 6.5)))

    def keep(a, d):
        q = P(a, d)
        if L.near_lane(a, [front], 18) or d < 3.2:
            return False
        if (q - arch_c).length < 2.9:
            return False
        return all((q - P(pa, 6.5)).length > 0.9 for pa in pillar_angs)
    deco.add(_scatter(44, 3.2, 9.2, lambda: tuft(3, 0.42, L.GRASS_B), keep))
    deco.add(_scatter(10, 3.2, 9.3, lambda: rock(rnd(0.12, 0.28), 0, 0.3, 0.6).move(0, 0, 0.05).paint(0xD6C6A0, jit=0.1), keep))
    for _ in range(16):
        a, d = rnd(0, 360), rnd(6.2, 9.2)
        if keep(a, d):
            fl = cone(0.11, 0.2, 0.33, 5).rotx(180).move(0, 0, 0.53).paint([0xFFF2B0, 0xFFD27A, 0xFFFFFF][int(rnd(0, 3))])
            deco.add(fl.move(P(a, d)))
    for i in range(6):
        a = 60.0 * i + rnd(-15, 15)
        if L.near_lane(a, [front], 22):
            continue
        deco.add(rock(rnd(0.4, 0.8), 0, 0.3, 0.7).move(P(a, TASK_R + rnd(0.5, 0.8), -0.15)).paint(0xB9A98A, top=L.GRASS_A, jit=0.08))
    make_object("isle_shrine", join(isle, deco))
    # altar_glow: the sun disc hanging in the arch + a glyph on the altar top
    g = Part()
    sun = Part()
    c_i = sun.vert((0, 0, 4.55))
    rim = [sun.vert((math.cos(math.tau * k / 12) * 1.05, 0, 4.55 + math.sin(math.tau * k / 12) * 1.05)) for k in range(12)]
    for k in range(12):
        sun.face((c_i, rim[k], rim[(k + 1) % 12]))
    for k in range(8):
        a = math.tau * k / 8
        ln = 1.52 if k % 2 == 0 else 1.36
        d = Vector((math.cos(a), 0, math.sin(a)))
        s = Vector((-d.z, 0, d.x)) * 0.13
        c0 = Vector((0, 0, 4.55))
        sun.poly([c0 + d * 1.12 + s, c0 + d * ln, c0 + d * 1.12 - s])
    g.add(sun.at_sim(back, 3.0, face=back + 90.0))
    gl, info = top_disc([0.42, 0.52], 10, z=1.02)
    g.add(gl)
    gc, info2 = top_disc([0, 0.2], 6, z=1.02)
    g.add(gc)
    for k in range(6):
        a = 60.0 * k + 30.0
        g.poly([P(a - 12, 0.26, 1.02), P(a + 12, 0.26, 1.02), P(a, 0.38, 1.02)], toward=(0, 0, 1))
    g.paint(lambda c, n: mix(0xFFFFFF, 0xFFF6DC, rnd(0, 1)), glow=True, jit=0.02)
    make_object("altar_glow", g)
    col_cylinder("col_altar", 0, 0, 1.2, 1.0, center=Vector((0, 0, 0)))
    lat = _dirv(back + 90.0)
    col_cylinder("col_arch_l", 0, 0, 0.45, 4.0, center=arch_c + lat * 1.9)
    col_cylinder("col_arch_r", 0, 0, 0.45, 4.0, center=arch_c - lat * 1.9)
    for i, pa in enumerate(pillar_angs):
        col_cylinder("col_pillar_%d" % i, pa, 6.5, 0.5, 3.5)


# =====================================================================================
#  cloud sea noise texture
# =====================================================================================
def cloud_noise(size=1024):
    """Seamless-tiling greyscale fBm cloud noise -> models/sky/cloud_noise.png."""
    import numpy as np
    rs = np.random.RandomState(1234)
    ys, xs = np.mgrid[0:size, 0:size].astype(np.float32) / size
    out = np.zeros((size, size), np.float32)
    amp, tot = 1.0, 0.0
    for f in (4, 8, 16, 32, 64, 128):
        g = rs.rand(f, f).astype(np.float32)
        x, y = xs * f, ys * f
        x0, y0 = np.floor(x).astype(int) % f, np.floor(y).astype(int) % f
        x1, y1 = (x0 + 1) % f, (y0 + 1) % f
        tx, ty = x - np.floor(x), y - np.floor(y)
        tx, ty = tx * tx * (3 - 2 * tx), ty * ty * (3 - 2 * ty)
        v = (g[y0, x0] * (1 - tx) + g[y0, x1] * tx) * (1 - ty) + (g[y1, x0] * (1 - tx) + g[y1, x1] * tx) * ty
        out += v * amp
        tot += amp
        amp *= 0.5
    out /= tot
    out = (out - out.min()) / (out.max() - out.min())
    out = np.clip((out - 0.5) * 1.5 + 0.5, 0.0, 1.0)
    out = out * out * (3 - 2 * out)
    img = bpy.data.images.new("cloud_noise", size, size, alpha=False)
    img.colorspace_settings.name = "Non-Color"
    rgba = np.empty((size, size, 4), np.float32)
    rgba[..., 0] = rgba[..., 1] = rgba[..., 2] = out
    rgba[..., 3] = 1.0
    img.pixels.foreach_set(rgba.ravel())
    path = os.path.join(L.OUT_DIR, "cloud_noise.png")
    img.filepath_raw = path
    img.file_format = "PNG"
    img.save()
    bpy.data.images.remove(img)
    print("WROTE", path, os.path.getsize(path))


def contact_sheet(cols=6, tw=320, th=240):
    """Tile every previews/<asset>.png into previews/contact_sheet.png."""
    import numpy as np
    names = [n for n in ASSETS if os.path.exists(os.path.join(L.PREVIEW_DIR, n + ".png"))]
    rows = (len(names) + cols - 1) // cols
    sheet = np.ones((rows * th, cols * tw, 4), np.float32)
    sheet[..., :3] = 0.93
    for i, n in enumerate(names):
        img = bpy.data.images.load(os.path.join(L.PREVIEW_DIR, n + ".png"))
        w, h = img.size
        px = np.empty(w * h * 4, np.float32)
        img.pixels.foreach_get(px)
        px = px.reshape(h, w, 4)
        yi = (np.arange(th) * h / th).astype(int)
        xi = (np.arange(tw) * w / tw).astype(int)
        small = px[yi][:, xi]
        r, c = divmod(i, cols)
        y0 = (rows - 1 - r) * th
        sheet[y0:y0 + th, c * tw:(c + 1) * tw] = small
        bpy.data.images.remove(img)
    out = bpy.data.images.new("contact_sheet", cols * tw, rows * th, alpha=False)
    out.pixels.foreach_set(sheet.ravel())
    out.filepath_raw = os.path.join(L.PREVIEW_DIR, "contact_sheet.png")
    out.file_format = "PNG"
    out.save()
    bpy.data.images.remove(out)
    print("WROTE contact sheet with", len(names), "assets")


# =====================================================================================
#  main
# =====================================================================================
def stats():
    rows = []
    total = 0
    for ob in bpy.context.scene.objects:
        if ob.type != "MESH" or ob.name.startswith("preview_"):
            continue
        me = ob.data
        tris = sum(len(p.vertices) - 2 for p in me.polygons)
        rows.append((ob.name, tris))
        if not ob.name.startswith("col_"):
            total += tris
    return rows, total


def seed_of(name):
    return sum(ord(c) * (i + 1) for i, c in enumerate(name))


def build(name, preview=True):
    L.reset_scene()
    L.reseed(seed_of(name))
    ASSETS[name]()
    objs = [o for o in bpy.context.scene.objects]
    rows, total = stats()
    path = L.export_glb(name, objs)
    if preview:
        L.render_preview(name, [o for o in objs if o.type == "MESH" and not o.name.startswith("col_")], **PREVIEW_OPTS.get(name, {}))
    size = os.path.getsize(path)
    print("ASSET %-22s tris %5d  %7.1f kB  nodes: %s" % (name, total, size / 1024.0, ", ".join("%s(%d)" % r for r in rows)))
    return rows, total, size


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    preview = "--no-preview" not in sys.argv
    names = args or (list(ASSETS) + ["cloud_noise", "contact_sheet"])
    for n in names:
        if n == "cloud_noise":
            cloud_noise()
        elif n == "contact_sheet":
            contact_sheet()
        elif n not in ASSETS:
            print("unknown asset:", n)
        else:
            build(n, preview)


if __name__ == "__main__":
    main()
