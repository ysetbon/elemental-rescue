"""Skyfall Isles - shared Blender helpers (headless bpy).

Everything is authored procedurally as flat-shaded low-poly geometry whose colour
lives in a per-corner colour attribute ("Col"), so the GLBs need no textures:
  material 0 = sky_paint (lit, vertex-coloured)
  material 1 = sky_glow  (emissive, vertex-coloured: lava, lanterns, crystals...)

Coordinates
-----------
The game sim is 2D (x, z) with y up; "sim angles" run from +x toward +z.
glTF Y-up export maps Blender (x, y, z) -> Godot (x, z, -y), so
    S(x, z, h)  = Blender (x, -z, h)
    P(a, d, h)  = S(cos a * d, sin a * d, h)        (a in degrees, sim angle)
A top view in Blender therefore looks exactly like the game's radar.
"""
import math
import os
import random

import bpy
from mathutils import Matrix, Vector, noise

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
OUT_DIR = os.path.join(ROOT, "models", "sky")
PREVIEW_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "previews")

rng = random.Random(7)


def reseed(seed):
    global rng
    rng = random.Random(seed)


# ------------------------------------------------------------------ colours
def hx(h):
    """0xRRGGBB -> (r, g, b) sRGB floats."""
    return ((h >> 16) & 255) / 255.0, ((h >> 8) & 255) / 255.0, (h & 255) / 255.0


def as_rgb(c):
    return hx(c) if isinstance(c, int) else tuple(c)


def mix(a, b, t):
    a = as_rgb(a)
    b = as_rgb(b)
    return tuple(a[i] + (b[i] - a[i]) * t for i in range(3))


def mul(a, k):
    a = as_rgb(a)
    return tuple(min(1.0, max(0.0, a[i] * k)) for i in range(3))


def srgb_to_lin(c):
    return tuple(((v / 12.92) if v <= 0.04045 else ((v + 0.055) / 1.055) ** 2.4) for v in c)


# palette
ROCK_A, ROCK_B, ROCK_C = 0x8A7A6A, 0xA8957C, 0xC9B79A
GRASS_A, GRASS_B = 0x8FA86E, 0xA9BD78
OBSIDIAN, LAVA_A, LAVA_B = 0x2B2630, 0xFF7A2A, 0xFFC24A
WATER_A, WATER_B = 0x6D9CE9, 0xB6D2F8
CORAL_A, CORAL_B = 0xF08A7A, 0xF6C0A0
LEAF_A, LEAF_B, LEAF_C = 0x5F8F3E, 0x7FAE55, 0xA9C97A
WOOD_A, WOOD_B = 0x9C7A52, 0x6E5236
BRONZE = 0xB8862E
STONE_A, STONE_B = 0xE3D8C4, 0xCBBFA6
TEAL = 0x1F8F9A
SMOG_A, SMOG_B = 0x6C6578, 0x463D55
VIOLET = 0x6B4FB3
SAND = 0xE8D9B0
FIRE_EL, WATER_EL, LEAF_EL = 0xF0662A, 0x6D9CE9, 0x8FA86E

# baked "golden hour" key direction (toward the sun), Blender coords
SUN_DIR = Vector((-0.83, -0.33, 0.45)).normalized()


# ------------------------------------------------------------------ coords
def S(x, z, h=0.0):
    return Vector((x, -z, h))


def P(a_deg, d, h=0.0):
    a = math.radians(a_deg)
    return Vector((math.cos(a) * d, -math.sin(a) * d, h))


def sim_angle_of(v):
    """Sim angle (deg, 0..360) of a Blender-space point."""
    return math.degrees(math.atan2(-v.y, v.x)) % 360.0


def ang_diff(a, b):
    return (b - a + 540.0) % 360.0 - 180.0


def near_lane(a_sim, lanes, half_deg):
    return any(abs(ang_diff(a_sim, l)) < half_deg for l in lanes)


def yaw_for(d_deg):
    """Blender Z rotation that points an asset's Godot-local +Z along sim direction d."""
    return math.pi / 2.0 - math.radians(d_deg)


