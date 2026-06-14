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
const N_O2 := 8
const N_CO2 := 3
const RIVER_X1 := 2.0
const RIVER_X2 := 14.0
const RADAR_RANGE := 70.0
const CAVE_MAX_STAY := 30.0
const CAVE_LOCKOUT := 10.0
const CAM_DIST := 13.0   # pulled back for situational awareness
const CAM_H := 5.5       # raised a touch for a clearer overview of the surroundings
const ASSIGN_CAM_H := 20.0   # min top-down "command view" height while assigning clan tasks
const ASSIGN_CAM_OFF := 5.0  # slight z tilt so the view isn't a degenerate straight-down
const TRAIL_N := 60

# ------------------------------------------------------ rescue-mode tuning
const BASE_HP := 1            # everyone starts able to take one touch
const MAX_HP_CAP := 4         # self-training ceiling for the player
const HIT_INVULN := 2.5       # i-frames after taking a hit or respawning
const SLOW_TIME := 5.0        # how long a predator stays sluggish after hitting you
const SLOW_FACTOR := 0.5      # speed multiplier while slowed
const TRAIN_TIME := 5.33      # seconds of self-training for +1 max heart (3x faster)
const TEACH_TIME := 4.0       # seconds in the clan hall to summon your clan (5x faster)
const CLAN_SIZE := 10         # full clan size (teaching tops you back up to this)
const CLAN_REFILL_AT := 3     # you may re-teach a fresh batch once down to this many
const CLAN_SCALE := 0.77      # ~40% bigger than the caged twin (0.55), smaller than you (1.0)
const CLAN_COOLDOWN := 8.0    # delay before you can re-teach after losing allies
const ALLY_HELP_RANGE := 30.0 # (unused now — clan hunt the prey across the whole map)
const KEY_PICK_DIST := 2.6
const CAGE_RELEASE_DIST := 3.4
const RESCUE_WIN_DIST := 4.2  # twin this close to your cave centre = win
const TWIN_LEASH := 18.0      # twin only follows while you're within this

# ------------------------------------------------------ smart-AI (context steering)
const STEER_SLOTS := 16       # candidate directions each NPC weighs every tick
const PROBE_DIST := 7.5       # how far ahead a direction is checked for walls/dead-ends
const DISGUISE_TIME := 15.0   # seconds you stay a black figure after a black stone
const N_BLACK_STONES := 4
const CO_REVERT_TIME := 15.0  # a spent CO₂ (now CO, gray, harmless) auto-recharges after this
const O2_RESPAWN := 10.0      # a consumed O₂ molecule reappears elsewhere after this
const O2_CHARGE_CAP := 8      # how many O₂ sips the player can bank for sprint stamina

# --- lighting, tuned to match docs/elements_graphics.png (warm key, cool fill, pink haze) ---
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
var cages: Array = []            # zoo cages [{ "x","z","r","ident","node" }]
var cage_by_el: Dictionary = {}  # el -> cage dict (the twin you must free)
var clan_hall_by_owner: Dictionary = {}   # el -> { "x","z","r" }
var train_pad_by_owner: Dictionary = {}   # el -> { "x","z","r" }
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
var stamina := 100.0
var o2_charges := 0              # O₂ sipped this round → bigger effective stamina tank

var camera: Camera3D
var ui: GameUI
var touch_move := Vector2.ZERO   # mobile joystick: x = strafe, y = forward (set by TouchControls)
var touch_sprint := false        # mobile sprint button
var mobile := false              # touch/phone session: bigger HUD + tap targets
var cam_yaw := 0.0
var dragging := false
var _press_pos := Vector2.ZERO
var _press_moved := false

# --------------------------------------------------------- rescue-mode state
var allies: Array = []           # [GameChar] recruited clan members
var freed_twin: GameChar = null  # the rescued caged twin (escort target)
var train_progress := 0.0        # 0..1 self-training channel
var teach_progress := 0.0        # 0..1 clan-hall channel
var clan_cooldown := 0.0
var has_key := false
var keys: Dictionary = {}        # el -> { "node": Node3D, "pos": Vector3, "hinted": bool }
var key_carrier: GameChar = null # a clan fetcher currently carrying your key to you
var won := false

# --------------------------------------------------------- black-stone disguise
var disguise_timer := 0.0        # >0 while you are a black (CO₂) figure
var disguise_node: CharVisual = null
var black_stones: Array = []     # [{ "node": Node3D, "pos": Vector3, "cooldown": float }]

var trail_pool: Array = []
var trail_idx := 0

var _shot_t := 0.0
var _shot_done := false

# ---- banner capture (recreate docs/for_readme.png in-engine) ----
var _banner := false
var _banner_t := 0.0
var _banner_done := false
var _banner_list: Array = []
# camera looks down -Z; river/houses on the left (-X), characters centre-right.
const BANNER_CAM_POS := Vector3(3.5, 3.0, 15.0)
const BANNER_CAM_LOOK := Vector3(-4.0, 2.0, -45.0)
const BANNER_FOV := 46.0
const BANNER_CHARS := [
	{ "el": "fire", "pos": Vector3(-0.5, 0, -13.0), "pose": 110.0 },   # LEFT, furthest → smallest
	{ "el": "water", "pos": Vector3(3.5, 0, -6.5), "pose": 75.0 },     # CENTRE, closest → biggest
	{ "el": "grass", "pos": Vector3(9.0, 0, -8.5), "pose": 40.0 },     # RIGHT, medium
]

func _setup_banner() -> void:
	_banner = true
	ui.visible = false
	for spec in BANNER_CHARS:
		var ch := make_character("element", spec["el"])
		ch.pos = spec["pos"]
		ch.group.position = ch.pos
		ch.group.rotation.y = atan2(BANNER_CAM_POS.x - ch.pos.x, BANNER_CAM_POS.z - ch.pos.z)
		ch.group.animate(spec["pose"], 11.0)
		_banner_list.append({ "ch": ch, "pose": spec["pose"] })
	_build_banner_leaves()
	camera.fov = BANNER_FOV
	camera.position = BANNER_CAM_POS
	camera.look_at(BANNER_CAM_LOOK, Vector3.UP)

# A hand-placed riverside scene that recreates docs/for_readme.png exactly.
func _build_banner_world() -> void:
	var gp := PlaneMesh.new(); gp.size = Vector2(600, 600)
	world_root.add_child(MeshLib.mi(gp, MeshLib.lit_mat(MeshLib.rgb(0xdce7f4))))
	# river on the left, running along Z, receding to the vanishing point
	var wmat := StandardMaterial3D.new()
	wmat.albedo_color = MeshLib.rgb(0xc4d6ef)
	wmat.metallic = 0.25; wmat.roughness = 0.05; wmat.metallic_specular = 0.9
	var rp := PlaneMesh.new(); rp.size = Vector2(18.0, 160.0)
	var river := MeshLib.mi(rp, wmat)
	river.position = Vector3(-19.0, 0.05, -55.0)
	world_root.add_child(river)
	for cx in [-9.8, -28.2]:   # bright curbs on both banks
		var curb := MeshLib.box(1.0, 0.3, 160.0, MeshLib.lit_mat(MeshLib.rgb(0xfafbfe)))
		curb.position = Vector3(cx, 0.13, -55.0)
		world_root.add_child(curb)
	# a clean row of houses on the far (left) bank, receding to the vanishing point
	var hc := [0xefa07f, 0xe98a5f, 0xf3c9a4, 0xf4f1e8, 0xefa07f, 0xe98a5f, 0xf3c9a4, 0xf4f1e8]
	var rc := [0x675f5c, 0xd2603c, 0x5e5863, 0x4e4b57, 0x675f5c, 0xd2603c, 0x5e5863, 0x4e4b57]
	var zz := 12.0
	var i := 0
	while zz > -74.0:
		_banner_house(-32.5, zz, MeshLib.rgb(hc[i % hc.size()]), MeshLib.rgb(rc[i % rc.size()]), 1.0)
		if i % 2 == 1:
			_banner_tree(-36.0, zz - 2.5, 1.1)
		zz -= 11.0; i += 1
	_banner_tree(-30.0, 7.0, 1.35)
	# right side — a near house cut off by the edge, small distant houses behind the trio, a tree
	_banner_house(25.0, -9.0, MeshLib.rgb(0xefa07f), MeshLib.rgb(0xd2603c), -1.0)
	_banner_house(13.0, -52.0, MeshLib.rgb(0xf3c9a4), MeshLib.rgb(0x5e5863), -1.0)
	_banner_house(17.5, -58.0, MeshLib.rgb(0xe98a5f), MeshLib.rgb(0x675f5c), -1.0)
	_banner_tree(20.0, -16.0, 1.0)

