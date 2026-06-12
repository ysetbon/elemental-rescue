class_name Game
extends Node3D
# Elemental Tag — Godot port of the Three.js prototype.
# Three elements play rock-paper-scissors tag across a twilight town while CO₂
# hunts everyone and O₂ molecules hand out points. Most points when time runs out.

# ------------------------------------------------------------------ constants
const ARENA := 120.0
const CATCH_DIST := 2.4
const SIGHT_RANGE := 55.0
const CO2_SIGHT := 28.0
const PTS_O2 := 5
const PTS_PREY := 15
const ROUND_TIME := 240.0
const N_O2 := 6
const N_CO2 := 3
const RIVER_X1 := 2.0
const RIVER_X2 := 14.0
const RADAR_RANGE := 70.0
const CAVE_MAX_STAY := 30.0
const CAVE_LOCKOUT := 10.0
const CAM_DIST := 13.0   # pulled back for situational awareness
const CAM_H := 5.5       # raised a touch for a clearer overview of the surroundings
const TRAIL_N := 60

# --- lighting, tuned to match elements_graphics.png (warm key, cool fill, pink haze) ---
const AMBIENT_COLOR := 0xc6d0ea
const AMBIENT_ENERGY := 0.70
const SUN_COLOR := 0xffeccb
const SUN_ENERGY := 0.60
const SUN_FROM := Vector3(-95.0, 52.0, 38.0)
const FOG_COLOR := 0xeec7b7
const FOG_DENSITY := 0.0062
const EXPOSURE := 1.0

const BRIDGES := [{ "z": -70.0, "half": 3.5 }, { "z": 0.0, "half": 3.5 }, { "z": 70.0, "half": 3.5 }]
const SCHOOL := { "x": 80.0, "z": -60.0, "w": 28.0, "d": 20.0 }
const PLAYGROUND := { "x": -70.0, "z": 70.0 }
const ZOO := { "x": -34.0, "z": 24.0 }

const ELEMENTS := {
	"fire": { "color": 0xf0662a, "glow": 0xffc878, "prey": "grass", "predator": "water", "label": "Fire" },
	"water": { "color": 0x6d9ce9, "glow": 0xb6d2f8, "prey": "fire", "predator": "grass", "label": "Water" },
	"grass": { "color": 0x8fa86e, "glow": 0xc8dcae, "prey": "water", "predator": "fire", "label": "Leaf" },
}

# --------------------------------------------------------------- world data
var world_root: Node3D
var obstacles: Array = []        # [{ "x","z","r" }]
var rects: Array = []            # [{ "x","z","hw","hd" }]
var caves: Array = []            # [{ "x","z","r","owner","openAngle","radarFill" }]
var cave_by_owner: Dictionary = {}
var deco_anims: Array = []       # [Callable(t_ms)]
var wind_leaves: Array = []

# --------------------------------------------------------------- game state
var chars: Dictionary = {}       # el -> GameChar
var npcs: Array = []             # [GameChar]
var player: GameChar = null
var running := false
var ending := false
var time_ms := 0.0
var time_left := ROUND_TIME
var o2_left := N_O2
var stamina := 100.0

var camera: Camera3D
var ui: GameUI
var cam_yaw := 0.0
var dragging := false

var trail_pool: Array = []
var trail_idx := 0

var _shot_t := 0.0
var _shot_done := false

# ------------------------------------------------------------------- setup
func _ready() -> void:
	randomize()
	_build_environment()
	world_root = Node3D.new()
	add_child(world_root)
	WorldBuilder.build(self)
	_build_trails()
	ui = GameUI.new()
	add_child(ui)
	ui.element_selected.connect(start_game)
	ui.play_again.connect(_on_play_again)
	var radar_caves: Array = []
	for c in caves:
		radar_caves.append({ "x": c["x"], "z": c["z"], "r": c["r"], "fill": c["radarFill"] })
	ui.radar.setup(RIVER_X1, RIVER_X2, BRIDGES, radar_caves)
	# debug: `-- autostart` skips the menu/countdown (handy for smoke-testing)
	if OS.get_cmdline_user_args().has("autostart"):
		var _el := "fire"
		if OS.get_cmdline_user_args().has("water"): _el = "water"
		elif OS.get_cmdline_user_args().has("grass"): _el = "grass"
		start_game(_el)
		running = true

func _build_environment() -> void:
	camera = Camera3D.new()
	camera.fov = 60
	camera.far = 900
	add_child(camera)

	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	var shader := Shader.new()
	shader.code = SKY_SHADER
	var smat := ShaderMaterial.new()
	smat.shader = shader
	sky.sky_material = smat
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = MeshLib.rgb(AMBIENT_COLOR)
	env.ambient_light_energy = AMBIENT_ENERGY
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	env.tonemap_exposure = EXPOSURE
	env.fog_enabled = true
	env.fog_light_color = MeshLib.rgb(FOG_COLOR)
	env.fog_density = FOG_DENSITY
	env.fog_sky_affect = 0.0
	env.fog_aerial_perspective = 0.0
	env.ssr_enabled = true
	env.ssr_max_steps = 48
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)

	var sun := DirectionalLight3D.new()
	sun.light_color = MeshLib.rgb(SUN_COLOR)
	sun.light_energy = SUN_ENERGY
	sun.shadow_enabled = false
	add_child(sun)
	sun.look_at_from_position(SUN_FROM, Vector3.ZERO, Vector3.UP)

