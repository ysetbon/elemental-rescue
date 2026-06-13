class_name WorldBuilder
extends Object
# Builds the static twilight town and registers collision data (obstacles /
# rects / caves) back onto the Game node. Faithful port of the prototype world.

const HOUSE_COLORS := [0xf4f1e8, 0xf7f4ec, 0xf0e6cd, 0xefa07f, 0xe98a5f, 0xf3c9a4, 0xfaf7f0]
const ROOF_COLORS := [0x4e4b57, 0x5e5863, 0x675f5c, 0xd2603c]
const CYPRESS_COLORS := [0x3d5244, 0x44604f, 0x35463a]
const CAVE_TINTS := { "fire": 0xd8907a, "water": 0x8aa8cc, "grass": 0x8cb896 }

static var _root: Node3D
static var _game

static func build(game) -> void:
	_game = game
	_root = game.world_root
	_ground_and_walls()
	_river_and_bridges()
	_build_school()
	_build_playground()
	_build_zoo()
	# home + neutral caves
	add_cave(-85, 45, "")
	add_cave(75, 80, "")
	add_cave(55, -85, "")
	add_cave(-20, -100, "fire")
	add_cave(30, 32, "water")
	add_cave(-95, 100, "grass")
	_build_clan_camps()
	_build_neighborhoods()
	_scatter()
	_build_wind_leaves()

# --------------------------------------------------- registration helpers
static func _obstacle(x: float, z: float, r: float) -> void:
	_game.obstacles.append({ "x": x, "z": z, "r": r })

static func _rect(x: float, z: float, hw: float, hd: float) -> void:
	_game.rects.append({ "x": x, "z": z, "hw": hw, "hd": hd })

static func _add(n: Node3D) -> void:
	_root.add_child(n)

static func _pick_house() -> Color:
	return MeshLib.rgb(HOUSE_COLORS[randi() % HOUSE_COLORS.size()])

# ------------------------------------------------------- ground / boundary
static func _ground_and_walls() -> void:
	var A: float = _game.ARENA
	var g := PlaneMesh.new()
	g.size = Vector2(A * 2 + 40, A * 2 + 40)
	_add(MeshLib.mi(g, MeshLib.lit_mat(MeshLib.rgb(0xdce7f4))))
	var wall_mat := MeshLib.lit_mat(MeshLib.rgb(0xe7e9f1))
	var walls := [
		[0.0, -A - 1.5, A * 2 + 6, 3.0], [0.0, A + 1.5, A * 2 + 6, 3.0],
		[-A - 1.5, 0.0, 3.0, A * 2 + 6], [A + 1.5, 0.0, 3.0, A * 2 + 6],
	]
	for w in walls:
		_add_box_wall(w[0], w[1], w[2], w[3], 3.0, wall_mat)

static func _add_box_wall(x: float, z: float, w: float, d: float, h: float, mat: Material) -> MeshInstance3D:
	var m := MeshLib.box(w, h, d, mat)
	m.position = Vector3(x, h / 2.0, z)
	_add(m)
	_rect(x, z, w / 2.0, d / 2.0)
	return m

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
	# white windows
	var on_z := win_side == "pz" or win_side == "nz"
	var span := w if on_z else d
	var sgn := 1.0 if (win_side == "pz" or win_side == "px") else -1.0
	var n := 2 if span > 8.5 else 1
	var win_mat := MeshLib.unlit_mat(MeshLib.rgb(0xfbfaf4))
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

static func _add_street(x: float, z: float, w: float, d: float) -> void:
	var p := PlaneMesh.new()
	p.size = Vector2(w, d)
	var s := MeshLib.mi(p, MeshLib.lit_mat(MeshLib.rgb(0xf4f5f9)))
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

