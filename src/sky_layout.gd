class_name SkyLayout
extends Object
# SKYFALL ISLES — the pure map data + geometry of the sky world (no nodes, no game
# state). Shared by SkyBuilder (visuals), ModeAscent (rules + AI), the radar and
# the online guests' prediction, so every side agrees on what is walkable.
#
# Sim plane is x/z (y = height); angles are degrees measured from +x toward +z.
# tools/blender/sky_layout.py mirrors these numbers for the Blender asset build.

# ------------------------------------------------------------------ the isles
const HEART_R := 26.0
const HOME_DIST := 120.0
const HOME_R := 22.0
const SANCTUM_R := 6.0
const WILD_DIST := 95.0
const WILD_R := 16.0
const HOME_ANG := { "fire": 210.0, "water": 330.0, "grass": 90.0 }
const HOME_NAME := { "fire": "Ember Crag", "water": "Tide Atoll", "grass": "Canopy Grove" }
const HOME_GLB := { "fire": "isle_home_fire", "water": "isle_home_water", "grass": "isle_home_leaf" }
const WILD := [
	{ "id": "w30", "ang": 30.0, "name": "Windmill Isle", "glb": "isle_wild_windmill" },
	{ "id": "w150", "ang": 150.0, "name": "Ruin Isle", "glb": "isle_wild_ruin" },
	{ "id": "w270", "ang": 270.0, "name": "Crystal Isle", "glb": "isle_wild_crystal" },
]
const ISLET_WILD_DIST := 140.0   # one small islet outside each wild isle
const ISLET_WILD_R := 7.0
const ISLET_HOME_DIST := 160.0   # ...and one outside each home isle
const ISLET_HOME_R := 6.0

const BRIDGE_HW := 2.0           # plank bridges are 4 m wide
const BRIDGE_PAIRS := [
	# the outer ring: home - wild - home - ...
	["w30", "h_grass"], ["h_grass", "w150"], ["w150", "h_fire"],
	["h_fire", "w270"], ["w270", "h_water"], ["h_water", "w30"],
	# a spoke from each wild isle to Heart Isle (no shared home spoke)
	["w30", "heart"], ["w150", "heart"], ["w270", "heart"],
	# the dead-end islets
	["w30", "i30"], ["w150", "i150"], ["w270", "i270"],
	["h_fire", "ih_fire"], ["h_water", "ih_water"], ["h_grass", "ih_grass"],
]

# ---- element routes: each home's private way to Heart Isle
const VINE_HW := 1.5             # Leaf's vine (only Leaf can walk it)
const STREAM_HW := 3.0           # Water's sky stream (Water surfs 2x, others wade)
const STREAM_BOOST := 2.0
const STREAM_WADE := 0.55        # same drag as the castle river
const VENT_HOME_OFF := 17.0      # Fire's vent pad: this far from Ember Crag's centre, toward Heart
const VENT_HEART_R := 23.0       # ...and its twin on Heart Isle's ground ring
const VENT_R := 1.6
const VENT_FLIGHT := 1.4
const VENT_DWELL := 0.3
# Seed gaps: Leaf stands on a seed for SEED_GROW s and a vine bridge anyone can
# use spans the gap for SEED_LIFE s. Two gaps: the OTHER two homes <-> Heart.
const SEED_OFF := 9.0            # lateral offset from the home-heart axis
const SEED_HW := 1.5
const SEED_GROW := 1.5
const SEED_LIFE := 10.0
const SEED_COOLDOWN := 5.0
const SEED_R := 2.2
const SEED_GAPS := [             # home isle, side (lateral normal = axis rotated by this many degrees)
	{ "home": "fire", "side": 90.0 },
	{ "home": "water", "side": -90.0 },
]

# ------------------------------------------------------------------ the spire
const SPIRE_TIERS := 5
const SPIRE_TIER_H := 6.0
const SPIRE_OUTER_R := [20.0, 16.0, 12.0, 8.5, 5.0]   # outer radius of tiers 1..5
const SPIRE_GROUND_R := [20.0, 26.0]
const SPIRE_RAMP_A0 := 300.0
const SPIRE_RAMP_STEP := 72.0
const SPIRE_RAMP_ARC := 22.0
const SPIRE_RAMP_RUN := [4.2, 3.0, 3.0, 2.6, 2.6]     # radial length of the stair from tier k up
const SPIRE_RAMP_MOUTH := 1.0                          # you step on within this of the foot
const SPIRE_PARAPET := 0.3
const SHORTCUT_OFFSETS := { "fire": -32.0, "water": 0.0, "grass": 32.0 }
const SHORTCUT_WALL_GAP := 1.8                          # pad centre sits this far out from the wall
const SHORTCUT_R := 1.3
const BELL_ZONE_R := 3.5

