class_name WorldBuilder
extends Object
# Builds the medieval castle world and registers collision data (obstacles /
# rects / caves) back onto the Game node. Each element lives in its own huge
# European castle: a crenellated curtain wall with corner towers and a gatehouse,
# an element-themed garden courtyard, and a great keep whose entrance hall,
# bedchambers, wall portraits and treasury are all walkable. The wilds between
# the castles hold the dungeon yard (cages), hamlets, the river — and all the
# roaming CO₂ / O₂.

const HOUSE_COLORS := [0xf1e9d6, 0xefe4cc, 0xe8dcc4, 0xf3ecd9, 0xe4d5b8]
const ROOF_COLORS := [0x8a5a44, 0x7a5a4c, 0x5e5863, 0x9c6a4e]
const CYPRESS_COLORS := [0x3d5244, 0x44604f, 0x35463a]
const CASTLE_TINTS := { "fire": 0xd8907a, "water": 0x8aa8cc, "grass": 0x8cb896 }

# ------------------------------------------------------------ castle framing
# Gate is an axis-aligned unit vector pointing from the castle centre toward its
# gatehouse (always facing the middle of the map). All castle geometry is laid
# out in local (u, v) coordinates: u along the gate direction, v perpendicular.
const CASTLES := {
	"fire": { "x": -128.0, "z": -122.0, "gate": Vector2(1, 0) },
	"water": { "x": 132.0, "z": 0.0, "gate": Vector2(-1, 0) },
	"grass": { "x": -128.0, "z": 122.0, "gate": Vector2(1, 0) },
}
const WALL_HALF := 34.0      # curtain wall half-size (the walled grounds are 68×68)
const WALL_H := 6.0
const WALL_T := 1.6
const GATE_HALF := 6.0       # gate opening half-width (12 wide → clans/twins path through)
const KEEP_HU := 11.0        # keep half-depth (along the gate axis)
const KEEP_HV := 13.0        # keep half-width
const KEEP_H := 7.5          # full keep height (upper half is see-through "storybook" stone)
const KEEP_SOLID := 3.2      # solid stone below this height; tinted glass-stone above
const KEEP_DOOR_HALF := 4.0  # keep door half-width (8 wide)
const HOME_R := 6.0          # the sanctum circle at the keep's heart = the home "cave"

# ---- the home tower: a walkable 6-floor house rising from the keep's centre.
# Only its owner can reach it (the sanctum circle walls everyone else out), and
# game.gd switches to a first-person view inside. One spiral turn = one floor.
const TOWER_R := 6.0         # outer wall radius (matches the sanctum circle)
const TOWER_IN_R := 5.15     # interior walk boundary
const TOWER_FLOOR_H := 3.6
const TOWER_LEVELS := 3      # walkable levels 0..3, where 3 is the roof terrace
const TOWER_DOOR_HALF := 0.45  # doorway half-angle (≈4.6u wide at the wall)

static var _root: Node3D
static var _game

static func build(game) -> void:
	_game = game
	_root = game.world_root
	_batches.clear()   # world can be rebuilt — never carry transforms across builds
	_ground_and_walls()
	_river_and_bridges()
	for el in ["fire", "water", "grass"]:
		_build_castle(el)
	# neutral wilderness caves — rough rock shelters out between the castles
	add_cave(-85, 0, "")
	add_cave(60, -120, "")
	add_cave(75, 90, "")
	add_cave(-20, -160, "")
	_build_dungeon_yard()
	_build_hamlet(-48, -66)
	_build_hamlet(86, -96)
	_scatter()
	_build_wind_leaves()
	_flush_batches()

# --------------------------------------------------- registration helpers
static func _obstacle(x: float, z: float, r: float) -> void:
	_game.obstacles.append({ "x": x, "z": z, "r": r })

static func _rect(x: float, z: float, hw: float, hd: float) -> void:
	_game.rects.append({ "x": x, "z": z, "hw": hw, "hd": hd })

static func _add(n: Node3D) -> void:
	_root.add_child(n)

# ------------------------------------------------ static-geometry batching
# Repeated static props (wall slabs, merlons, stair steps, floor plates, tower
# drums, flowers, …) accumulate per (mesh, material) and are flushed into one
# MultiMeshInstance3D each at the end of build() — hundreds of identical draw
# calls collapse into a few. Transforms are GLOBAL (relative to world_root).
# Only use this for geometry that is never animated, toggled or repositioned.
# Transparent materials keep their own MeshInstance3D so alpha sorting stays
# exactly as before.
static var _batches: Dictionary = {}

static func _batch_mesh(mesh: Mesh, mat: Material, xf: Transform3D) -> void:
	var bm := mat as BaseMaterial3D
	if bm != null and bm.transparency != BaseMaterial3D.TRANSPARENCY_DISABLED:
		var m := MeshLib.mi(mesh, mat)
		m.transform = xf
		_add(m)
		return
	var key := "%d:%d" % [mesh.get_instance_id(), mat.get_instance_id()]
	if not _batches.has(key):
		_batches[key] = { "mesh": mesh, "mat": mat, "xfs": [] }
	(_batches[key]["xfs"] as Array).append(xf)

static func _batch_box(w: float, h: float, d: float, mat: Material, xf: Transform3D) -> void:
	_batch_mesh(MeshLib.box_mesh(w, h, d), mat, xf)

static func _flush_batches() -> void:
	for key in _batches:
		var b: Dictionary = _batches[key]
		var xfs: Array = b["xfs"]
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = b["mesh"]
		mm.instance_count = xfs.size()
		for i in xfs.size():
			mm.set_instance_transform(i, xfs[i])
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		mmi.material_override = b["mat"]
		_add(mmi)
	_batches.clear()

static func _pick_house() -> Color:
	return MeshLib.rgb(HOUSE_COLORS[randi() % HOUSE_COLORS.size()])

static func _glass_or_lit(c: Color, alpha: float) -> Material:
	if _game.lite:
		return MeshLib.lit_mat(c)
	return MeshLib.glass_stone_mat(c, alpha)

# ------------------------------------------- castle local-frame helpers
# Local → world for a point (u along the gate axis, v across it).
static func _lw(cd: Dictionary, u: float, v: float) -> Vector2:
	var g: Vector2 = cd["gate"]
	return Vector2(cd["x"] + g.x * u - g.y * v, cd["z"] + g.y * u + g.x * v)

# Local → world for a direction.
static func _ld(cd: Dictionary, du: float, dv: float) -> Vector2:
	var g: Vector2 = cd["gate"]
	return Vector2(g.x * du - g.y * dv, g.y * du + g.x * dv)

# Local box extents (lu × lv) → world axis-aligned extents (x × z).
static func _lsz(cd: Dictionary, lu: float, lv: float) -> Vector2:
	return Vector2(lu, lv) if absf((cd["gate"] as Vector2).x) > 0.5 else Vector2(lv, lu)

# An axis-aligned wall slab placed in castle-local coords. y0 == 0 → grounded
# and registered as blocking; y0 > 0 → floating decoration (lintels, glass
# storeys) with no extra collision of its own.
static func _cwall(cd: Dictionary, u: float, v: float, lu: float, lv: float, h: float, mat: Material, y0: float = 0.0) -> void:
	var w := _lw(cd, u, v)
	var s := _lsz(cd, lu, lv)
	_batch_box(s.x, h, s.y, mat, Transform3D(Basis(), Vector3(w.x, y0 + h / 2.0, w.y)))
	if y0 == 0.0:
		_rect(w.x, w.y, s.x / 2.0, s.y / 2.0)

# Place a prebuilt node at local (u, v), turning its +Z toward local dir (du, dv).
static func _place(cd: Dictionary, node: Node3D, u: float, v: float, du: float, dv: float, y: float = 0.0) -> void:
	var w := _lw(cd, u, v)
	var d := _ld(cd, du, dv)
	node.position = Vector3(w.x, y, w.y)
	node.rotation.y = atan2(d.x, d.y)
	_add(node)

# ------------------------------------------------------- ground / boundary
static func _ground_and_walls() -> void:
	var A: float = _game.ARENA
	var g := PlaneMesh.new()
	g.size = Vector2(A * 2 + 40, A * 2 + 40)
	_add(MeshLib.mi(g, MeshLib.lit_mat(MeshLib.rgb(0xd9e6d4))))   # pale meadow
	var wall_mat := MeshLib.lit_mat(MeshLib.rgb(0xb6bac8))
	var walls := [
		[0.0, -A - 1.5, A * 2 + 6, 3.0], [0.0, A + 1.5, A * 2 + 6, 3.0],
		[-A - 1.5, 0.0, 3.0, A * 2 + 6], [A + 1.5, 0.0, 3.0, A * 2 + 6],
	]
	for w in walls:
		_add_box_wall(w[0], w[1], w[2], w[3], 4.0, wall_mat)

static func _add_box_wall(x: float, z: float, w: float, d: float, h: float, mat: Material) -> void:
	_batch_box(w, h, d, mat, Transform3D(Basis(), Vector3(x, h / 2.0, z)))
	_rect(x, z, w / 2.0, d / 2.0)

# --------------------------------------------------------- house + props
static func _add_house(x: float, z: float, w: float, d: float, h: float, color: Color, win_side: String = "pz") -> void:
	_add_box_wall(x, z, w, d, h, MeshLib.lit_mat(color))
	# gabled roof
	var prism := PrismMesh.new()
	prism.size = Vector3(w + 1.0, h * 0.5, d + 1.0)
	var roof := MeshLib.mi(prism, MeshLib.lit_mat(MeshLib.rgb(ROOF_COLORS[randi() % ROOF_COLORS.size()])))
	roof.position = Vector3(x, h + h * 0.25, z)
	_add(roof)
	if randf() < 0.5:
		var ch := MeshLib.box(0.7, 1.1, 0.7, MeshLib.lit_mat(MeshLib.rgb(0x8a7466)))
		ch.position = Vector3(x + (randf() - 0.5) * w * 0.35, h + h * 0.32, z + (randf() - 0.5) * d * 0.3)
		_add(ch)
	# timber-framed windows (warm candlelight)
	var on_z := win_side == "pz" or win_side == "nz"
	var span := w if on_z else d
	var sgn := 1.0 if (win_side == "pz" or win_side == "px") else -1.0
	var n := 2 if span > 8.5 else 1
	var win_mat := MeshLib.unlit_mat(MeshLib.rgb(0xf7e9b8))
	for i in n:
		var off := 0.0
		if n == 2:
			off = -span * 0.22 if i == 0 else span * 0.22
		var win := MeshLib.box(1.8 if on_z else 0.12, 1.4, 0.12 if on_z else 1.8, win_mat)
		if on_z:
			win.position = Vector3(x + off, h * 0.52, z + sgn * (d / 2.0 + 0.07))
		else:
			win.position = Vector3(x + sgn * (w / 2.0 + 0.07), h * 0.52, z + off)
		_add(win)

static func _add_cypress(x: float, z: float, scale: float = 1.0) -> void:
	var s := scale * (0.8 + randf() * 0.5)
	var grp := Node3D.new()
	var trunk := MeshLib.cyl(0.09 * s, 0.13 * s, 0.7 * s, MeshLib.lit_mat(MeshLib.rgb(0x8a7866)))
	trunk.position.y = 0.35 * s
	var body := MeshLib.sphere(0.75 * s, MeshLib.lit_mat(MeshLib.rgb(CYPRESS_COLORS[randi() % CYPRESS_COLORS.size()])), 14, 12)
	body.scale = Vector3(1, 2.9, 1)
	body.position.y = 0.6 * s + 2.0 * s
	grp.add_child(trunk)
	grp.add_child(body)
	grp.position = Vector3(x, 0, z)
	_add(grp)
	_obstacle(x, z, 0.8 * s)

static func _add_street(x: float, z: float, w: float, d: float, col: int = 0xcfc8b4) -> void:
	var p := PlaneMesh.new()
	p.size = Vector2(w, d)
	var s := MeshLib.mi(p, MeshLib.lit_mat(MeshLib.rgb(col)))
	s.position = Vector3(x, 0.02, z)
	_add(s)