# ------------------------------------------------------------- caves
static func add_cave(cx: float, cz: float, owner: String) -> void:
	var r := 4.8
	var open_angle := atan2(-cz, -cx)
	var rock_mat: Material = MeshLib.lit_mat(MeshLib.rgb(CAVE_TINTS[owner])) if owner != "" else MeshLib.lit_mat(MeshLib.rgb(0xbcc0cc))
	var segs := 12
	for i in segs:
		var a := open_angle + PI / 4.0 + i * (PI * 1.5 / (segs - 1))
		var x := cx + cos(a) * r
		var z := cz + sin(a) * r
		var rock := MeshLib.sphere(1.5, rock_mat, 6, 4)
		rock.position = Vector3(x, 1.2, z)
		rock.scale = Vector3(1, 1.7, 1)
		rock.rotation = Vector3((randf() - 0.5) * 0.3, randf() * PI, (randf() - 0.5) * 0.3)
		_add(rock)
		_obstacle(x, z, 1.25)
	# semi-glass / semi-stone roof so a character sheltering inside stays visible from above
	var roof_col: Color = MeshLib.rgb(CAVE_TINTS[owner]) if owner != "" else MeshLib.rgb(0xbcc0cc)
	var roof := MeshLib.cyl(r + 1.4, r + 0.5, 1.2, MeshLib.glass_stone_mat(roof_col, 0.42), 14)
	roof.position = Vector3(cx, 3.6, cz)
	_add(roof)
	var glow_color: Color = MeshLib.rgb(_game.ELEMENTS[owner]["color"]) if owner != "" else MeshLib.rgb(0xf0c060)
	var glow := MeshLib.disc(r - 0.8, MeshLib.unlit_mat(glow_color, 0.16 if owner != "" else 0.09), 22)
	glow.position = Vector3(cx, 0.08, cz)
	_add(glow)
	if owner != "":
		var bm := CylinderMesh.new()
		bm.top_radius = 0.4; bm.bottom_radius = 0.4; bm.height = 60.0
		bm.radial_segments = 8; bm.cap_top = false; bm.cap_bottom = false
		var beam_mat := MeshLib.unlit_mat(glow_color, 0.28)
		beam_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		var beam := MeshLib.mi(bm, beam_mat)
		beam.position = Vector3(cx, 30, cz)
		_add(beam)
	var radar_fill: Color = MeshLib.rgb(_game.ELEMENTS[owner]["color"]) if owner != "" else MeshLib.rgb(0xe0a93c)
	var cave := { "x": cx, "z": cz, "r": r, "owner": owner, "openAngle": open_angle, "radarFill": radar_fill }
	_game.caves.append(cave)
	if owner != "":
		_game.cave_by_owner[owner] = cave

# ------------------------------------------------------------- school
static func _build_school() -> void:
	var s: Dictionary = _game.SCHOOL
	var sx: float = s["x"]; var sz: float = s["z"]; var w: float = s["w"]; var d: float = s["d"]
	var brick := MeshLib.lit_mat(MeshLib.rgb(0xead9b8))
	var H := 4.0; var T := 0.7; var door_w := 5.0
	_add_box_wall(sx, sz - d / 2.0, w, T, H, brick)
	_add_box_wall(sx, sz + d / 2.0, w, T, H, brick)
	_add_box_wall(sx + w / 2.0, sz, T, d, H, brick)
	var seg_d := (d - door_w) / 2.0
	_add_box_wall(sx - w / 2.0, sz - door_w / 2.0 - seg_d / 2.0, T, seg_d, H, brick)
	_add_box_wall(sx - w / 2.0, sz + door_w / 2.0 + seg_d / 2.0, T, seg_d, H, brick)
	var frame_mat := MeshLib.lit_mat(MeshLib.rgb(0xf0c060))
	var lintel := MeshLib.box(T + 0.3, 0.7, door_w + 1.0, frame_mat)
	lintel.position = Vector3(sx - w / 2.0, H - 0.35, sz)
	_add(lintel)
	var roof := MeshLib.box(w + 2.0, 0.6, d + 2.0, MeshLib.lit_mat(MeshLib.rgb(ROOF_COLORS[0])))
	roof.position = Vector3(sx, H + 1.6, sz)
	_add(roof)
	var floor_p := PlaneMesh.new(); floor_p.size = Vector2(w - T, d - T)
	var floor := MeshLib.mi(floor_p, MeshLib.lit_mat(MeshLib.rgb(0xe8dec6)))
	floor.position = Vector3(sx, 0.07, sz)
	_add(floor)
	var board := MeshLib.box(0.2, 2.4, 8.0, MeshLib.lit_mat(MeshLib.rgb(0x2e5a40)))
	board.position = Vector3(sx + w / 2.0 - 0.6, 2.0, sz)
	_add(board)
	var chalk := MeshLib.box(0.22, 0.12, 2.4, MeshLib.unlit_mat(MeshLib.rgb(0xfdfaf0)))
	chalk.position = Vector3(sx + w / 2.0 - 0.58, 2.3, sz - 1.5)
	_add(chalk)
	var desk_mat := MeshLib.lit_mat(MeshLib.rgb(0xcbab80))
	var add_desk := func(dx: float, dz: float, big: bool) -> void:
		var dm := MeshLib.box(3.0 if big else 2.2, 1.1, 1.6 if big else 1.2, desk_mat)
		dm.position = Vector3(dx, 0.55, dz)
		_add(dm)
		_obstacle(dx, dz, 1.5 if big else 1.1)
	add_desk.call(sx + w / 2.0 - 4.0, sz, true)
	for rz in [-5.5, 0.0, 5.5]:
		for rx_off in [-7.0, -2.0]:
			add_desk.call(sx + rx_off, sz + rz, false)
	var sign := MeshLib.box(0.2, 1.4, 3.0, frame_mat)
	sign.position = Vector3(sx - w / 2.0 - 3.0, 2.4, sz - 4.0)
	_add(sign)
	var post := MeshLib.cyl(0.12, 0.12, 2.6, MeshLib.lit_mat(MeshLib.rgb(0x97816a)), 6)
	post.position = Vector3(sx - w / 2.0 - 3.0, 1.3, sz - 4.0)
	_add(post)