# ------------------------------------------------------------------ built data
static var NODES: Dictionary = {}     # id -> { id, x, z, r, kind, ang, d, el?, name?, glb? }
static var ISLES: Array = []          # every node dict (heart first)
static var BRIDGES: Array = []        # [{ a, b, ax, az, bx, bz, hw }]
static var EDGES: Array = []          # nav graph [{ a, b, kind, idx? }]
static var VINE: Dictionary = {}      # { ax, az, bx, bz, hw }
static var STREAM: Dictionary = {}
static var VENT_HOME := Vector2.ZERO
static var VENT_HEART := Vector2.ZERO
static var SEEDS: Array = []          # [{ ax, az, bx, bz, hw, ma:Vector2, mb:Vector2, home }]
static var _ready := false

static func ensure() -> void:
	if _ready:
		return
	_ready = true
	NODES.clear(); ISLES.clear(); BRIDGES.clear(); EDGES.clear(); SEEDS.clear()
	_add("heart", 0.0, 0.0, HEART_R, "heart", {})
	for el in ["fire", "water", "grass"]:
		_add("h_" + el, HOME_ANG[el], HOME_DIST, HOME_R, "home", { "el": el, "name": HOME_NAME[el], "glb": HOME_GLB[el] })
	for w in WILD:
		_add(w["id"], w["ang"], WILD_DIST, WILD_R, "wild", { "name": w["name"], "glb": w["glb"] })
	for w in WILD:
		_add("i%d" % int(w["ang"]), w["ang"], ISLET_WILD_DIST, ISLET_WILD_R, "islet", { "glb": "islet_small_a" })
	for el in ["fire", "water", "grass"]:
		_add("ih_" + el, HOME_ANG[el], ISLET_HOME_DIST, ISLET_HOME_R, "islet", { "glb": "islet_small_b" })
	for p in BRIDGE_PAIRS:
		var a: Dictionary = NODES[p[0]]
		var b: Dictionary = NODES[p[1]]
		BRIDGES.append({ "a": p[0], "b": p[1], "ax": a["x"], "az": a["z"], "bx": b["x"], "bz": b["z"], "hw": BRIDGE_HW })
		EDGES.append({ "a": p[0], "b": p[1], "kind": "bridge" })
	var hg: Dictionary = NODES["h_grass"]
	VINE = { "ax": hg["x"], "az": hg["z"], "bx": 0.0, "bz": 0.0, "hw": VINE_HW }
	var hw_: Dictionary = NODES["h_water"]
	STREAM = { "ax": hw_["x"], "az": hw_["z"], "bx": 0.0, "bz": 0.0, "hw": STREAM_HW }
	var hf: Dictionary = NODES["h_fire"]
	var to_heart := pol(HOME_ANG["fire"] + 180.0, 1.0)
	VENT_HOME = Vector2(hf["x"], hf["z"]) + to_heart * VENT_HOME_OFF
	VENT_HEART = pol(HOME_ANG["fire"], VENT_HEART_R)
	EDGES.append({ "a": "h_grass", "b": "heart", "kind": "vine" })
	EDGES.append({ "a": "h_water", "b": "heart", "kind": "stream" })
	EDGES.append({ "a": "h_fire", "b": "heart", "kind": "vent" })
	for i in SEED_GAPS.size():
		var sg: Dictionary = SEED_GAPS[i]
		var el: String = sg["home"]
		var h: Dictionary = NODES["h_" + el]
		var u := pol(HOME_ANG[el] + 180.0, 1.0)                    # home -> heart
		var n := pol(HOME_ANG[el] + 180.0 + float(sg["side"]), 1.0) # lateral
		var a0 := Vector2(h["x"], h["z"]) + n * SEED_OFF
		var b0 := n * SEED_OFF
		var ma := a0 + u * (sqrt(HOME_R * HOME_R - SEED_OFF * SEED_OFF) - 1.6)    # seed on the home rim
		var mb := b0 - u * (sqrt(HEART_R * HEART_R - SEED_OFF * SEED_OFF) - 1.6)  # seed on Heart's rim
		SEEDS.append({ "ax": a0.x, "az": a0.y, "bx": b0.x, "bz": b0.y, "hw": SEED_HW, "ma": ma, "mb": mb, "home": el })
		EDGES.append({ "a": "h_" + el, "b": "heart", "kind": "seed", "idx": i })