# ------------------------------------------------------------- the river
static func _river_and_bridges() -> void:
	var A: float = _game.ARENA
	var x1: float = _game.RIVER_X1
	var x2: float = _game.RIVER_X2
	var plane := PlaneMesh.new()
	plane.size = Vector2(x2 - x1, A * 2 + 6)
	var wmat := StandardMaterial3D.new()
	wmat.albedo_color = MeshLib.rgb(0xc4d6ef)
	wmat.metallic = 0.2
	wmat.roughness = 0.06
	wmat.metallic_specular = 0.9
	var water := MeshLib.mi(plane, wmat)
	water.position = Vector3((x1 + x2) / 2.0, 0.05, 0)
	_add(water)
	# bright curbs
	var bank_mat := MeshLib.lit_mat(MeshLib.rgb(0xfafbfe))
	for x in [x1 - 0.6, x2 + 0.6]:
		var b := MeshLib.box(1.2, 0.3, A * 2 + 6, bank_mat)
		b.position = Vector3(x, 0.12, 0)
		_add(b)
	# bridges
	var wood := MeshLib.lit_mat(MeshLib.rgb(0xc0a78f))
	var rail_mat := MeshLib.lit_mat(MeshLib.rgb(0x97816a))
	for br in _game.BRIDGES:
		var half: float = br["half"]
		var bz: float = br["z"]
		var deck := MeshLib.box(x2 - x1 + 4, 0.5, half * 2, wood)
		deck.position = Vector3((x1 + x2) / 2.0, 0.3, bz)
		_add(deck)
		for sgn in [-1, 1]:
			var rail := MeshLib.box(x2 - x1 + 4, 0.8, 0.25, rail_mat)
			rail.position = Vector3((x1 + x2) / 2.0, 0.95, bz + sgn * (half - 0.15))
			_add(rail)

# ------------------------------------------------------- neutral caves
# Rough rock shelters in the wilds (the castles replace the old element caves).
static func add_cave(cx: float, cz: float, owner: String) -> void:
	var r := 4.8
	var open_angle := atan2(-cz, -cx)
	var rock_mat: Material = MeshLib.lit_mat(MeshLib.rgb(CASTLE_TINTS[owner])) if owner != "" else MeshLib.lit_mat(MeshLib.rgb(0xbcc0cc))
	var segs := 12
	for i in segs:
		var a := open_angle + PI / 4.0 + i * (PI * 1.5 / (segs - 1))
		var x := cx + cos(a) * r
		var z := cz + sin(a) * r
		var rot := Vector3((randf() - 0.5) * 0.3, randf() * PI, (randf() - 0.5) * 0.3)
		_batch_mesh(MeshLib.sphere_mesh(1.5, 6, 4), rock_mat,
			Transform3D(Basis.from_euler(rot) * Basis.from_scale(Vector3(1, 1.7, 1)), Vector3(x, 1.2, z)))
		_obstacle(x, z, 1.25)
	# semi-glass / semi-stone roof so a character sheltering inside stays visible from above
	var roof_col: Color = MeshLib.rgb(CASTLE_TINTS[owner]) if owner != "" else MeshLib.rgb(0xbcc0cc)
	var roof := MeshLib.cyl(r + 1.4, r + 0.5, 1.2, _glass_or_lit(roof_col, 0.42), 14)
	roof.position = Vector3(cx, 3.6, cz)
	_add(roof)
	var glow_color: Color = MeshLib.rgb(_game.ELEMENTS[owner]["color"]) if owner != "" else MeshLib.rgb(0xf0c060)
	var glow := MeshLib.disc(r - 0.8, MeshLib.unlit_mat(glow_color, 0.16 if owner != "" else 0.09), 22)
	glow.position = Vector3(cx, 0.08, cz)
	_add(glow)
	var radar_fill: Color = MeshLib.rgb(_game.ELEMENTS[owner]["color"]) if owner != "" else MeshLib.rgb(0xe0a93c)
	var cave := { "x": cx, "z": cz, "r": r, "owner": owner, "openAngle": open_angle, "radarFill": radar_fill }
	_game.caves.append(cave)
	if owner != "":
		_game.cave_by_owner[owner] = cave

# A tall glowing pillar in the element's colour so the castle keeps read from
# anywhere on the big map (same trick the old home caves used).
static func _add_beam(x: float, z: float, col: Color) -> void:
	var bm := CylinderMesh.new()
	bm.top_radius = 0.4; bm.bottom_radius = 0.4; bm.height = 60.0
	bm.radial_segments = 8; bm.cap_top = false; bm.cap_bottom = false
	var beam_mat := MeshLib.unlit_mat(col, 0.28)
	beam_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	var beam := MeshLib.mi(bm, beam_mat)
	beam.position = Vector3(x, 30, z)
	_add(beam)

# ================================================================= castles
static func _build_castle(el: String) -> void:
	var cd: Dictionary = CASTLES[el]
	var col: Color = MeshLib.rgb(_game.ELEMENTS[el]["color"])
	var tint: Color = MeshLib.rgb(CASTLE_TINTS[el])
	var stone := MeshLib.lit_mat(MeshLib.rgb(0xb9bcc8))
	var stone_dark := MeshLib.lit_mat(MeshLib.rgb(0x9fa3b2))
	# everything inside the curtain wall counts as castle grounds — the wilds
	# (molecule spawns, wander targets, black stones, scatter) stay out of it
	_game.castle_grounds.append({ "x": cd["x"], "z": cd["z"], "r": WALL_HALF * 1.45 })

	# courtyard ground — each element gets its own garden floor
	var yard_tints := { "fire": 0xcdb4a4, "water": 0xc4d2dc, "grass": 0xc2d8b0 }
	var yard_p := PlaneMesh.new()
	yard_p.size = Vector2(WALL_HALF * 2 - 2, WALL_HALF * 2 - 2)
	var yard := MeshLib.mi(yard_p, MeshLib.lit_mat(MeshLib.rgb(yard_tints[el])))
	yard.position = Vector3(cd["x"], 0.03, cd["z"])
	_add(yard)

	_curtain_wall(cd, stone, stone_dark, col)
	_build_garden(el, cd, col)
	_build_home_shrine(el, cd, col)
	_build_keep(el, cd, col, tint, stone, stone_dark)

	# clan hall + training pad live in the back corners of the courtyard garden
	var hall_w := _lw(cd, -24.0, 20.0)
	var pad_w := _lw(cd, -24.0, -20.0)
	_build_clan_hall(hall_w.x, hall_w.y, col)
	_build_training_pad(pad_w.x, pad_w.y, col)
	_game.clan_hall_by_owner[el] = { "x": hall_w.x, "z": hall_w.y, "r": 3.2 }
	_game.train_pad_by_owner[el] = { "x": pad_w.x, "z": pad_w.y, "r": 2.6 }

	# a dirt road from the gate out into the wilds
	var road_c := _lw(cd, WALL_HALF + 13.0, 0.0)
	var road_s := _lsz(cd, 26.0, 6.0)
	_add_street(road_c.x, road_c.y, road_s.x, road_s.y)

# ------------------------------------------------ curtain wall + towers + gate
static func _curtain_wall(cd: Dictionary, stone: Material, stone_dark: Material, col: Color) -> void:
	var W := WALL_HALF
	var seg := W - GATE_HALF                       # gate-wall segment length
	# gate wall (+u) — two segments flanking the opening
	_cwall(cd, W, -(GATE_HALF + seg / 2.0), WALL_T, seg, WALL_H, stone)
	_cwall(cd, W, GATE_HALF + seg / 2.0, WALL_T, seg, WALL_H, stone)
	# back and side walls — full runs
	_cwall(cd, -W, 0.0, WALL_T, W * 2, WALL_H, stone)
	_cwall(cd, 0.0, -W, W * 2, WALL_T, WALL_H, stone)
	_cwall(cd, 0.0, W, W * 2, WALL_T, WALL_H, stone)
	# gate arch over the opening (clearance below, crown above)
	_cwall(cd, W, 0.0, WALL_T + 0.6, GATE_HALF * 2 + 2.4, WALL_H - 4.6, stone_dark, 4.6)
	# crenellated battlements (skip on lite devices — pure decoration)
	if not _game.lite:
		_merlons(cd, stone_dark)
	# corner towers with element-coloured cone roofs + flags
	for su in [-1.0, 1.0]:
		for sv in [-1.0, 1.0]:
			var w := _lw(cd, su * W, sv * W)
			_add_tower(w.x, w.y, 4.2, 10.0, stone, col, true)
	# mid-wall towers on the three gateless sides
	for t in [[-W, 0.0], [0.0, -W], [0.0, W]]:
		var w := _lw(cd, t[0], t[1])
		_add_tower(w.x, w.y, 3.0, 8.5, stone, col, false)
	# gatehouse — twin drum towers hugging the opening
	for sv in [-1.0, 1.0]:
		var w := _lw(cd, W, sv * (GATE_HALF + 2.6))
		_add_tower(w.x, w.y, 2.6, 9.0, stone, col, true)
	# long banners either side of the gate on the inner wall face
	for sv in [-1.0, 1.0]:
		var b := MeshLib.box(0.12, 3.4, 1.3, MeshLib.unlit_mat(col))
		var w := _lw(cd, W - WALL_T, sv * (GATE_HALF + 5.5))
		b.position = Vector3(w.x, WALL_H - 2.2, w.y)
		var d := _ld(cd, 1.0, 0.0)
		b.rotation.y = atan2(d.x, d.y) + PI / 2.0
		_add(b)

static func _merlons(cd: Dictionary, mat: Material) -> void:
	var W := WALL_HALF
	var step := 4.0
	var n := int((W * 2) / step)
	for i in n + 1:
		var off := -W + i * step
		if absf(off) > GATE_HALF + 1.0:            # leave the gate opening clear
			_cwall(cd, W, off, WALL_T + 0.3, 1.5, 0.9, mat, WALL_H)
		_cwall(cd, -W, off, WALL_T + 0.3, 1.5, 0.9, mat, WALL_H)
		_cwall(cd, off, -W, 1.5, WALL_T + 0.3, 0.9, mat, WALL_H)
		_cwall(cd, off, W, 1.5, WALL_T + 0.3, 0.9, mat, WALL_H)

static func _add_tower(x: float, z: float, r: float, h: float, stone: Material, col: Color, flag: bool) -> void:
	_batch_mesh(MeshLib.cyl_mesh(r, r * 1.12, h, 12), stone, Transform3D(Basis(), Vector3(x, h / 2.0, z)))
	_batch_mesh(MeshLib.cyl_mesh(r + 0.4, r + 0.4, 0.6, 12), stone, Transform3D(Basis(), Vector3(x, h - 0.3, z)))
	_batch_mesh(MeshLib.cyl_mesh(0.0, r + 0.5, r * 0.9, 12), MeshLib.lit_mat(col.darkened(0.25)),
		Transform3D(Basis(), Vector3(x, h + r * 0.45, z)))
	if flag:
		_batch_mesh(MeshLib.cyl_mesh(0.06, 0.06, 2.2, 5), MeshLib.lit_mat(MeshLib.rgb(0x97816a)),
			Transform3D(Basis(), Vector3(x, h + r * 0.9 + 1.1, z)))
		_batch_box(1.2, 0.7, 0.07, MeshLib.unlit_mat(col),
			Transform3D(Basis(), Vector3(x + 0.65, h + r * 0.9 + 1.8, z)))
	_obstacle(x, z, r + 0.2)

static func _cone(r: float, h: float, seg: int) -> CylinderMesh:
	var c := CylinderMesh.new()
	c.top_radius = 0.0; c.bottom_radius = r; c.height = h; c.radial_segments = seg; c.rings = 1
	return c