# ------------------------------------------------------------------ Part
class Part:
    """A bag of polygons with per-corner colours, material index and optional UVs."""

    def __init__(self):
        self.v = []      # Vector
        self.f = []      # tuple of vertex indices
        self.col = []    # per face: list of per-corner sRGB tuples (or None = unpainted)
        self.mat = []    # per face: 0 paint / 1 glow
        self.uv = []     # per face: list of per-corner (u, v) or None

    # --- building
    def vert(self, p):
        self.v.append(Vector(p))
        return len(self.v) - 1

    def face(self, idx, toward=None, uv=None):
        idx = list(idx)
        if toward is not None:
            n = self._normal(idx)
            if n.dot(Vector(toward)) < 0.0:
                idx.reverse()
                if uv is not None:
                    uv = list(reversed(uv))
        self.f.append(tuple(idx))
        self.col.append(None)
        self.mat.append(0)
        self.uv.append(uv)
        return len(self.f) - 1

    def poly(self, pts, toward=None, uv=None):
        return self.face([self.vert(p) for p in pts], toward, uv)

    def add(self, other):
        o = len(self.v)
        self.v.extend(Vector(p) for p in other.v)
        self.f.extend(tuple(i + o for i in f) for f in other.f)
        self.col.extend(other.col)
        self.mat.extend(other.mat)
        self.uv.extend(other.uv)
        return self

    def copy(self):
        return Part().add(self)

    # --- queries
    def _normal(self, idx):
        n = Vector((0.0, 0.0, 0.0))
        k = len(idx)
        for i in range(k):
            a = self.v[idx[i]]
            b = self.v[idx[(i + 1) % k]]
            n.x += (a.y - b.y) * (a.z + b.z)
            n.y += (a.z - b.z) * (a.x + b.x)
            n.z += (a.x - b.x) * (a.y + b.y)
        return n.normalized() if n.length > 1e-12 else Vector((0, 0, 1))

    def tris(self):
        return sum(len(f) - 2 for f in self.f)

    def bounds(self):
        xs = [p.x for p in self.v]
        ys = [p.y for p in self.v]
        zs = [p.z for p in self.v]
        return Vector((min(xs), min(ys), min(zs))), Vector((max(xs), max(ys), max(zs)))

    # --- transforms
    def tr(self, m):
        self.v = [m @ p for p in self.v]
        if m.to_3x3().determinant() < 0.0:
            self.f = [tuple(reversed(f)) for f in self.f]
            self.col = [list(reversed(c)) if c else c for c in self.col]
            self.uv = [list(reversed(u)) if u else u for u in self.uv]
        return self

    def move(self, x=0.0, y=0.0, z=0.0):
        if isinstance(x, Vector):
            return self.tr(Matrix.Translation(x))
        return self.tr(Matrix.Translation((x, y, z)))

    def rotz(self, deg):
        return self.tr(Matrix.Rotation(math.radians(deg), 4, "Z"))

    def rotx(self, deg):
        return self.tr(Matrix.Rotation(math.radians(deg), 4, "X"))

    def roty(self, deg):
        return self.tr(Matrix.Rotation(math.radians(deg), 4, "Y"))

    def scale(self, sx, sy=None, sz=None):
        sy = sx if sy is None else sy
        sz = sx if sz is None else sz
        return self.tr(Matrix.Diagonal((sx, sy, sz, 1.0)))

    def at_sim(self, a_deg, d, h=0.0, face=None):
        """Place at sim polar (a, d); `face` = sim direction the part's local +X should point."""
        if face is not None:
            self.rotz(-face)
        return self.move(P(a_deg, d, h))

    def flip(self):
        self.f = [tuple(reversed(f)) for f in self.f]
        self.col = [list(reversed(c)) if c else c for c in self.col]
        self.uv = [list(reversed(u)) if u else u for u in self.uv]
        return self

    def orient_outward(self, center=None):
        """Flip faces so normals point away from `center` (convex-ish parts)."""
        if center is None:
            lo, hi = self.bounds()
            center = (lo + hi) * 0.5
        for i, f in enumerate(self.f):
            c = sum((self.v[j] for j in f), Vector()) / len(f)
            if self._normal(f).dot(c - center) < 0.0:
                self.f[i] = tuple(reversed(f))
                if self.uv[i]:
                    self.uv[i] = list(reversed(self.uv[i]))
                if self.col[i]:
                    self.col[i] = list(reversed(self.col[i]))
        return self

    def displace(self, amp, freq=0.5, seed=0.0, axis=None):
        """Perlin push along the direction from the part centre (rocks, clouds)."""
        lo, hi = self.bounds()
        c = (lo + hi) * 0.5
        off = Vector((seed * 13.1, seed * 7.7, seed * 3.3))
        for i, p in enumerate(self.v):
            d = p - c
            if d.length < 1e-6:
                continue
            k = 1.0 + amp * noise.noise(p * freq + off)
            q = c + d * k
            if axis == "xy":
                q.z = p.z
            self.v[i] = q
        return self

    # --- painting
    def paint(self, base, top=None, under=None, z0=None, z1=None, lo=0.72, hi=None,
              jit=0.06, sun=0.07, glow=False, only_unpainted=True, shade=0.10):
        """Bake painterly vertex colours.
        base : 0xRRGGBB | (r,g,b) | fn(center, normal) -> colour
        top / under : colours blended onto up / down facing faces
        z0..z1 : vertical gradient - corners at z0 are multiplied by `lo`, at z1 by 1
                 (and optionally blended toward `hi`)
        jit : per-face brightness jitter, sun : warm/cool directional tint
        """
        for i, f in enumerate(self.f):
            if only_unpainted and self.col[i] is not None:
                continue
            n = self._normal(f)
            cen = sum((self.v[j] for j in f), Vector()) / len(f)
            c = base(cen, n) if callable(base) else base
            c = as_rgb(c)
            if top is not None and n.z > 0.0:
                c = mix(c, top, min(1.0, n.z * n.z * 1.1))
            if under is not None and n.z < 0.0:
                c = mix(c, under, min(1.0, n.z * n.z * 1.1))
            if not glow:
                k = 1.0 + shade * n.z + rng.uniform(-jit, jit)
                s = n.dot(SUN_DIR) * sun
                c = (c[0] * (k + s * 1.2), c[1] * (k + s * 0.4), c[2] * (k - s * 1.3))
                hj = rng.uniform(-jit, jit) * 0.5
                c = (c[0] * (1 + hj), c[1], c[2] * (1 - hj))
            else:
                k = 1.0 + rng.uniform(-jit, jit)
                c = (c[0] * k, c[1] * k, c[2] * k)
            corners = []
            for j in f:
                cc = c
                if z0 is not None and z1 is not None and abs(z1 - z0) > 1e-6:
                    t = min(1.0, max(0.0, (self.v[j].z - z0) / (z1 - z0)))
                    cc = mul(cc, lo + (1.0 - lo) * t)
                    if hi is not None:
                        cc = mix(cc, hi, t * 0.35)
                corners.append(tuple(min(1.0, max(0.0, x)) for x in cc))
            self.col[i] = corners
            self.mat[i] = 1 if glow else 0
        return self