func _banner_house(x: float, z: float, col: Color, roofcol: Color, win_dir: float) -> void:
	var w := 7.0; var d := 6.0; var h := 3.4
	var body := MeshLib.box(w, h, d, MeshLib.lit_mat(col))
	body.position = Vector3(x, h * 0.5, z)
	world_root.add_child(body)
	var prism := PrismMesh.new(); prism.size = Vector3(w + 1.0, h * 0.55, d + 1.0)
	var roof := MeshLib.mi(prism, MeshLib.lit_mat(roofcol))
	roof.position = Vector3(x, h + h * 0.27, z)
	world_root.add_child(roof)
	var win := MeshLib.box(0.12, 1.3, 1.6, MeshLib.unlit_mat(MeshLib.rgb(0xfbfaf4)))
	win.position = Vector3(x + win_dir * (w * 0.5 + 0.07), h * 0.52, z)   # window faces the river
	world_root.add_child(win)

func _banner_tree(x: float, z: float, s: float) -> void:
	var trunk := MeshLib.cyl(0.1 * s, 0.14 * s, 0.7 * s, MeshLib.lit_mat(MeshLib.rgb(0x8a7866)))
	trunk.position = Vector3(x, 0.35 * s, z)
	world_root.add_child(trunk)
	var body := MeshLib.sphere(0.75 * s, MeshLib.lit_mat(MeshLib.rgb(0x44604f)), 14, 12)
	body.scale = Vector3(1, 2.9, 1)
	body.position = Vector3(x, 0.6 * s + 2.0 * s, z)
	world_root.add_child(body)

func _build_banner_leaves() -> void:
	var mesh := WorldBuilder._make_windleaf_mesh()
	var tones := [0x5e9450, 0x6aa55e, 0x4f8a45, 0x6fa85c]
	# match the reference exactly: 2 upper-centre, 3 upper-right, 3 low foreground
	var spots := [
		Vector3(1.5, 6.0, -16.0), Vector3(3.8, 6.6, -15.0),                             # upper-centre (above Fire/Water)
		Vector3(11.0, 6.4, -12.0), Vector3(13.5, 5.7, -10.0), Vector3(15.5, 4.9, -9.0), # upper-right (above/right of Leaf)
		Vector3(0.5, 0.7, -6.0), Vector3(4.5, 0.45, -2.6), Vector3(11.0, 1.0, -3.2),    # low foreground
	]
	var ti := 0
	for p in spots:
		var mat := MeshLib.unlit_mat(MeshLib.rgb(tones[ti % tones.size()]), 0.96)
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		var m := MeshLib.mi(mesh, mat)
		m.position = p
		m.rotation = Vector3(0.7 + ti * 0.4, ti * 0.8, 0.5 + ti * 0.3)
		m.scale = Vector3.ONE * (0.55 + (ti % 3) * 0.12)
		world_root.add_child(m)
		ti += 1

# ------------------------------------------------------------------- setup
func _ready() -> void:
	var is_banner := OS.get_cmdline_user_args().has("banner")
	randomize()
	_build_environment()
	world_root = Node3D.new()
	add_child(world_root)
	if is_banner:
		_build_banner_world()    # a dedicated hand-placed scene, not the procedural town
	else:
		WorldBuilder.build(self)
	_build_trails()
	ui = GameUI.new()
	mobile = TouchControls.is_touch_session()
	ui.mobile = mobile   # 2x HUD + task buttons on phones
	add_child(ui)
	var touch := TouchControls.new()   # on-screen joystick + sprint (mobile only)
	touch.game = self
	add_child(touch)
	ui.element_selected.connect(start_game)
	ui.play_again.connect(_on_play_again)
	ui.task_assigned.connect(_assign_task)
	var radar_caves: Array = []
	for c in caves:
		radar_caves.append({ "x": c["x"], "z": c["z"], "r": c["r"], "fill": c["radarFill"] })
	ui.radar.setup(RIVER_X1, RIVER_X2, BRIDGES, radar_caves)
	if OS.get_cmdline_user_args().has("banner"):
		_setup_banner()
		return
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

	if _banner:
		_banner_t += delta
		for e in _banner_list:
			e["ch"].group.animate(e["pose"], 11.0)
		if _banner_t > 1.6 and not _banner_done:
			_banner_done = true
			get_viewport().get_texture().get_image().save_png("res://_banner.png")
			get_tree().quit()
		return

	if running:
		_tick_timers(dt)
		_update_player(dt)
		for ch in chars.values():
			if not ch.is_player and ch.alive:
				_update_element_ai(ch, dt)
		for a in allies:
			_update_ally(a, dt)
		if freed_twin:
			_update_twin(freed_twin, dt)
		for n in npcs:
			if n.alive:
				if n.kind == "co2":
					_update_co2(n, dt)
				else:
					_update_o2(n, dt)
		_update_cave_timers(dt)
		_update_training(dt)
		_update_teaching(dt)
		_refresh_channel()
		_update_key(dt)
		_update_black_stones(dt)
		_check_catches()
		_check_rescue()
		_update_hud_status()
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
	# drive the black-figure disguise model so it mirrors the (now-hidden) player
	if disguise_node and is_instance_valid(disguise_node) and player and _is_disguised():
		disguise_node.position = player.pos
		disguise_node.rotation.y = player.group.rotation.y
		disguise_node.animate(time_ms, player.vel.length())

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
# Left-drag looks around; a left-click that didn't drag selects/deselects a clan
# member (so you can multi-select them and hand out tasks).
func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			dragging = true
			_press_pos = event.position
			_press_moved = false
		else:
			dragging = false
			if not _press_moved:
				_click_select(event.position)
	elif event is InputEventMouseMotion and dragging:
		cam_yaw -= event.relative.x * 0.0052
		if event.position.distance_to(_press_pos) > 6.0:
			_press_moved = true

# Clan member nearest to a screen position (within the pick radius), or null.
func _ally_at(screen_pos: Vector2) -> GameChar:
	if not player or allies.is_empty():
		return null
	var picked: GameChar = null
	var best := 150.0 if mobile else 64.0   # pixels; much bigger tap target on phones
	for a in allies:
		var wp: Vector3 = a.pos + Vector3(0, 1.4, 0)
		if camera.is_position_behind(wp):
			continue
		var sp: Vector2 = camera.unproject_position(wp)
		var d := sp.distance_to(screen_pos)
		if d < best:
			best = d; picked = a
	return picked

func _click_select(screen_pos: Vector2) -> void:
	if not player or allies.is_empty():
		return
	var picked := _ally_at(screen_pos)
	if picked:
		_set_selected(picked, not picked.selected)
	else:
		_clear_selection()   # clicked empty space — drop the selection
	ui.show_task_buttons(_has_selection())

# True when a touch at this screen position should pick a clan member rather than
# drive the on-screen controls — i.e. we're in the top-down command view and the
# touch landed on a selectable member. The mobile joystick/sprint use this so a tap
# on a left-side member (drawn under the joystick) selects it, while taps on empty
# ground still drive movement so you can walk away / flee.
func touch_selects_clan(screen_pos: Vector2) -> bool:
	return _clan_assign_active() and _ally_at(screen_pos) != null

func _set_selected(a: GameChar, on: bool) -> void:
	a.selected = on
	var sel = a.group.get_meta("sel", null)
	if sel and is_instance_valid(sel):
		sel.visible = on

func _clear_selection() -> void:
	for a in allies:
		_set_selected(a, false)

func _has_selection() -> bool:
	return allies.any(func(a): return a.selected)

func _assign_task(task: String) -> void:
	var n := 0
	for a in allies:
		if a.selected:
			a.role = task
			_set_selected(a, false)
			n += 1
	if n > 0:
		var names := { "protect": "protect you", "attack": "attack %s" % ELEMENTS[ELEMENTS[player.el]["prey"]]["label"], "fetch": "fetch your key" }
		ui.toast("%d clan → %s" % [n, names.get(task, task)])
	ui.show_task_buttons(false)