func _build_trails() -> void:
	for i in TRAIL_N:
		var m := StandardMaterial3D.new()
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.albedo_color = Color(1, 1, 1, 0)
		var s := SphereMesh.new()
		s.radius = 0.22; s.height = 0.44; s.radial_segments = 8; s.rings = 5
		var mi := MeshInstance3D.new()
		mi.mesh = s
		mi.material_override = m
		mi.visible = false
		add_child(mi)
		trail_pool.append({ "mesh": mi, "mat": m, "life": 0.0 })

# ------------------------------------------------------------------ main loop
func _process(delta: float) -> void:
	var dt: float = minf(0.05, delta)
	time_ms += delta * 1000.0
	for fn in deco_anims:
		fn.call(time_ms)
	_update_wind_leaves(dt, time_ms)

	if running:
		time_left -= dt
		if time_left <= 0.0:
			time_left = 0.0
			end_game("time")
		ui.set_timer("Time " + _fmt_time(time_left))
		_update_player(dt)
		for ch in chars.values():
			if not ch.is_player and ch.alive:
				_update_element_ai(ch, dt)
		for n in npcs:
			if n.alive:
				if n.kind == "co2":
					_update_co2(n, dt)
				else:
					_update_o2(n, dt)
		_update_cave_timers(dt)
		_check_catches()
		for ch in chars.values():
			if ch.alive and not ch.is_player and ch.vel.length_squared() > 120.0 and randf() < dt * 14.0:
				_spawn_trail(ch)

	_update_trails(dt)
	for ch in all_chars():
		if not ch.alive:
			continue
		ch.group.position = ch.pos
		if ch.vel.length_squared() > 0.5:
			ch.group.rotation.y = lerp_angle(ch.group.rotation.y, atan2(ch.vel.x, ch.vel.z), 1.0 - pow(0.001, dt))
		ch.group.animate(time_ms, ch.vel.length())

	_update_camera(dt)

	# TEMP capture hook: `-- autostart shot [water|grass] [walk]`
	if OS.get_cmdline_user_args().has("shot") and player:
		var walk := OS.get_cmdline_user_args().has("walk")
		if walk:
			# drive the player forward and watch from the side
			player.vel = Vector3(-sin(cam_yaw), 0, -cos(cam_yaw)) * player.speed
			player.pos += player.vel * delta
			player.group.rotation.y = atan2(player.vel.x, player.vel.z)
			player.group.animate(time_ms, player.vel.length())
			var bx: float = player.pos.x + sin(cam_yaw + 1.5) * 5.0
			var bz: float = player.pos.z + cos(cam_yaw + 1.5) * 5.0
			camera.position = Vector3(bx, 1.9, bz)
			camera.look_at(Vector3(player.pos.x, 1.3, player.pos.z), Vector3.UP)
		else:
			player.group.rotation.y = cam_yaw  # face the camera
			var px: float = player.pos.x + sin(cam_yaw) * 4.5
			var pz: float = player.pos.z + cos(cam_yaw) * 4.5
			camera.position = Vector3(px, 2.4, pz)
			camera.look_at(Vector3(player.pos.x, 1.6, player.pos.z), Vector3.UP)
		var cap := 3.4
		for a in OS.get_cmdline_user_args():
			if a.begins_with("cap"): cap = float(a.substr(3)) / 10.0
		_shot_t += delta
		if _shot_t > cap and not _shot_done:
			_shot_done = true
			var img := get_viewport().get_texture().get_image()
			img.save_png("res://_shot.png")
			get_tree().quit()

# ------------------------------------------------------------------ input
func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		dragging = event.pressed
	elif event is InputEventMouseMotion and dragging:
		cam_yaw -= event.relative.x * 0.0052

# ------------------------------------------------------------------ camera
func _update_camera(dt: float) -> void:
	if player:
		var d := _cam_obstruction(player.pos.x, player.pos.z, sin(cam_yaw), cos(cam_yaw), CAM_DIST)
		var tx := player.pos.x + sin(cam_yaw) * d
		var tz := player.pos.z + cos(cam_yaw) * d
		camera.position = camera.position.lerp(Vector3(tx, CAM_H, tz), 1.0 - pow(0.0001, dt))
		camera.look_at(Vector3(player.pos.x, 1.9, player.pos.z), Vector3.UP)
		var blips: Array = []
		for ch in all_chars():
			if not ch.alive or ch == player:
				continue
			blips.append({ "pos": Vector2(ch.pos.x, ch.pos.z), "color": ch.radar_color, "o2": ch.kind == "o2" })
		ui.radar.update_data(Vector2(player.pos.x, player.pos.z), player.group.rotation.y, blips)
	else:
		var a := time_ms * 0.00006
		camera.position = Vector3(sin(a) * 62.0, 17.0, cos(a) * 62.0)
		camera.look_at(Vector3(0, 2, 0), Vector3.UP)