def join(*parts):
    out = Part()
    for p in parts:
        if p is not None:
            out.add(p)
    return out


# ------------------------------------------------------------------ primitives
def ring(r, n, z=0.0, phase=0.0):
    return [Vector((math.cos(phase + math.tau * i / n) * r, math.sin(phase + math.tau * i / n) * r, z)) for i in range(n)]


def lathe(profile, seg, cap_bottom=True, cap_top=True, rf=None, phase=0.0, arc=None):
    """Revolve [(r, z), ...] (bottom -> top) around Z. rf(angle, z) -> radius multiplier.
    arc = (a0_deg, a1_deg) for a partial revolve (open)."""
    p = Part()
    a0, a1 = (0.0, 360.0) if arc is None else arc
    closed = arc is None
    cols = seg if closed else seg + 1
    rings = []
    for (r, z) in profile:
        row = []
        for i in range(cols):
            a = math.radians(a0 + (a1 - a0) * i / seg) + phase
            k = rf(a, z) if rf else 1.0
            row.append(p.vert((math.cos(a) * r * k, math.sin(a) * r * k, z)))
        rings.append(row)
    for j in range(len(rings) - 1):
        for i in range(seg):
            i2 = (i + 1) % cols if closed else i + 1
            a, b, c, d = rings[j][i], rings[j][i2], rings[j + 1][i2], rings[j + 1][i]
            if profile[j][0] < 1e-6:
                p.face((a, c, d))
            elif profile[j + 1][0] < 1e-6:
                p.face((a, b, d))
            else:
                p.face((a, b, c, d))
    if closed:
        if cap_bottom and profile[0][0] > 1e-6:
            p.face(list(reversed(rings[0])))
        if cap_top and profile[-1][0] > 1e-6:
            p.face(rings[-1])
    return p


def cyl(r0, r1, z0, z1, seg=8, caps=True, phase=0.0):
    return lathe([(r0, z0), (r1, z1)], seg, caps, caps, phase=phase)


def cone(r, z0, z1, seg=8, phase=0.0):
    return lathe([(r, z0), (0.0, z1)], seg, True, False, phase=phase)


def prism(n, r0, r1, z0, z1, tip=0.0, phase=0.0):
    """n-gon column; tip > 0 adds a pointed cap of that height (crystals, basalt)."""
    prof = [(r0, z0), (r1, z1)]
    if tip > 0.0:
        prof.append((0.0, z1 + tip))
    return lathe(prof, n, True, tip <= 0.0, phase=phase)