# ------------------------------------------------------------------ camera
func _update_camera(dt: float) -> void:
	if player:
		if _clan_assign_active():
			# top-down command view, raised enough that the whole clan ring stays in frame
			var hall: Dictionary = clan_hall_by_owner[player.el]
			var cam_h := _assign_cam_height()
			camera.position = camera.position.lerp(Vector3(hall["x"], cam_h, hall["z"] + ASSIGN_CAM_OFF), 1.0 - pow(0.0006, dt))
			camera.look_at(Vector3(hall["x"], 3.1, hall["z"]), Vector3.UP)
		else:
			# inside your home cave (e.g. just respawned after dying) drop to a low, close
			# angle so you see your character under the roof instead of staring at the ceiling
			var in_cave := inside_own_cave(player)
			var cam_h: float = 2.4 if in_cave else CAM_H
			var max_d: float = 7.5 if in_cave else CAM_DIST
			var look_y: float = 1.2 if in_cave else 1.9
			var snap: float = 0.00002 if in_cave else 0.0001
			var d := _cam_obstruction(player.pos.x, player.pos.z, sin(cam_yaw), cos(cam_yaw), max_d)
			var tx := player.pos.x + sin(cam_yaw) * d
			var tz := player.pos.z + cos(cam_yaw) * d
			camera.position = camera.position.lerp(Vector3(tx, cam_h, tz), 1.0 - pow(snap, dt))
			camera.look_at(Vector3(player.pos.x, look_y, player.pos.z), Vector3.UP)
		var blips: Array = []
		for ch in all_chars():
			if not ch.alive or ch == player:
				continue
			blips.append({ "pos": Vector2(ch.pos.x, ch.pos.z), "color": ch.radar_color, "o2": ch.kind == "o2" })
		# objective markers: your colour-matched key, then the cage to free your twin
		if not has_key and keys.has(player.el):
			var mk: Dictionary = keys[player.el]
			blips.append({ "pos": Vector2(mk["pos"].x, mk["pos"].z), "color": MeshLib.rgb(ELEMENTS[player.el]["color"]), "o2": false })
		elif has_key and freed_twin == null and cage_by_el.has(player.el):
			var cg: Dictionary = cage_by_el[player.el]
			blips.append({ "pos": Vector2(cg["x"], cg["z"]), "color": Color(0.95, 0.82, 0.22), "o2": false })
		# available black stones (disguise pickups)
		for s in black_stones:
			if s["cooldown"] <= 0.0:
				blips.append({ "pos": Vector2(s["pos"].x, s["pos"].z), "color": Color(0.35, 0.3, 0.45), "o2": false })
		ui.radar.update_data(Vector2(player.pos.x, player.pos.z), player.group.rotation.y, blips)
	else:
		var a := time_ms * 0.00006
		camera.position = Vector3(sin(a) * 62.0, 17.0, cos(a) * 62.0)
		camera.look_at(Vector3(0, 2, 0), Vector3.UP)

# Command-view height that keeps the whole clan ring (radius ~5) in frame. Tall/
# narrow phone screens have a tighter horizontal field of view, so the camera is
# pulled up further on those — never below the ASSIGN_CAM_H floor.
func _assign_cam_height() -> float:
	var vp := get_viewport().get_visible_rect().size
	var aspect: float = (vp.x / vp.y) if vp.y > 1.0 else 1.7
	var half_v := tan(deg_to_rad(camera.fov * 0.5))
	if half_v < 0.01:
		return ASSIGN_CAM_H
	var fit := 7.0 / (half_v * minf(1.0, aspect))   # clan ring radius + margin
	return maxf(ASSIGN_CAM_H, fit)

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

# Inside your own clan hall or training pad — a safe haven, like your cave: nothing
# that's walled out of the room can reach you here.
func inside_own_room(ch: GameChar) -> bool:
	if ch.kind != "element":
		return false
	var hall: Dictionary = clan_hall_by_owner.get(ch.el, {})
	if not hall.is_empty() and Vector2(ch.pos.x - hall["x"], ch.pos.z - hall["z"]).length() < hall["r"]:
		return true
	var pad: Dictionary = train_pad_by_owner.get(ch.el, {})
	if not pad.is_empty() and Vector2(ch.pos.x - pad["x"], ch.pos.z - pad["z"]).length() < pad["r"]:
		return true
	return false

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
# A clan hall / training pad only admits its owning element (and that element's
# clan + freed twin). Rival elements, CO₂ (black) and O₂ (white) are kept out.
func room_blocks(ch: GameChar, owner: String) -> bool:
	return ch.kind != "element" or ch.el != owner

func _block_circle(ch: GameChar, room: Dictionary) -> void:
	var dx: float = ch.pos.x - room["x"]
	var dz: float = ch.pos.z - room["z"]
	var dist := sqrt(dx * dx + dz * dz)
	var mn: float = room["r"] + 1.2
	if dist < mn and dist > 0.001:
		var k := (mn - dist) / dist
		ch.pos.x += dx * k; ch.pos.z += dz * k

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
	# your clan hall + training totem are private — keep everyone but their owner out
	for el in clan_hall_by_owner:
		if room_blocks(ch, el):
			_block_circle(ch, clan_hall_by_owner[el])
	for el in train_pad_by_owner:
		if room_blocks(ch, el):
			_block_circle(ch, train_pad_by_owner[el])
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
	for el in clan_hall_by_owner:
		if room_blocks(ch, el):
			d = _avoid_zone(ch, d, clan_hall_by_owner[el])
	for el in train_pad_by_owner:
		if room_blocks(ch, el):
			d = _avoid_zone(ch, d, train_pad_by_owner[el])
	d.y = 0
	return d.normalized() if d.length_squared() > 0.0 else d

func _avoid_zone(ch: GameChar, d: Vector3, zone: Dictionary) -> Vector3:
	var dx: float = ch.pos.x - zone["x"]
	var dz: float = ch.pos.z - zone["z"]
	var dist := sqrt(dx * dx + dz * dz)
	var rr: float = zone["r"] + 3.0
	if dist < rr and dist > 0.01:
		var w := (rr - dist) / rr
		d.x += dx / dist * w * 2.0
		d.z += dz / dist * w * 2.0
	return d

func _slow_mult(ch: GameChar) -> float:
	return SLOW_FACTOR if ch.slow_timer > 0.0 else 1.0

func _steer(ch: GameChar, desired: Vector3, dt: float, mult: float = 1.0) -> void:
	if desired.length_squared() == 0.0:
		ch.vel *= pow(0.02, dt)
	else:
		var dir := _avoidance_and_walls(ch, desired)
		var target := dir * (ch.speed * mult * terrain_mult(ch) * _slow_mult(ch))
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

# ------------------------------------------------------------------ smart AI
# Context steering: every NPC weighs STEER_SLOTS candidate headings, scoring each
# by how well it moves toward "attract" points and away from "repel" points, while
# penalising directions that run into walls / dead-ends. This makes chasers cut off
# their prey (they aim at a predicted lead point) and makes fleers slip toward open
# space instead of trapping themselves in a corner — i.e. genuinely tactical movement.
func _falloff(dist: float, rng: float) -> float:
	return clampf(1.0 - dist / rng, 0.0, 1.0)

func _lead_point(from: Vector3, target: GameChar, chaser_speed: float) -> Vector3:
	var lead: float = clampf(from.distance_to(target.pos) / maxf(chaser_speed, 1.0), 0.0, 1.3)
	return target.pos + target.vel * lead

# how clear a heading is: 1 = open, 0 = wall/obstacle just ahead
func _slot_openness(ch: GameChar, dir: Vector3) -> float:
	var ax := ch.pos.x; var az := ch.pos.z
	var bx := ax + dir.x * PROBE_DIST; var bz := az + dir.z * PROBE_DIST
	for o in obstacles:
		if _seg_circle(ax, az, bx, bz, o["x"], o["z"], o["r"] + 0.9):
			return 0.0
	for r in rects:
		if _seg_aabb(ax, az, bx, bz, r["x"] - r["hw"] - 0.9, r["z"] - r["hd"] - 0.9, r["x"] + r["hw"] + 0.9, r["z"] + r["hd"] + 0.9):
			return 0.0
	var m := ARENA - 4.0
	if absf(bx) > m or absf(bz) > m:
		return 0.35
	return 1.0