# --------------------------------------------------------------- the keep
static func _build_keep(el: String, cd: Dictionary, col: Color, tint: Color, stone: Material, stone_dark: Material) -> void:
	var HU := KEEP_HU
	var HV := KEEP_HV
	var upper := _glass_or_lit(tint, 0.35)
	var glass_h := KEEP_H - KEEP_SOLID

	# interior stone floor + entrance steps
	var fl := PlaneMesh.new()
	fl.size = _lsz(cd, HU * 2 - 0.6, HV * 2 - 0.6)
	var fmi := MeshLib.mi(fl, MeshLib.lit_mat(MeshLib.rgb(0xd8d2c2)))
	fmi.position = Vector3(cd["x"], 0.06, cd["z"])
	_add(fmi)
	_cwall(cd, HU + 1.2, 0.0, 2.4, KEEP_DOOR_HALF * 2 + 1.6, 0.22, stone_dark, 0.001)

	# --- outer walls: solid stone below, tinted glass-stone storey above so the
	# chase camera (and the top-down command view) can always see inside
	var side_seg := HV - KEEP_DOOR_HALF
	_cwall(cd, HU, -(KEEP_DOOR_HALF + side_seg / 2.0), 0.9, side_seg, KEEP_SOLID, stone)   # front, left of door
	_cwall(cd, HU, KEEP_DOOR_HALF + side_seg / 2.0, 0.9, side_seg, KEEP_SOLID, stone)      # front, right of door
	_cwall(cd, -HU, 0.0, 0.9, HV * 2, KEEP_SOLID, stone)                                   # back
	_cwall(cd, 0.0, -HV, HU * 2, 0.9, KEEP_SOLID, stone)                                   # sides
	_cwall(cd, 0.0, HV, HU * 2, 0.9, KEEP_SOLID, stone)
	_cwall(cd, HU, 0.0, 0.9, HV * 2, glass_h, upper, KEEP_SOLID)                           # glass storey (door is below)
	_cwall(cd, -HU, 0.0, 0.9, HV * 2, glass_h, upper, KEEP_SOLID)
	_cwall(cd, 0.0, -HV, HU * 2, 0.9, glass_h, upper, KEEP_SOLID)
	_cwall(cd, 0.0, HV, HU * 2, 0.9, glass_h, upper, KEEP_SOLID)
	# see-through roof slab + banner over the door. Built as four slabs leaving a
	# hole where the home tower rises through — one big slab would slice through
	# the tower's bedchamber storey at knee height.
	var roof_mat := _glass_or_lit(tint, 0.4)
	var hole := TOWER_R + 0.2
	for sv in [-1.0, 1.0]:
		_cwall(cd, 0.0, sv * (hole + HV + 0.75) / 2.0, HU * 2 + 1.5, HV + 0.75 - hole, 0.45, roof_mat, KEEP_H + 0.1)
	for su in [-1.0, 1.0]:
		_cwall(cd, su * (hole + HU + 0.75) / 2.0, 0.0, HU + 0.75 - hole, hole * 2, 0.45, roof_mat, KEEP_H + 0.1)
	var door_banner := MeshLib.box(2.0, 2.6, 0.14, MeshLib.unlit_mat(col))
	_place(cd, door_banner, HU + 0.6, 0.0, 1.0, 0.0, KEEP_SOLID + 1.2)
	# small corner turrets
	for su in [-1.0, 1.0]:
		for sv in [-1.0, 1.0]:
			var w := _lw(cd, su * HU, sv * HV)
			_add_tower(w.x, w.y, 1.6, KEEP_H + 2.0, stone, col, false)

	# --- interior partitions (chest-high so the camera reads the rooms) ---
	# side walls toward the bedchambers; the tower's curved wall closes the middle
	_cwall(cd, -3.0, -10.9, 0.6, 4.25, 3.0, stone_dark)
	_cwall(cd, -3.0, 10.9, 0.6, 4.25, 3.0, stone_dark)
	# spine wall splitting the back into two bedchambers (stops at the tower)
	_cwall(cd, -8.6, 0.0, 4.8, 0.6, 3.0, stone_dark)

	# --- the sanctum: home glow + beacon (this circle is the "cave" — safe for
	# its element, walled to everyone else, and where the rescued twin must reach).
	# The HOME TOWER rises from this exact circle — its ground hall IS home.
	var w0 := _lw(cd, 0.0, 0.0)
	var glow := MeshLib.disc(HOME_R - 1.6, MeshLib.unlit_mat(col, 0.18), 22)
	glow.position = Vector3(w0.x, 0.1, w0.y)
	_add(glow)
	_add_beam(w0.x, w0.y, col)
	var g: Vector2 = cd["gate"]
	var cave := { "x": w0.x, "z": w0.y, "r": HOME_R, "owner": el,
		"openAngle": atan2(g.y, g.x), "radarFill": col }
	_game.caves.append(cave)
	_game.cave_by_owner[el] = cave
	_build_tower(el, cd, col, tint, stone, stone_dark)

	# --- great hall furnishing ---
	# carpet from the keep door to the tower door
	var carpet := MeshLib.box(_lsz(cd, 5.0, 3.4).x, 0.05, _lsz(cd, 5.0, 3.4).y, MeshLib.unlit_mat(col, 0.45))
	var cw := _lw(cd, 8.5, 0.0)
	carpet.position = Vector3(cw.x, 0.1, cw.y)
	_add(carpet)
	# treasury nook: the dais where a raiding rival finds ITS key (game.gd
	# reads key_spot_by_owner and parks each element's key in its predator's keep)
	var ped_w := _add_key_dais(cd, 6.0, -9.5, col)
	_game.key_spot_by_owner[el] = Vector3(ped_w.x, 0.0, ped_w.y)
	_add_chest(cd, 9.2, -11.6, col)
	_add_chest(cd, 3.4, -11.8, col)
	# wall torches
	for t in [[7.0, -12.2, 0.0, 1.0], [7.0, 12.2, 0.0, -1.0], [-8.0, -12.2, 0.0, 1.0], [-8.0, 12.2, 0.0, -1.0]]:
		_add_torch(cd, t[0], t[1])

	# --- portraits: framed images of THIS castle's element character ---
	_add_portrait(el, cd, 3.5, HV - 0.65, 0.0, -1.0, 0.0, "clan")     # great hall — the king and his clan
	_add_portrait(el, cd, 3.5, -(HV - 0.65), 0.0, 1.0, 0.0, "sword")  # great hall — at war with its predator
	_add_portrait(el, cd, -(HU - 0.65), 6.5, 1.0, 0.0, 0.0, "crown")  # bedchambers — the crowned ruler
	_add_portrait(el, cd, -(HU - 0.65), -6.5, 1.0, 0.0, 0.0, "heart") # bedchambers — in love

	# --- bedchambers ---
	# north room (v > 0): two beds, heads against the back wall
	_add_bed(cd, -9.0, 3.6, col)
	_add_bed(cd, -9.0, 9.4, col)
	# south room (v < 0): one bed + a candle table
	_add_bed(cd, -9.0, -8.8, col)
	_add_table(cd, -8.8, -4.2)
	# rugs
	for rv in [6.5, -6.5]:
		var rug := MeshLib.disc(1.7, MeshLib.unlit_mat(col, 0.22), 16)
		var rw := _lw(cd, -5.6, rv)
		rug.position = Vector3(rw.x, 0.09, rw.y)
		_add(rug)

# ------------------------------------------------------------ the home tower
# Position on the tower's own polar grid: `ang` is the local angle measured
# from the door direction, `rr` the distance from the tower centre.
static func _tw(cd: Dictionary, rr: float, ang: float) -> Vector2:
	return _lw(cd, cos(ang) * rr, sin(ang) * rr)

# World yaw of the door direction (+u); local angle a sits at door_ang + a.
static func _door_ang(cd: Dictionary) -> float:
	var g: Vector2 = cd["gate"]
	return atan2(g.y, g.x)

# Place a node at polar (rr, ang), y0 up. face_in: +Z toward the tower centre
# (furniture backed against the curved wall); otherwise +Z runs tangentially.
static func _tower_place(cd: Dictionary, node: Node3D, rr: float, ang: float, face_in: bool, y0: float = 0.0) -> Vector2:
	var w := _tw(cd, rr, ang)
	var wa := _door_ang(cd) + ang
	node.position = Vector3(w.x, y0, w.y)
	node.rotation.y = atan2(-cos(wa), -sin(wa)) if face_in else -wa
	_add(node)
	return w

# The same placement as _tower_place, but as a global Transform3D for batching.
static func _tower_xf(cd: Dictionary, rr: float, ang: float, face_in: bool, y0: float = 0.0) -> Transform3D:
	var w := _tw(cd, rr, ang)
	var wa := _door_ang(cd) + ang
	var yaw := atan2(-cos(wa), -sin(wa)) if face_in else -wa
	return Transform3D(Basis(Vector3.UP, yaw), Vector3(w.x, y0, w.y))