func _cam_obstruction(px: float, pz: float, dx: float, dz: float, maxd: float) -> float:
	var best := maxd
	for o in obstacles:
		var ox: float = px - o["x"]
		var oz: float = pz - o["z"]
		var b: float = ox * dx + oz * dz
		var c: float = ox * ox + oz * oz - o["r"] * o["r"]
		var disc: float = b * b - c
		if disc < 0.0:
			continue
		var t: float = -b - sqrt(disc)
		if t > 0.0 and t < best:
			best = t
	for r in rects:
		var t: float = _ray_aabb(px, pz, dx, dz, r["x"] - r["hw"], r["z"] - r["hd"], r["x"] + r["hw"], r["z"] + r["hd"])
		if t >= 0.0 and t < best:
			best = t
	return maxf(2.6, best - 0.5) if best < maxd else maxd

func _ray_aabb(ox: float, oz: float, dx: float, dz: float, minx: float, minz: float, maxx: float, maxz: float) -> float:
	var tmin := -INF
	var tmax := INF
	if absf(dx) < 1e-9:
		if ox < minx or ox > maxx:
			return -1.0
	else:
		var t1 := (minx - ox) / dx
		var t2 := (maxx - ox) / dx
		if t1 > t2:
			var tmp := t1; t1 = t2; t2 = tmp
		tmin = maxf(tmin, t1); tmax = minf(tmax, t2)
	if absf(dz) < 1e-9:
		if oz < minz or oz > maxz:
			return -1.0
	else:
		var t1 := (minz - oz) / dz
		var t2 := (maxz - oz) / dz
		if t1 > t2:
			var tmp := t1; t1 = t2; t2 = tmp
		tmin = maxf(tmin, t1); tmax = minf(tmax, t2)
	if tmax < tmin or tmax < 0.0:
		return -1.0
	return maxf(0.0, tmin)

# ------------------------------------------------------------------ terrain
func in_river(p: Vector3) -> bool:
	return p.x > RIVER_X1 and p.x < RIVER_X2

func on_bridge(p: Vector3) -> bool:
	for b in BRIDGES:
		if absf(p.z - b["z"]) < b["half"]:
			return true
	return false

func terrain_mult(ch: GameChar) -> float:
	if ch.kind != "element":
		return 1.0
	if ch.el == "water":
		return 1.0
	return 0.55 if (in_river(ch.pos) and not on_bridge(ch.pos)) else 1.0

# ------------------------------------------------------------------ caves
func inside_cave(p: Vector3) -> bool:
	for c in caves:
		if Vector2(p.x - c["x"], p.z - c["z"]).length() < c["r"] - 0.4:
			return true
	return false

func inside_own_cave(ch: GameChar) -> bool:
	if not cave_by_owner.has(ch.el):
		return false
	var c: Dictionary = cave_by_owner[ch.el]
	return Vector2(ch.pos.x - c["x"], ch.pos.z - c["z"]).length() < c["r"]

func cave_blocks(ch: GameChar, c: Dictionary) -> bool:
	if ch.kind == "co2":
		return true
	if c["owner"] == "":
		return false
	if ch.kind != "element":
		return true
	if ch.el != c["owner"]:
		return true
	return ch.cave_cooldown > 0.0

func _eject_from_cave(ch: GameChar) -> void:
	if not cave_by_owner.has(ch.el):
		return
	var c: Dictionary = cave_by_owner[ch.el]
	var a: float = c["openAngle"]
	ch.pos = Vector3(c["x"] + cos(a) * (c["r"] + 2.2), 0, c["z"] + sin(a) * (c["r"] + 2.2))
	ch.vel = Vector3(cos(a), 0, sin(a)) * 6.0
	ch.cave_cooldown = CAVE_LOCKOUT
	if ch.is_player:
		ui.toast("Ejected! Cave locked for %ds" % int(CAVE_LOCKOUT))

func _update_cave_timers(dt: float) -> void:
	for ch in chars.values():
		if not ch.alive:
			continue
		if ch.cave_cooldown > 0.0:
			ch.cave_cooldown = maxf(0.0, ch.cave_cooldown - dt)
		if inside_own_cave(ch):
			ch.cave_time += dt
			if ch.cave_time >= CAVE_MAX_STAY:
				ch.cave_time = 0.0
				_eject_from_cave(ch)
		else:
			ch.cave_time = 0.0
	if player and player.alive and inside_own_cave(player):
		ui.set_cave("Home — safe %ds left" % int(ceil(CAVE_MAX_STAY - player.cave_time)))
	elif player and player.cave_cooldown > 0.0:
		ui.set_cave("Cave lockout %ds" % int(ceil(player.cave_cooldown)))
	else:
		ui.set_cave("")