# attracts / repels: arrays of { "pos": Vector3, "weight": float, "range": float }
func _smart_move(ch: GameChar, attracts: Array, repels: Array, dt: float, speed_mult: float) -> void:
	var best := -1e20
	var best_dir := Vector3.ZERO
	var vdir := ch.vel.normalized() if ch.vel.length() > 0.1 else Vector3.ZERO
	for i in STEER_SLOTS:
		var a := TAU * float(i) / float(STEER_SLOTS)
		var dir := Vector3(sin(a), 0, cos(a))
		var score := 0.0
		for at in attracts:
			var to: Vector3 = at["pos"] - ch.pos; to.y = 0
			var dd := to.length()
			if dd > 0.01:
				score += at["weight"] * dir.dot(to / dd) * _falloff(dd, at.get("range", 40.0))
		for rp in repels:
			var to: Vector3 = rp["pos"] - ch.pos; to.y = 0
			var dd := to.length()
			if dd > 0.01:
				score -= rp["weight"] * dir.dot(to / dd) * _falloff(dd, rp.get("range", 30.0))
		score += (_slot_openness(ch, dir) - 1.0) * 3.0       # shun walls / dead-ends
		score += dir.dot(vdir) * 0.2                          # momentum — less jitter
		if score > best:
			best = score; best_dir = dir
	_steer(ch, best_dir, dt, speed_mult)

func _update_element_ai(ch: GameChar, dt: float) -> void:
	var me: Dictionary = ELEMENTS[ch.el]
	var predator: GameChar = chars.get(me["predator"])
	var prey: GameChar = chars.get(me["prey"])
	# while the player wears a black stone they're "energized" — the element they'd
	# normally eat them (this char, if its prey is the player) must flee instead.
	var prey_is_empowered: bool = prey != null and prey.is_player and _is_disguised()
	var attracts: Array = []
	var repels: Array = []
	var speed_mult := 1.0
	var threatened := false
	# flee your predator and any CO₂ you can see
	if predator and predator.alive and not inside_own_cave(ch) and ch.pos.distance_to(predator.pos) < 30.0 and can_see(ch, predator):
		repels.append({ "pos": predator.pos, "weight": 3.2, "range": 30.0 })
		threatened = true
	if prey_is_empowered and not inside_own_cave(ch) and ch.pos.distance_to(prey.pos) < 32.0 and can_see(ch, prey):
		repels.append({ "pos": prey.pos, "weight": 3.4, "range": 32.0 })   # run from the energized player
		threatened = true
	for n in npcs:
		if n.kind == "co2" and n.alive and n.co_timer <= 0.0 and ch.pos.distance_to(n.pos) < 22.0 and can_see(ch, n):
			repels.append({ "pos": n.pos, "weight": 2.6, "range": 22.0 })
			threatened = true
	if threatened:
		speed_mult = 1.18
		# break for home — a safe haven the threats can't enter
		if cave_by_owner.has(ch.el) and ch.cave_cooldown <= 0.0:
			var c: Dictionary = cave_by_owner[ch.el]
			attracts.append({ "pos": Vector3(c["x"], 0, c["z"]), "weight": 2.4, "range": 70.0 })
	else:
		# hunt: aim at where the prey is GOING, not where it is (but never chase an energized player).
		# elements no longer need O₂, so with nothing to chase they just roam.
		if prey and prey.alive and not prey_is_empowered and not inside_own_cave(prey) and ch.pos.distance_to(prey.pos) < 38.0 and can_see(ch, prey):
			attracts.append({ "pos": _lead_point(ch.pos, prey, ch.speed), "weight": 3.0, "range": 38.0 })
			speed_mult = 1.12
	if attracts.is_empty() and repels.is_empty():
		_steer(ch, _wander_tick(ch, dt), dt)
		return
	_smart_move(ch, attracts, repels, dt, speed_mult)

func _update_co2(ch: GameChar, dt: float) -> void:
	# spent CO₂ is now CO (gray): harmless, and immediately goes looking for the
	# nearest O₂ anywhere on the map to grab an oxygen and turn back into CO₂
	if ch.co_timer > 0.0:
		var o2: GameChar = null
		var od := 1.0e20
		for n in npcs:
			if n.kind == "o2" and n.alive:
				var d := ch.pos.distance_to(n.pos)
				if d < od:
					o2 = n; od = d
		if o2:
			_smart_move(ch, [{ "pos": _lead_point(ch.pos, o2, ch.speed), "weight": 3.0, "range": 320.0 }], [], dt, 1.05)
		else:
			_steer(ch, _wander_tick(ch, dt), dt, 0.7)
		return
	var best: GameChar = null
	var bd := CO2_SIGHT
	for e in _co2_targets():
		var d := ch.pos.distance_to(e.pos)
		if d < bd and can_see(ch, e, CO2_SIGHT):
			best = e; bd = d
	var attracts: Array = []
	var repels: Array = []
	if best:
		attracts.append({ "pos": _lead_point(ch.pos, best, ch.speed), "weight": 3.0, "range": CO2_SIGHT })
	# spread out from other CO₂ so the pack covers ground instead of stacking up
	for n in npcs:
		if n.kind == "co2" and n != ch and ch.pos.distance_to(n.pos) < 11.0:
			repels.append({ "pos": n.pos, "weight": 1.0, "range": 11.0 })
	if attracts.is_empty() and repels.is_empty():
		_steer(ch, _wander_tick(ch, dt), dt, 0.8)
		return
	_smart_move(ch, attracts, repels, dt, 1.08 if best else 0.85)

# CO₂ spends an oxygen when it tags you → becomes CO (gray, harmless) for a while.
func _co2_to_co(ch: GameChar) -> void:
	ch.co_timer = CO_REVERT_TIME
	ch.radar_color = MeshLib.rgb(0x9a97a8)
	var spare = ch.group.get_meta("spare_o", null)
	var bond = ch.group.get_meta("spare_bond", null)
	if spare and is_instance_valid(spare): spare.visible = false
	if bond and is_instance_valid(bond): bond.visible = false

# CO grabs an oxygen (O₂) or waits it out → back to dangerous CO₂.
func _co_to_co2(ch: GameChar) -> void:
	ch.co_timer = 0.0
	ch.radar_color = MeshLib.rgb(0x3a3744)
	var spare = ch.group.get_meta("spare_o", null)
	var bond = ch.group.get_meta("spare_bond", null)
	if spare and is_instance_valid(spare): spare.visible = true
	if bond and is_instance_valid(bond): bond.visible = true

func _consume_o2(o: GameChar) -> void:
	o.alive = false
	o.group.visible = false
	o.respawn_timer = O2_RESPAWN