# ------------------------------------------------------------- playground
static func _build_playground() -> void:
	var p: Dictionary = _game.PLAYGROUND
	var px: float = p["x"]; var pz: float = p["z"]
	var metal := MeshLib.lit_mat(MeshLib.rgb(0xe8825e))
	var metal2 := MeshLib.lit_mat(MeshLib.rgb(0x6f9bd8))
	var pad_p := PlaneMesh.new(); pad_p.size = Vector2(32, 32)
	var pad := MeshLib.mi(pad_p, MeshLib.lit_mat(MeshLib.rgb(0xf0e8d6)))
	pad.position = Vector3(px, 0.06, pz)
	_add(pad)

	# swing set
	var sw := Node3D.new()
	var top := MeshLib.cyl(0.12, 0.12, 7.0, metal, 8)
	top.rotation.z = PI / 2.0; top.position.y = 3.4
	sw.add_child(top)
	for sgn in [-1, 1]:
		var leg_a := MeshLib.cyl(0.12, 0.12, 3.8, metal, 6)
		leg_a.position = Vector3(sgn * 3.4, 1.7, 0.8); leg_a.rotation.x = 0.22
		var leg_b := MeshLib.cyl(0.12, 0.12, 3.8, metal, 6)
		leg_b.position = Vector3(sgn * 3.4, 1.7, -0.8); leg_b.rotation.x = -0.22
		sw.add_child(leg_a); sw.add_child(leg_b)
	var seats: Array = []
	for sx in [-1.4, 1.4]:
		var pivot := Node3D.new()
		pivot.position = Vector3(sx, 3.4, 0)
		var rope1 := MeshLib.cyl(0.04, 0.04, 2.6, MeshLib.lit_mat(MeshLib.rgb(0xeceef4)), 4)
		rope1.position = Vector3(-0.4, -1.3, 0)
		var rope2 := MeshLib.cyl(0.04, 0.04, 2.6, MeshLib.lit_mat(MeshLib.rgb(0xeceef4)), 4)
		rope2.position = Vector3(0.4, -1.3, 0)
		var seat := MeshLib.box(1.1, 0.12, 0.5, MeshLib.lit_mat(MeshLib.rgb(0x3a3744)))
		seat.position.y = -2.6
		pivot.add_child(rope1); pivot.add_child(rope2); pivot.add_child(seat)
		sw.add_child(pivot)
		seats.append(pivot)
	sw.position = Vector3(px - 8, 0, pz - 6)
	_add(sw)
	_game.deco_anims.append(func(t: float) -> void:
		seats[0].rotation.x = sin(t * 0.0022) * 0.45
		seats[1].rotation.x = sin(t * 0.0022 + 1.6) * 0.45)
	_obstacle(px - 8 - 3.4, pz - 6, 0.9)
	_obstacle(px - 8 + 3.4, pz - 6, 0.9)

	# slide
	var slide := Node3D.new()
	var tower := MeshLib.box(2.2, 3.0, 2.2, metal2); tower.position.y = 1.5
	var ramp := MeshLib.box(1.6, 0.2, 5.6, MeshLib.lit_mat(MeshLib.rgb(0xf0c060)))
	ramp.position = Vector3(0, 1.5, 3.6); ramp.rotation.x = 0.5
	var ladder := MeshLib.box(1.2, 0.15, 2.6, metal2)
	ladder.position = Vector3(0, 1.6, -2.2); ladder.rotation.x = -0.9
	slide.add_child(tower); slide.add_child(ramp); slide.add_child(ladder)
	slide.position = Vector3(px + 7, 0, pz - 5)
	_add(slide)
	_obstacle(px + 7, pz - 5, 1.8)

	# merry-go-round
	var mg := Node3D.new()
	var dsc := MeshLib.cyl(2.4, 2.4, 0.25, MeshLib.lit_mat(MeshLib.rgb(0xbaa0e0)), 16)
	dsc.position.y = 0.4
	mg.add_child(dsc)
	for i in 4:
		var bar := MeshLib.cyl(0.08, 0.08, 1.2, metal, 6)
		var a := i * PI / 2.0
		bar.position = Vector3(cos(a) * 1.8, 1.05, sin(a) * 1.8)
		mg.add_child(bar)
	mg.position = Vector3(px, 0, pz + 7)
	_add(mg)
	_game.deco_anims.append(func(t: float) -> void: mg.rotation.y = t * 0.0009)
	_obstacle(px, pz + 7, 2.6)

	# seesaw
	var ss := Node3D.new()
	var ful := MeshLib.mi(_cone(0.6, 1.0, 8), metal2); ful.position.y = 0.5
	var plank := MeshLib.box(6.0, 0.2, 0.8, MeshLib.lit_mat(MeshLib.rgb(0x93c79a)))
	plank.position.y = 1.0
	ss.add_child(ful); ss.add_child(plank)
	ss.position = Vector3(px - 3, 0, pz + 1)
	_add(ss)
	_game.deco_anims.append(func(t: float) -> void: plank.rotation.z = sin(t * 0.0016) * 0.22)
	_obstacle(px - 3, pz + 1, 0.9)