def box(sx, sy, sz, center=(0, 0, 0), taper=1.0):
    """Axis box; taper scales the top face in x/y."""
    p = Part()
    cx, cy, cz = center
    hx_, hy, hz = sx / 2.0, sy / 2.0, sz / 2.0
    vs = []
    for z, k in ((-hz, 1.0), (hz, taper)):
        for (x, y) in ((-hx_, -hy), (hx_, -hy), (hx_, hy), (-hx_, hy)):
            vs.append(p.vert((cx + x * k, cy + y * k, cz + z)))
    p.face((vs[3], vs[2], vs[1], vs[0]))
    p.face((vs[4], vs[5], vs[6], vs[7]))
    for i in range(4):
        j = (i + 1) % 4
        p.face((vs[i], vs[j], vs[4 + j], vs[4 + i]))
    return p


def box_z0(sx, sy, sz, x=0.0, y=0.0, z=0.0, taper=1.0):
    """Box whose BASE sits at height z."""
    return box(sx, sy, sz, (x, y, z + sz / 2.0), taper)


def icosphere(r=1.0, sub=1):
    t = (1.0 + 5.0 ** 0.5) / 2.0
    vs = [Vector(v).normalized() for v in (
        (-1, t, 0), (1, t, 0), (-1, -t, 0), (1, -t, 0), (0, -1, t), (0, 1, t),
        (0, -1, -t), (0, 1, -t), (t, 0, -1), (t, 0, 1), (-t, 0, -1), (-t, 0, 1))]
    fs = [(0, 11, 5), (0, 5, 1), (0, 1, 7), (0, 7, 10), (0, 10, 11), (1, 5, 9), (5, 11, 4),
          (11, 10, 2), (10, 7, 6), (7, 1, 8), (3, 9, 4), (3, 4, 2), (3, 2, 6), (3, 6, 8),
          (3, 8, 9), (4, 9, 5), (2, 4, 11), (6, 2, 10), (8, 6, 7), (9, 8, 1)]
    for _ in range(sub):
        cache = {}

        def mid(a, b):
            key = (min(a, b), max(a, b))
            if key not in cache:
                vs.append(((vs[a] + vs[b]) * 0.5).normalized())
                cache[key] = len(vs) - 1
            return cache[key]
        nf = []
        for (a, b, c) in fs:
            ab, bc, ca = mid(a, b), mid(b, c), mid(c, a)
            nf += [(a, ab, ca), (b, bc, ab), (c, ca, bc), (ab, bc, ca)]
        fs = nf
    p = Part()
    for v in vs:
        p.vert(v * r)
    for f in fs:
        p.face(f)
    return p


def rock(r=1.0, sub=1, amp=0.35, squash=0.75, seed=None):
    seed = rng.uniform(0, 100) if seed is None else seed
    p = icosphere(r, sub)
    p.displace(amp, 0.9 / max(r, 0.2), seed)
    p.scale(rng.uniform(0.85, 1.2), rng.uniform(0.85, 1.2), squash)
    p.rotz(rng.uniform(0, 360))
    return p


def blob(r=1.0, sub=2, amp=0.22, squash=0.8, seed=None, freq=None):
    seed = rng.uniform(0, 100) if seed is None else seed
    p = icosphere(r, sub)
    p.displace(amp, freq if freq else 1.3 / max(r, 0.2), seed)
    p.scale(1.0, 1.0, squash)
    return p


def tube(path, radius, sides=5, caps=True, twist=0.0):
    """Sweep an n-gon along a polyline. radius: float or list per point."""
    p = Part()
    pts = [Vector(q) for q in path]
    n = len(pts)
    rs = radius if isinstance(radius, (list, tuple)) else [radius] * n
    rows = []
    up = Vector((0, 0, 1))
    prev_x = None
    for i in range(n):
        if i == 0:
            t = pts[1] - pts[0]
        elif i == n - 1:
            t = pts[-1] - pts[-2]
        else:
            t = pts[i + 1] - pts[i - 1]
        t.normalize()
        ref = up if abs(t.dot(up)) < 0.95 else Vector((1, 0, 0))
        x = prev_x - t * prev_x.dot(t) if prev_x is not None else ref.cross(t)
        if x.length < 1e-6:
            x = ref.cross(t)
        x.normalize()
        y = t.cross(x)
        prev_x = x
        row = []
        for k in range(sides):
            a = math.tau * k / sides + twist * i
            row.append(p.vert(pts[i] + (x * math.cos(a) + y * math.sin(a)) * rs[i]))
        rows.append(row)
    for i in range(n - 1):
        for k in range(sides):
            k2 = (k + 1) % sides
            p.face((rows[i][k], rows[i][k2], rows[i + 1][k2], rows[i + 1][k]))
    if caps:
        p.face(list(reversed(rows[0])))
        p.face(rows[-1])
    return p