func _update_o2(ch: GameChar, dt: float) -> void:
	# while you wear a black disguise the O₂ (whites) see through it and hunt you
	if _is_disguised() and player and player.alive:
		var attracts: Array = [{ "pos": _lead_point(ch.pos, player, ch.speed * 1.4), "weight": 3.0, "range": 80.0 }]
		var repels: Array = []
		for n in npcs:
			if n.kind == "o2" and n != ch and ch.pos.distance_to(n.pos) < 7.0:
				repels.append({ "pos": n.pos, "weight": 0.8, "range": 7.0 })
		_smart_move(ch, attracts, repels, dt, 1.55)
		return
	# otherwise drift, fleeing any element that gets close (without cornering itself)
	var repels: Array = []
	for e in chars.values():
		if e.alive and ch.pos.distance_to(e.pos) < 11.0:
			repels.append({ "pos": e.pos, "weight": 2.2, "range": 11.0 })
	for a in allies:
		if ch.pos.distance_to(a.pos) < 11.0:
			repels.append({ "pos": a.pos, "weight": 2.2, "range": 11.0 })
	if repels.is_empty():
		_steer(ch, _wander_tick(ch, dt), dt, 0.55)
		return
	_smart_move(ch, [], repels, dt, 1.0)

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
	mx += touch_move.x   # mobile joystick (zero on desktop)
	mz += touch_move.y
	var ln := minf(1.0, sqrt(mx * mx + mz * mz))
	var sprint := (Input.is_key_pressed(KEY_SHIFT) or touch_sprint) and ln > 0.05 and stamina > 1.0
	# each O₂ sipped makes the (same-size) tank effectively bigger: slower drain, faster refill
	var drain := 30.0 * maxf(0.35, 1.0 - 0.09 * o2_charges)
	var recover := 13.0 * (1.0 + 0.16 * o2_charges)
	if sprint:
		stamina = maxf(0.0, stamina - dt * drain)
	else:
		stamina = minf(100.0, stamina + dt * recover)
	ui.set_stamina(stamina)
	var target := Vector3.ZERO
	if ln > 0.05:
		var fx := -sin(cam_yaw)
		var fz := -cos(cam_yaw)
		var rx := -fz
		var rz := fx
		target = Vector3(fx * mz + rx * mx, 0, fz * mz + rz * mx).normalized()
		var power := 1.25 if _is_disguised() else 1.0   # energized by a black stone — run the predator down
		target *= player.speed * power * (1.5 if sprint else 1.0) * terrain_mult(player) * _slow_mult(player) * ln
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
	a.append_array(allies)
	if freed_twin:
		a.append(freed_twin)
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
	# elemental predators hit their prey (a hit costs a heart, not a life)
	for el in ["fire", "water", "grass"]:
		var a: GameChar = chars.get(el)
		if a == null or not a.alive or inside_own_cave(a):
			continue
		var prey: GameChar = chars.get(ELEMENTS[el]["prey"])
		if prey == null or not prey.alive or inside_own_cave(prey) or inside_own_room(prey):
			continue
		if prey.is_player and _is_disguised():
			continue        # energized: your predator can't catch you right now
		if a.pos.distance_to(prey.pos) < CATCH_DIST:
			_take_hit(prey, a)
	# black-stone power-up (Pac-Man style): while disguised you can EAT your predator
	if _is_disguised() and player and player.alive and not inside_own_cave(player):
		var pred: GameChar = chars.get(ELEMENTS[player.el]["predator"])
		if pred and pred.alive and not inside_own_cave(pred) and pred.invuln_timer <= 0.0 and player.pos.distance_to(pred.pos) < CATCH_DIST:
			ui.toast("Gotcha! You caught your predator %s!" % ELEMENTS[pred.el]["label"])
			_take_hit(pred, player)
	# ATTACK clan smack the element you hunt
	if player and player.alive and not allies.is_empty():
		var prey: GameChar = chars.get(ELEMENTS[player.el]["prey"])
		if prey != null and prey.alive and not inside_own_cave(prey) and not inside_own_room(prey):
			for a in allies:
				if a.role == "attack" and a.pos.distance_to(prey.pos) < CATCH_DIST:
					_take_hit(prey, a)
					break
	# PROTECT clan defend you. They always neutralise the threat (briefly SLOW your
	# predator, or spend a black CO₂'s oxygen so it becomes harmless CO). But they only
	# DIE doing it once the whole clan is assigned — while you're still organising, the
	# predator/CO₂ can't actually catch your defenders. (מתאבדים, once you're committed.)
	var clan_live := _all_clan_assigned()
	for a in allies.duplicate():
		if a.role != "protect":
			continue
		var pred: GameChar = chars.get(ELEMENTS[player.el]["predator"])
		if pred and pred.alive and not inside_own_cave(pred) and pred.slow_timer <= 0.0 and a.pos.distance_to(pred.pos) < CATCH_DIST:
			pred.slow_timer = SLOW_TIME    # brief slow-down, not a trip home
			if clan_live:
				ui.toast("A clan member sacrificed itself to slow %s!" % ELEMENTS[pred.el]["label"])
				_disperse_ally(a)          # mortal only once the clan is fully assigned
			continue
		for n in npcs:
			if n.kind == "co2" and n.co_timer <= 0.0 and a.pos.distance_to(n.pos) < CATCH_DIST:
				_co2_to_co(n)              # spend the CO₂'s oxygen → it becomes CO
				if clan_live:
					_disperse_ally(a)      # ...and the defender dies
				break
	# CO₂ hits any exposed element or clan member. Tagging YOU spends an oxygen, so it
	# drops to harmless CO (gray). A gray CO can't hit anyone — it hunts an O₂ to recharge.
	for n in npcs:
		if n.kind != "co2":
			continue
		if n.co_timer > 0.0:
			# gray CO: catching an O₂ turns it back into dangerous CO₂
			for o in npcs:
				if o.kind == "o2" and o.alive and n.pos.distance_to(o.pos) < CATCH_DIST + 0.4:
					_consume_o2(o)
					_co_to_co2(n)
					break
			continue
		for v in _co2_targets():
			if n.pos.distance_to(v.pos) < CATCH_DIST:
				var hit_player: bool = v.is_player
				_take_hit(v, n)
				if hit_player:
					_co2_to_co(n)
				break
	# while you're disguised, O₂ (whites) hunt the black figure and bite a heart off
	if _is_disguised() and player and player.alive and player.invuln_timer <= 0.0 and not inside_own_room(player):
		for n in npcs:
			if n.kind == "o2" and n.alive and n.pos.distance_to(player.pos) < CATCH_DIST + 0.4:
				ui.toast("An O₂ caught you while disguised!")
				_end_disguise()
				_take_hit(player, n)
				break
	# only the player sips O₂ now — it supercharges sprint stamina (elements no longer
	# need oxygen for anything; not collectible while you're a black figure)
	if player and player.alive and not _is_disguised():
		for n in npcs:
			if n.kind == "o2" and n.alive and n.pos.distance_to(player.pos) < CATCH_DIST + 0.4:
				_consume_o2(n)
				_gain_o2_charge()
				break

func _gain_o2_charge() -> void:
	o2_charges = mini(O2_CHARGE_CAP, o2_charges + 1)
	stamina = minf(100.0, stamina + 22.0)   # a refreshing gulp right away, too
	ui.toast("O₂! Sprint tank boosted (%d/%d)" % [o2_charges, O2_CHARGE_CAP])

func _is_disguised() -> bool:
	return disguise_timer > 0.0

func _co2_targets() -> Array:
	# while you're home in the clan house, CO₂ can't see you or any of your clan
	var hide_mine := _player_in_clan_hall()
	var out: Array = []
	for e in chars.values():
		if not e.alive or inside_cave(e.pos) or inside_own_room(e):
			continue
		if e.is_player and (_is_disguised() or hide_mine):
			continue        # disguised, or safe at home → CO₂ ignore you
		out.append(e)
	if not hide_mine:
		for a in allies:
			# only assigned (active) clan are in play — idle ones waiting for orders are safe
			if a.role != "" and not inside_own_room(a):
				out.append(a)
	return out

func _name_of(ch: GameChar) -> String:
	if ch.kind == "co2":
		return "CO₂"
	return ELEMENTS[ch.el]["label"] if ch.el != "" else ch.kind

# A hit costs one heart. The player (and AI elements) refill at their home cave
# when the last heart is gone; clan members just disperse. Whoever lands a hit on
# the player or a clan member is punished with a 5s slow.
func _take_hit(victim: GameChar, attacker: GameChar) -> void:
	if not victim.alive or victim.invuln_timer > 0.0:
		return
	if victim.is_player or victim.ally:
		attacker.slow_timer = SLOW_TIME
	if victim.ally:
		ui.toast("Clan member down — %s slowed!" % _name_of(attacker))
		_disperse_ally(victim)
		return
	victim.invuln_timer = HIT_INVULN
	victim.hp -= 1
	if attacker.kind == "element" and victim.kind == "element":
		attacker.score += PTS_PREY
	if victim.hp <= 0:
		_respawn(victim)
	elif victim.is_player:
		ui.toast("Hit!  %d hearts left" % victim.hp)
		_update_hud_hearts()