static func _cone(r: float, h: float, seg: int) -> CylinderMesh:
	var c := CylinderMesh.new()
	c.top_radius = 0.0; c.bottom_radius = r; c.height = h; c.radial_segments = seg; c.rings = 1
	return c

# ------------------------------------------------------------- zoo
static func _build_zoo() -> void:
	var z: Dictionary = _game.ZOO
	var zx: float = z["x"]; var zz: float = z["z"]
	var path_p := PlaneMesh.new(); path_p.size = Vector2(30, 30)
	var path := MeshLib.mi(path_p, MeshLib.lit_mat(MeshLib.rgb(0xdcd8e4)))
	path.position = Vector3(zx, 0.055, zz)
	_add(path)
	var bar_mat := MeshLib.lit_mat(MeshLib.rgb(0xa09eb0))
	var builders: Array[Callable] = [MeshLib.build_flame, MeshLib.build_droplet, MeshLib.build_leaf, MeshLib.build_o2, MeshLib.build_co2]
	var idents := ["fire", "water", "grass", "o2", "co2"]
	for i in 5:
		var a := float(i) / 5.0 * TAU + 0.5
		_add_cage(zx + cos(a) * 9.0, zz + sin(a) * 9.0, builders[i], bar_mat, idents[i])
	var bench_mat := MeshLib.lit_mat(MeshLib.rgb(0xc0a78f))
	for a in [0.2, 2.3, 4.4]:
		var bench := MeshLib.box(2.4, 0.5, 0.8, bench_mat)
		bench.position = Vector3(zx + cos(a) * 14.5, 0.35, zz + sin(a) * 14.5)
		bench.rotation.y = -a
		_add(bench)

static func _add_cage(cx: float, cz: float, build_fn: Callable, bar_mat: Material, ident: String = "") -> void:
	var r := 2.3
	# bars + ring + captive live in one group so releasing the twin can hide them.
	# semi-glass / semi-stone bars + a translucent domed lid so the captive stays
	# visible even when the camera looks straight down from the ceiling.
	var gs := MeshLib.glass_stone_mat(MeshLib.rgb(0xa6b0c4), 0.5)
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

# ----------------------------------------------------- clan camps (per element)
static func _build_clan_camps() -> void:
	for el in ["fire", "water", "grass"]:
		var c: Dictionary = _game.cave_by_owner[el]
		var cx: float = c["x"]; var cz: float = c["z"]
		var dir := Vector2(-cx, -cz).normalized()   # point in toward the map centre
		var perp := Vector2(-dir.y, dir.x)
		var hx := cx + dir.x * 11.0 + perp.x * 5.0
		var hz := cz + dir.y * 11.0 + perp.y * 5.0
		var px := cx + dir.x * 11.0 - perp.x * 5.0
		var pz := cz + dir.y * 11.0 - perp.y * 5.0
		var col: Color = MeshLib.rgb(_game.ELEMENTS[el]["color"])
		_build_clan_hall(hx, hz, col)
		_build_training_pad(px, pz, col)
		_game.clan_hall_by_owner[el] = { "x": hx, "z": hz, "r": 3.2 }
		_game.train_pad_by_owner[el] = { "x": px, "z": pz, "r": 2.6 }

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
	var roof := MeshLib.cyl(3.1, 3.4, 0.4, MeshLib.glass_stone_mat(col, 0.5), 16)
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