static func _add(id: String, ang: float, d: float, r: float, kind: String, extra: Dictionary) -> void:
	var p := pol(ang, d)
	var o := { "id": id, "x": p.x, "z": p.y, "r": r, "kind": kind, "ang": ang, "d": d }
	for k in extra:
		o[k] = extra[k]
	NODES[id] = o
	ISLES.append(o)

# ------------------------------------------------------------------ geometry
static func pol(deg: float, d: float) -> Vector2:
	var a := deg_to_rad(deg)
	return Vector2(cos(a) * d, sin(a) * d)

static func pol3(deg: float, d: float, y: float = 0.0) -> Vector3:
	var a := deg_to_rad(deg)
	return Vector3(cos(a) * d, y, sin(a) * d)

static func ang_of(x: float, z: float) -> float:
	return fposmod(rad_to_deg(atan2(z, x)), 360.0)

# signed shortest turn from `from` to `to`, in degrees (-180..180]
static func ang_diff(from: float, to: float) -> float:
	return fposmod(to - from + 180.0, 360.0) - 180.0

static func seg_dist(px: float, pz: float, ax: float, az: float, bx: float, bz: float) -> float:
	var vx := bx - ax
	var vz := bz - az
	var l2 := vx * vx + vz * vz
	var t := 0.0 if l2 < 1e-9 else clampf(((px - ax) * vx + (pz - az) * vz) / l2, 0.0, 1.0)
	var dx := px - ax - vx * t
	var dz := pz - az - vz * t
	return sqrt(dx * dx + dz * dz)

static func _on_seg(px: float, pz: float, s: Dictionary, pad: float = 0.0) -> bool:
	return seg_dist(px, pz, s["ax"], s["az"], s["bx"], s["bz"]) <= float(s["hw"]) + pad

# Which isle (node id) a point stands on, or "" when it is over a gap / on a bridge.
static func node_of(x: float, z: float) -> String:
	if x * x + z * z <= HEART_R * HEART_R:
		return "heart"
	for is_ in ISLES:
		var dx: float = x - is_["x"]
		var dz: float = z - is_["z"]
		if dx * dx + dz * dz <= is_["r"] * is_["r"]:
			return is_["id"]
	return ""

# The walkable test for the ground layer (tier 0): island circles + bridge capsules
# + the element routes their owner may use + any grown seed vines (bitmask).
static func on_ground(x: float, z: float, el: String, vines: int = 0, pad: float = 0.0) -> bool:
	for is_ in ISLES:
		var dx: float = x - is_["x"]
		var dz: float = z - is_["z"]
		var rr: float = is_["r"] + pad
		if dx * dx + dz * dz <= rr * rr:
			return true
	for b in BRIDGES:
		if _on_seg(x, z, b, pad):
			return true
	if _on_seg(x, z, STREAM, pad):
		return true
	if el == "grass" and _on_seg(x, z, VINE, pad):
		return true
	for i in SEEDS.size():
		if (vines & (1 << i)) != 0 and _on_seg(x, z, SEEDS[i], pad):
			return true
	return false

static func on_stream(x: float, z: float) -> bool:
	if not _on_seg(x, z, STREAM):
		return false
	return node_of(x, z) == ""

# ------------------------------------------------------------------ the spire
static func ramp_ang(k: int) -> float:
	return fposmod(SPIRE_RAMP_A0 + SPIRE_RAMP_STEP * float(k), 360.0)

# the wall you face on tier k (0..4): the next drum's outer radius. Tier 5 has none.
static func tier_inner(k: int) -> float:
	return float(SPIRE_OUTER_R[k]) if k < SPIRE_TIERS else 0.0

static func tier_outer(k: int) -> float:
	return HEART_R if k == 0 else float(SPIRE_OUTER_R[k - 1])

static func band_mid(k: int) -> float:
	if k >= SPIRE_TIERS:
		return 2.0
	return (tier_inner(k) + tier_outer(k)) * 0.5

static func pad_ang(k: int, el: String) -> float:
	return fposmod(ramp_ang(k) + 180.0 + float(SHORTCUT_OFFSETS[el]), 360.0)