def top_disc(radii, seg, z=0.0, jitter=0.0, exact=(), phase_deg=0.0):
    """Flat up-facing disc/annulus made of concentric bands (radii ascending; 0 = centre).
    Returns (part, info) where info[i] = (r_mid, sim_angle_mid, r_in, r_out) per face."""
    p = Part()
    info = []
    rows = []
    for r in radii:
        if r < 1e-6:
            rows.append([p.vert((0, 0, z))])
            continue
        row = []
        for i in range(seg):
            a_sim = phase_deg + 360.0 * i / seg
            rr, aa = r, a_sim
            if jitter > 0.0 and r not in exact and r != radii[-1] and r != radii[0]:
                rr = r + rng.uniform(-jitter, jitter)
                aa = a_sim + rng.uniform(-jitter, jitter) * 30.0 / max(r, 1.0)
            row.append(p.vert(P(aa, rr, z)))
        rows.append(row)
    up = (0, 0, 1)
    for j in range(len(rows) - 1):
        r0, r1 = radii[j], radii[j + 1]
        for i in range(seg):
            i2 = (i + 1) % seg
            am = phase_deg + 360.0 * (i + 0.5) / seg
            if len(rows[j]) == 1:
                p.face((rows[j][0], rows[j + 1][i], rows[j + 1][i2]), toward=up)
            else:
                p.face((rows[j][i], rows[j + 1][i], rows[j + 1][i2], rows[j][i2]), toward=up)
            info.append(((r0 + r1) * 0.5, am % 360.0, r0, r1))
    return p, info


def paint_faces(part, info, fn, jit=0.05, shade=0.0):
    """Colour top_disc faces: fn(r_mid, a_sim) -> colour or (colour, 'glow')."""
    for i, (rm, am, r0, r1) in enumerate(info):
        res = fn(rm, am)
        glow = False
        if isinstance(res, tuple) and len(res) == 2 and res[1] == "glow":
            res, glow = res[0], True
        c = as_rgb(res)
        k = 1.0 + rng.uniform(-jit, jit)
        hj = rng.uniform(-jit, jit) * 0.5
        c = (min(1, c[0] * k * (1 + hj)), min(1, c[1] * k), min(1, c[2] * k * (1 - hj)))
        part.col[i] = [c] * len(part.f[i])
        part.mat[i] = 1 if glow else 0
    return part


def leaf(length=0.6, width=0.28, droop=0.15):
    """A little diamond leaf lying along +X from the origin (4 tris, folded)."""
    p = Part()
    a = p.vert((0, 0, 0))
    b = p.vert((length * 0.45, width * 0.5, droop * 0.25))
    c = p.vert((length, 0, -droop))
    d = p.vert((length * 0.45, -width * 0.5, droop * 0.25))
    e = p.vert((length * 0.5, 0, 0.0))
    p.face((a, e, b))
    p.face((b, e, c))
    p.face((c, e, d))
    p.face((d, e, a))
    return p


def tuft(n=4, h=0.5, col=GRASS_B):
    """A clump of grass blades."""
    p = Part()
    for _ in range(n):
        a = rng.uniform(0, math.tau)
        w = rng.uniform(0.08, 0.14)
        hh = h * rng.uniform(0.6, 1.2)
        lean = rng.uniform(0.1, 0.35)
        d = Vector((math.cos(a), math.sin(a), 0))
        s = Vector((-d.y, d.x, 0)) * w
        o = d * rng.uniform(0.0, 0.15)
        p.poly([o - s, o + s, o + d * lean + Vector((0, 0, hh))])
    p.paint(col, z0=0.0, z1=h, lo=0.7, jit=0.1)
    return p


def strip_on_ground(path, width, z=0.03):
    """Flat ribbon following a 2D polyline (lava cracks, paths)."""
    p = Part()
    pts = [Vector((q[0], q[1], z)) for q in path]
    ws = width if isinstance(width, (list, tuple)) else [width] * len(pts)
    left, right = [], []
    for i in range(len(pts)):
        if i == 0:
            t = pts[1] - pts[0]
        elif i == len(pts) - 1:
            t = pts[-1] - pts[-2]
        else:
            t = pts[i + 1] - pts[i - 1]
        t.z = 0
        t.normalize()
        s = Vector((-t.y, t.x, 0)) * ws[i] * 0.5
        left.append(p.vert(pts[i] + s))
        right.append(p.vert(pts[i] - s))
    for i in range(len(pts) - 1):
        p.face((left[i], right[i], right[i + 1], left[i + 1]), toward=(0, 0, 1))
    return p