static func _build_tower(el: String, cd: Dictionary, col: Color, tint: Color, stone: Material, stone_dark: Material) -> void:
	var fh := TOWER_FLOOR_H
	var top := TOWER_LEVELS * fh
	var w0 := _lw(cd, 0.0, 0.0)
	# furniture-collision circles per level (game.gd walks the tower on these)
	var furn: Array = []
	for i in TOWER_LEVELS + 1:
		furn.append([])
	var blk := func(lvl: int, w: Vector2, r: float) -> void:
		furn[lvl].append({ "x": w.x, "z": w.y, "r": r })

	# --- interior wall material must show its inside faces (the camera lives here)
	var wall_in := StandardMaterial3D.new()
	wall_in.albedo_color = MeshLib.rgb(0xb9bcc8)
	wall_in.roughness = 1.0
	wall_in.cull_mode = BaseMaterial3D.CULL_DISABLED
	var floor_mat := MeshLib.lit_mat(MeshLib.rgb(0xcabfa8))
	var wood := MeshLib.lit_mat(MeshLib.rgb(0x7a5a3a))
	var gold := MeshLib.lit_mat(MeshLib.rgb(0xc9a23f))

	# --- ground storey: an arc of wall segments leaving the doorway open
	var segs := 18
	for i in segs:
		var a := TOWER_DOOR_HALF + (TAU - TOWER_DOOR_HALF * 2.0) * (float(i) + 0.5) / segs
		_batch_box(0.5, fh, 2.05, stone, _tower_xf(cd, TOWER_R - 0.25, a, false, fh / 2.0))
		var w := _tw(cd, TOWER_R - 0.25, a)
		_obstacle(w.x, w.y, 1.0)     # world-side collision (AI, twin, pre-entry player)
	# door jambs + lintel + a step
	for s in [-1.0, 1.0]:
		_batch_box(0.7, fh, 0.7, stone_dark, _tower_xf(cd, TOWER_R - 0.2, s * TOWER_DOOR_HALF, false, fh / 2.0))
		var wj := _tw(cd, TOWER_R - 0.2, s * TOWER_DOOR_HALF)
		_obstacle(wj.x, wj.y, 0.55)
	var lintel := MeshLib.box(0.8, 1.2, TOWER_R * 2.0 * sin(TOWER_DOOR_HALF) + 1.4, stone_dark)
	_tower_place(cd, lintel, TOWER_R - 0.2, 0.0, false, fh - 0.6)
	var step := MeshLib.box(0.22, 0.22, 3.6, stone_dark)
	_tower_place(cd, step, TOWER_R + 0.55, 0.0, false, 0.11)

	# --- upper storeys: open tubes (double-sided) + a tinted band at each floor line
	for f in range(1, TOWER_LEVELS):
		var tube := CylinderMesh.new()
		tube.top_radius = TOWER_R - 0.12
		tube.bottom_radius = TOWER_R
		tube.height = fh
		tube.radial_segments = 20
		tube.cap_top = false
		tube.cap_bottom = false
		var tm := MeshLib.mi(tube, wall_in)
		tm.position = Vector3(w0.x, f * fh + fh / 2.0, w0.y)
		_add(tm)
	for f in range(1, TOWER_LEVELS + 1):
		# an open tube — a capped cylinder would fill the whole storey with an
		# opaque disc, burying the floor plates and the glass descent hatch
		var band := CylinderMesh.new()
		band.top_radius = TOWER_R + 0.14
		band.bottom_radius = TOWER_R + 0.14
		band.height = 0.34
		band.radial_segments = 20
		band.cap_top = false
		band.cap_bottom = false
		var band_mi := MeshLib.mi(band, MeshLib.lit_mat(tint))
		band_mi.position = Vector3(w0.x, f * fh, w0.y)
		_add(band_mi)

	# --- small windows: warm slits poking through the wall (seen inside and out)
	for f in range(1, TOWER_LEVELS):
		for a in [0.55, 2.2, 4.75]:
			_batch_box(0.8, 1.15, 0.62, MeshLib.unlit_mat(MeshLib.rgb(0xfff0c0)),
				_tower_xf(cd, TOWER_R - 0.1, a, false, f * fh + 1.9))

	# --- floor plates: rings of wedges leaving the central stairwell open.
	# The wedge just clockwise of the stair seam is rendered as a SEE-THROUGH
	# panel — a window in the floor, right beside the first step down, so you can
	# tell at a glance you can descend to the level below.
	var nplate := 14
	for f in range(1, TOWER_LEVELS + 1):
		for i in nplate:
			var a := TAU * (float(i) + 0.5) / nplate
			_batch_box(2.75, 0.22, 1.98, floor_mat, _tower_xf(cd, 3.95, a, false, f * fh - 0.11))
		var rim := TorusMesh.new()
		rim.inner_radius = 2.5
		rim.outer_radius = 2.66
		var rim_mi := MeshLib.mi(rim, wood)
		rim_mi.position = Vector3(w0.x, f * fh + 0.02, w0.y)
		_add(rim_mi)

	# --- the spiral: central column + one turn of steps per floor
	var column := MeshLib.cyl(0.45, 0.55, top + 1.6, stone_dark, 12)
	column.position = Vector3(w0.x, (top + 1.6) / 2.0, w0.y)
	_add(column)
	_obstacle(w0.x, w0.y, 1.0)
	var step_mat := MeshLib.lit_mat(MeshLib.rgb(0xb2a88e))
	for i in 12 * TOWER_LEVELS:
		var a := TAU * float(i) / 12.0
		var sy := fh * float(i) / 12.0
		_batch_box(1.9, 0.14, 0.85, step_mat, _tower_xf(cd, 1.7, a, false, sy - 0.07))
	# glowing rims + down-beacons make the spiral's descent obvious on every floor
	_add_stair_guides(cd, tint)

	# --- roof terrace: parapet ring, banner pole, brazier and a stargazing scope
	for i in 16:
		var a := TAU * (float(i) + 0.5) / 16.0
		_batch_box(0.45, 1.15, 2.2, stone, _tower_xf(cd, TOWER_R - 0.22, a, false, top + 0.57))
		if i % 2 == 0:
			_batch_box(0.5, 0.5, 1.0, stone_dark, _tower_xf(cd, TOWER_R - 0.22, a, false, top + 1.4))
	var pole := MeshLib.cyl(0.07, 0.07, 3.2, MeshLib.lit_mat(MeshLib.rgb(0x97816a)), 6)
	pole.position = Vector3(w0.x, top + 2.2, w0.y)
	_add(pole)
	var rflag := MeshLib.box(1.6, 0.95, 0.08, MeshLib.unlit_mat(col))
	rflag.position = Vector3(w0.x + 0.9, top + 3.2, w0.y)
	_add(rflag)
	var rbraz_w := _tw(cd, 3.8, 2.6)
	var rbowl := MeshLib.cyl(0.6, 0.4, 0.7, MeshLib.lit_mat(MeshLib.rgb(0x4a4650)), 10)
	rbowl.position = Vector3(rbraz_w.x, top + 0.35, rbraz_w.y)
	_add(rbowl)
	var rflame := MeshLib.sphere(0.3, MeshLib.unlit_mat(MeshLib.rgb(0xffa040)), 10, 8)
	rflame.position = Vector3(rbraz_w.x, top + 0.9, rbraz_w.y)
	_add(rflame)
	blk.call(TOWER_LEVELS,rbraz_w, 0.7)
	var scope := Node3D.new()
	var barrel := MeshLib.cyl(0.14, 0.2, 1.6, gold, 8)
	barrel.rotation.x = 1.0
	barrel.position.y = 1.3
	scope.add_child(barrel)
	for si in 3:
		var leg := MeshLib.cyl(0.05, 0.05, 1.1, wood, 5)
		var la := si * TAU / 3.0
		leg.position = Vector3(cos(la) * 0.4, 0.55, sin(la) * 0.4)
		leg.rotation.z = cos(la) * 0.35
		leg.rotation.x = -sin(la) * 0.35
		scope.add_child(leg)
	var scope_w := _tower_place(cd, scope, 3.8, 5.6, true, top)
	blk.call(TOWER_LEVELS,scope_w, 0.7)
	# --- roof rune shaft: a glowing sigil laid FLAT on the roof floor; step onto
	# it and game.gd's _tower_secrets drops you straight down to the throne hall
	# (the mirror of the ground-floor secret portrait that whisks you up here).
	var rune_w := _tw(cd, 3.4, 3.0)
	var rune := MeshLib.disc(1.35, MeshLib.unlit_mat(tint.lightened(0.3), 0.55), 24)
	rune.position = Vector3(rune_w.x, top + 0.05, rune_w.y)
	_add(rune)
	var rune_ring := TorusMesh.new()
	rune_ring.inner_radius = 1.18
	rune_ring.outer_radius = 1.42
	var rune_ring_mi := MeshLib.mi(rune_ring, MeshLib.unlit_mat(col, 0.85))
	rune_ring_mi.position = Vector3(rune_w.x, top + 0.08, rune_w.y)
	_add(rune_ring_mi)
	var emblem := _mini_figure(el, 0.55)   # the element's sigil, laid face-up
	emblem.rotation.x = -PI / 2.0
	emblem.position = Vector3(rune_w.x, top + 0.12, rune_w.y)
	_add(emblem)
	var land_w := _tw(cd, 3.6, 0.0)        # landing: by the throne-hall front door
	if not _game.lite:
		_game.deco_anims.append(func(t: float) -> void:
			rune.scale = Vector3.ONE * (1.0 + sin(t * 0.004) * 0.08))

	# ================= the floors of home (0-2 + roof) =================
	# L0 — throne hall (also the sanctum the twin must reach)
	var thr_w := _add_throne(cd, 3.6, PI, col)
	blk.call(0, thr_w, 1.0)
	_obstacle(thr_w.x, thr_w.y, 0.9)
	var hearth0 := _add_hearth(cd, 4.55, 1.85, 0.0)
	blk.call(0, hearth0, 0.9)
	_obstacle(hearth0.x, hearth0.y, 0.8)
	_add_portrait(el, cd, cos(2.6) * 4.68, sin(2.6) * 4.68, -cos(2.6), -sin(2.6), 0.0, "co2")
	for ba in [0.9, 5.4]:
		var bench := MeshLib.box(2.0, 0.5, 0.6, wood)
		var wb := _tower_place(cd, bench, 4.3, ba, false, 0.25)
		blk.call(0, wb, 0.8)
		_obstacle(wb.x, wb.y, 0.7)
	# the SECRET portrait — walk into it and a hidden ladder whisks you to the roof
	_add_portrait(el, cd, cos(4.3) * 4.68, sin(4.3) * 4.68, -cos(4.3), -sin(4.3), 0.0, "key")
	var pass_w := _tw(cd, 4.3, 4.3)

	# L1 — MUSIC & LIBRARY: a piano and drifting notes share the floor with the
	# bookshelves and the sliding-shelf SECRET room.
	var piano_w := _add_piano(cd, 3.9, 5.3, fh)
	blk.call(1, piano_w, 1.5)
	var cello_w := _add_cello(cd, 4.2, 4.4, fh)
	blk.call(1, cello_w, 0.7)
	var mstool := MeshLib.cyl(0.32, 0.28, 0.6, wood, 8)
	var wms := _tower_place(cd, mstool, 2.95, 4.95, false, fh + 0.3)
	blk.call(1, wms, 0.45)
	if not _game.lite:
		for ni in 3:
			var note := Node3D.new()
			var head := MeshLib.sphere(0.13, MeshLib.unlit_mat(MeshLib.rgb(0x2a2733)), 8, 6)
			head.scale = Vector3(1.2, 0.85, 1.0)
			note.add_child(head)
			var stem := MeshLib.box(0.04, 0.55, 0.04, MeshLib.unlit_mat(MeshLib.rgb(0x2a2733)))
			stem.position = Vector3(0.13, 0.3, 0)
			note.add_child(stem)
			var na := 4.8 + ni * 0.42
			var nw := _tw(cd, 3.3, na)
			var base_y := fh + 1.7 + ni * 0.3
			note.position = Vector3(nw.x, base_y, nw.y)
			_add(note)
			var ph := ni * 2.1
			_game.deco_anims.append(func(t: float) -> void:
				note.position.y = base_y + sin(t * 0.0021 + ph) * 0.25
				note.rotation.y = sin(t * 0.0013 + ph) * 0.5)
	# the library side: bookshelves + a reading chair
	for ba2 in [0.6, 1.35, 2.0]:
		var bw := _add_bookshelf(cd, 4.6, ba2, fh)
		blk.call(1, bw, 0.75)
	var chair := Node3D.new()
	var cseat := MeshLib.box(0.9, 0.45, 0.9, MeshLib.lit_mat(col.lightened(0.3)))
	cseat.position.y = 0.35
	chair.add_child(cseat)
	var cback := MeshLib.box(0.9, 0.9, 0.2, MeshLib.lit_mat(col.lightened(0.15)))
	cback.position = Vector3(0, 0.85, -0.35)
	chair.add_child(cback)
	var wch := _tower_place(cd, chair, 3.5, 1.1, true, fh)
	blk.call(1, wch, 0.7)
	_add_portrait(el, cd, cos(5.9) * 4.68, sin(5.9) * 4.68, -cos(5.9), -sin(5.9), fh, "child")
	# hidden nook: walled slice of the floor, its doorway sealed by a bookshelf
	# (see game.gd _tower_secrets — walking up to it slides the shelf into the wall)
	var nook_a1 := 2.75
	var nook_a2 := 3.65
	var nwall := MeshLib.box(2.15, 3.0, 0.35, stone_dark)
	_tower_place(cd, nwall, 3.97, nook_a2, false, fh + 1.5)
	for rr2 in [3.3, 4.6]:
		blk.call(1, _tw(cd, rr2, nook_a2), 0.6)
	var iwall := MeshLib.box(0.35, 3.0, 2.3, stone_dark)
	_tower_place(cd, iwall, 2.95, (nook_a1 + nook_a2) / 2.0, false, fh + 1.5)
	blk.call(1, _tw(cd, 2.95, 3.05), 0.55)
	blk.call(1, _tw(cd, 2.95, 3.4), 0.55)
	var shelf_door := _make_bookshelf_node(2.0)
	var shelf_closed_w := _tw(cd, 3.95, nook_a1)
	var shelf_wa := _door_ang(cd) + nook_a1
	shelf_door.position = Vector3(shelf_closed_w.x, fh, shelf_closed_w.y)
	shelf_door.rotation.y = -shelf_wa + PI   # spine along the radial line, books facing the library
	_add(shelf_door)
	var shelf_closed := shelf_door.position
	var shelf_open := shelf_closed + Vector3(cos(shelf_wa), 0, sin(shelf_wa)) * 2.05  # slides into the outer wall
	# the treasure inside
	var chest := Node3D.new()
	var cbody := MeshLib.box(1.5, 0.7, 0.9, MeshLib.lit_mat(MeshLib.rgb(0x7a5a3a)))
	cbody.position.y = 0.35
	chest.add_child(cbody)
	var clid := MeshLib.box(1.5, 0.3, 0.9, MeshLib.lit_mat(MeshLib.rgb(0x6a4c30)))
	clid.position.y = 0.82
	chest.add_child(clid)
	var cband := MeshLib.box(1.56, 0.14, 0.96, gold)
	cband.position.y = 0.62
	chest.add_child(cband)
	var chest_w := _tower_place(cd, chest, 4.55, 3.35, true, fh)
	blk.call(1, chest_w, 0.6)
	var sparkle := MeshLib.sphere(0.18, MeshLib.unlit_mat(col, 0.9), 8, 6)
	var sp_w := _tw(cd, 4.3, 3.35)
	sparkle.position = Vector3(sp_w.x, fh + 1.3, sp_w.y)
	_add(sparkle)
	var ngw := _tw(cd, 3.9, 3.15)
	var nglow := MeshLib.disc(0.9, MeshLib.unlit_mat(col, 0.2), 12)
	nglow.position = Vector3(ngw.x, fh + 0.05, ngw.y)
	_add(nglow)

	# L2 — bedchamber
	var bed_w := _add_tower_bed(cd, 3.95, PI, col, 2.0 * fh)
	blk.call(2, bed_w, 1.3)
	var ward := Node3D.new()
	var wbody := MeshLib.box(1.7, 2.5, 0.7, wood)
	wbody.position.y = 1.25
	ward.add_child(wbody)
	var wline := MeshLib.box(0.04, 2.1, 0.06, MeshLib.lit_mat(MeshLib.rgb(0x4a3826)))
	wline.position = Vector3(0, 1.25, 0.36)
	ward.add_child(wline)
	var ww := _tower_place(cd, ward, 4.4, 1.9, true, 2.0 * fh)
	blk.call(2, ww, 1.0)
	var desk := Node3D.new()
	var dtop := MeshLib.box(1.4, 0.1, 0.8, wood)
	dtop.position.y = 0.75
	desk.add_child(dtop)
	for s in [-1.0, 1.0]:
		var dleg := MeshLib.box(0.1, 0.72, 0.7, wood)
		dleg.position = Vector3(s * 0.6, 0.36, 0)
		desk.add_child(dleg)
	var candle := MeshLib.cyl(0.06, 0.06, 0.3, MeshLib.unlit_mat(MeshLib.rgb(0xf6f0dc)), 6)
	candle.position = Vector3(0.3, 0.95, 0)
	desk.add_child(candle)
	var cflame := MeshLib.sphere(0.08, MeshLib.unlit_mat(MeshLib.rgb(0xffc060)), 8, 6)
	cflame.position = Vector3(0.3, 1.14, 0)
	desk.add_child(cflame)
	var wd := _tower_place(cd, desk, 4.3, 4.5, true, 2.0 * fh)
	blk.call(2, wd, 0.85)
	_add_portrait(el, cd, cos(0.8) * 4.68, sin(0.8) * 4.68, -cos(0.8), -sin(0.8), 2.0 * fh, "trophy")

	# --- register it all for game.gd
	var zone_w := _tw(cd, 3.95, nook_a1 - 0.55)
	var nook_w := _tw(cd, 3.95, 3.2)
	_game.tower_by_owner[el] = {
		"x": w0.x, "z": w0.y,
		"door_ang": _door_ang(cd),
		"r_in": TOWER_IN_R, "floor_h": fh, "levels": TOWER_LEVELS,
		"furn": furn,
		"shelf": {
			"level": 1, "node": shelf_door, "closed": shelf_closed, "open": shelf_open,
			"zone": { "x": zone_w.x, "z": zone_w.y, "r": 1.5 },
			"block": { "x": shelf_closed_w.x, "z": shelf_closed_w.y, "r": 1.1 },
		},
		"nook": { "level": 1, "x": nook_w.x, "z": nook_w.y, "r": 1.1 },
		"passage": { "x": pass_w.x, "z": pass_w.y, "r": 1.0 },
		"roof_drop": { "x": rune_w.x, "z": rune_w.y, "r": 1.35, "lx": land_w.x, "lz": land_w.y },
	}