# ------------------------------------------------------------- line of sight
func can_see(a: GameChar, b: GameChar, range_: float = SIGHT_RANGE) -> bool:
	var dx := b.pos.x - a.pos.x
	var dz := b.pos.z - a.pos.z
	var dist := sqrt(dx * dx + dz * dz)
	if dist > range_:
		return false
	if dist < 0.01:
		return true
	for o in obstacles:
		if _seg_circle(a.pos.x, a.pos.z, b.pos.x, b.pos.z, o["x"], o["z"], o["r"]):
			return false
	for r in rects:
		if _seg_aabb(a.pos.x, a.pos.z, b.pos.x, b.pos.z, r["x"] - r["hw"], r["z"] - r["hd"], r["x"] + r["hw"], r["z"] + r["hd"]):
			return false
	return true

func _seg_circle(ax: float, az: float, bx: float, bz: float, cx: float, cz: float, r: float) -> bool:
	var dx := bx - ax
	var dz := bz - az
	var l2 := dx * dx + dz * dz
	var t := 0.0 if l2 < 1e-9 else clampf(((cx - ax) * dx + (cz - az) * dz) / l2, 0.0, 1.0)
	var qx := ax + dx * t
	var qz := az + dz * t
	return Vector2(qx - cx, qz - cz).length() < r

func _seg_aabb(ax: float, az: float, bx: float, bz: float, minx: float, minz: float, maxx: float, maxz: float) -> bool:
	var dx := bx - ax
	var dz := bz - az
	var tmin := 0.0
	var tmax := 1.0
	if absf(dx) < 1e-9:
		if ax < minx or ax > maxx:
			return false
	else:
		var t1 := (minx - ax) / dx
		var t2 := (maxx - ax) / dx
		if t1 > t2:
			var tmp := t1; t1 = t2; t2 = tmp
		tmin = maxf(tmin, t1); tmax = minf(tmax, t2)
		if tmin > tmax:
			return false
	if absf(dz) < 1e-9:
		if az < minz or az > maxz:
			return false
	else:
		var t1 := (minz - az) / dz
		var t2 := (maxz - az) / dz
		if t1 > t2:
			var tmp := t1; t1 = t2; t2 = tmp
		tmin = maxf(tmin, t1); tmax = minf(tmax, t2)
		if tmin > tmax:
			return false
	return tmax >= tmin

# ------------------------------------------------------------- movement core
func resolve_collisions(ch: GameChar) -> void:
	var R := 0.9
	for o in obstacles:
		var dx: float = ch.pos.x - o["x"]
		var dz: float = ch.pos.z - o["z"]
		var dist := sqrt(dx * dx + dz * dz)
		var mn: float = o["r"] + R
		if dist < mn and dist > 0.001:
			var k := (mn - dist) / dist
			ch.pos.x += dx * k; ch.pos.z += dz * k
	for r in rects:
		var dx: float = ch.pos.x - r["x"]
		var dz: float = ch.pos.z - r["z"]
		if absf(dx) < r["hw"] + R and absf(dz) < r["hd"] + R:
			var ox: float = r["hw"] + R - absf(dx)
			var oz: float = r["hd"] + R - absf(dz)
			if ox < oz:
				ch.pos.x += signf(dx if dx != 0.0 else 1.0) * ox
			else:
				ch.pos.z += signf(dz if dz != 0.0 else 1.0) * oz
	for c in caves:
		if not cave_blocks(ch, c):
			continue
		var dx: float = ch.pos.x - c["x"]
		var dz: float = ch.pos.z - c["z"]
		var dist := sqrt(dx * dx + dz * dz)
		var mn: float = c["r"] + 0.4
		if dist < mn and dist > 0.001:
			var k := (mn - dist) / dist
			ch.pos.x += dx * k; ch.pos.z += dz * k
	var m := ARENA - 1.2
	ch.pos.x = clampf(ch.pos.x, -m, m)
	ch.pos.z = clampf(ch.pos.z, -m, m)

func random_spot(min_r: float = 0.0) -> Vector3:
	for i in 60:
		var x := (randf() * 2.0 - 1.0) * (ARENA - 10.0)
		var z := (randf() * 2.0 - 1.0) * (ARENA - 10.0)
		if Vector2(x, z).length() < min_r:
			continue
		if x > RIVER_X1 - 2 and x < RIVER_X2 + 2:
			continue
		if caves.any(func(c): return Vector2(c["x"] - x, c["z"] - z).length() < c["r"] + 3):
			continue
		if rects.any(func(r): return absf(x - r["x"]) < r["hw"] + 2 and absf(z - r["z"]) < r["hd"] + 2):
			continue
		if obstacles.any(func(o): return Vector2(o["x"] - x, o["z"] - z).length() < o["r"] + 1.5):
			continue
		return Vector3(x, 0, z)
	return Vector3(-30, 0, -30)