# ------------------------------------------------------------------ islands
def island_body(r, depth, seg=48, seed=1.0, lip=1.1, lip_col=GRASS_A, rock_cols=(ROCK_A, ROCK_B, ROCK_C),
                levels=7, glow_veins=None):
    """Rim lip + rocky underside tapering to a point. The top edge ring is EXACTLY r at z=0."""
    p = Part()
    off = Vector((seed * 5.3, seed * 2.1, seed * 9.7))

    def nz(a, k, f=1.0):
        return noise.noise(Vector((math.cos(a) * f, math.sin(a) * f, k)) + off)

    rows = [[p.vert(P(360.0 * i / seg, r, 0.0)) for i in range(seg)]]
    # irregular rocky lip just outside the walkable disc
    row = []
    for i in range(seg):
        a = math.tau * i / seg
        w = lip * (0.75 + 0.6 * abs(nz(a, 0.3, 2.3)))
        row.append(p.vert(P(360.0 * i / seg, r + w, -0.12 - 0.3 * abs(nz(a, 1.7, 3.1)))))
    rows.append(row)
    tip = Vector((nz(0.3, 5.0) * r * 0.12, nz(1.3, 6.0) * r * 0.12, -depth))

    def surf(a_deg, t, push=1.0):
        a = math.radians(a_deg)
        z = -depth * (t ** 1.15)
        rad = (r + lip * 0.6) * ((1.0 - t) ** 0.62)
        k = 1.0 + 0.16 * nz(a, t * 3.0, 1.6) + 0.07 * nz(a, t * 7.0, 4.2)
        q = P(a_deg, rad * k * push, z + 0.9 * nz(a, t * 5.0 + 9.0, 2.7))
        return q + Vector((tip.x, tip.y, 0)) * (t ** 2)

    for j in range(1, levels + 1):
        t = j / (levels + 0.6)
        rows.append([p.vert(surf(360.0 * i / seg, t)) for i in range(seg)])
    tip_i = p.vert(tip)
    band = []
    for j in range(len(rows) - 1):
        for i in range(seg):
            i2 = (i + 1) % seg
            fi = p.face((rows[j][i], rows[j + 1][i], rows[j + 1][i2], rows[j][i2]))
            band.append((fi, j))
    for i in range(seg):
        i2 = (i + 1) % seg
        fi = p.face((rows[-1][i], tip_i, rows[-1][i2]))
        band.append((fi, len(rows) - 1))
    p.orient_outward(Vector((0, 0, -depth * 0.35)))
    # colours: lip in the top colour, then strata bands darkening downward
    nb = len(rows)
    for fi, j in band:
        f = p.f[fi]
        if j == 0:
            c = mul(lip_col, rng.uniform(0.86, 1.0))
        else:
            base = rock_cols[(j + (1 if rng.random() < 0.18 else 0)) % len(rock_cols)]
            c = mul(base, (1.02 - 0.42 * (j / nb)) * rng.uniform(0.9, 1.06))
            n = p._normal(f)
            s = n.dot(SUN_DIR) * 0.10
            c = (c[0] * (1 + s * 1.2), c[1] * (1 + s * 0.4), c[2] * (1 - s * 1.2))
        p.col[fi] = [tuple(min(1.0, max(0.0, x)) for x in c)] * len(f)
    out = p
    # a few hanging rocks under the rim
    for _ in range(max(3, int(r / 4))):
        a = rng.uniform(0, 360)
        d = r * rng.uniform(0.35, 0.8)
        rk = rock(rng.uniform(0.6, 1.5) * max(1.0, r / 14.0), 1, 0.35, rng.uniform(1.1, 1.8))
        rk.move(P(a, d, -depth * rng.uniform(0.38, 0.62)))
        rk.paint(rock_cols[0], jit=0.08, shade=0.2)
        for i in range(len(rk.col)):
            rk.col[i] = [mul(c, 0.72) for c in rk.col[i]]
        out.add(rk)
    if glow_veins:
        for _ in range(glow_veins[1]):
            a = rng.uniform(0, 360)
            t0 = rng.uniform(0.06, 0.2)
            pts = []
            for k in range(7):
                t = t0 + 0.085 * k
                a += rng.uniform(-5, 5)
                pts.append(surf(a, t, 1.015))
            v = tube(pts, [0.3, 0.27, 0.24, 0.2, 0.16, 0.12, 0.06], 3, False)
            v.paint(glow_veins[0], glow=True, jit=0.1)
            out.add(v)
    return out


# ------------------------------------------------------------------ bpy glue
_booted = False