# Descent aid: a faint glowing rim traces each floor's stairwell opening so the
# floor↔stair edge is easy to find. The see-through descent panel itself is built
# into the floor-plate ring (see _build_tower). Purely cosmetic.
static func _add_stair_guides(cd: Dictionary, tint: Color) -> void:
	var c := _lw(cd, 0.0, 0.0)
	var edge := MeshLib.unlit_mat(tint.lightened(0.25), 0.28)
	for f in range(1, TOWER_LEVELS + 1):
		var y: float = f * TOWER_FLOOR_H
		var ring := TorusMesh.new()
		ring.inner_radius = 2.3
		ring.outer_radius = 2.54
		var rm := MeshLib.mi(ring, edge)
		rm.position = Vector3(c.x, y + 0.05, c.y)
		_add(rm)

# A hearth: stone surround + fire glow, backed against the tower wall.
static func _add_hearth(cd: Dictionary, rr: float, ang: float, y0: float) -> Vector2:
	var n := Node3D.new()
	var stone_d := MeshLib.lit_mat(MeshLib.rgb(0x8e8a96))
	var back := MeshLib.box(1.8, 1.7, 0.4, stone_d)
	back.position = Vector3(0, 0.85, -0.3)
	n.add_child(back)
	for s in [-1.0, 1.0]:
		var post := MeshLib.box(0.35, 1.3, 0.5, stone_d)
		post.position = Vector3(s * 0.75, 0.65, 0.05)
		n.add_child(post)
	var mantel := MeshLib.box(1.9, 0.22, 0.65, stone_d)
	mantel.position = Vector3(0, 1.4, 0.05)
	n.add_child(mantel)
	var fire := MeshLib.sphere(0.32, MeshLib.unlit_mat(MeshLib.rgb(0xffa040)), 10, 8)
	fire.scale = Vector3(1.3, 1.0, 0.8)
	fire.position = Vector3(0, 0.35, 0.05)
	n.add_child(fire)
	var glow := MeshLib.disc(0.75, MeshLib.unlit_mat(MeshLib.rgb(0xff7030), 0.25), 12)
	glow.position = Vector3(0, 0.03, 0.35)
	n.add_child(glow)
	if not _game.lite:
		var ph := randf() * TAU
		_game.deco_anims.append(func(t: float) -> void:
			fire.scale = Vector3(1.3, 1.0 + sin(t * 0.019 + ph) * 0.18, 0.8))
	return _tower_place(cd, n, rr, ang, true, y0)

# A grand piano (well, a storybook one): body, keys, propped lid and bench.
static func _add_piano(cd: Dictionary, rr: float, ang: float, y0: float) -> Vector2:
	var n := Node3D.new()
	var dark := MeshLib.lit_mat(MeshLib.rgb(0x2a2731))
	var body := MeshLib.box(2.2, 0.55, 1.35, dark)
	body.position.y = 1.0
	n.add_child(body)
	for s in [[-0.9, -0.5], [0.9, -0.5], [0.0, 0.55]]:
		var leg := MeshLib.cyl(0.07, 0.09, 0.75, dark, 6)
		leg.position = Vector3(s[0], 0.37, s[1])
		n.add_child(leg)
	var keys := MeshLib.box(1.9, 0.1, 0.32, MeshLib.unlit_mat(MeshLib.rgb(0xf6f2e6)))
	keys.position = Vector3(0, 1.3, 0.78)
	n.add_child(keys)
	var blacks := MeshLib.box(1.7, 0.06, 0.14, MeshLib.unlit_mat(MeshLib.rgb(0x17151f)))
	blacks.position = Vector3(0, 1.36, 0.7)
	n.add_child(blacks)
	var lid := MeshLib.box(2.1, 0.07, 1.25, dark)
	lid.position = Vector3(0, 1.75, -0.35)
	lid.rotation.x = 0.55
	n.add_child(lid)
	var bench := MeshLib.box(1.2, 0.5, 0.45, MeshLib.lit_mat(MeshLib.rgb(0x7a5a3a)))
	bench.position = Vector3(0, 0.25, 1.45)
	n.add_child(bench)
	return _tower_place(cd, n, rr, ang, true, y0)

# A cello resting on its stand.
static func _add_cello(cd: Dictionary, rr: float, ang: float, y0: float) -> Vector2:
	var n := Node3D.new()
	var body := MeshLib.sphere(0.5, MeshLib.lit_mat(MeshLib.rgb(0xa06a3a)), 12, 10)
	body.scale = Vector3(0.75, 1.15, 0.35)
	body.position = Vector3(0, 0.75, 0.1)
	body.rotation.x = -0.22
	n.add_child(body)
	var neck := MeshLib.box(0.09, 1.0, 0.07, MeshLib.lit_mat(MeshLib.rgb(0x3a2c20)))
	neck.position = Vector3(0, 1.75, -0.14)
	neck.rotation.x = -0.22
	n.add_child(neck)
	var scroll := MeshLib.sphere(0.09, MeshLib.lit_mat(MeshLib.rgb(0x3a2c20)), 8, 6)
	scroll.position = Vector3(0, 2.28, -0.26)
	n.add_child(scroll)
	for s in [-1.0, 1.0]:
		var sleg := MeshLib.cyl(0.04, 0.04, 0.9, MeshLib.lit_mat(MeshLib.rgb(0x4a4650)), 5)
		sleg.position = Vector3(s * 0.3, 0.45, 0.32)
		sleg.rotation.x = 0.35
		n.add_child(sleg)
	return _tower_place(cd, n, rr, ang, true, y0)

# One bookshelf unit (frame + three rows of books) placed against the wall.
static func _add_bookshelf(cd: Dictionary, rr: float, ang: float, y0: float) -> Vector2:
	var n := _make_bookshelf_node(1.8)
	return _tower_place(cd, n, rr, ang, true, y0)

static func _make_bookshelf_node(width: float) -> Node3D:
	var n := Node3D.new()
	var frame := MeshLib.box(width, 2.5, 0.45, MeshLib.lit_mat(MeshLib.rgb(0x6a4c30)))
	frame.position.y = 1.25
	n.add_child(frame)
	var tones := [0xc46a5a, 0x6d9ce9, 0x8fa86e, 0xf0c060, 0xbaa0e0]
	for row in 3:
		var books := MeshLib.box(width - 0.25, 0.52, 0.3, MeshLib.lit_mat(MeshLib.rgb(tones[(row * 2) % tones.size()])))
		books.position = Vector3(0, 0.55 + row * 0.72, 0.12)
		n.add_child(books)
	return n

# The throne now lives on the tower's ground floor, facing the door.
static func _add_throne(cd: Dictionary, rr: float, ang: float, col: Color) -> Vector2:
	var n := Node3D.new()
	var wood := MeshLib.lit_mat(MeshLib.rgb(0x6e5138))
	var gold := MeshLib.lit_mat(MeshLib.rgb(0xc9a23f))
	var plinth := MeshLib.box(2.6, 0.3, 2.0, MeshLib.lit_mat(MeshLib.rgb(0xc4beac)))
	plinth.position.y = 0.15
	n.add_child(plinth)
	var seat := MeshLib.box(1.5, 0.55, 1.1, wood)
	seat.position = Vector3(0, 0.57, -0.1)
	n.add_child(seat)
	var back := MeshLib.box(1.5, 2.3, 0.25, wood)
	back.position = Vector3(0, 1.45, -0.7)
	n.add_child(back)
	var crest := MeshLib.box(0.9, 0.5, 0.2, gold)
	crest.position = Vector3(0, 2.75, -0.7)
	n.add_child(crest)
	var cushion := MeshLib.box(1.3, 0.16, 0.9, MeshLib.unlit_mat(col, 0.9))
	cushion.position = Vector3(0, 0.9, -0.05)
	n.add_child(cushion)
	for s in [-1.0, 1.0]:
		var arm := MeshLib.box(0.22, 0.7, 1.0, wood)
		arm.position = Vector3(s * 0.85, 0.9, -0.15)
		n.add_child(arm)
	return _tower_place(cd, n, rr, ang, true)

# A bed on the tower's polar grid (head against the curved wall).
static func _add_tower_bed(cd: Dictionary, rr: float, ang: float, col: Color, y0: float) -> Vector2:
	var n := Node3D.new()
	var wood := MeshLib.lit_mat(MeshLib.rgb(0x7a5a3a))
	var frame := MeshLib.box(1.9, 0.45, 3.1, wood)
	frame.position.y = 0.25
	n.add_child(frame)
	var head := MeshLib.box(1.9, 1.05, 0.18, wood)
	head.position = Vector3(0, 0.75, -1.46)
	n.add_child(head)
	var mattress := MeshLib.box(1.66, 0.26, 2.8, MeshLib.lit_mat(MeshLib.rgb(0xf2eee2)))
	mattress.position.y = 0.58
	n.add_child(mattress)
	var pillow := MeshLib.box(1.2, 0.2, 0.6, MeshLib.lit_mat(MeshLib.rgb(0xfaf7ee)))
	pillow.position = Vector3(0, 0.78, -1.0)
	n.add_child(pillow)
	var blanket := MeshLib.box(1.7, 0.16, 1.8, MeshLib.lit_mat(col.lightened(0.15)))
	blanket.position = Vector3(0, 0.68, 0.5)
	n.add_child(blanket)
	return _tower_place(cd, n, rr, ang, true, y0)

# A flat treasury dais: the key bobs low (its teeth dip to ~0.1), so it gets a
# gold-ringed floor rostrum rather than a raised column it would clip through.
static func _add_key_dais(cd: Dictionary, u: float, v: float, col: Color) -> Vector2:
	var w := _lw(cd, u, v)
	var dais := MeshLib.disc(1.15, MeshLib.lit_mat(MeshLib.rgb(0xc4beac)), 16)
	dais.position = Vector3(w.x, 0.04, w.y)
	_add(dais)
	var ring := TorusMesh.new()
	ring.inner_radius = 1.05; ring.outer_radius = 1.25
	var ring_mi := MeshLib.mi(ring, MeshLib.lit_mat(MeshLib.rgb(0xc9a23f)))
	ring_mi.position = Vector3(w.x, 0.07, w.y)
	_add(ring_mi)
	var halo := MeshLib.disc(0.95, MeshLib.unlit_mat(col, 0.16), 16)
	halo.position = Vector3(w.x, 0.06, w.y)
	_add(halo)
	return w

static func _add_chest(cd: Dictionary, u: float, v: float, col: Color) -> void:
	var n := Node3D.new()
	var wood := MeshLib.lit_mat(MeshLib.rgb(0x7a5a3a))
	var body := MeshLib.box(1.5, 0.7, 0.9, wood)
	body.position.y = 0.35
	n.add_child(body)
	var lid := MeshLib.box(1.5, 0.3, 0.9, MeshLib.lit_mat(MeshLib.rgb(0x6a4c30)))
	lid.position.y = 0.82
	n.add_child(lid)
	var band := MeshLib.box(1.56, 0.14, 0.96, MeshLib.lit_mat(MeshLib.rgb(0xc9a23f)))
	band.position.y = 0.62
	n.add_child(band)
	var gleam := MeshLib.sphere(0.16, MeshLib.unlit_mat(col, 0.9), 8, 6)
	gleam.position = Vector3(0.3, 1.0, 0)
	n.add_child(gleam)
	_place(cd, n, u, v, 0.0, 1.0 if v < 0 else -1.0)
	var w := _lw(cd, u, v)
	_obstacle(w.x, w.y, 0.85)