# ------------------------------------------------------------------ steering
func _avoidance_and_walls(ch: GameChar, desired: Vector3) -> Vector3:
	var d := desired
	var m := ARENA - 4.0
	if ch.pos.x > m: d.x -= (ch.pos.x - m) * 0.25
	if ch.pos.x < -m: d.x += (-m - ch.pos.x) * 0.25
	if ch.pos.z > m: d.z -= (ch.pos.z - m) * 0.25
	if ch.pos.z < -m: d.z += (-m - ch.pos.z) * 0.25
	for o in obstacles:
		var dx: float = ch.pos.x - o["x"]
		var dz: float = ch.pos.z - o["z"]
		var dist := sqrt(dx * dx + dz * dz)
		var rr: float = o["r"] + 1.8
		if dist < rr and dist > 0.01:
			var w := (rr - dist) / rr
			d.x += dx / dist * w * 1.7; d.z += dz / dist * w * 1.7
	for r in rects:
		var dx: float = ch.pos.x - r["x"]
		var dz: float = ch.pos.z - r["z"]
		if absf(dx) < r["hw"] + 2.2 and absf(dz) < r["hd"] + 2.2:
			var px: float = absf(dx) - r["hw"]
			var pz: float = absf(dz) - r["hd"]
			if px > pz:
				d.x += signf(dx if dx != 0.0 else 1.0) * 1.5
			else:
				d.z += signf(dz if dz != 0.0 else 1.0) * 1.5
	for c in caves:
		if not cave_blocks(ch, c):
			continue
		var dx: float = ch.pos.x - c["x"]
		var dz: float = ch.pos.z - c["z"]
		var dist := sqrt(dx * dx + dz * dz)
		var rr: float = c["r"] + 2.8
		if dist < rr and dist > 0.01:
			var w := (rr - dist) / rr
			d.x += dx / dist * w * 2.2; d.z += dz / dist * w * 2.2
	d.y = 0
	return d.normalized() if d.length_squared() > 0.0 else d

func _steer(ch: GameChar, desired: Vector3, dt: float, mult: float = 1.0) -> void:
	if desired.length_squared() == 0.0:
		ch.vel *= pow(0.02, dt)
	else:
		var dir := _avoidance_and_walls(ch, desired)
		var target := dir * (ch.speed * mult * terrain_mult(ch))
		ch.vel = ch.vel.lerp(target, 1.0 - pow(0.0005, dt))
	ch.pos += ch.vel * dt
	resolve_collisions(ch)

func _wander_tick(ch: GameChar, dt: float) -> Vector3:
	ch.wander_timer -= dt
	if ch.wander_timer <= 0.0 or ch.pos.distance_to(ch.wander_target) < 4.0:
		ch.wander_timer = 3.0 + randf() * 4.0
		ch.wander_target = random_spot()
	var v := ch.wander_target - ch.pos
	v.y = 0
	return v.normalized()

# ------------------------------------------------------------------ AI
func _update_element_ai(ch: GameChar, dt: float) -> void:
	var me: Dictionary = ELEMENTS[ch.el]
	var predator: GameChar = chars.get(me["predator"])
	var prey: GameChar = chars.get(me["prey"])
	var desired := Vector3.ZERO
	var speed_mult := 1.0
	var threat: GameChar = null
	var threat_d := 1e9

	if predator and predator.alive and not inside_own_cave(ch):
		var d := ch.pos.distance_to(predator.pos)
		if d < 26.0 and can_see(ch, predator):
			threat = predator; threat_d = d
	for n in npcs:
		if n.kind != "co2":
			continue
		var d := ch.pos.distance_to(n.pos)
		if d < 18.0 and d < threat_d and can_see(ch, n):
			threat = n; threat_d = d

	if threat:
		var away := ch.pos - threat.pos
		away.y = 0
		away = away.normalized()
		if cave_by_owner.has(ch.el) and ch.cave_cooldown <= 0.0:
			var c: Dictionary = cave_by_owner[ch.el]
			var to_cave := Vector3(c["x"] - ch.pos.x, 0, c["z"] - ch.pos.z)
			if to_cave.length() < 55.0 and to_cave.normalized().dot(away) > -0.2:
				away = away.lerp(to_cave.normalized(), 0.65).normalized()
		desired = away
		speed_mult = 1.18
		ch.wander_timer = 0.0
	elif prey and prey.alive and not inside_own_cave(prey) and ch.pos.distance_to(prey.pos) < 34.0 and can_see(ch, prey):
		desired = prey.pos - ch.pos
		desired.y = 0
		desired = desired.normalized()
		speed_mult = 1.12
	else:
		var best: GameChar = null
		var bd := 30.0
		for n in npcs:
			if n.kind != "o2" or not n.alive:
				continue
			var d := ch.pos.distance_to(n.pos)
			if d < bd and can_see(ch, n):
				best = n; bd = d
		if best:
			desired = best.pos - ch.pos
			desired.y = 0
			desired = desired.normalized()
		else:
			desired = _wander_tick(ch, dt)
	_steer(ch, desired, dt, speed_mult)