def reset_scene():
    """Empty the scene between assets (keeps the GPU context + materials alive)."""
    global _booted
    if not _booted:
        bpy.ops.wm.read_factory_settings(use_empty=True)
        _booted = True
    for ob in list(bpy.data.objects):
        bpy.data.objects.remove(ob, do_unlink=True)
    for coll in (bpy.data.meshes, bpy.data.cameras, bpy.data.lights):
        for b in list(coll):
            if b.users == 0:
                coll.remove(b)


def get_materials():
    paint = bpy.data.materials.get("sky_paint")
    if paint is None:
        paint = bpy.data.materials.new("sky_paint")
        paint.use_nodes = True
        nt = paint.node_tree
        bsdf = nt.nodes["Principled BSDF"]
        vc = nt.nodes.new("ShaderNodeVertexColor")
        vc.layer_name = "Col"
        nt.links.new(vc.outputs["Color"], bsdf.inputs["Base Color"])
        bsdf.inputs["Roughness"].default_value = 1.0
        bsdf.inputs["Metallic"].default_value = 0.0
        paint.use_backface_culling = False
    glow = bpy.data.materials.get("sky_glow")
    if glow is None:
        glow = bpy.data.materials.new("sky_glow")
        glow.use_nodes = True
        nt = glow.node_tree
        bsdf = nt.nodes["Principled BSDF"]
        vc = nt.nodes.new("ShaderNodeVertexColor")
        vc.layer_name = "Col"
        nt.links.new(vc.outputs["Color"], bsdf.inputs["Base Color"])
        nt.links.new(vc.outputs["Color"], bsdf.inputs["Emission Color"])
        bsdf.inputs["Emission Strength"].default_value = 3.0
        bsdf.inputs["Roughness"].default_value = 1.0
        glow.use_backface_culling = False
    return paint, glow


def make_object(name, part, location=None, rotation=None, parent=None, hide_render=False):
    """Part -> bpy mesh object (flat shaded, 'Col' corner colours, <= 2 materials)."""
    paint, glow = get_materials()
    me = bpy.data.meshes.new(name)
    me.from_pydata([tuple(v) for v in part.v], [], [list(f) for f in part.f])
    me.update()
    used = sorted(set(part.mat))
    slot_of = {}
    for m in used:
        slot_of[m] = len(me.materials)
        me.materials.append(glow if m == 1 else paint)
    if not used:
        me.materials.append(paint)
    ca = me.color_attributes.new("Col", "FLOAT_COLOR", "CORNER")
    data = ca.data
    li = 0
    for fi, f in enumerate(part.f):
        cols = part.col[fi] or [(0.8, 0.0, 0.8)] * len(f)
        for k in range(len(f)):
            c = srgb_to_lin(as_rgb(cols[k]))
            data[li].color = (c[0], c[1], c[2], 1.0)
            li += 1
    me.color_attributes.active_color = ca
    me.color_attributes.render_color_index = 0
    if any(u is not None for u in part.uv):
        uvl = me.uv_layers.new(name="UVMap")
        li = 0
        for fi, f in enumerate(part.f):
            us = part.uv[fi] or [(0.0, 0.0)] * len(f)
            for k in range(len(f)):
                uvl.data[li].uv = us[k]
                li += 1
    for fi, poly in enumerate(me.polygons):
        poly.material_index = slot_of.get(part.mat[fi], 0)
        poly.use_smooth = False
    ob = bpy.data.objects.new(name, me)
    bpy.context.scene.collection.objects.link(ob)
    if location is not None:
        ob.location = location
    if rotation is not None:
        ob.rotation_euler = rotation
    if parent is not None:
        ob.parent = parent
    ob.hide_render = hide_render
    ob["tris"] = part.tris()
    return ob


def col_cylinder(name, a_sim, d, r, h=3.0, center=None):
    """Collision helper: a low-poly vertical cylinder (Godot reads centre + radius)."""
    p = cyl(r, r, 0.0, h, 12)
    p.paint(0xFF00FF, jit=0.0)
    c = center if center is not None else P(a_sim, d, 0.0)
    p.move(c)
    ob = make_object(name, p, hide_render=True)
    ob.display_type = "WIRE"
    return ob


def export_glb(name, objects=None):
    os.makedirs(OUT_DIR, exist_ok=True)
    path = os.path.join(OUT_DIR, name + ".glb")
    bpy.ops.object.select_all(action="DESELECT")
    objs = objects if objects is not None else list(bpy.context.scene.objects)
    for o in objs:
        o.hide_set(False)
        o.select_set(True)
    bpy.context.view_layer.objects.active = objs[0]
    gltf_export(path, apply=True)
    return path