static func _add_table(cd: Dictionary, u: float, v: float) -> void:
	var n := Node3D.new()
	var wood := MeshLib.lit_mat(MeshLib.rgb(0x8a6a48))
	var top := MeshLib.box(1.1, 0.1, 1.1, wood)
	top.position.y = 0.75
	n.add_child(top)
	var leg := MeshLib.cyl(0.09, 0.11, 0.72, wood, 6)
	leg.position.y = 0.36
	n.add_child(leg)
	var candle := MeshLib.cyl(0.06, 0.06, 0.3, MeshLib.unlit_mat(MeshLib.rgb(0xf6f0dc)), 6)
	candle.position.y = 0.95
	n.add_child(candle)
	var flame := MeshLib.sphere(0.09, MeshLib.unlit_mat(MeshLib.rgb(0xffc060)), 8, 6)
	flame.position.y = 1.15
	n.add_child(flame)
	_place(cd, n, u, v, 1.0, 0.0)
	var w := _lw(cd, u, v)
	_obstacle(w.x, w.y, 0.7)

static func _add_torch(cd: Dictionary, u: float, v: float) -> void:
	var w := _lw(cd, u, v)
	_batch_mesh(MeshLib.cyl_mesh(0.05, 0.07, 0.7, 6), MeshLib.lit_mat(MeshLib.rgb(0x6a5136)),
		Transform3D(Basis(), Vector3(w.x, 2.35, w.y)))
	var flame := MeshLib.sphere(0.17, MeshLib.unlit_mat(MeshLib.rgb(0xffb054)), 8, 6)
	flame.position = Vector3(w.x, 2.82, w.y)
	_add(flame)
	if not _game.lite:
		var ph := randf() * TAU
		_game.deco_anims.append(func(t: float) -> void:
			flame.scale = Vector3.ONE * (1.0 + sin(t * 0.02 + ph) * 0.18))

# A framed painting of the castle's own element character, hung on a wall.
# The "canvas" is a dark backdrop with a flattened mini figure in relief.
# y0 lifts it to an upper tower floor.
# A framed portrait. `variant` chooses a little scene painted around the element:
#   plain · crown (ruler) · clan (king + minions) · child (parent) · sword (war
#   on the predator that eats it) · key (wedded to its key) · co2 (charged, ringed
#   by CO₂) · heart (in love) · trophy (champion).
static func _add_portrait(el: String, cd: Dictionary, u: float, v: float, du: float, dv: float, y0: float = 0.0, variant: String = "plain") -> void:
	var n := Node3D.new()
	var gold := MeshLib.lit_mat(MeshLib.rgb(0xc9a23f))
	var backs := { "fire": 0x3a2420, "water": 0x1f2c40, "grass": 0x24321f }
	var canvas := MeshLib.box(2.1, 2.7, 0.08, MeshLib.unlit_mat(MeshLib.rgb(backs[el])))
	canvas.position.y = 2.0
	n.add_child(canvas)
	for sy in [0.62, 3.38]:
		var bar := MeshLib.box(2.4, 0.16, 0.14, gold)
		bar.position = Vector3(0, sy, 0.02)
		n.add_child(bar)
	for sx in [-1.12, 1.12]:
		var bar := MeshLib.box(0.16, 2.9, 0.14, gold)
		bar.position = Vector3(sx, 2.0, 0.02)
		n.add_child(bar)
	var plaque := MeshLib.box(0.8, 0.22, 0.1, gold)
	plaque.position = Vector3(0, 0.4, 0.04)
	n.add_child(plaque)
	_portrait_scene(el, n, variant, gold)
	_place(cd, n, u, v, du, dv, y0)

# Paints the figure (and any companions/props) onto an already-framed canvas.
static func _portrait_scene(el: String, n: Node3D, variant: String, gold: Material) -> void:
	var lite: bool = _game.lite
	var pred := { "fire": "water", "water": "grass", "grass": "fire" }   # who eats me
	var keycol := { "fire": 0xff5a3a, "water": 0x4aa0ff, "grass": 0x7ad04a }
	# the star of the painting — shift aside when a companion/prop shares the frame
	var side := variant in ["child", "sword", "key", "heart", "trophy"]
	var main := _mini_figure(el, 0.62)
	main.position = Vector3(0.5 if side else 0.0, 0.85, 0.14)
	n.add_child(main)
	match variant:
		"crown", "clan":
			var crown := _crown(gold)
			crown.position = Vector3(0.0, 1.95, 0.22)
			n.add_child(crown)
		"child":
			var kid := _mini_figure(el, 0.34)
			kid.position = Vector3(-0.62, 0.72, 0.16)
			n.add_child(kid)
		"sword":
			var sword := _sword()
			sword.position = Vector3(0.28, 1.35, 0.24)
			sword.rotation.z = -0.55
			n.add_child(sword)
			var foe := _mini_figure(pred[el], 0.32)      # the predator, cowering
			foe.position = Vector3(-0.72, 0.66, 0.16)
			n.add_child(foe)
		"key":
			var key := MeshLib.key_node(MeshLib.rgb(keycol[el]))
			key.scale = Vector3(0.5, 0.5, 0.12)
			key.rotation.z = 0.5
			key.position = Vector3(-0.55, 1.45, 0.2)
			n.add_child(key)
		"co2":
			if not lite:
				for i in 2:
					var c := MeshLib.build_co2()
					c.scale = Vector3(0.24, 0.24, 0.06)
					c.position = Vector3(-0.72 + i * 1.42, 0.66, 0.16)
					n.add_child(c)
		"heart":
			n.add_child(_heart(Vector3(-0.55, 1.5, 0.2)))
		"trophy":
			n.add_child(_trophy(Vector3(-0.55, 1.3, 0.2), gold))
	if variant == "clan" and not lite:
		for i in 3:
			var minion := _mini_figure(el, 0.24)
			minion.position = Vector3(-0.78 + i * 0.78, 0.5, 0.18)
			n.add_child(minion)

# A squashed-flat element figure that reads as a painted character.
static func _mini_figure(el2: String, s: float) -> Node3D:
	var builders := { "fire": MeshLib.build_flame, "water": MeshLib.build_droplet, "grass": MeshLib.build_leaf }
	var m: Node3D = builders[el2].call()
	m.scale = Vector3(s, s, s * 0.22)
	return m

static func _crown(gold: Material) -> Node3D:
	var c := Node3D.new()
	var band := MeshLib.cyl(0.24, 0.26, 0.16, gold, 10)
	c.add_child(band)
	for i in 5:
		var a := i * TAU / 5.0
		var spike := MeshLib.box(0.07, 0.24, 0.05, gold)
		spike.position = Vector3(cos(a) * 0.2, 0.16, 0)
		c.add_child(spike)
	c.scale = Vector3(1, 1, 0.4)
	return c

static func _sword() -> Node3D:
	var s := Node3D.new()
	var steel := MeshLib.lit_mat(MeshLib.rgb(0xcfd6e0))
	var blade := MeshLib.box(0.08, 1.05, 0.05, steel)
	blade.position.y = 0.5
	s.add_child(blade)
	var guard := MeshLib.box(0.42, 0.09, 0.07, MeshLib.lit_mat(MeshLib.rgb(0x8a6a3a)))
	s.add_child(guard)
	var grip := MeshLib.box(0.07, 0.26, 0.06, MeshLib.lit_mat(MeshLib.rgb(0x5a3a24)))
	grip.position.y = -0.16
	s.add_child(grip)
	return s

static func _heart(pos: Vector3) -> Node3D:
	var mat := MeshLib.unlit_mat(MeshLib.rgb(0xff5a6a))
	var h := Node3D.new()
	for sx in [-1.0, 1.0]:
		var lobe := MeshLib.sphere(0.16, mat, 10, 8)
		lobe.position = Vector3(sx * 0.13, 0.11, 0)
		h.add_child(lobe)
	var tip := MeshLib.box(0.3, 0.3, 0.1, mat)
	tip.rotation.z = PI / 4.0
	tip.position = Vector3(0, -0.13, 0)
	h.add_child(tip)
	h.scale = Vector3(1, 1, 0.4)
	h.position = pos
	return h

static func _trophy(pos: Vector3, gold: Material) -> Node3D:
	var cup := Node3D.new()
	var bowl := MeshLib.cyl(0.26, 0.12, 0.3, gold, 10)
	bowl.position.y = 0.2
	cup.add_child(bowl)
	var stem := MeshLib.cyl(0.05, 0.05, 0.18, gold, 6)
	cup.add_child(stem)
	var foot := MeshLib.cyl(0.15, 0.18, 0.08, gold, 10)
	foot.position.y = -0.13
	cup.add_child(foot)
	for sx in [-1.0, 1.0]:
		var handle := MeshLib.box(0.08, 0.24, 0.05, gold)
		handle.position = Vector3(sx * 0.3, 0.22, 0)
		handle.rotation.z = sx * 0.5
		cup.add_child(handle)
	cup.scale = Vector3(1, 1, 0.4)
	cup.position = pos
	return cup

static func _add_bed(cd: Dictionary, u: float, v: float, col: Color) -> void:
	var n := Node3D.new()
	var wood := MeshLib.lit_mat(MeshLib.rgb(0x7a5a3a))
	var frame := MeshLib.box(1.9, 0.45, 3.1, wood)
	frame.position.y = 0.25
	n.add_child(frame)
	var head := MeshLib.box(1.9, 1.05, 0.18, wood)
	head.position = Vector3(0, 0.75, -1.46)
	n.add_child(head)
	var mattress := MeshLib.box(1.66, 0.26, 2.8, MeshLib.lit_mat(MeshLib.rgb(0xf2eee2)))
	mattress.position.y = 0.58
	n.add_child(mattress)
	var pillow := MeshLib.box(1.2, 0.2, 0.6, MeshLib.lit_mat(MeshLib.rgb(0xfaf7ee)))
	pillow.position = Vector3(0, 0.78, -1.0)
	n.add_child(pillow)
	var blanket := MeshLib.box(1.7, 0.16, 1.8, MeshLib.lit_mat(col.lightened(0.15)))
	blanket.position = Vector3(0, 0.68, 0.5)
	n.add_child(blanket)
	# foot of the bed points toward the room (+u = toward the hall)
	_place(cd, n, u, v, 1.0, 0.0)
	var w := _lw(cd, u, v)
	_obstacle(w.x, w.y, 1.3)

# --------------------------------------------------- element garden courtyards
static func _build_garden(el: String, cd: Dictionary, col: Color) -> void:
	# stone path from the gatehouse to the keep door
	var path_c := _lw(cd, (WALL_HALF + KEEP_HU) / 2.0 + 0.5, 0.0)
	var path_s := _lsz(cd, WALL_HALF - KEEP_HU - 1.0, 5.5)
	_add_street(path_c.x, path_c.y, path_s.x, path_s.y, 0xd6d0c0)
	# lamp posts along the path
	for pu in [WALL_HALF - 6.0, KEEP_HU + 6.0]:
		for sv in [-1.0, 1.0]:
			_add_lamp(cd, pu, sv * 4.4)
	match el:
		"fire":
			_garden_fire(cd, col)
		"water":
			_garden_water(cd, col)
		"grass":
			_garden_grass(cd, col)

static func _add_lamp(cd: Dictionary, u: float, v: float) -> void:
	var w := _lw(cd, u, v)
	_batch_mesh(MeshLib.cyl_mesh(0.08, 0.1, 2.2, 6), MeshLib.lit_mat(MeshLib.rgb(0x5a544e)),
		Transform3D(Basis(), Vector3(w.x, 1.1, w.y)))
	_batch_mesh(MeshLib.sphere_mesh(0.22, 10, 8), MeshLib.unlit_mat(MeshLib.rgb(0xffe6a8), 0.95),
		Transform3D(Basis(), Vector3(w.x, 2.35, w.y)))
	_obstacle(w.x, w.y, 0.35)