func _respawn(ch: GameChar) -> void:
	ch.hp = ch.max_hp
	ch.invuln_timer = HIT_INVULN
	ch.slow_timer = 0.0
	ch.cave_time = 0.0
	ch.vel = Vector3.ZERO
	if cave_by_owner.has(ch.el):
		var c: Dictionary = cave_by_owner[ch.el]
		ch.pos = Vector3(c["x"], 0, c["z"])
		ch.group.position = ch.pos
	if ch.is_player:
		ui.toast("Caught! Back to your cave.")
		_update_hud_hearts()

func _disperse_ally(a: GameChar) -> void:
	allies.erase(a)
	if key_carrier == a:
		key_carrier = null          # key drops where the carrier fell (its pos already tracks)
	a.group.queue_free()
	if allies.is_empty():
		clan_cooldown = CLAN_COOLDOWN
	ui.show_task_buttons(_has_selection())
	_update_hud_status()

# ------------------------------------------------------ rescue subsystems
func _tick_timers(dt: float) -> void:
	for ch in all_chars():
		if ch.slow_timer > 0.0:
			ch.slow_timer = maxf(0.0, ch.slow_timer - dt)
		if ch.invuln_timer > 0.0:
			ch.invuln_timer = maxf(0.0, ch.invuln_timer - dt)
	if clan_cooldown > 0.0:
		clan_cooldown = maxf(0.0, clan_cooldown - dt)
	if disguise_timer > 0.0:
		disguise_timer = maxf(0.0, disguise_timer - dt)
		if disguise_timer <= 0.0:
			_end_disguise()
	# CO₂ chemistry: spent CO recharges to CO₂; consumed O₂ molecules reappear
	for n in npcs:
		if n.kind == "co2" and n.co_timer > 0.0:
			n.co_timer = maxf(0.0, n.co_timer - dt)
			if n.co_timer <= 0.0:
				_co_to_co2(n)
		elif n.kind == "o2" and not n.alive and n.respawn_timer > 0.0:
			n.respawn_timer = maxf(0.0, n.respawn_timer - dt)
			if n.respawn_timer <= 0.0:
				n.pos = random_spot()
				n.group.position = n.pos
				n.alive = true
				n.group.visible = true

# Clan members don't follow you — they help. Fetchers go get the key and bring it
# back; everyone else hunts the element you eat across the whole map.
func _update_ally(a: GameChar, dt: float) -> void:
	if not player or not player.alive:
		_steer(a, Vector3.ZERO, dt)
		return
	var attracts: Array = []
	var repels: Array = []
	var ring := Vector3(cos(a.follow_angle), 0, sin(a.follow_angle))
	var mult := 1.2
	# attack/fetch keep clear of live (black) CO₂ so they aren't dispersed for nothing.
	# defenders do NOT avoid — they hurl themselves at threats ("מתאבדים" for you).
	if a.role == "attack" or a.role == "fetch":
		for n in npcs:
			if n.kind == "co2" and n.co_timer <= 0.0 and a.pos.distance_to(n.pos) < 13.0:
				repels.append({ "pos": n.pos, "weight": 1.8, "range": 13.0 })

	match a.role:
		"fetch":
			# bolt straight for your key the moment you're tasked, then carry it back
			if not has_key and keys.has(player.el):
				var target: Vector3
				if key_carrier == a:
					target = player.pos
				elif key_carrier == null:
					target = keys[player.el]["pos"]
				else:
					target = key_carrier.pos
				attracts.append({ "pos": target, "weight": 3.4, "range": 280.0 })
			else:
				# key delivered — follow you, and stand still once you stop and I'm in place
				var slot := player.pos + ring * 4.0
				if player.vel.length() < 0.6 and a.pos.distance_to(slot) < 1.8:
					_steer(a, Vector3.ZERO, dt)
					return
				attracts.append({ "pos": slot, "weight": 1.4, "range": 40.0 })
		"attack":
			# ALWAYS hunt the element you eat — chase it down, and if it ducks into its
			# cave just camp at the entrance. Never trot back to you (that yo-yo looked silly).
			var prey: GameChar = chars.get(ELEMENTS[player.el]["prey"])
			if prey and prey.alive:
				attracts.append({ "pos": _lead_point(a.pos, prey, a.speed), "weight": 3.6, "range": 320.0 })
		"protect":
			# stand guard inside the clan house until you head out
			if _player_in_clan_hall():
				_steer(a, Vector3.ZERO, dt)
				return
			# once you're out, shadow you — and charge anyone coming to catch you
			var threat: GameChar = _nearest_threat_to_player(a)
			if threat and player.pos.distance_to(threat.pos) < 30.0:
				attracts.append({ "pos": _lead_point(a.pos, threat, a.speed), "weight": 3.8, "range": 280.0 })
				mult = 1.35
			else:
				# no threat — guard you, and stand at ease once you stop and I'm in place
				var slot := player.pos + ring * 2.6
				if player.vel.length() < 0.6 and a.pos.distance_to(slot) < 1.6:
					_steer(a, Vector3.ZERO, dt)
					return
				attracts.append({ "pos": slot, "weight": 2.6, "range": 40.0 })
				mult = 1.1
		_:
			# idle: gather in a ring around the clan hall but OUTSIDE its roof (radius
			# ~3.4), spread out so the top-down view shows every member clearly
			var hall: Dictionary = clan_hall_by_owner.get(player.el, {})
			var c: Vector3 = Vector3(hall["x"], 0, hall["z"]) if not hall.is_empty() else player.pos
			var slot := c + ring * 5.0
			var d := slot - a.pos; d.y = 0
			_steer(a, d.normalized() if d.length() > 0.9 else Vector3.ZERO, dt, 0.9)
			return
	_smart_move(a, attracts, repels, dt, mult)

func _player_in_clan_hall() -> bool:
	var hall: Dictionary = clan_hall_by_owner.get(player.el, {})
	return not hall.is_empty() and Vector2(player.pos.x - hall["x"], player.pos.z - hall["z"]).length() < hall["r"]

# True once every clan member has a task — only then is the clan fully "live" (defenders
# become mortal). While anyone is still unassigned the clan is in a protected setup state.
func _all_clan_assigned() -> bool:
	return not allies.is_empty() and not allies.any(func(a): return a.role == "")

# Top-down command view is on while you still have unassigned clan and you're at the
# hall — so you can look down through the roof and hand out tasks. It ends when every
# member has a task (or you walk away from the hall).
func _clan_assign_active() -> bool:
	if not player or allies.is_empty():
		return false
	if not allies.any(func(a): return a.role == ""):
		return false
	var hall: Dictionary = clan_hall_by_owner.get(player.el, {})
	if hall.is_empty():
		return false
	return Vector2(player.pos.x - hall["x"], player.pos.z - hall["z"]).length() < hall["r"] + 10.0

# the nearest thing menacing the player: their predator, or a still-dangerous CO₂
func _nearest_threat_to_player(a: GameChar) -> GameChar:
	var best: GameChar = null
	var bd := 1.0e20
	var pred: GameChar = chars.get(ELEMENTS[player.el]["predator"])
	if pred and pred.alive and not inside_own_cave(pred):
		bd = player.pos.distance_to(pred.pos); best = pred
	for n in npcs:
		if n.kind == "co2" and n.alive and n.co_timer <= 0.0:
			var d := player.pos.distance_to(n.pos)
			if d < bd and d < 45.0:
				bd = d; best = n
	return best

# The rescued twin trails the player while in leash range, otherwise waits.
func _update_twin(t: GameChar, dt: float) -> void:
	if not player:
		_steer(t, Vector3.ZERO, dt)
		return
	var d := t.pos.distance_to(player.pos)
	if d > TWIN_LEASH or d < 2.6:
		_steer(t, Vector3.ZERO, dt)
		return
	var desired := player.pos - t.pos
	desired.y = 0
	_steer(t, desired.normalized(), dt, 1.05)

# Self-training: stand on your totem with no enemy near to earn +1 max heart.
func _update_training(dt: float) -> void:
	if not player or not player.alive or player.max_hp >= MAX_HP_CAP:
		train_progress = 0.0
		return
	var pad: Dictionary = train_pad_by_owner.get(player.el, {})
	if pad.is_empty():
		train_progress = 0.0
		return
	# the pad is walled to enemies, so simply standing on it trains you safely
	var on_pad: bool = Vector2(player.pos.x - pad["x"], player.pos.z - pad["z"]).length() < pad["r"]
	if on_pad:
		train_progress += dt / TRAIN_TIME
		if train_progress >= 1.0:
			train_progress = 0.0
			player.max_hp = mini(MAX_HP_CAP, player.max_hp + 1)
			player.hp = player.max_hp
			ui.toast("Self-training complete — max hearts now %d!" % player.max_hp)
			_update_hud_hearts()
	else:
		train_progress = maxf(0.0, train_progress - dt / TRAIN_TIME)