def gltf_export(path, apply=True):
    """Export the selection. glTF cannot carry a per-vertex emissive colour (the exporter would
    write a flat white emissiveFactor x3 and wash every glow part out), so sky_glow is written
    WITHOUT emission: the game recognises the material by name and renders it unshaded/bright."""
    _, glow = get_materials()
    bsdf = glow.node_tree.nodes["Principled BSDF"]
    keep = bsdf.inputs["Emission Strength"].default_value
    bsdf.inputs["Emission Strength"].default_value = 0.0
    try:
        bpy.ops.export_scene.gltf(
            filepath=path, export_format="GLB", use_selection=True, export_yup=True, export_apply=apply,
            export_vertex_color="MATERIAL", export_all_vertex_colors=False,
            export_active_vertex_color_when_no_material=True,
            export_cameras=False, export_lights=False, export_animations=False,
            export_normals=True, export_texcoords=True, export_materials="EXPORT")
    finally:
        bsdf.inputs["Emission Strength"].default_value = keep


# ------------------------------------------------------------------ previews
def setup_render(w=640, h=480, samples=16):
    sc = bpy.context.scene
    sc.render.engine = "BLENDER_EEVEE"
    sc.render.resolution_x = w
    sc.render.resolution_y = h
    sc.render.resolution_percentage = 100
    sc.render.film_transparent = False
    try:
        sc.eevee.taa_render_samples = samples
    except Exception:
        pass
    sc.view_settings.view_transform = "Standard"
    world = bpy.data.worlds.get("sky_world") or bpy.data.worlds.new("sky_world")
    world.use_nodes = True
    bg = world.node_tree.nodes.get("Background")
    bg.inputs[0].default_value = (0.86, 0.66, 0.60, 1.0)
    bg.inputs[1].default_value = 0.55
    sc.world = world
    sun = bpy.data.objects.get("preview_sun")
    if sun is None:
        ld = bpy.data.lights.new("preview_sun", "SUN")
        ld.energy = 3.2
        ld.color = (1.0, 0.92, 0.80)
        sun = bpy.data.objects.new("preview_sun", ld)
        sc.collection.objects.link(sun)
    # light travels along -SUN_DIR: aim the lamp's -Z down that way
    sun.rotation_euler = (-SUN_DIR).to_track_quat("-Z", "Y").to_euler()
    cam = bpy.data.objects.get("preview_cam")
    if cam is None:
        cam = bpy.data.objects.new("preview_cam", bpy.data.cameras.new("preview_cam"))
        sc.collection.objects.link(cam)
    sc.camera = cam
    return cam


def frame_camera(cam, objs, az_deg=35.0, el_deg=28.0, fov_deg=38.0, margin=1.12, focus=None, dist_scale=1.0):
    pts = []
    for o in objs:
        if o.type != "MESH" or o.hide_render:
            continue
        mw = o.matrix_world
        pts.extend(mw @ v.co for v in o.data.vertices)
    if not pts:
        return
    lo = Vector((min(p.x for p in pts), min(p.y for p in pts), min(p.z for p in pts)))
    hi = Vector((max(p.x for p in pts), max(p.y for p in pts), max(p.z for p in pts)))
    c = (lo + hi) * 0.5 if focus is None else Vector(focus)
    rad = max((p - c).length for p in pts)
    cam.data.lens_unit = "FOV"
    cam.data.angle = math.radians(fov_deg)
    sc = bpy.context.scene
    aspect = sc.render.resolution_y / sc.render.resolution_x
    half = math.atan(math.tan(math.radians(fov_deg) * 0.5) * min(1.0, aspect))
    dist = rad * margin / math.sin(half) * dist_scale
    az, el = math.radians(az_deg), math.radians(el_deg)
    # az measured like a sim angle so previews look "from the south-east" of the radar
    d = Vector((math.cos(az) * math.cos(el), -math.sin(az) * math.cos(el), math.sin(el)))
    cam.location = c + d * dist
    cam.rotation_euler = (-d).to_track_quat("-Z", "Y").to_euler()
    cam.data.clip_start = max(0.05, dist * 0.01)
    cam.data.clip_end = dist * 6.0 + 100.0


def render_preview(name, objs=None, **kw):
    os.makedirs(PREVIEW_DIR, exist_ok=True)
    w = kw.pop("w", 640)
    h = kw.pop("h", 480)
    cam = setup_render(w, h)
    objs = objs if objs is not None else [o for o in bpy.context.scene.objects if o.type == "MESH"]
    frame_camera(cam, objs, **kw)
    bpy.context.scene.render.filepath = os.path.join(PREVIEW_DIR, name + ".png")
    bpy.ops.render.render(write_still=True)