static func _flower_bed(cd: Dictionary, u: float, v: float, r: float, colors: Array) -> void:
	var w := _lw(cd, u, v)
	_batch_mesh(MeshLib.cyl_mesh(r, r, 0.02, 14), MeshLib.lit_mat(MeshLib.rgb(0x6e5f4e)),
		Transform3D(Basis(), Vector3(w.x, 0.05, w.y)))
	var n := 4 if _game.lite else 8
	for i in n:
		var a := randf() * TAU
		var rr := sqrt(randf()) * (r - 0.3)
		var fx := w.x + cos(a) * rr
		var fz := w.y + sin(a) * rr
		_batch_mesh(MeshLib.cyl_mesh(0.03, 0.03, 0.5, 5), MeshLib.lit_mat(MeshLib.rgb(0x4c7048)),
			Transform3D(Basis(), Vector3(fx, 0.25, fz)))
		_batch_mesh(MeshLib.sphere_mesh(0.14, 8, 6), MeshLib.unlit_mat(MeshLib.rgb(colors[i % colors.size()])),
			Transform3D(Basis(), Vector3(fx, 0.56, fz)))

# The homecoming circle: a painted parent-and-child marker between two flame
# braziers BEHIND the keep. The freed twin must be brought onto it to win
# (game.gd _check_rescue). Fire's ember garden already owns that brazier pair
# at (-16, ±10); water/grass get a matching pair so every castle reads the same.
static func _build_home_shrine(el: String, cd: Dictionary, col: Color) -> void:
	if el != "fire":
		_add_brazier(cd, -16.0, 10.0)
		_add_brazier(cd, -16.0, -10.0)
	var w := _lw(cd, -16.0, 0.0)
	var pm := PlaneMesh.new()
	pm.size = Vector2(5.6, 5.6)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_texture = MeshLib.home_marker_tex(el, col)
	var decal := MeshLib.mi(pm, mat)
	decal.position = Vector3(w.x, 0.12, w.y)
	_add(decal)
	if not _game.lite:
		_game.deco_anims.append(func(t: float) -> void:
			var k := 1.0 + sin(t * 0.003) * 0.06
			decal.scale = Vector3(k, 1.0, k))
	_game.home_spot_by_owner[el] = { "x": w.x, "z": w.y, "r": 3.2 }

static func _add_brazier(cd: Dictionary, u: float, v: float) -> void:
	var w := _lw(cd, u, v)
	_batch_mesh(MeshLib.cyl_mesh(0.75, 0.45, 0.8, 10), MeshLib.lit_mat(MeshLib.rgb(0x4a4650)),
		Transform3D(Basis(), Vector3(w.x, 0.4, w.y)))
	var flame := MeshLib.sphere(0.38, MeshLib.unlit_mat(MeshLib.rgb(0xffa040)), 10, 8)
	flame.position = Vector3(w.x, 1.0, w.y)
	_add(flame)
	var glow := MeshLib.disc(1.1, MeshLib.unlit_mat(MeshLib.rgb(0xff7030), 0.2), 14)
	glow.position = Vector3(w.x, 0.06, w.y)
	_add(glow)
	_obstacle(w.x, w.y, 0.8)
	if not _game.lite:
		var ph := randf() * TAU
		_game.deco_anims.append(func(t: float) -> void:
			flame.scale = Vector3.ONE * (1.0 + sin(t * 0.017 + ph) * 0.16))

# FIRE — an ember garden: braziers, glowing ember pools ringed with dark rock,
# and beds of flame-coloured flowers on ash.
static func _garden_fire(cd: Dictionary, _col: Color) -> void:
	for sv in [-1.0, 1.0]:
		_add_brazier(cd, 17.0, sv * 12.0)
		_add_brazier(cd, 0.0, sv * 17.5)
		_add_brazier(cd, -16.0, sv * 10.0)
		# ember pool
		var w := _lw(cd, 8.0, sv * 17.0)
		var pool := MeshLib.disc(2.2, MeshLib.unlit_mat(MeshLib.rgb(0xff6a28), 0.5), 18)
		pool.position = Vector3(w.x, 0.06, w.y)
		_add(pool)
		var rock_mat := MeshLib.lit_mat(MeshLib.rgb(0x4e4652))
		for i in 6:
			var a := float(i) / 6.0 * TAU
			_batch_mesh(MeshLib.sphere_mesh(0.5, 6, 4), rock_mat, Transform3D(
				Basis.from_scale(Vector3(1, 0.75, 1)),
				Vector3(w.x + cos(a) * 2.6, 0.35, w.y + sin(a) * 2.6)))
		_flower_bed(cd, 22.0, sv * 17.0, 2.0, [0xff5a3c, 0xffa03c, 0xffd05c])
		_flower_bed(cd, -6.0, sv * 16.5, 1.8, [0xff5a3c, 0xffa03c, 0xffd05c])

# WATER — fountain courts: lily ponds with reeds, twin fountains and beds of
# blue and white blossom.
static func _garden_water(cd: Dictionary, _col: Color) -> void:
	var pond_mat := _glass_or_lit(MeshLib.rgb(0x8ab4e8), 0.55)
	for sv in [-1.0, 1.0]:
		# lily pond
		var w := _lw(cd, 16.0, sv * 13.0)
		var pond := MeshLib.cyl(3.2, 3.2, 0.14, pond_mat, 20)
		pond.position = Vector3(w.x, 0.08, w.y)
		_add(pond)
		var rim := TorusMesh.new()
		rim.inner_radius = 3.1; rim.outer_radius = 3.55
		var rim_mi := MeshLib.mi(rim, MeshLib.lit_mat(MeshLib.rgb(0xaeb2c0)))
		rim_mi.position = Vector3(w.x, 0.14, w.y)
		_add(rim_mi)
		for i in 4:
			var a := randf() * TAU
			_batch_mesh(MeshLib.cyl_mesh(0.32, 0.32, 0.02, 8), MeshLib.lit_mat(MeshLib.rgb(0x5e9660)),
				Transform3D(Basis(), Vector3(w.x + cos(a) * (0.6 + randf() * 1.8), 0.17, w.y + sin(a) * (0.6 + randf() * 1.8))))
		for i in 5:
			var a := PI * 0.25 + float(i) * 0.35
			_batch_mesh(MeshLib.cyl_mesh(0.05, 0.05, 1.3, 4), MeshLib.lit_mat(MeshLib.rgb(0x567a52)),
				Transform3D(Basis(), Vector3(w.x + cos(a) * 3.5, 0.65, w.y + sin(a) * 3.5)))
		_add_fountain(cd, -2.0, sv * 17.5)
		_flower_bed(cd, 23.0, sv * 18.0, 2.0, [0x6da0e8, 0xbcd4f8, 0xf4f8ff])
		_flower_bed(cd, -16.0, sv * 9.5, 1.8, [0x6da0e8, 0xbcd4f8, 0xf4f8ff])

static func _add_fountain(cd: Dictionary, u: float, v: float) -> void:
	var w := _lw(cd, u, v)
	var base := MeshLib.cyl(1.7, 1.9, 0.45, MeshLib.lit_mat(MeshLib.rgb(0xaeb2c0)), 14)
	base.position = Vector3(w.x, 0.22, w.y)
	_add(base)
	var pool := MeshLib.disc(1.5, _glass_or_lit(MeshLib.rgb(0x8ab4e8), 0.6), 14)
	pool.position = Vector3(w.x, 0.47, w.y)
	_add(pool)
	var column := MeshLib.cyl(0.28, 0.36, 0.8, MeshLib.lit_mat(MeshLib.rgb(0x9fa3b2)), 8)
	column.position = Vector3(w.x, 0.85, w.y)
	_add(column)
	var bowl := MeshLib.cyl(0.7, 0.35, 0.3, MeshLib.lit_mat(MeshLib.rgb(0xaeb2c0)), 10)
	bowl.position = Vector3(w.x, 1.35, w.y)
	_add(bowl)
	var jet := MeshLib.sphere(0.26, MeshLib.unlit_mat(MeshLib.rgb(0xdcecfc), 0.9), 10, 8)
	jet.position = Vector3(w.x, 1.7, w.y)
	_add(jet)
	_obstacle(w.x, w.y, 1.9)
	if not _game.lite:
		var ph := randf() * TAU
		_game.deco_anims.append(func(t: float) -> void:
			jet.position.y = 1.7 + sin(t * 0.004 + ph) * 0.12)

# LEAF — a formal green garden: clipped hedgerows, topiary balls, cypress and
# bright mixed flower beds.
static func _garden_grass(cd: Dictionary, _col: Color) -> void:
	var hedge := MeshLib.lit_mat(MeshLib.rgb(0x4c7a4e))
	for sv in [-1.0, 1.0]:
		# hedgerows framing the side lawns (kept clear of the spawn ring out front)
		_cwall(cd, 2.0, sv * 16.5, 0.9, 7.0, 1.1, hedge)
		_cwall(cd, -17.0, sv * 8.5, 6.5, 0.9, 1.1, hedge)
		# topiary
		for t in [[20.0, 17.5], [-6.0, 17.0]]:
			var w := _lw(cd, t[0], sv * t[1])
			var trunk := MeshLib.cyl(0.1, 0.13, 0.9, MeshLib.lit_mat(MeshLib.rgb(0x8a7866)), 6)
			trunk.position = Vector3(w.x, 0.45, w.y)
			_add(trunk)
			var ball := MeshLib.sphere(0.85, hedge, 12, 10)
			ball.position = Vector3(w.x, 1.7, w.y)
			_add(ball)
			_obstacle(w.x, w.y, 0.9)
		var cw := _lw(cd, 14.0, sv * 12.0)
		_add_cypress(cw.x, cw.y, 0.9)
		_flower_bed(cd, 24.0, sv * 13.0, 2.2, [0xe86a8a, 0xf0c060, 0xbcd4f8, 0xffffff])
		_flower_bed(cd, -11.0, sv * 16.0, 1.8, [0xe86a8a, 0xf0c060, 0xffffff])

# ------------------------------------------------------------- dungeon yard
# The old zoo, re-dressed for the castle age: a broken-walled prison yard out
# in the wilds where the caged twins (and molecule captives) wait.
static func _build_dungeon_yard() -> void:
	var z: Dictionary = _game.ZOO
	var zx: float = z["x"]; var zz: float = z["z"]
	var floor_p := PlaneMesh.new(); floor_p.size = Vector2(34, 34)
	var floor_mi := MeshLib.mi(floor_p, MeshLib.lit_mat(MeshLib.rgb(0xc6c2ce)))
	floor_mi.position = Vector3(zx, 0.055, zz)
	_add(floor_mi)
	# crumbling perimeter — low wall stubs with wide gaps on every side
	var ruin := MeshLib.lit_mat(MeshLib.rgb(0x9fa3b2))
	for seg in [[-9.0, -16.0, 9.0, 1.2], [9.5, -16.0, 7.0, 1.2], [-9.0, 16.0, 9.0, 1.2], [9.5, 16.0, 7.0, 1.2],
			[-16.0, -9.0, 1.2, 9.0], [-16.0, 9.5, 1.2, 7.0], [16.0, -9.0, 1.2, 9.0], [16.0, 9.5, 1.2, 7.0]]:
		_add_box_wall(zx + seg[0], zz + seg[1], seg[2], seg[3], 2.1, ruin)
	# corner braziers light the yard
	for sx in [-1.0, 1.0]:
		for sz2 in [-1.0, 1.0]:
			var bx: float = zx + sx * 12.5
			var bz: float = zz + sz2 * 12.5
			var bowl := MeshLib.cyl(0.7, 0.42, 0.75, MeshLib.lit_mat(MeshLib.rgb(0x4a4650)), 10)
			bowl.position = Vector3(bx, 0.38, bz)
			_add(bowl)
			var flame := MeshLib.sphere(0.34, MeshLib.unlit_mat(MeshLib.rgb(0xffa040)), 10, 8)
			flame.position = Vector3(bx, 0.95, bz)
			_add(flame)
			_obstacle(bx, bz, 0.75)
	var bar_mat := MeshLib.lit_mat(MeshLib.rgb(0x6e6c7a))
	var builders: Array[Callable] = [MeshLib.build_flame, MeshLib.build_droplet, MeshLib.build_leaf, MeshLib.build_o2, MeshLib.build_co2]
	var idents := ["fire", "water", "grass", "o2", "co2"]
	for i in 5:
		var a := float(i) / 5.0 * TAU + 0.5
		_add_cage(zx + cos(a) * 9.0, zz + sin(a) * 9.0, builders[i], bar_mat, idents[i])