func _update_co2(ch: GameChar, dt: float) -> void:
	var best: GameChar = null
	var bd := CO2_SIGHT
	for e in chars.values():
		if not e.alive or inside_cave(e.pos):
			continue
		var d := ch.pos.distance_to(e.pos)
		if d < bd and can_see(ch, e, CO2_SIGHT):
			best = e; bd = d
	var desired: Vector3
	if best:
		desired = best.pos - ch.pos
		desired.y = 0
		desired = desired.normalized()
	else:
		desired = _wander_tick(ch, dt)
	_steer(ch, desired, dt, 1.06 if best else 0.8)

func _update_o2(ch: GameChar, dt: float) -> void:
	var flee: GameChar = null
	var fd := 10.0
	for e in chars.values():
		if not e.alive:
			continue
		var d := ch.pos.distance_to(e.pos)
		if d < fd:
			flee = e; fd = d
	var desired: Vector3
	if flee:
		desired = ch.pos - flee.pos
		desired.y = 0
		desired = desired.normalized()
	else:
		desired = _wander_tick(ch, dt)
	_steer(ch, desired, dt, 1.0 if flee else 0.55)

# ------------------------------------------------------------------ player
func _update_player(dt: float) -> void:
	if not player or not player.alive:
		return
	var mx := 0.0
	var mz := 0.0
	if Input.is_physical_key_pressed(KEY_W) or Input.is_physical_key_pressed(KEY_UP): mz += 1.0
	if Input.is_physical_key_pressed(KEY_S) or Input.is_physical_key_pressed(KEY_DOWN): mz -= 1.0
	if Input.is_physical_key_pressed(KEY_D) or Input.is_physical_key_pressed(KEY_RIGHT): mx += 1.0
	if Input.is_physical_key_pressed(KEY_A) or Input.is_physical_key_pressed(KEY_LEFT): mx -= 1.0
	var ln := minf(1.0, sqrt(mx * mx + mz * mz))
	var sprint := (Input.is_key_pressed(KEY_SHIFT)) and ln > 0.05 and stamina > 1.0
	if sprint:
		stamina = maxf(0.0, stamina - dt * 30.0)
	else:
		stamina = minf(100.0, stamina + dt * 13.0)
	ui.set_stamina(stamina)
	var target := Vector3.ZERO
	if ln > 0.05:
		var fx := -sin(cam_yaw)
		var fz := -cos(cam_yaw)
		var rx := -fz
		var rz := fx
		target = Vector3(fx * mz + rx * mx, 0, fz * mz + rz * mx).normalized()
		target *= player.speed * (1.5 if sprint else 1.0) * terrain_mult(player) * ln
	player.vel = player.vel.lerp(target, 1.0 - pow(0.0003, dt))
	player.pos += player.vel * dt
	resolve_collisions(player)
	if sprint and player.vel.length_squared() > 40.0 and randf() < dt * 26.0:
		_spawn_trail(player)

# ------------------------------------------------------------------ trails
func _spawn_trail(ch: GameChar) -> void:
	if ch.kind != "element":
		return
	var t: Dictionary = trail_pool[trail_idx % TRAIL_N]
	trail_idx += 1
	var mi: MeshInstance3D = t["mesh"]
	var mat: StandardMaterial3D = t["mat"]
	mi.visible = true
	var glow := MeshLib.rgb(ELEMENTS[ch.el]["glow"])
	mat.albedo_color = Color(glow.r, glow.g, glow.b, 0.5)
	mi.position = Vector3(ch.pos.x + (randf() - 0.5) * 0.5, 0.4 + randf() * 0.4, ch.pos.z + (randf() - 0.5) * 0.5)
	mi.scale = Vector3.ONE * (0.8 + randf() * 0.5)
	t["life"] = 1.0

func _update_trails(dt: float) -> void:
	for t in trail_pool:
		if t["life"] <= 0.0:
			continue
		t["life"] -= dt * 1.8
		var mi: MeshInstance3D = t["mesh"]
		var mat: StandardMaterial3D = t["mat"]
		if t["life"] <= 0.0:
			mi.visible = false
			mat.albedo_color.a = 0.0
			continue
		mat.albedo_color.a = t["life"] * 0.5
		mi.position.y += dt * 0.7
		var s := maxf(0.05, mi.scale.x * (1.0 - dt * 0.9))
		mi.scale = Vector3.ONE * s