static func pad_pos(k: int, el: String) -> Vector2:
	return pol(pad_ang(k, el), tier_inner(k) + SHORTCUT_WALL_GAP)

static func in_sector(ang: float, k: int) -> bool:
	return absf(ang_diff(ang, ramp_ang(k))) <= SPIRE_RAMP_ARC * 0.5

# Inside the stair wedge that climbs from tier k to k+1?
static func in_wedge(k: int, x: float, z: float) -> bool:
	if k < 0 or k >= SPIRE_TIERS:
		return false
	var r := sqrt(x * x + z * z)
	var R := tier_inner(k)
	return r >= R and r <= R + float(SPIRE_RAMP_RUN[k]) and in_sector(ang_of(x, z), k)

# Standing height for a point on tier k (the stair wedge slopes up toward the wall).
static func height_at(k: int, x: float, z: float) -> float:
	var base := float(k) * SPIRE_TIER_H
	if k >= SPIRE_TIERS:
		return base
	var r := sqrt(x * x + z * z)
	var R := tier_inner(k)
	var run := float(SPIRE_RAMP_RUN[k])
	if r <= R + run and r >= R - 0.05 and in_sector(ang_of(x, z), k):
		return base + SPIRE_TIER_H * clampf((R + run - r) / run, 0.0, 1.0)
	return base

# The tier a free-floating thing (a smog cloud) rides at a given radius, capped.
static func tier_for_radius(r: float, max_tier: int) -> int:
	var t := 0
	for k in SPIRE_TIERS:
		if r < float(SPIRE_OUTER_R[k]):
			t = k + 1
	return mini(t, max_tier)

# ------------------------------------------------------------------ navigation
# Dijkstra over the isle graph. `starts` = [{ id, c }]. Returns { "D": {id: cost},
# "P": {id: { from, e } | null} }. Costs are metres-ish; routes an element cannot
# use are skipped, swallowed isles are heavily penalised.
static func edge_cost(e: Dictionary, el: String, from: String, smog_target: float) -> float:
	var A: Dictionary = NODES[e["a"]]
	var B: Dictionary = NODES[e["b"]]
	var d := Vector2(A["x"] - B["x"], A["z"] - B["z"]).length()
	match String(e["kind"]):
		"vine":
			if el != "grass":
				return INF
		"stream":
			d *= (0.5 if el == "water" else 1.8)
		"vent":
			if el != "fire":
				return INF
			d = 34.0            # a 1.4 s fling + the walk to the pad
		"seed":
			if el != "grass":
				return INF
			d += 24.0           # the 1.5 s grow
	var to: Dictionary = B if from == String(e["a"]) else A
	if String(to["id"]) != "heart" and float(to["d"]) + float(to["r"]) * 0.3 > smog_target:
		d += 90.0
	return d

static func dijkstra(starts: Array, el: String, smog_target: float) -> Dictionary:
	var D := {}
	var P := {}
	var done := {}
	for id in NODES:
		D[id] = INF
	for s in starts:
		if float(s["c"]) < float(D[s["id"]]):
			D[s["id"]] = float(s["c"])
			P[s["id"]] = null
	while true:
		var u := ""
		var bu := INF
		for id in NODES:
			if not done.has(id) and float(D[id]) < bu:
				bu = float(D[id]); u = id
		if u == "":
			break
		done[u] = true
		for e in EDGES:
			var v := ""
			if String(e["a"]) == u:
				v = e["b"]
			elif String(e["b"]) == u:
				v = e["a"]
			if v == "":
				continue
			var c: float = bu + edge_cost(e, el, u, smog_target)
			if c < float(D[v]):
				D[v] = c
				P[v] = { "from": u, "e": e }
	return { "D": D, "P": P }

# Where a bridge/route from isle `id` toward isle `toward` meets `id`'s ground.
static func port_on(id: String, toward: String, frac: float = 0.72) -> Vector2:
	var A: Dictionary = NODES[id]
	var B: Dictionary = NODES[toward]
	var d := Vector2(B["x"] - A["x"], B["z"] - A["z"])
	if id == "heart":
		return d.normalized() * 23.6
	return Vector2(A["x"], A["z"]) + d.normalized() * (float(A["r"]) * frac)

# The smog sea: safe radius after `elapsed` seconds of the round.
static func smog_target(idx: int, rise_r: Array) -> float:
	return 190.0 if idx <= 0 else float(rise_r[mini(idx, rise_r.size()) - 1])