# ------------------------------------------------------------- neighborhoods
static func _build_neighborhoods() -> void:
	_add_street(-66, -60, 62, 16)
	var x := -94.0
	while x <= -38.0:
		var jx := x + (randf() - 0.5) * 3.0
		_add_house(jx, -75 + (randf() - 0.5) * 2.0, 8 + randf() * 3.0, 7 + randf() * 2.0, 3 + randf() * 0.9, _pick_house(), "pz")
		_add_house(jx + 4, -45 + (randf() - 0.5) * 2.0, 8 + randf() * 3.0, 7 + randf() * 2.0, 3 + randf() * 0.9, _pick_house(), "nz")
		if randf() < 0.65: _add_cypress(jx + 6.8, -75 + (randf() - 0.5) * 4.0)
		if randf() < 0.65: _add_cypress(jx - 2.5, -45 + (randf() - 0.5) * 4.0)
		x += 13.5
	_add_street(85, 19, 12, 50)
	var zz := -4.0
	while zz <= 42.0:
		_add_house(93, zz + (randf() - 0.5) * 3.0, 7 + randf() * 2.0, 8 + randf() * 3.0, 3 + randf() * 0.9, _pick_house(), "nx")
		if randf() < 0.7: _add_cypress(86 + randf() * 2.0, zz + 6)
		zz += 13.5

static func _scatter() -> void:
	var A: float = _game.ARENA
	var x1: float = _game.RIVER_X1
	var x2: float = _game.RIVER_X2
	var keepouts := [
		{ "x": _game.PLAYGROUND["x"], "z": _game.PLAYGROUND["z"], "r": 19.0 },
		{ "x": _game.ZOO["x"], "z": _game.ZOO["z"], "r": 18.0 },
		{ "x": -66.0, "z": -60.0, "r": 40.0 },
		{ "x": 93.0, "z": 19.0, "r": 26.0 },
	]
	for el in _game.clan_hall_by_owner:
		var h: Dictionary = _game.clan_hall_by_owner[el]
		keepouts.append({ "x": h["x"], "z": h["z"], "r": 8.0 })
	for el in _game.train_pad_by_owner:
		var p: Dictionary = _game.train_pad_by_owner[el]
		keepouts.append({ "x": p["x"], "z": p["z"], "r": 7.0 })
	var spots: Array = []
	for i in 34:
		var x := 0.0; var z := 0.0; var ok := false; var tries := 0
		while not ok and tries < 80:
			x = (randf() * 2.0 - 1.0) * (A - 8)
			z = (randf() * 2.0 - 1.0) * (A - 8)
			ok = Vector2(x, z).length() > 10.0 \
				and not (x > x1 - 4 and x < x2 + 4) \
				and _game.caves.all(func(c): return Vector2(c["x"] - x, c["z"] - z).length() > c["r"] + 6) \
				and keepouts.all(func(k): return Vector2(k["x"] - x, k["z"] - z).length() > k["r"]) \
				and _game.rects.all(func(r): return absf(x - r["x"]) > r["hw"] + 6 or absf(z - r["z"]) > r["hd"] + 6) \
				and spots.all(func(s): return Vector2(s[0] - x, s[1] - z).length() > 12)
			tries += 1
		if not ok:
			continue
		spots.append([x, z])
		if randf() < 0.35:
			var sides := ["pz", "nz", "px", "nx"]
			_add_house(x, z, 7 + randf() * 2.5, 6 + randf() * 2.0, 2.9 + randf() * 0.9, _pick_house(), sides[randi() % 4])
			if randf() < 0.6: _add_cypress(x + 5.5, z + (randf() - 0.5) * 3.0, 0.9)
		else:
			_add_cypress(x, z)
			if randf() < 0.5: _add_cypress(x + 2.4 + randf() * 1.5, z + (randf() - 0.5) * 3.0, 0.8)

# ------------------------------------------------------------- wind leaves
static func _build_wind_leaves() -> void:
	var A: float = _game.ARENA
	var mesh := _make_windleaf_mesh()
	var tones := [0x7cb46c, 0x8fc27e, 0x6aa55e, 0x9acb86]
	for i in 44:
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