# ------------------------------------------------------------- wind leaves
func _update_wind_leaves(dt: float, t: float) -> void:
	var cx := player.pos.x if player else 0.0
	var cz := player.pos.z if player else 0.0
	var W := 64.0
	for L in wind_leaves:
		L["x"] += L["vx"] * dt
		L["z"] += L["vz"] * dt
		if L["x"] - cx > W: L["x"] -= W * 2.0
		elif L["x"] - cx < -W: L["x"] += W * 2.0
		if L["z"] - cz > W: L["z"] -= W * 2.0
		elif L["z"] - cz < -W: L["z"] += W * 2.0
		var y: float = L["y"] + sin(t * 0.001 * L["bob"] + L["ph"]) * 1.1
		var mesh: MeshInstance3D = L["mesh"]
		mesh.position = Vector3(L["x"], maxf(0.15, y), L["z"])
		mesh.rotation = Vector3(
			sin(t * 0.0009 + L["ph"]) * 1.15,
			t * 0.0005 * L["spin"] + L["ph"],
			cos(t * 0.0007 + L["ph"] * 1.7) * 0.85)

# ------------------------------------------------------------- characters
func all_chars() -> Array:
	var a: Array = chars.values().duplicate()
	a.append_array(npcs)
	return a

func alive_elements() -> Array:
	return chars.values().filter(func(c): return c.alive)

func make_character(kind: String, el: String = "", is_player: bool = false) -> GameChar:
	var model: CharVisual
	if kind == "element":
		if el == "fire": model = MeshLib.build_flame()
		elif el == "water": model = MeshLib.build_droplet()
		else: model = MeshLib.build_leaf()
	elif kind == "o2":
		model = MeshLib.build_o2()
	else:
		model = MeshLib.build_co2()
	var shadow_r := 1.5
	if kind == "element":
		shadow_r = 1.05 if el == "fire" else 1.5
	elif kind == "co2":
		shadow_r = 1.85
	MeshLib.add_blob_shadow(model, shadow_r)
	add_child(model)
	var ch := GameChar.new()
	ch.kind = kind
	ch.el = el
	ch.is_player = is_player
	ch.group = model
	ch.speed = 10.2 if kind == "co2" else (6.0 if kind == "o2" else 11.0)
	if kind == "element":
		ch.radar_color = MeshLib.rgb(ELEMENTS[el]["color"])
	elif kind == "o2":
		ch.radar_color = MeshLib.rgb(0xeceef6)
	else:
		ch.radar_color = MeshLib.rgb(0x3a3744)
	return ch

# ------------------------------------------------------------- scoring
func update_board() -> void:
	var entries: Array = []
	for el in ["fire", "water", "grass"]:
		var ch: GameChar = chars.get(el)
		if ch == null:
			continue
		entries.append({ "el": el, "label": ELEMENTS[el]["label"], "score": ch.score, "alive": ch.alive, "me": ch.is_player })
	ui.set_board(entries)

func _check_catches() -> void:
	# elements catch their prey
	for el in ["fire", "water", "grass"]:
		var a: GameChar = chars.get(el)
		if a == null or not a.alive or inside_own_cave(a):
			continue
		var prey: GameChar = chars.get(ELEMENTS[el]["prey"])
		if prey == null or not prey.alive or inside_own_cave(prey):
			continue
		if a.pos.distance_to(prey.pos) < CATCH_DIST:
			a.score += PTS_PREY
			ui.toast("%s caught %s!  +%d" % [ELEMENTS[el]["label"], ELEMENTS[prey.el]["label"], PTS_PREY])
			_eliminate(prey)
	# CO₂ catches any exposed element
	for n in npcs:
		if n.kind != "co2":
			continue
		for el in ["fire", "water", "grass"]:
			var e: GameChar = chars.get(el)
			if e == null or not e.alive or inside_cave(e.pos):
				continue
			if n.pos.distance_to(e.pos) < CATCH_DIST:
				ui.toast("CO₂ caught %s!" % ELEMENTS[el]["label"])
				_eliminate(e)
	# O₂ collected for points
	for n in npcs:
		if n.kind != "o2" or not n.alive:
			continue
		for el in ["fire", "water", "grass"]:
			var e: GameChar = chars.get(el)
			if e == null or not e.alive:
				continue
			if n.pos.distance_to(e.pos) < CATCH_DIST + 0.4:
				n.alive = false
				n.group.visible = false
				o2_left -= 1
				e.score += PTS_O2
				if e.is_player:
					ui.toast("O₂ +%d!  (%d left)" % [PTS_O2, o2_left])
				update_board()
				break

func _eliminate(ch: GameChar) -> void:
	ch.alive = false
	ch.group.visible = false
	update_board()
	if ch.is_player:
		get_tree().create_timer(0.9).timeout.connect(func(): end_game("caught"), CONNECT_ONE_SHOT)
	elif alive_elements().size() <= 1:
		get_tree().create_timer(0.9).timeout.connect(func(): end_game("last"), CONNECT_ONE_SHOT)