# Clan hall: stand inside for the full teach time to summon a fresh clan.
func _update_teaching(dt: float) -> void:
	if not player or not player.alive:
		teach_progress = 0.0
		return
	var hall: Dictionary = clan_hall_by_owner.get(player.el, {})
	# you can teach a fresh batch when you have none — or to top up once down to a few
	if hall.is_empty() or allies.size() > CLAN_REFILL_AT:
		teach_progress = 0.0
		return
	var inside: bool = Vector2(player.pos.x - hall["x"], player.pos.z - hall["z"]).length() < hall["r"]
	if inside:
		teach_progress += dt / TEACH_TIME
		if teach_progress >= 1.0:
			teach_progress = 0.0
			_summon_clan(hall)
	else:
		teach_progress = maxf(0.0, teach_progress - dt / TEACH_TIME)

# Bring the clan back up to full strength: spawn fresh idle members for the empty slots,
# then re-spread everyone's formation angle evenly.
func _summon_clan(hall: Dictionary) -> void:
	var need := CLAN_SIZE - allies.size()
	for i in need:
		var a := make_character("element", player.el)
		a.ally = true
		a.role = ""                 # idle — waiting for you to give them a task
		a.max_hp = 1; a.hp = 1
		a.group.scale = Vector3.ONE * CLAN_SCALE
		var ang := TAU * float(allies.size()) / float(CLAN_SIZE)
		a.pos = Vector3(hall["x"] + cos(ang) * 2.8, 0, hall["z"] + sin(ang) * 2.8)
		a.group.position = a.pos
		# a translucent gray shroud that shows when this member is selected
		var sel := MeshLib.sphere(1.25, MeshLib.unlit_mat(MeshLib.rgb(0x8c8c96), 0.45), 14, 10)
		sel.position.y = 1.4
		sel.visible = false
		a.group.add_child(sel)
		a.group.set_meta("sel", sel)
		allies.append(a)
	for i in allies.size():
		allies[i].follow_angle = TAU * float(i) / float(allies.size())
	if need >= CLAN_SIZE:
		ui.toast("Clan of %d is waiting! Click them (multi-select) and pick a task." % need)
	else:
		ui.toast("Reinforcements! %d fresh clan members — click to assign." % need)
	_update_hud_status()

func _refresh_channel() -> void:
	if train_progress > 0.0:
		ui.set_channel("Self-training", train_progress)
	elif teach_progress > 0.0:
		ui.set_channel("Teaching clan", teach_progress)
	else:
		ui.set_channel("", -1.0)

# Each element has its own colour-matched key; only that element may take it. The
# player's key can be picked up by the player or fetched by a clan fetcher; the two
# rival keys just sit in the world (their owners don't rescue).
func _update_key(dt: float) -> void:
	if keys.is_empty() or not keys.has(player.el):
		return
	var mine: Dictionary = keys[player.el]
	var mnode: Node3D = mine["node"]
	# spin every key; bob the idle ones in place
	for el in keys:
		var k: Dictionary = keys[el]
		var node: Node3D = k["node"]
		node.rotation.y += dt * (2.4 if (el == player.el and has_key) else 1.4)
		var carried: bool = el == player.el and (has_key or key_carrier != null)
		var beam = node.get_meta("beam", null)
		if beam:
			beam.visible = not carried       # drop the pillar once it's on your back / being carried
		if not carried:
			node.position = Vector3(k["pos"].x, 1.1 + sin(time_ms * 0.004 + node.position.x) * 0.2, k["pos"].z)
	if has_key:
		_magnet_key_to(mnode, player, 1.7, dt)
		return
	# a clan fetcher is bringing your key to you
	if key_carrier != null:
		if not allies.has(key_carrier) or not is_instance_valid(key_carrier.group):
			key_carrier = null                      # carrier lost — key drops where it was
		else:
			mine["pos"] = key_carrier.pos           # radar / drop point tracks the carrier
			keys[player.el] = mine
			_magnet_key_to(mnode, key_carrier, 1.4, dt)
			if player and player.alive and key_carrier.pos.distance_to(player.pos) < 2.6:
				has_key = true
				key_carrier = null
				ui.toast("Your clan brought you your key! Free your twin at the zoo cage.")
				_update_objective()
				_update_hud_status()
			return
	# the player walks onto their OWN key
	if player and player.alive and player.pos.distance_to(mine["pos"]) < KEY_PICK_DIST:
		has_key = true
		ui.toast("Got your %s key! Free your twin at the zoo cage." % ELEMENTS[player.el]["label"])
		_update_objective()
		_update_hud_status()
		return
	# a fetcher grabs your OWN key
	for a in allies:
		if a.role == "fetch" and a.pos.distance_to(mine["pos"]) < KEY_PICK_DIST:
			key_carrier = a
			ui.toast("Your clan grabbed your key — bringing it to you!")
			break
	# bumping a rival key does nothing — say so, once
	for el in keys:
		if el == player.el:
			continue
		var k: Dictionary = keys[el]
		if not k["hinted"] and player and player.pos.distance_to(k["pos"]) < KEY_PICK_DIST + 0.6:
			k["hinted"] = true
			keys[el] = k
			ui.toast("That's %s's key — only %s can take it." % [ELEMENTS[el]["label"], ELEMENTS[el]["label"]])

func _near_any_room(p: Vector3) -> bool:
	for el in clan_hall_by_owner:
		var r: Dictionary = clan_hall_by_owner[el]
		if Vector2(p.x - r["x"], p.z - r["z"]).length() < r["r"] + 2.0:
			return true
	for el in train_pad_by_owner:
		var r: Dictionary = train_pad_by_owner[el]
		if Vector2(p.x - r["x"], p.z - r["z"]).length() < r["r"] + 2.0:
			return true
	return false

func _magnet_key_to(node: Node3D, ch: GameChar, dist: float, dt: float) -> void:
	var yaw := ch.group.rotation.y
	var behind := ch.pos - Vector3(sin(yaw), 0, cos(yaw)) * dist
	behind.y = 1.5 + sin(time_ms * 0.005) * 0.12
	node.position = node.position.lerp(behind, 1.0 - pow(0.0008, dt))

# Release the twin at your cage, then win by walking it into your home cave.
func _check_rescue() -> void:
	if won or not player or not player.alive:
		return
	if has_key and freed_twin == null:
		var cage: Dictionary = cage_by_el.get(player.el, {})
		if not cage.is_empty() and player.pos.distance_to(Vector3(cage["x"], 0, cage["z"])) < CAGE_RELEASE_DIST:
			_release_twin(cage)
	if freed_twin and cave_by_owner.has(player.el):
		var c: Dictionary = cave_by_owner[player.el]
		if Vector2(freed_twin.pos.x - c["x"], freed_twin.pos.z - c["z"]).length() < RESCUE_WIN_DIST:
			won = true
			end_game("rescued")

func _release_twin(cage: Dictionary) -> void:
	WorldBuilder.open_cage(cage)
	obstacles = obstacles.filter(func(o): return absf(o["x"] - cage["x"]) > 0.01 or absf(o["z"] - cage["z"]) > 0.01)
	var t := make_character("element", player.el)
	t.is_twin = true
	t.max_hp = 999; t.hp = 999
	t.pos = Vector3(cage["x"], 0, cage["z"])
	t.group.position = t.pos
	t.group.scale = Vector3.ONE * 0.8
	freed_twin = t
	ui.toast("%s is free! Lead them home to your cave." % ELEMENTS[player.el]["label"])
	_update_objective()

func _free_keys() -> void:
	for el in keys:
		var node = keys[el].get("node")
		if node and is_instance_valid(node):
			node.queue_free()
	keys = {}