static func _add_cage(cx: float, cz: float, build_fn: Callable, bar_mat: Material, ident: String = "") -> void:
	var r := 2.3
	# bars + ring + captive live in one group so releasing the twin can hide them.
	# semi-glass / semi-stone bars + a translucent domed lid so the captive stays
	# visible even when the camera looks straight down from the ceiling.
	var gs := _glass_or_lit(MeshLib.rgb(0xa6b0c4), 0.5)
	var content := Node3D.new()
	_root.add_child(content)
	for i in 10:
		var a := float(i) / 10.0 * TAU
		var bar := MeshLib.cyl(0.07, 0.07, 3.2, gs, 5)
		bar.position = Vector3(cx + cos(a) * r, 1.6, cz + sin(a) * r)
		content.add_child(bar)
	var ring := TorusMesh.new()
	ring.inner_radius = r - 0.09; ring.outer_radius = r + 0.09
	var top_ring := MeshLib.mi(ring, gs)
	top_ring.position = Vector3(cx, 3.2, cz)
	content.add_child(top_ring)
	var lid := MeshLib.sphere(r + 0.1, gs, 14, 7)
	lid.scale = Vector3(1, 0.45, 1)
	lid.position = Vector3(cx, 3.2, cz)
	content.add_child(lid)
	var base := MeshLib.cyl(r + 0.3, r + 0.3, 0.18, MeshLib.lit_mat(MeshLib.rgb(0xccc9d6)), 18)
	base.position = Vector3(cx, 0.09, cz)
	_add(base)
	var mini: CharVisual = build_fn.call()
	mini.scale = Vector3.ONE * 0.55
	mini.position = Vector3(cx, 0.15, cz)
	content.add_child(mini)
	if not _game.lite:
		_game.deco_anims.append(func(t: float) -> void:
			mini.animate(t, 0.0)
			mini.rotation.y = sin(t * 0.0007 + cx) * 0.6)
	_obstacle(cx, cz, r + 0.2)
	var cage := { "x": cx, "z": cz, "r": r, "ident": ident, "node": content }
	_game.cages.append(cage)
	if ident == "fire" or ident == "water" or ident == "grass":
		_game.cage_by_el[ident] = cage

# Hide a cage's bars + captive when the twin is freed.
static func open_cage(cage: Dictionary) -> void:
	var node = cage.get("node")
	if node and is_instance_valid(node):
		node.visible = false

# Re-lock every cage (and restore its collision) for a fresh round.
static func reset_cages(game) -> void:
	for cage in game.cages:
		var node = cage.get("node")
		if node and is_instance_valid(node):
			node.visible = true
		var present: bool = game.obstacles.any(func(o): return absf(o["x"] - cage["x"]) < 0.01 and absf(o["z"] - cage["z"]) < 0.01)
		if not present:
			game.obstacles.append({ "x": cage["x"], "z": cage["z"], "r": cage["r"] + 0.2 })

# ------------------------------------------------- clan hall / training pad
static func _build_clan_hall(x: float, z: float, col: Color) -> void:
	var pad := MeshLib.cyl(3.2, 3.2, 0.16, MeshLib.lit_mat(MeshLib.rgb(0xe8e2d2)), 20)
	pad.position = Vector3(x, 0.08, z); _add(pad)
	var glow := MeshLib.disc(3.0, MeshLib.unlit_mat(col, 0.16), 22)
	glow.position = Vector3(x, 0.1, z); _add(glow)
	var post_mat := MeshLib.lit_mat(MeshLib.rgb(0x97816a))
	for i in 4:
		var a := i * PI / 2.0 + PI / 4.0
		var post := MeshLib.cyl(0.12, 0.12, 3.0, post_mat, 6)
		post.position = Vector3(x + cos(a) * 2.6, 1.5, z + sin(a) * 2.6); _add(post)
	# translucent canopy so the top-down command view can see the members beneath it
	var roof := MeshLib.cyl(3.1, 3.4, 0.4, _glass_or_lit(col, 0.5), 16)
	roof.position = Vector3(x, 3.1, z); _add(roof)
	var pole := MeshLib.cyl(0.1, 0.1, 4.4, post_mat, 6); pole.position = Vector3(x, 2.2, z); _add(pole)
	var flag := MeshLib.box(1.4, 0.9, 0.08, MeshLib.unlit_mat(col)); flag.position = Vector3(x + 0.8, 3.9, z); _add(flag)

static func _build_training_pad(x: float, z: float, col: Color) -> void:
	var pad := MeshLib.cyl(2.6, 2.6, 0.16, MeshLib.lit_mat(MeshLib.rgb(0xd9cfc0)), 18)
	pad.position = Vector3(x, 0.08, z); _add(pad)
	var glow := MeshLib.disc(2.4, MeshLib.unlit_mat(col, 0.14), 20)
	glow.position = Vector3(x, 0.1, z); _add(glow)
	var totem := MeshLib.cyl(0.34, 0.4, 2.4, MeshLib.lit_mat(col), 10)
	totem.position = Vector3(x, 1.2, z); _add(totem)
	var top := MeshLib.sphere(0.5, MeshLib.unlit_mat(col, 0.9), 12, 8)
	top.position = Vector3(x, 2.6, z); _add(top)
	_obstacle(x, z, 0.5)

# ------------------------------------------------------------- hamlets
# Small timber-and-plaster villages out in the wilds between the castles.
static func _build_hamlet(hx: float, hz: float) -> void:
	_add_street(hx, hz, 26, 26, 0xd2ccba)
	for h in [[-13.0, -8.0, "px"], [-13.5, 6.0, "px"], [13.0, -9.0, "nx"], [12.5, 7.0, "nx"], [0.0, -15.0, "pz"], [1.0, 15.0, "nz"]]:
		_add_house(hx + h[0] + (randf() - 0.5) * 2.0, hz + h[1] + (randf() - 0.5) * 2.0,
			7.0 + randf() * 2.5, 6.0 + randf() * 2.0, 2.9 + randf() * 0.8, _pick_house(), h[2])
	# the village well
	var ring := MeshLib.cyl(1.1, 1.2, 0.85, MeshLib.lit_mat(MeshLib.rgb(0xaeb2c0)), 12)
	ring.position = Vector3(hx, 0.42, hz)
	_add(ring)
	var wtr := MeshLib.disc(0.85, _glass_or_lit(MeshLib.rgb(0x8ab4e8), 0.6), 12)
	wtr.position = Vector3(hx, 0.75, hz)
	_add(wtr)
	var post_mat := MeshLib.lit_mat(MeshLib.rgb(0x8a6f52))
	for s in [-1.0, 1.0]:
		var post := MeshLib.cyl(0.09, 0.09, 2.2, post_mat, 6)
		post.position = Vector3(hx + s * 1.0, 1.1, hz)
		_add(post)
	var wroof := MeshLib.mi(_cone(1.5, 0.9, 8), MeshLib.lit_mat(MeshLib.rgb(ROOF_COLORS[0])))
	wroof.position = Vector3(hx, 2.5, hz)
	_add(wroof)
	_obstacle(hx, hz, 1.35)
	# hay bales + barrels
	for i in 3:
		var a := randf() * TAU
		var bx := hx + cos(a) * (7.0 + randf() * 3.0)
		var bz := hz + sin(a) * (7.0 + randf() * 3.0)
		if randf() < 0.5:
			var hay := MeshLib.cyl(0.7, 0.7, 1.1, MeshLib.lit_mat(MeshLib.rgb(0xd8bc72)), 10)
			hay.rotation.z = PI / 2.0
			hay.position = Vector3(bx, 0.7, bz)
			_add(hay)
		else:
			var barrel := MeshLib.cyl(0.5, 0.55, 0.95, MeshLib.lit_mat(MeshLib.rgb(0x8a6a48)), 10)
			barrel.position = Vector3(bx, 0.48, bz)
			_add(barrel)
		_obstacle(bx, bz, 0.75)

# ------------------------------------------------------------- wilderness
static func _scatter() -> void:
	var A: float = _game.ARENA
	var x1: float = _game.RIVER_X1
	var x2: float = _game.RIVER_X2
	var keepouts := [
		{ "x": _game.ZOO["x"], "z": _game.ZOO["z"], "r": 21.0 },
		{ "x": -48.0, "z": -66.0, "r": 24.0 },
		{ "x": 86.0, "z": -96.0, "r": 24.0 },
	]
	for el in CASTLES:
		var cd: Dictionary = CASTLES[el]
		keepouts.append({ "x": cd["x"], "z": cd["z"], "r": WALL_HALF * 1.45 + 6.0 })
	var spots: Array = []
	var count := 40 if _game.lite else 64
	for i in count:
		var x := 0.0; var z := 0.0; var ok := false; var tries := 0
		while not ok and tries < 80:
			x = (randf() * 2.0 - 1.0) * (A - 8)
			z = (randf() * 2.0 - 1.0) * (A - 8)
			ok = Vector2(x, z).length() > 10.0 \
				and not (x > x1 - 4 and x < x2 + 4) \
				and _game.caves.all(func(c): return Vector2(c["x"] - x, c["z"] - z).length() > c["r"] + 6) \
				and keepouts.all(func(k): return Vector2(k["x"] - x, k["z"] - z).length() > k["r"]) \
				and _game.rects.all(func(r): return absf(x - r["x"]) > r["hw"] + 6 or absf(z - r["z"]) > r["hd"] + 6) \
				and spots.all(func(s): return Vector2(s[0] - x, s[1] - z).length() > 13)
			tries += 1
		if not ok:
			continue
		spots.append([x, z])
		var roll := randf()
		if roll < 0.55:
			_add_cypress(x, z)
			if randf() < 0.5: _add_cypress(x + 2.4 + randf() * 1.5, z + (randf() - 0.5) * 3.0, 0.8)
		elif roll < 0.8:
			# mossy standing boulder
			var rock := MeshLib.sphere(1.1 + randf() * 0.7, MeshLib.lit_mat(MeshLib.rgb(0xa8acb8)), 7, 5)
			rock.position = Vector3(x, 0.8, z)
			rock.scale = Vector3(1, 1.1 + randf() * 0.6, 1)
			rock.rotation.y = randf() * PI
			_add(rock)
			_obstacle(x, z, 1.3)
		else:
			# a lone woodsman's hut
			var sides := ["pz", "nz", "px", "nx"]
			_add_house(x, z, 6.0 + randf() * 2.0, 5.5 + randf() * 1.5, 2.7 + randf() * 0.6, _pick_house(), sides[randi() % 4])
			if randf() < 0.6: _add_cypress(x + 5.0, z + (randf() - 0.5) * 3.0, 0.9)

# ------------------------------------------------------------- wind leaves
static func _build_wind_leaves() -> void:
	if _game.mode == Game.Mode.SERVER or _game.lite:
		return   # pure decoration; skip it for headless and lite worlds
	var A: float = _game.ARENA
	var mesh := _make_windleaf_mesh()
	var tones := [0x7cb46c, 0x8fc27e, 0x6aa55e, 0x9acb86]
	for i in 60:
		var mat := MeshLib.unlit_mat(MeshLib.rgb(tones[i % tones.size()]), 0.92)
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		var m := MeshLib.mi(mesh, mat)
		var low := randf() < 0.5
		var s := 0.55 + randf() * 0.85
		m.scale = Vector3.ONE * s
		_add(m)
		_game.wind_leaves.append({
			"mesh": m,
			"x": (randf() * 2.0 - 1.0) * A, "z": (randf() * 2.0 - 1.0) * A,
			"y": (0.25 + randf() * 1.2) if low else (1.6 + randf() * 11.0),
			"ph": randf() * 7.0, "spin": (randf() * 2.0 - 1.0) * 2.2,
			"vx": 2.2 + randf() * 2.6, "vz": (randf() * 2.0 - 1.0) * 1.4,
			"bob": 0.4 + randf() * 1.3,
		})

static func _make_windleaf_mesh() -> ArrayMesh:
	# sample the original quadratic-bezier leaf outline, then triangulate
	var pts := PackedVector2Array()
	var segs := [
		[Vector2(0, -0.55), Vector2(0.42, -0.28), Vector2(0.35, 0.15)],
		[Vector2(0.35, 0.15), Vector2(0.24, 0.5), Vector2(0, 0.62)],
		[Vector2(0, 0.62), Vector2(-0.24, 0.5), Vector2(-0.35, 0.15)],
		[Vector2(-0.35, 0.15), Vector2(-0.42, -0.28), Vector2(0, -0.55)],
	]
	for seg in segs:
		for k in 6:
			var t := float(k) / 6.0
			var a: Vector2 = seg[0]; var c: Vector2 = seg[1]; var b: Vector2 = seg[2]
			var p := a.lerp(c, t).lerp(c.lerp(b, t), t)
			pts.append(p)
	var idx := Geometry2D.triangulate_polygon(pts)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for ii in idx:
		st.add_vertex(Vector3(pts[ii].x, pts[ii].y, 0))
	return st.commit()