# ------------------------------------------------------------- game flow
func start_game(my_el: String) -> void:
	_clear_actors()
	ending = false
	stamina = 100.0
	time_left = ROUND_TIME
	o2_left = N_O2
	for el in ["fire", "water", "grass"]:
		var ch := make_character("element", el, el == my_el)
		var c: Dictionary = cave_by_owner[el]
		var a: float = c["openAngle"]
		# spawn well clear of the cave mouth so the chase camera (which sits behind
		# the player, i.e. back toward the cave) isn't looking through the rocks.
		ch.pos = Vector3(c["x"] + cos(a) * (c["r"] + 16.0), 0, c["z"] + sin(a) * (c["r"] + 16.0))
		ch.group.position = ch.pos
		ch.group.rotation.y = atan2(-ch.pos.x, -ch.pos.z)
		chars[el] = ch
		if ch.is_player:
			player = ch
	for i in N_O2:
		var o := make_character("o2")
		o.pos = random_spot()
		o.group.position = o.pos
		npcs.append(o)
	for i in N_CO2:
		var c := make_character("co2")
		c.pos = random_spot(40.0)
		c.group.position = c.pos
		npcs.append(c)
	var me: Dictionary = ELEMENTS[my_el]
	ui.set_role("You: %s — catch %s, flee %s" % [me["label"], ELEMENTS[me["prey"]]["label"], ELEMENTS[me["predator"]]["label"]])
	cam_yaw = atan2(player.pos.x, player.pos.z)
	ui.show_hud()
	ui.set_timer("Time " + _fmt_time(ROUND_TIME))
	update_board()
	_run_countdown()

func _run_countdown() -> void:
	running = false
	for s in ["3", "2", "1", "GO!"]:
		ui.set_countdown(s)
		await get_tree().create_timer(0.75).timeout
	ui.set_countdown("")
	if not ending:
		running = true

func end_game(reason: String) -> void:
	if ending and reason != "force":
		return
	ending = true
	running = false
	var rows: Array = chars.values().duplicate()
	rows.sort_custom(func(a, b): return a.score > b.score)
	var out: Array = []
	for i in rows.size():
		var ch: GameChar = rows[i]
		out.append({
			"label": ELEMENTS[ch.el]["label"], "color": MeshLib.rgb(GameUI.UI_COLORS[ch.el]),
			"score": ch.score, "me": ch.is_player, "alive": ch.alive, "winner": i == 0,
		})
	var top: GameChar = rows[0] if rows.size() > 0 else null
	var title := ""
	if reason == "caught":
		title = "Caught!"
	elif top and top.is_player:
		title = "You win!"
	elif top:
		title = ELEMENTS[top.el]["label"] + " wins!"
	var sub := "Only one element left standing."
	if reason == "time":
		sub = "The clock ran out — most points takes it."
	elif reason == "caught":
		sub = "You were tagged. Final standings above."
	ui.show_end(out, title, sub)

func _clear_actors() -> void:
	for ch in all_chars():
		ch.group.queue_free()
	chars = {}
	npcs = []
	player = null

func _on_play_again() -> void:
	_clear_actors()
	ending = false
	running = false
	ui.show_start()

func _fmt_time(s: float) -> String:
	var m := int(s) / 60
	var ss := int(s) % 60
	return "%d:%02d" % [m, ss]

# ------------------------------------------------------------------ sky shader
const SKY_SHADER := """
shader_type sky;
void sky() {
	float t = clamp((1.0 - EYEDIR.y) * 0.5, 0.0, 1.0);
	// indigo zenith -> lavender -> warm pink -> peach horizon (matched to reference art)
	vec3 c0 = vec3(0.33, 0.35, 0.82);
	vec3 c1 = vec3(0.44, 0.44, 0.83);
	vec3 c2 = vec3(0.60, 0.54, 0.83);
	vec3 c3 = vec3(0.80, 0.64, 0.81);
	vec3 c4 = vec3(0.95, 0.72, 0.74);
	vec3 c5 = vec3(0.99, 0.82, 0.73);
	vec3 c6 = vec3(0.99, 0.88, 0.80);
	vec3 col = c0;
	col = mix(col, c1, smoothstep(0.00, 0.22, t));
	col = mix(col, c2, smoothstep(0.22, 0.40, t));
	col = mix(col, c3, smoothstep(0.40, 0.50, t));
	col = mix(col, c4, smoothstep(0.50, 0.57, t));
	col = mix(col, c5, smoothstep(0.57, 0.66, t));
	col = mix(col, c6, smoothstep(0.66, 1.00, t));
	// big soft moon, upper-left, melting into the sky (no hard disc)
	vec3 md = normalize(vec3(-0.62, 0.46, -0.64));
	float dm = distance(normalize(EYEDIR), md);
	col = mix(col, vec3(1.0, 0.99, 0.95), smoothstep(0.26, 0.0, dm) * 0.55);
	col += vec3(1.0, 0.99, 0.95) * smoothstep(0.06, 0.0, dm) * 0.4;
	COLOR = col;
}
"""