# --------------------------------------------------------- black-stone disguise
func _spawn_black_stones() -> void:
	_free_black_stones()
	var dark := MeshLib.unlit_mat(MeshLib.rgb(0x2a2733))
	var glow := MeshLib.unlit_mat(MeshLib.rgb(0x6a5f86), 0.4)
	for i in N_BLACK_STONES:
		var spot := random_spot()
		for t in 20:
			var s := random_spot()
			if not _near_any_room(s):
				spot = s
				break
		var n := Node3D.new()
		var rock := MeshLib.sphere(0.55, dark, 12, 8)
		rock.scale = Vector3(1.2, 0.85, 1.0)
		n.add_child(rock)
		var halo := MeshLib.disc(0.95, glow, 18)
		halo.position.y = -0.4
		n.add_child(halo)
		n.position = Vector3(spot.x, 0.5, spot.z)
		add_child(n)
		black_stones.append({ "node": n, "pos": spot, "cooldown": 0.0 })

func _free_black_stones() -> void:
	for s in black_stones:
		var node = s.get("node")
		if node and is_instance_valid(node):
			node.queue_free()
	black_stones = []

func _update_black_stones(dt: float) -> void:
	for s in black_stones:
		var node: Node3D = s["node"]
		if s["cooldown"] > 0.0:
			s["cooldown"] -= dt
			if s["cooldown"] <= 0.0:
				var spot := random_spot()
				for t in 20:
					var c := random_spot()
					if not _near_any_room(c):
						spot = c
						break
				s["pos"] = spot
				node.position = Vector3(spot.x, 0.5, spot.z)
				node.visible = true
			continue
		node.position.y = 0.5 + sin(time_ms * 0.004 + node.position.x) * 0.12
		node.rotation.y += dt * 0.7
		if not _is_disguised() and player and player.alive and player.pos.distance_to(s["pos"]) < KEY_PICK_DIST:
			node.visible = false
			s["cooldown"] = 25.0
			_start_disguise()

func _start_disguise() -> void:
	if disguise_node == null:
		disguise_node = MeshLib.build_co2()
		MeshLib.add_blob_shadow(disguise_node, 1.85)
		add_child(disguise_node)
	disguise_node.visible = true
	if player and is_instance_valid(player.group):
		player.group.visible = false
	disguise_timer = DISGUISE_TIME
	ui.toast("Energized! Hunt down your predator, blend in with CO₂ — but O₂ now hunt you (%ds)" % int(DISGUISE_TIME))
	_update_hud_status()

func _end_disguise() -> void:
	disguise_timer = 0.0
	if disguise_node and is_instance_valid(disguise_node):
		disguise_node.visible = false
	if player and is_instance_valid(player.group):
		player.group.visible = true
	ui.toast("Your disguise faded — you're you again.")
	_update_hud_status()

# A key shaped like a little bow+shaft+teeth, finished as silvery metal tinted with
# the element's exact colour (silvery-red Fire, silvery-blue Water, silvery-green Leaf).
func _make_key_node(el: String) -> Node3D:
	var base: Color = MeshLib.rgb(ELEMENTS[el]["color"])
	var n := MeshLib.key_node(base)
	# a tall light pillar in the element's colour, like the home caves, so you can
	# spot the key from across the map
	var bm := CylinderMesh.new()
	bm.top_radius = 0.32; bm.bottom_radius = 0.32; bm.height = 60.0
	bm.radial_segments = 8; bm.cap_top = false; bm.cap_bottom = false
	var beam_mat := MeshLib.unlit_mat(base, 0.26)
	beam_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	var beam := MeshLib.mi(bm, beam_mat)
	beam.position.y = 29.0
	n.add_child(beam)
	n.set_meta("beam", beam)
	return n

# Each element's key is parked in its PREDATOR's camp — out among that predator's
# cave, clan hall and training pad. So claiming your key means a raid into the turf
# of the element that hunts you (and every element's key follows the same rule).
func _pick_key_spot(pred_el: String, used: Array) -> Vector3:
	var c: Dictionary = cave_by_owner[pred_el]
	var hall: Dictionary = clan_hall_by_owner.get(pred_el, c)
	var pad: Dictionary = train_pad_by_owner.get(pred_el, c)
	# heart of the camp: midway between the predator's clan hall and training pad
	var center := Vector3((hall["x"] + pad["x"]) * 0.5, 0.0, (hall["z"] + pad["z"]) * 0.5)
	for i in 60:
		var ang := randf() * TAU
		var rad := 5.0 + randf() * 8.0
		var s := Vector3(center.x + cos(ang) * rad, 0.0, center.z + sin(ang) * rad)
		if _near_any_room(s):
			continue                                        # not inside a walled hall/pad
		if Vector2(s.x - c["x"], s.z - c["z"]).length() < c["r"] + 3.0:
			continue                                        # not buried in the cave rocks
		if used.any(func(u): return Vector2(u.x - s.x, u.z - s.z).length() < 16.0):
			continue
		return s
	# fallback: just past the camp toward the map centre — always clear of the walls
	var dir := Vector2(center.x - c["x"], center.z - c["z"]).normalized()
	return Vector3(c["x"] + dir.x * 14.0, 0.0, c["z"] + dir.y * 14.0)

# One key per element, each parked in that element's predator's camp.
func _spawn_keys() -> void:
	_free_keys()
	var used: Array = []
	for el in ["fire", "water", "grass"]:
		var spot := _pick_key_spot(ELEMENTS[el]["predator"], used)
		used.append(spot)
		var node := _make_key_node(el)
		node.position = Vector3(spot.x, 1.1, spot.z)
		add_child(node)
		keys[el] = { "node": node, "pos": spot, "hinted": false }

func _update_hud_hearts() -> void:
	if player:
		ui.set_hearts(player.hp, player.max_hp)

func _update_hud_status() -> void:
	var s := "Clan %d/%d   ·   Key: %s" % [allies.size(), CLAN_SIZE, ("yes" if has_key else "no")]
	if o2_charges > 0:
		s += "   ·   O₂ %d/%d" % [o2_charges, O2_CHARGE_CAP]
	if _is_disguised():
		s += "   ·   🖤 Disguised %ds" % int(ceil(disguise_timer))
	ui.set_status(s)

func _update_objective() -> void:
	var txt := "Find your %s key" % ELEMENTS[player.el]["label"]
	if won:
		txt = "Rescued!"
	elif freed_twin:
		txt = "Escort %s home to your cave!" % ELEMENTS[player.el]["label"]
	elif has_key:
		txt = "Free %s at the zoo cage" % ELEMENTS[player.el]["label"]
	ui.set_objective(txt)

# ------------------------------------------------------------- game flow
func start_game(my_el: String) -> void:
	_clear_actors()
	ending = false
	won = false
	stamina = 100.0
	o2_charges = 0
	# reset rescue state
	allies = []
	freed_twin = null
	has_key = false
	key_carrier = null
	train_progress = 0.0
	teach_progress = 0.0
	clan_cooldown = 0.0
	disguise_timer = 0.0
	WorldBuilder.reset_cages(self)
	for el in ["fire", "water", "grass"]:
		var ch := make_character("element", el, el == my_el)
		ch.max_hp = BASE_HP
		ch.hp = BASE_HP
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
	ui.setup_task_icons(my_el, ELEMENTS[my_el]["predator"], ELEMENTS[my_el]["prey"])
	ui.show_task_buttons(false)
	_spawn_keys()
	_spawn_black_stones()
	_update_hud_hearts()
	_update_hud_status()
	_update_objective()
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
	var title := "Round over"
	var sub := "Final standings above."
	if reason == "rescued" and player:
		title = "You freed %s!  🎉" % ELEMENTS[player.el]["label"]
		sub = "You brought your twin safely home. Rescue complete!"
	elif top and top.is_player:
		title = "You win!"
	elif top:
		title = ELEMENTS[top.el]["label"] + " leads!"
	ui.show_end(out, title, sub)

func _clear_actors() -> void:
	for ch in all_chars():
		ch.group.queue_free()
	chars = {}
	npcs = []
	allies = []
	freed_twin = null
	key_carrier = null
	player = null
	if ui:
		ui.show_task_buttons(false)
	_free_keys()
	_free_black_stones()
	if disguise_node and is_instance_valid(disguise_node):
		disguise_node.queue_free()
	disguise_node = null
	disguise_timer = 0.0
	has_key = false

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
