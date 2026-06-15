class_name Game
extends Node3D
# Elemental Tag — Godot port of the Three.js prototype.
# Three elements play rock-paper-scissors tag across a twilight town while CO₂
# hunts everyone and O₂ molecules hand out points. Most points when time runs out.

# ------------------------------------------------------------------ constants
const ARENA := 120.0
const CATCH_DIST := 2.4
# Online only: a guest is DRAWN ~(½RTT + INTERP_DELAY)·speed from where the host authoritatively
# has it (guest prioritises its own smoothness over matching the host — see _render_off). So
# when a networked human is the catcher or the prey, widen the catch by this pad so a catch
# that LOOKS dead-on actually registers. Host-vs-AI and AI-vs-AI stay tight at CATCH_DIST.
# Sized from the QA harness (scripts/nettest): the guest renders other actors ~2u beyond
# their true position at ~140ms RTT, ~3–4u at ~300ms RTT + sprint. 1.6 → a 4.0u effective
# catch, which cleared the typical gap in-test (note: own-avatar reconcile skew is a separate,
# tiny ~0.1–0.5u — the input-seq reconciliation removes the latency lead).
const NET_CATCH_PAD := 1.6
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
# element actors — generalized from the old single-`chars[el]` model so each
# element can hold many actors (humans + NPC fillers) for online multiplayer.
var actors: Array = []           # all element actors (humans + NPC fillers)
var by_el: Dictionary = {}       # el -> Array[GameChar]
var peer_actor: Dictionary = {}  # peer_id -> GameChar (humans only)
var _next_net_id := 1
var npcs: Array = []             # [GameChar] — O₂ / CO₂ molecules
var player: GameChar = null      # the LOCAL human's actor (null on the server)
var running := false
var ending := false
var time_ms := 0.0
var time_left := ROUND_TIME
var stamina := 100.0
var o2_charges := 0              # O₂ sipped this round → bigger effective stamina tank

var camera: Camera3D
var world_env: WorldEnvironment
var ui: GameUI

# ------------------------------------------------------------- online multiplayer
enum Mode { SINGLE, SERVER, CLIENT, HOST }
var mode: int = Mode.SINGLE       # SINGLE = local; HOST = this browser is the authority
                                  # (runs the sim + plays); CLIENT = guest viewer.
                                  # SERVER (old headless authority) is retired — kept in
                                  # the enum only so CLIENT keeps its value.
var net: NetManager = null        # /root/Game/Net — present in every mode
var net_input: Dictionary = {}    # SERVER: peer_id -> { move:Vector2, sprint:bool, yaw:float, seq:int }

# ---- replication (P3) ----
const SNAP_HZ := 30.0             # server snapshot rate (raised from 20 now that online mode
                                  # drops the O₂/CO₂ molecules → far fewer actors per snapshot)
const SNAP_FLOATS := 8            # per-actor: net_id, x, z, yaw, spd, flags, hp, last_input_seq
# Remote actors use fixed-delay snapshot interpolation on the host clock. The host
# sends every actor every tick so client buffers have uniform keyframes to blend.
const INTERP_DELAY := 0.10        # seconds behind the host clock (~3 snapshots @30Hz)
const EXTRAP_MAX := 0.20          # cap dead reckoning during a brief data gap
const GHOST_STALE := 2.0          # drop a ghost not updated in this many host-time seconds
const SNAP_BUFFER_MAX := 40       # ~1.3s of history @30Hz, enough to absorb TCP bursts
var _host_t_latest := 0.0         # newest host snapshot timestamp received (s)
const META_EVERY := 5             # SERVER: send the bulky status meta (scores/objective/keys)
                                  # only every Nth snapshot (30Hz / 5 = 6Hz); positions stay 30Hz
var _snap_accum := 0.0            # SERVER: snapshot send throttle
var _snap_tick := 0               # SERVER: snapshot counter (gates the meta payload)
# CLIENT match state
var local_net_id := 0             # this client's own actor net_id (0 = not in a match)
var local_el := ""                # this client's element this match
var ghosts: Dictionary = {}       # net_id -> CharVisual (remote actors we render)
var _net_actors := {}             # CLIENT: net_id -> { buf:Array, last_t:float, flags:int, hp:int }
                                  # buf entries: { t:float, pos:Vector3, yaw:float, spd:float } (per-actor keyframes)
const LOCAL_TRUST_SNAP_DIST := 10.0 # CLIENT: emergency snap distance when reconciliation history is unavailable
const PRED_HIST_MAX := 96
const RECONCILE_EPS := 0.25
var _pred_hist: Array = []        # CLIENT: recent predicted frames keyed by latest sent input seq
# ---- guest own-avatar render smoothing (never-glitch) ----
# The simulation (player.pos) stays authoritative-accurate via prediction + reconcile, but
# what we DRAW (mesh + camera) is player.pos + _render_off, where _render_off absorbs a
# reconcile snap and then decays to zero. Steady walking has no snap → _render_off stays 0
# → no lag; a correction eases away over REND_SMOOTH instead of jolting the whole world.
# This is the explicit trade: the guest is briefly drawn where it THINKS it is, not where
# the host has it — which is exactly why catches use a forgiving radius (see _catch_dist).
var _render_off := Vector3.ZERO
const REND_SMOOTH := 0.07         # seconds to ease a correction away (≈ no visible snap)
const REND_OFF_MAX := 2.5         # u — cap so frequent corrections can't pile into a drift
const REND_SNAP_DIST := 6.0       # u — beyond this it's a teleport/respawn → snap, don't ease
# Smoothed host-clock offset so render time advances steadily even when snapshots arrive
# jittery (the raw per-snapshot anchor made ghosts micro-stutter under jitter).
var _host_off := 0.0              # est_host_time() = _now() + _host_off
var _host_off_init := false
# ---- QA telemetry (only when net_log: ?netlog=1 / `-- nettest` / NET_LOG=1) ----
var net_log := false
var _nl_accum := 0.0              # 1 Hz report throttle (s)
var _nl_last_arr := 0.0          # guest: previous snapshot arrival (s)
var _nl_snap_ms := 33.0          # guest: EMA snapshot interval (ms)
var _nl_snap_jit := 0.0          # guest: EMA snapshot interval jitter (ms)
var _nl_skew := 0.0              # guest: EMA reconcile error (u) — host-auth vs my predicted self
var _nl_skew_max := 0.0          # guest: worst reconcile error in the window (u)
var _nl_snaps := 0               # guest: corrections over RECONCILE_EPS (the old code would jolt)
var _nl_rtt := 0.0              # guest: EMA round-trip (ms)
var _nl_render_frames := 0
var _nl_extrap_frames := 0       # guest: ghost-render frames spent extrapolating (buffer underrun)
var _nl_underruns := 0           # guest: frames the extrapolation hit EXTRAP_MAX (a real stall)
var _nl_buf_sum := 0.0
var _nl_seen_min := 1.0e9        # guest: closest I *rendered* myself to another ghost (u)
var _nl_host_auth := {}          # host: net_id -> min authoritative dist to the host avatar (u)
# headless host+guest harness (`-- nettest [join]`) scenario state
var _nt_picked := false
var _nt_started := false
var _nt_run_t := 0.0             # seconds since this side's match actually went live
var key_nodes: Dictionary = {}    # CLIENT: el -> Node3D (rendered team keys)
var _net_rk := {}                 # CLIENT: el -> key-held bool (from meta)
var _net_rt := {}                 # CLIENT: el -> twin-freed bool (from meta)
var _scores := { "fire": 0, "water": 0, "grass": 0 }
var _net_time_left := ROUND_TIME
# SERVER rescue state, shared per element (one key/twin per team)
var has_key_by_el := {}            # el -> bool
var twin_by_el := {}               # el -> GameChar (freed twin) or absent
# Production server (set once the Render service is deployed). Override on web
# with ?server=ws://host:port for local testing.
const PROD_SERVER_URL := "wss://elemental-rescue-server.onrender.com"

var touch_move := Vector2.ZERO   # mobile joystick: x = strafe, y = forward (set by TouchControls)
var touch_sprint := false        # mobile sprint button
var mobile := false              # touch/phone session: bigger HUD + tap targets
var lite := false                # lighter rendering for weak/touch devices (render-scale,
                                 # fewer wind-leaves, throttled décor, no SSR)
var _deco_accum := 0.0           # lite: frame time accumulated between cosmetic updates
const DECO_LITE_HZ := 20.0       # lite: run décor / wind-leaf animation at this rate, not per-frame
const PERF_SCALE_LITE := 0.75    # lite: render the 3D world at 75% then upscale (HUD stays sharp)
const PERF_SCALE_GUEST := 0.60   # guests prioritize local responsiveness over visual sharpness
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
	if OS.get_cmdline_user_args().has("testclient"):
		_ready_testclient()   # dev hook: headless lobby smoke-test (see _ready_testclient)
		return
	if OS.get_cmdline_user_args().has("nettest"):
		_ready_nettest()      # dev hook: REAL headless host+guest sim w/ telemetry (scripts/nettest)
		return
	_ready_visual()

# Create the Net node — same path (/root/Game/Net) on host and guests so messages line up.
func _start_net() -> void:
	net = NetManager.new()
	net.name = "Net"
	net.game = self
	add_child(net)

func _ready_visual() -> void:
	var is_banner := OS.get_cmdline_user_args().has("banner")
	randomize()
	_read_net_log_flag()
	mobile = TouchControls.is_touch_session()
	lite = mobile   # phones get the lighter renderer (set before the world is built)
	_apply_perf_scale()
	_build_environment()
	if is_banner:
		world_root = Node3D.new()
		add_child(world_root)
		_build_banner_world()    # a dedicated hand-placed scene, not the procedural town
	else:
		_rebuild_world(randi())
	_build_trails()
	ui = GameUI.new()
	ui.mobile = mobile   # 2x HUD + task buttons on phones
	add_child(ui)
	var touch := TouchControls.new()   # on-screen joystick + sprint (mobile only)
	touch.game = self
	add_child(touch)
	ui.element_selected.connect(start_game)
	ui.play_again.connect(_on_play_again)
	ui.task_assigned.connect(_assign_task)
	_sync_radar_world()
	_start_net()
	_wire_online()
	# opened via an invite link (…?room=CODE) → jump straight to joining that room
	var _room := _room_url_param()
	if _room != "":
		call_deferred("_auto_join_room", _room)
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

# 3D render-scale is the single biggest phone FPS lever: render the 3D world at a
# lower internal resolution and upscale it; the 2D HUD / joystick stay crisp. Tune
# live on web with ?q=high|balanced|max to A/B without a redeploy.
func _apply_perf_scale() -> void:
	var scale := 1.0
	if mode == Mode.CLIENT:
		scale = PERF_SCALE_GUEST
	elif lite:
		scale = PERF_SCALE_LITE
	if OS.has_feature("web"):
		var q: Variant = JavaScriptBridge.eval("(new URLSearchParams(location.search)).get('q')", true)
		match (str(q) if q != null else ""):
			"high": scale = 1.0
			"balanced": scale = 0.75
			"max": scale = 0.6
	get_viewport().scaling_3d_scale = clampf(scale, 0.4, 1.0)
	if world_env != null and world_env.environment != null:
		world_env.environment.ssr_enabled = not lite

# How many seconds of decorative animation to advance this frame. On lite devices we
# batch it to ~20Hz (it's purely cosmetic), returning -1.0 on the frames we skip so the
# saved CPU goes to a steadier framerate.
func _cosmetic_step(delta: float) -> float:
	if not lite:
		return delta
	_deco_accum += delta
	if _deco_accum < 1.0 / DECO_LITE_HZ:
		return -1.0
	var d := _deco_accum
	_deco_accum = 0.0
	return d

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
	env.ssr_enabled = not lite   # screen-space reflections: off on phones (costly, little benefit)
	env.ssr_max_steps = 48
	var we := WorldEnvironment.new()
	we.environment = env
	world_env = we
	add_child(we)

	var sun := DirectionalLight3D.new()
	sun.light_color = MeshLib.rgb(SUN_COLOR)
	sun.light_energy = SUN_ENERGY
	sun.shadow_enabled = false
	add_child(sun)
	sun.look_at_from_position(SUN_FROM, Vector3.ZERO, Vector3.UP)

func _rebuild_world(world_seed: int) -> void:
	if world_root != null and is_instance_valid(world_root):
		world_root.queue_free()
	world_root = Node3D.new()
	add_child(world_root)
	obstacles.clear()
	rects.clear()
	caves.clear()
	cave_by_owner.clear()
	cages.clear()
	cage_by_el.clear()
	clan_hall_by_owner.clear()
	train_pad_by_owner.clear()
	deco_anims.clear()
	wind_leaves.clear()
	seed(world_seed)
	WorldBuilder.build(self)
	_sync_radar_world()

func _sync_radar_world() -> void:
	if ui == null:
		return
	var radar_caves: Array = []
	for c in caves:
		radar_caves.append({ "x": c["x"], "z": c["z"], "r": c["r"], "fill": c["radarFill"] })
	ui.radar.setup(RIVER_X1, RIVER_X2, BRIDGES, radar_caves)

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
	if mode == Mode.HOST:
		_host_process(delta)     # this browser is the authority: simulate, render, play
		return
	if mode == Mode.CLIENT:
		_client_process(delta)   # guest viewer: render snapshots, never sim locally
		return
	var dt: float = minf(0.05, delta)
	time_ms += delta * 1000.0
	var cd := _cosmetic_step(delta)
	if cd >= 0.0:
		for fn in deco_anims:
			fn.call(time_ms)
		_update_wind_leaves(minf(0.08, cd), time_ms)

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
		for ch in actors:
			if not ch.is_human and ch.alive:
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
		for ch in actors:
			if ch.alive and not ch.is_human and ch.vel.length_squared() > 120.0 and randf() < dt * 14.0:
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
			# On a guest follow the DRAWN position (player.pos + eased correction) so the
			# world never jolts when the host nudges us; host/single follow the sim directly.
			var cp: Vector3 = _client_render_pos() if mode == Mode.CLIENT else player.pos
			var d := _cam_obstruction(cp.x, cp.z, sin(cam_yaw), cos(cam_yaw), max_d)
			var tx := cp.x + sin(cam_yaw) * d
			var tz := cp.z + cos(cam_yaw) * d
			camera.position = camera.position.lerp(Vector3(tx, cam_h, tz), 1.0 - pow(snap, dt))
			camera.look_at(Vector3(cp.x, look_y, cp.z), Vector3.UP)
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
	for ch in actors:
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
	if mode == Mode.SERVER:
		return
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

# nearest ALIVE actor of a group (the per-element array in by_el) to a point.
func _nearest_in(group: Array, from: Vector3) -> GameChar:
	var best: GameChar = null
	var bd := 1.0e20
	for c in group:
		if not c.alive:
			continue
		var d: float = from.distance_to(c.pos)
		if d < bd:
			bd = d; best = c
	return best

func _update_element_ai(ch: GameChar, dt: float) -> void:
	var me: Dictionary = ELEMENTS[ch.el]
	var predator: GameChar = _nearest_in(by_el.get(me["predator"], []), ch.pos)
	var prey: GameChar = _nearest_in(by_el.get(me["prey"], []), ch.pos)
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
	if ch.group == null:
		return
	var spare = ch.group.get_meta("spare_o", null)
	var bond = ch.group.get_meta("spare_bond", null)
	if spare and is_instance_valid(spare): spare.visible = false
	if bond and is_instance_valid(bond): bond.visible = false

# CO grabs an oxygen (O₂) or waits it out → back to dangerous CO₂.
func _co_to_co2(ch: GameChar) -> void:
	ch.co_timer = 0.0
	ch.radar_color = MeshLib.rgb(0x3a3744)
	if ch.group == null:
		return
	var spare = ch.group.get_meta("spare_o", null)
	var bond = ch.group.get_meta("spare_bond", null)
	if spare and is_instance_valid(spare): spare.visible = true
	if bond and is_instance_valid(bond): bond.visible = true

func _consume_o2(o: GameChar) -> void:
	o.alive = false
	if o.group:
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
	for e in actors:
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
	var a: Array = actors.duplicate()
	a.append_array(npcs)
	a.append_array(allies)
	if freed_twin:
		a.append(freed_twin)
	return a

func alive_elements() -> Array:
	return actors.filter(func(c): return c.alive)

func make_character(kind: String, el: String = "", is_player: bool = false) -> GameChar:
	var ch := GameChar.new()
	ch.kind = kind
	ch.el = el
	ch.is_player = is_player
	ch.net_id = _next_net_id
	_next_net_id += 1
	ch.speed = 10.2 if kind == "co2" else (6.0 if kind == "o2" else 11.0)
	if kind == "element":
		ch.radar_color = MeshLib.rgb(ELEMENTS[el]["color"])
	elif kind == "o2":
		ch.radar_color = MeshLib.rgb(0xeceef6)
	else:
		ch.radar_color = MeshLib.rgb(0x3a3744)
	# headless server has no visuals — leave group null (the GLB models aren't even
	# shipped in the server pack); every per-frame visual write guards on `ch.group`.
	if mode == Mode.SERVER:
		return ch
	ch.group = _build_char_visual(kind, el)
	return ch

# Build + parent a CharVisual for a kind/element (shared by make_character and the
# client's networked ghosts).
func _build_char_visual(kind: String, el: String) -> CharVisual:
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
	return model

# ------------------------------------------------------------- scoring
func update_board() -> void:
	var my_el := player.el if player else ""
	var entries: Array = []
	for el in ["fire", "water", "grass"]:
		var group: Array = by_el.get(el, [])
		if group.is_empty():
			continue
		var score := 0
		var any_alive := false
		for c in group:
			score += c.score
			if c.alive:
				any_alive = true
		entries.append({ "el": el, "label": ELEMENTS[el]["label"], "score": score, "alive": any_alive, "me": el == my_el })
	ui.set_board(entries)

func _check_catches() -> void:
	# elemental predators hit the nearest catchable prey actor (a hit costs a heart)
	for a in actors:
		if not a.alive or inside_own_cave(a):
			continue
		var prey: GameChar = null
		var nd := 1.0e20
		for p in by_el.get(ELEMENTS[a.el]["prey"], []):
			if not p.alive or inside_own_cave(p) or inside_own_room(p):
				continue
			if p.is_player and _is_disguised():
				continue        # energized: their predator can't catch them right now
			var d: float = a.pos.distance_to(p.pos)
			if d < nd:
				nd = d; prey = p
		if prey and nd < _catch_dist(a, prey):
			_take_hit(prey, a)
	# black-stone power-up (Pac-Man style): while disguised you can EAT your predator
	if _is_disguised() and player and player.alive and not inside_own_cave(player):
		var pred: GameChar = _nearest_in(by_el.get(ELEMENTS[player.el]["predator"], []), player.pos)
		if pred and not inside_own_cave(pred) and pred.invuln_timer <= 0.0 and player.pos.distance_to(pred.pos) < CATCH_DIST:
			ui.toast("Gotcha! You caught your predator %s!" % ELEMENTS[pred.el]["label"])
			_take_hit(pred, player)
	# ATTACK clan smack the element you hunt
	if player and player.alive and not allies.is_empty():
		var prey: GameChar = _nearest_in(by_el.get(ELEMENTS[player.el]["prey"], []), player.pos)
		if prey != null and not inside_own_cave(prey) and not inside_own_room(prey):
			for a in allies:
				if a.role == "attack" and a.pos.distance_to(prey.pos) < CATCH_DIST:
					_take_hit(prey, a)
					break
	# PROTECT clan defend you. They always neutralise the threat (briefly SLOW your
	# predator, or spend a black CO₂'s oxygen so it becomes harmless CO). But they only
	# DIE doing it once the whole clan is assigned — while you're still organising, the
	# predator/CO₂ can't actually catch your defenders. (מתאבדים, once you're committed.)
	var clan_live := _all_clan_assigned()
	var ppred: GameChar = _nearest_in(by_el.get(ELEMENTS[player.el]["predator"], []), player.pos) if player else null
	for a in allies.duplicate():
		if a.role != "protect":
			continue
		var pred: GameChar = ppred
		if pred and not inside_own_cave(pred) and pred.slow_timer <= 0.0 and a.pos.distance_to(pred.pos) < CATCH_DIST:
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
			if n.pos.distance_to(v.pos) < _catch_dist(n, v):
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
	for e in actors:
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
		if ch.group:
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
				n.alive = true
				if n.group:
					n.group.position = n.pos
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
			var prey: GameChar = _nearest_in(by_el.get(ELEMENTS[player.el]["prey"], []), a.pos)
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
	if not player:
		return false
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
	var pred: GameChar = _nearest_in(by_el.get(ELEMENTS[player.el]["predator"], []), player.pos)
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
# Single-player entry: one local human + NPC fillers (the N=1 case of _spawn_match).
func start_game(my_el: String) -> void:
	_spawn_match([{ "peer": 1, "el": my_el, "local": true }], my_el)

# Build a match from a list of humans [{peer, el, local?}]. Each element is filled
# with NPC elementals up to the largest human team ("match the biggest team"), so
# the three elements stay balanced however players pick. Single-player is N=1.
func _spawn_match(humans: Array, local_el: String = "") -> void:
	_clear_actors()
	ending = false
	won = false
	stamina = 100.0
	o2_charges = 0
	time_left = ROUND_TIME
	_snap_accum = 0.0
	has_key_by_el = {}
	twin_by_el = {}
	# reset rescue state
	allies = []
	freed_twin = null
	has_key = false
	key_carrier = null
	train_progress = 0.0
	teach_progress = 0.0
	clan_cooldown = 0.0
	disguise_timer = 0.0
	_next_net_id = 1
	WorldBuilder.reset_cages(self)
	var human_count := { "fire": 0, "water": 0, "grass": 0 }
	for h in humans:
		human_count[h["el"]] += 1
	var biggest := maxi(1, maxi(human_count["fire"], maxi(human_count["water"], human_count["grass"])))
	for el in ["fire", "water", "grass"]:
		by_el[el] = []
		for h in humans:
			if h["el"] == el:
				var is_local: bool = (mode != Mode.SERVER) and bool(h.get("local", false))
				var hc := _spawn_element_actor(el, int(h["peer"]), true, is_local)
				if is_local:
					player = hc
		for _i in (biggest - human_count[el]):
			_spawn_element_actor(el, 0, false, false)
	# No molecules online → the host doesn't simulate them, they don't go in the
	# snapshot, and no client renders them as moving ghosts. This is the cheapest
	# multiplayer lag win: fewer moving actors to sim, encode, send, and draw.
	# (single-player keeps the full set.)
	var n_o2 := 0 if mode != Mode.SINGLE else N_O2
	var n_co2 := 0 if mode != Mode.SINGLE else N_CO2
	for i in n_o2:
		var o := make_character("o2")
		o.pos = random_spot()
		if o.group: o.group.position = o.pos
		npcs.append(o)
	for i in n_co2:
		var c := make_character("co2")
		c.pos = random_spot(40.0)
		if c.group: c.group.position = c.pos
		npcs.append(c)
	if mode != Mode.SERVER and local_el != "":
		var me: Dictionary = ELEMENTS[local_el]
		ui.set_role("You: %s — catch %s, flee %s" % [me["label"], ELEMENTS[me["prey"]]["label"], ELEMENTS[me["predator"]]["label"]])
		if player:
			cam_yaw = atan2(player.pos.x, player.pos.z)
		ui.show_hud()
		ui.setup_task_icons(local_el, ELEMENTS[local_el]["predator"], ELEMENTS[local_el]["prey"])
		ui.show_task_buttons(false)
	_spawn_keys()
	_spawn_black_stones()
	if mode != Mode.SERVER:
		_update_hud_hearts()
		_update_hud_status()
		_update_objective()
		update_board()
	_run_countdown()

# Create one element actor (human or NPC filler), placed at its element's cave
# mouth and registered in actors / by_el / peer_actor.
func _spawn_element_actor(el: String, peer: int, is_human: bool, is_local: bool) -> GameChar:
	var ch := make_character("element", el, is_local)
	ch.peer_id = peer
	ch.is_human = is_human
	ch.max_hp = BASE_HP
	ch.hp = BASE_HP
	# fan multiple same-element actors around the cave mouth so they don't stack
	var idx: int = by_el[el].size()
	ch.pos = _element_spawn_pos(el, idx)
	if ch.group:
		ch.group.position = ch.pos
		ch.group.rotation.y = atan2(-ch.pos.x, -ch.pos.z)
	by_el[el].append(ch)
	actors.append(ch)
	if peer != 0:
		peer_actor[peer] = ch
	return ch

func _element_spawn_pos(el: String, idx: int) -> Vector3:
	var c: Dictionary = cave_by_owner[el]
	var a: float = _element_spawn_angle(c, idx)
	# spawn well clear of the cave mouth so the chase camera isn't looking through rocks
	return Vector3(c["x"] + cos(a) * (c["r"] + 16.0), 0, c["z"] + sin(a) * (c["r"] + 16.0))

func _element_spawn_angle(c: Dictionary, idx: int) -> float:
	var base_a: float = c["openAngle"]
	if idx == 0:
		return base_a
	return base_a + float((idx + 1) / 2) * 0.42 * (1 if idx % 2 == 1 else -1)

func _human_spawn_index(humans: Array, peer: int, el: String) -> int:
	var idx := 0
	for h in humans:
		if String(h["el"]) != el:
			continue
		if int(h["peer"]) == peer:
			return idx
		idx += 1
	return 0

func _run_countdown() -> void:
	running = false
	for s in ["3", "2", "1", "GO!"]:
		if mode != Mode.SERVER:
			ui.set_countdown(s)
		await get_tree().create_timer(0.75).timeout
	if mode != Mode.SERVER:
		ui.set_countdown("")
	if not ending:
		running = true

func end_game(reason: String) -> void:
	if ending and reason != "force":
		return
	ending = true
	running = false
	# standings are per-element TEAM (humans + NPC fillers of that element aggregated)
	var rows: Array = []
	for el in ["fire", "water", "grass"]:
		var group: Array = by_el.get(el, [])
		if group.is_empty():
			continue
		var score := 0
		var any_alive := false
		var is_me := false
		for c in group:
			score += c.score
			if c.alive:
				any_alive = true
			if c.is_player:
				is_me = true
		rows.append({ "el": el, "score": score, "alive": any_alive, "me": is_me })
	rows.sort_custom(func(a, b): return a["score"] > b["score"])
	var out: Array = []
	for i in rows.size():
		var r: Dictionary = rows[i]
		out.append({
			"label": ELEMENTS[r["el"]]["label"], "color": MeshLib.rgb(GameUI.UI_COLORS[r["el"]]),
			"score": r["score"], "me": r["me"], "alive": r["alive"], "winner": i == 0,
		})
	var top: Dictionary = rows[0] if rows.size() > 0 else {}
	var title := "Round over"
	var sub := "Final standings above."
	if reason == "rescued" and player:
		title = "You freed %s!  🎉" % ELEMENTS[player.el]["label"]
		sub = "You brought your twin safely home. Rescue complete!"
	elif not top.is_empty() and top["me"]:
		title = "You win!"
	elif not top.is_empty():
		title = ELEMENTS[top["el"]]["label"] + " leads!"
	ui.show_end(out, title, sub)

func _clear_actors() -> void:
	for ch in all_chars():
		if ch.group and is_instance_valid(ch.group) and not ch.group.is_queued_for_deletion():
			ch.group.queue_free()
	actors = []
	by_el = {}
	peer_actor = {}
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
	if mode != Mode.SINGLE:   # leaving an online match → disconnect cleanly
		if net:
			net.leave()
		mode = Mode.SINGLE
		_set_lite(mobile)
	ui.show_start()

# ------------------------------------------------------------------ online (client)
func _wire_online() -> void:
	ui.online_pressed.connect(func() -> void: ui.show_online_panel())
	ui.host_requested.connect(_on_host_requested)
	ui.join_requested.connect(_on_join_requested)
	ui.back_pressed.connect(_on_back_pressed)
	ui.lobby_element_picked.connect(func(el: String) -> void: net.choose_element(el))
	ui.lobby_start_pressed.connect(func() -> void: net.start_match())
	ui.copy_invite_pressed.connect(_on_copy_invite)
	net.joined_room.connect(_on_joined_room)
	net.join_failed.connect(_on_join_failed)
	net.lobby_changed.connect(_on_lobby_changed)
	net.match_starting.connect(_on_match_starting)
	net.match_ended.connect(_on_match_ended)
	net.connection_lost.connect(_on_connection_lost)

func _server_url() -> String:
	if OS.has_feature("web"):
		var ov: Variant = JavaScriptBridge.eval("(new URLSearchParams(location.search)).get('server')", true)
		if ov != null and str(ov) != "":
			return str(ov)
		return PROD_SERVER_URL
	return "ws://127.0.0.1:%d" % NetManager.DEFAULT_PORT   # native/editor → local server

func _set_lite(enabled: bool) -> void:
	lite = enabled
	_apply_perf_scale()

func _on_host_requested(name_: String) -> void:
	mode = Mode.HOST   # the host browser runs the authoritative game
	_set_lite(mobile)
	ui.set_online_status("Connecting…")
	net.connect_to(_server_url(), name_, "create", NetManager.gen_code())

func _on_join_requested(name_: String, code: String) -> void:
	if code.strip_edges() == "":
		ui.set_online_status("Enter the host's code to join.")
		return
	mode = Mode.CLIENT
	_set_lite(true)
	ui.set_online_status("Connecting…")
	net.connect_to(_server_url(), name_, "join", code)

func _on_back_pressed() -> void:
	if net:
		net.leave()
	mode = Mode.SINGLE
	_set_lite(mobile)
	ui.show_start()

# Copy a shareable invite link (the site URL + ?room=CODE) to the clipboard so the
# host can paste it to friends; they open it and auto-join.
func _on_copy_invite() -> void:
	var code: String = net.current_code if net else ""
	if code == "":
		return
	var link := _invite_link(code)
	DisplayServer.clipboard_set(link)
	ui.toast("Invite link copied! Paste it to your friends.")

func _invite_link(code: String) -> String:
	if OS.has_feature("web"):
		# Build the link in JS so we can carry over an active server override
		# (?server=…). Without it, an invite from a host on a custom/local server
		# drops the override and sends invited players to production instead —
		# they'd just see "No game with that code." The server value is read and
		# re-encoded entirely inside JS (never interpolated through GDScript), and
		# `code` is safe alphanumeric from NetManager.gen_code().
		var js := "(function(c){var p=new URLSearchParams();p.set('room',c);var s=(new URLSearchParams(location.search)).get('server');if(s)p.set('server',s);return location.origin+location.pathname+'?'+p.toString();})('%s')" % code
		var link: Variant = JavaScriptBridge.eval(js, true)
		if link != null and str(link) != "":
			return str(link)
	return "Join my Elemental Rescue game — room code: %s" % code

# If the page was opened with ?room=CODE (an invite link), jump straight to joining.
func _room_url_param() -> String:
	if OS.has_feature("web"):
		var v: Variant = JavaScriptBridge.eval("(new URLSearchParams(location.search)).get('room') || ''", true)
		if v != null:
			return str(v).strip_edges().to_upper()
	return ""

func _auto_join_room(code: String) -> void:
	ui.show_online_panel()
	ui.set_join_code(code)
	mode = Mode.CLIENT
	_set_lite(true)
	ui.set_online_status("Joining room %s…" % code)
	net.connect_to(_server_url(), "Player", "join", code)

func _on_joined_room(_code: String) -> void:
	ui.set_online_status("")   # the lobby screen is drawn by _on_lobby_changed (arrives next)

func _on_join_failed(reason: String) -> void:
	mode = Mode.SINGLE
	_set_lite(mobile)
	ui.set_online_status(reason)

func _on_lobby_changed(players: Array, my_id: int, admin_id: int, code: String) -> void:
	ui.show_lobby(players, my_id, admin_id, code)

func _on_match_starting(world_seed: int, humans: Array, net_ids: Dictionary) -> void:
	_client_start_match(world_seed, humans, net_ids)

# CLIENT: enter a networked match. Rebuild the static world from the host's seed so
# prediction collides against the same map, then render remote actors as ghosts.
func _client_start_match(world_seed: int, humans: Array, net_ids: Dictionary) -> void:
	_set_lite(true)
	_client_clear()
	_clear_actors()
	_rebuild_world(world_seed)
	var my_peer := net.my_id
	# net_ids came over JSON, so its keys are strings (e.g. {"3": 5}); check both forms.
	local_net_id = int(net_ids.get(str(my_peer), net_ids.get(my_peer, 0)))
	local_el = "fire"
	var spawn_idx := 0
	for h in humans:
		if int(h["peer"]) == my_peer:
			local_el = String(h["el"])
			spawn_idx = _human_spawn_index(humans, my_peer, local_el)
			break
	# local predicted avatar (drives the camera + sends input)
	player = make_character("element", local_el, true)
	player.is_human = true
	player.net_id = local_net_id
	player.pos = _element_spawn_pos(local_el, spawn_idx)
	if player.group:
		player.group.position = player.pos
	cam_yaw = atan2(player.pos.x, player.pos.z)
	stamina = 100.0
	o2_charges = 0
	var me: Dictionary = ELEMENTS[local_el]
	ui.set_role("You: %s — catch %s, flee %s" % [me["label"], ELEMENTS[me["prey"]]["label"], ELEMENTS[me["predator"]]["label"]])
	ui.setup_task_icons(local_el, ELEMENTS[local_el]["predator"], ELEMENTS[local_el]["prey"])
	ui.show_task_buttons(false)
	ui.show_hud()
	_run_countdown()

func _client_clear() -> void:
	running = false
	for nid in ghosts:
		if is_instance_valid(ghosts[nid]):
			ghosts[nid].queue_free()
	ghosts.clear()
	for el in key_nodes:
		if is_instance_valid(key_nodes[el]):
			key_nodes[el].queue_free()
	key_nodes.clear()
	_net_actors.clear()
	_pred_hist.clear()
	_host_t_latest = 0.0
	_host_off = 0.0
	_host_off_init = false
	_render_off = Vector3.ZERO
	if player and player.group and is_instance_valid(player.group):
		player.group.queue_free()
	player = null
	local_net_id = 0

func _now() -> float:
	return float(Time.get_ticks_msec()) / 1000.0

func _est_host_time() -> float:
	return _now() + _host_off

# CLIENT: where the local avatar is DRAWN — the authoritative sim position plus a decaying
# offset that swallowed the last reconcile correction. Equals player.pos in steady motion.
func _client_render_pos() -> Vector3:
	return (player.pos + _render_off) if player else Vector3.ZERO

# A networked human (a guest) — its drawn position lags the host's authoritative one, so
# catches involving it get the forgiving pad. The host's own avatar (== player) does not.
func _is_remote_human(ch: GameChar) -> bool:
	return ch != null and ch.is_human and ch != player

# Effective catch distance for a predator/prey pair. Padded only on the host when a guest
# is involved; single-player and host-vs-AI stay exactly at CATCH_DIST.
func _catch_dist(a: GameChar, b: GameChar) -> float:
	if mode == Mode.HOST and (_is_remote_human(a) or _is_remote_human(b)):
		return CATCH_DIST + NET_CATCH_PAD
	return CATCH_DIST

# CLIENT: a snapshot arrived. Remote actors get keyframes for interpolation. The local
# avatar stays locally predicted unless the host reports an unmistakable desync.
func client_on_snapshot(adata: PackedFloat32Array, _meta: Dictionary) -> void:
	if local_net_id == 0 or adata.size() < 1:
		return
	var host_t := float(adata[0])
	_host_t_latest = host_t
	# Track the host-clock offset (host_t − local_now) with a slow EMA so render time
	# advances steadily; hard-resync only on a big step (first snapshot, or after a stall).
	var inst_off := host_t - _now()
	if not _host_off_init:
		_host_off = inst_off
		_host_off_init = true
	elif absf(inst_off - _host_off) > 0.25:
		_host_off = inst_off
	else:
		_host_off = lerpf(_host_off, inst_off, 0.08)
	if net_log:
		var arr := _now()
		if _nl_last_arr > 0.0:
			var iv := (arr - _nl_last_arr) * 1000.0
			_nl_snap_ms = lerpf(_nl_snap_ms, iv, 0.1)
			_nl_snap_jit = lerpf(_nl_snap_jit, absf(iv - _nl_snap_ms), 0.1)
		_nl_last_arr = arr
	# Per-actor keyframe ingest on the host timeline.
	var local_seen := false
	var local_pos := Vector3.ZERO
	var local_yaw := 0.0
	var local_spd := 0.0
	var local_flags := 0
	var local_hp := BASE_HP
	var local_ack_seq := 0
	var count := int((adata.size() - 1) / SNAP_FLOATS)
	for k in count:
		var b := 1 + k * SNAP_FLOATS
		var nid := int(adata[b])
		var pos := Vector3(adata[b + 1], 0, adata[b + 2])
		var yaw := float(adata[b + 3])
		var spd := float(adata[b + 4])
		var flags := int(adata[b + 5])
		var hp := int(adata[b + 6])
		var ack_seq := int(adata[b + 7])
		if nid == local_net_id and player != null:
			local_seen = true
			local_pos = pos
			local_yaw = yaw
			local_spd = spd
			local_flags = flags
			local_hp = hp
			local_ack_seq = ack_seq
			continue
		var a = _net_actors.get(nid, null)
		if a == null:
			a = { "buf": [], "last_t": host_t, "flags": flags, "hp": hp }
			_net_actors[nid] = a
		a["last_t"] = host_t
		a["flags"] = flags
		a["hp"] = hp
		if a["buf"].is_empty() or host_t > float(a["buf"][a["buf"].size() - 1]["t"]):
			a["buf"].append({ "t": host_t, "pos": pos, "yaw": yaw, "spd": spd })
		while a["buf"].size() > SNAP_BUFFER_MAX:
			a["buf"].pop_front()
	if player and local_seen:
		_client_reconcile_local(local_pos, local_yaw, local_spd, local_flags, local_hp, local_ack_seq)

# CLIENT: slow status payload (scores / objective / key positions). Arrives as its own
# JSON message (~6Hz) now that positions ride a separate binary frame. Omitted fields
# keep their previous values (the host only attaches the full meta every META_EVERY-th tick).
func client_on_meta(meta: Dictionary) -> void:
	if local_net_id == 0:
		return
	_net_time_left = float(meta.get("tl", _net_time_left))
	var sc: Dictionary = meta.get("sc", {})
	for el in ["fire", "water", "grass"]:
		_scores[el] = int(sc.get(el, _scores[el]))
	_net_rk = meta.get("rk", _net_rk)
	_net_rt = meta.get("rt", _net_rt)
	if meta.has("kp"):
		_client_sync_keys(meta["kp"])

func _client_get_ghost(nid: int, flags: int) -> CharVisual:
	if ghosts.has(nid):
		return ghosts[nid]
	var kind: String = _KIND_NAME[flags & 3]
	var el: String = _EL_NAME[(flags >> 2) & 3]
	var cv := _build_char_visual(kind, el)
	ghosts[nid] = cv
	return cv

func _on_connection_lost() -> void:
	mode = Mode.SINGLE
	running = false
	ui.toast("Disconnected from the server.")
	ui.show_start()

# HOST: the admin clicked START. The host browser is the authority — it builds the
# match (humans + NPC fillers, with visuals), plays as its own avatar, and streams
# snapshots to the guests. net.gd calls this, then broadcasts "start" to the guests.
func host_start_match(world_seed: int, humans: Array) -> void:
	_rebuild_world(world_seed)
	var hs: Array = []
	var my_el := "fire"
	for h in humans:
		var is_local: bool = bool(h.get("local", false))
		hs.append({ "peer": int(h["peer"]), "el": String(h["el"]), "local": is_local })
		if is_local:
			my_el = String(h["el"])
	net_input.clear()
	local_el = my_el
	_spawn_match(hs, my_el)        # creates visuals + the host's own avatar; running flips true after the countdown

# HOST: a guest dropped — leave their avatar behind as an AI filler so its team isn't
# suddenly a player short, and stop reading their (now absent) input.
func host_remove_peer(peer: int) -> void:
	net_input.erase(peer)
	if peer_actor.has(peer):
		var ch: GameChar = peer_actor[peer]
		ch.is_human = false
		ch.peer_id = 0
		peer_actor.erase(peer)

# HOST authority tick: simulate everyone (the host's own avatar from local input, the
# guests from their relayed input, plus AI + molecules), resolve catches/rescue, render
# the world, and stream snapshots to the guests.
func _host_process(delta: float) -> void:
	if camera == null:
		return
	var dt: float = minf(0.05, delta)
	time_ms += delta * 1000.0
	var cd := _cosmetic_step(delta)
	if cd >= 0.0:
		for fn in deco_anims:
			fn.call(time_ms)
	if running:
		time_left = maxf(0.0, time_left - dt)
		_host_capture_local_input(dt)        # host's own avatar input -> net_input[my_id]
		_tick_timers(dt)
		for ch in actors:
			if ch.is_human:
				_update_human_net(ch, dt)
			elif ch.alive:
				_update_element_ai(ch, dt)
		for n in npcs:
			if n.alive:
				if n.kind == "co2":
					_update_co2(n, dt)
				else:
					_update_o2(n, dt)
		_update_cave_timers(dt)
		_check_catches()
		_server_rescue(dt)
		_host_sync_hud()
		_snap_accum += dt
		if _snap_accum >= 1.0 / SNAP_HZ:
			_snap_accum = 0.0
			_broadcast_snapshot()
	if cd >= 0.0:
		_update_wind_leaves(minf(0.08, cd), time_ms)
	_update_trails(dt)
	for ch in all_chars():
		if not ch.alive or ch.group == null:
			continue
		ch.group.position = ch.pos
		if ch.vel.length_squared() > 0.5:
			ch.group.rotation.y = lerp_angle(ch.group.rotation.y, atan2(ch.vel.x, ch.vel.z), 1.0 - pow(0.001, dt))
		ch.group.animate(time_ms, ch.vel.length())
	_update_camera(dt)
	if net_log:
		_nl_host_tick(dt)

# HOST: read this player's own input (keyboard + on-screen joystick/sprint) and stash
# it as net_input so _update_human_net moves the host's avatar like any other human.
func _host_capture_local_input(dt: float) -> void:
	var hid := net.my_id
	if player == null or not player.alive:
		net_input[hid] = { "move": Vector2.ZERO, "sprint": false, "yaw": cam_yaw, "seq": 0 }
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
	if sprint:
		stamina = maxf(0.0, stamina - dt * 30.0)
	else:
		stamina = minf(100.0, stamina + dt * 13.0)
	ui.set_stamina(stamina)
	net_input[hid] = { "move": Vector2(mx, mz), "sprint": sprint, "yaw": cam_yaw, "seq": 0 }

# HOST: drive the shared HUD from the host's own authoritative state (it reuses the
# client HUD helpers, which read these _net_* mirrors).
func _host_sync_hud() -> void:
	if player == null:
		return
	local_el = player.el
	for el in ["fire", "water", "grass"]:
		_net_rk[el] = bool(has_key_by_el.get(el, false))
		_net_rt[el] = twin_by_el.get(el) != null
		_scores[el] = _team_score(el)
	_net_time_left = time_left
	has_key = bool(has_key_by_el.get(player.el, false))   # radar objective marker
	freed_twin = twin_by_el.get(player.el)
	_client_update_hud()

# Move a human actor from its latest networked input (server-authoritative). Mirror
# of _update_player's movement math, minus local-only stamina/o2/disguise/UI.
func _update_human_net(ch: GameChar, dt: float) -> void:
	if not ch.alive:
		return
	var inp: Dictionary = net_input.get(ch.peer_id, {})
	var mv: Vector2 = inp.get("move", Vector2.ZERO)
	var sprint: bool = inp.get("sprint", false)
	var yaw: float = inp.get("yaw", 0.0)
	_apply_human_move(ch, mv.x, mv.y, sprint, yaw, dt)

func _apply_human_move(ch: GameChar, mx: float, mz: float, sprint: bool, yaw: float, dt: float) -> void:
	var ln := minf(1.0, sqrt(mx * mx + mz * mz))
	var target := Vector3.ZERO
	if ln > 0.05:
		var fx := -sin(yaw)
		var fz := -cos(yaw)
		var rx := -fz
		var rz := fx
		target = Vector3(fx * mz + rx * mx, 0, fz * mz + rz * mx).normalized()
		target *= ch.speed * (1.5 if sprint else 1.0) * terrain_mult(ch) * _slow_mult(ch) * ln
	ch.vel = ch.vel.lerp(target, 1.0 - pow(0.0003, dt))
	ch.pos += ch.vel * dt
	resolve_collisions(ch)

# SERVER: stash a peer's latest input (consumed by _update_human_net).
func server_set_input(peer: int, mx: float, mz: float, sprint: bool, yaw: float, seq: int = 0) -> void:
	net_input[peer] = { "move": Vector2(mx, mz), "sprint": sprint, "yaw": yaw, "seq": seq }

# ---- snapshot encoding (shared layout, server packs / client unpacks) ----
const _KIND_CODE := { "element": 0, "o2": 1, "co2": 2 }
const _EL_CODE := { "": 0, "fire": 1, "water": 2, "grass": 3 }
const _EL_NAME := ["", "fire", "water", "grass"]
const _KIND_NAME := ["element", "o2", "co2"]

func _pack_flags(ch: GameChar) -> int:
	var f := int(_KIND_CODE[ch.kind])           # bits 0-1 kind
	f |= int(_EL_CODE.get(ch.el, 0)) << 2        # bits 2-3 element
	if ch.alive: f |= 1 << 4
	if ch.co_timer > 0.0: f |= 1 << 5            # CO (spent / grey)
	if ch.slow_timer > 0.0: f |= 1 << 6          # slowed (predator hit) → clients predict at half speed too
	return f

func _broadcast_snapshot() -> void:
	var list: Array = []
	list.append_array(actors)
	list.append_array(npcs)
	for el in twin_by_el:
		if twin_by_el[el] != null:
			list.append(twin_by_el[el])
	# Every actor, every tick. Uniform host-clock keyframes let guests interpolate
	# between real samples instead of switching in and out of dead reckoning.
	var data := PackedFloat32Array()
	data.resize(1 + list.size() * SNAP_FLOATS)
	data[0] = float(time_ms) * 0.001
	var i := 1
	for ch in list:
		var yaw := atan2(ch.vel.x, ch.vel.z) if ch.vel.length_squared() > 0.04 else 0.0
		var spd: float = ch.vel.length()
		data[i] = float(ch.net_id)
		data[i + 1] = ch.pos.x
		data[i + 2] = ch.pos.z
		data[i + 3] = yaw
		data[i + 4] = spd
		data[i + 5] = float(_pack_flags(ch))
		data[i + 6] = float(ch.hp)
		data[i + 7] = float(int(net_input.get(ch.peer_id, {}).get("seq", 0)) if ch.is_human else 0)
		i += SNAP_FLOATS
	# Per-element rescue state + key positions, so each client can show its objective
	# and render the (un-held) keys. This changes slowly, so we only attach it every
	# META_EVERY-th snapshot (~6Hz); positions still go out at the full 30Hz. Saves the
	# fractional-CPU free server most of its per-tick Dictionary-encoding cost. The
	# client keeps its previous values on the snapshots that omit it.
	var meta := {}
	_snap_tick += 1
	if _snap_tick % META_EVERY == 1:
		var kp := {}
		for el in keys:
			if not bool(has_key_by_el.get(el, false)):
				kp[el] = [keys[el]["pos"].x, keys[el]["pos"].z]
		var rt := {}
		for el in ["fire", "water", "grass"]:
			rt[el] = twin_by_el.get(el) != null
		meta = {
			"tl": time_left,
			"sc": { "fire": _team_score("fire"), "water": _team_score("water"), "grass": _team_score("grass") },
			"rk": has_key_by_el.duplicate(),   # el -> bool (key held)
			"rt": rt,                          # el -> bool (twin freed)
			"kp": kp,                          # el -> [x,z] (un-held key positions)
		}
	if net:
		net.broadcast_snapshot(data, meta)

func _team_score(el: String) -> int:
	var s := 0
	for c in by_el.get(el, []):
		s += c.score
	return s

# ---- server-authoritative rescue (shared per element) ----
# One key / one caged twin per element team. Any human of element E can grab E's
# key, free E's twin at E's cage, and escort it home to win for the whole team.
func _server_rescue(dt: float) -> void:
	for el in ["fire", "water", "grass"]:
		var grp: Array = by_el.get(el, [])
		# pick up the team key
		if not bool(has_key_by_el.get(el, false)) and keys.has(el):
			var kp: Vector3 = keys[el]["pos"]
			for h in grp:
				if h.is_human and h.alive and h.pos.distance_to(kp) < KEY_PICK_DIST:
					has_key_by_el[el] = true
					break
		# free the caged twin once a teammate carrying the key reaches the cage
		if bool(has_key_by_el.get(el, false)) and twin_by_el.get(el) == null and cage_by_el.has(el):
			var cg: Dictionary = cage_by_el[el]
			var cgp := Vector3(cg["x"], 0, cg["z"])
			for h in grp:
				if h.is_human and h.alive and h.pos.distance_to(cgp) < CAGE_RELEASE_DIST:
					_server_release_twin(el)
					break
		# escort: the twin trails the nearest teammate; reaching home wins the round
		var twin: GameChar = twin_by_el.get(el)
		if twin != null and twin.alive:
			var lead := _nearest_human_of(el, twin.pos)
			if lead != null:
				var d := twin.pos.distance_to(lead.pos)
				if d <= TWIN_LEASH and d > 2.6:
					var dir := lead.pos - twin.pos
					dir.y = 0
					twin.vel = twin.vel.lerp(dir.normalized() * twin.speed * 1.05, 1.0 - pow(0.0006, dt))
					twin.pos += twin.vel * dt
					resolve_collisions(twin)
				else:
					twin.vel = twin.vel.lerp(Vector3.ZERO, 1.0 - pow(0.0006, dt))
			if cave_by_owner.has(el):
				var hc: Dictionary = cave_by_owner[el]
				if twin.pos.distance_to(Vector3(hc["x"], 0, hc["z"])) < RESCUE_WIN_DIST:
					_server_end_match("rescued", el)
					return

func _server_release_twin(el: String) -> void:
	var t := make_character("element", el)   # group null on server
	t.is_twin = true
	t.max_hp = 1
	t.hp = 1
	var cg: Dictionary = cage_by_el[el]
	t.pos = Vector3(cg["x"], 0, cg["z"])
	twin_by_el[el] = t

func _nearest_human_of(el: String, from: Vector3) -> GameChar:
	var best: GameChar = null
	var bd := 1.0e20
	for h in by_el.get(el, []):
		if h.is_human and h.alive:
			var d: float = from.distance_to(h.pos)
			if d < bd:
				bd = d; best = h
	return best

func _server_end_match(reason: String, winner_el: String) -> void:
	if ending:
		return
	ending = true
	running = false
	won = true
	var standings: Array = []
	for el in ["fire", "water", "grass"]:
		standings.append({ "el": el, "score": _team_score(el), "winner": el == winner_el })
	if net:
		net.broadcast_end(reason, winner_el, standings)
	# the host doesn't receive its own broadcast — show it the end screen directly,
	# keeping its actors on screen (like single-player).
	if mode == Mode.HOST:
		_show_end_screen(reason, winner_el, standings.duplicate(true))
	print("[host] match ended: %s team wins (%s)" % [winner_el, reason])

# Networked viewer tick: predict the local avatar from input, draw every other
# actor as an interpolated ghost, follow with the camera. No local simulation.
func _client_process(delta: float) -> void:
	if camera == null:
		return   # headless test client / pre-visual: nothing to draw
	var dt: float = minf(0.05, delta)
	time_ms += delta * 1000.0
	var cd := _cosmetic_step(delta)
	if cd >= 0.0:
		for fn in deco_anims:
			fn.call(time_ms)
	if local_net_id == 0 or player == null or not running:
		_update_camera(dt)   # lobby/countdown backdrop; no prediction until GO
		return
	_client_predict_local(dt)
	_client_render_remote(dt)
	if cd >= 0.0:
		_update_wind_leaves(minf(0.08, cd), time_ms)
	_update_camera(dt)
	_client_update_hud()
	if net_log:
		_nl_guest_tick(dt)

func _client_predict_local(dt: float) -> void:
	var mx := 0.0
	var mz := 0.0
	if Input.is_physical_key_pressed(KEY_W) or Input.is_physical_key_pressed(KEY_UP): mz += 1.0
	if Input.is_physical_key_pressed(KEY_S) or Input.is_physical_key_pressed(KEY_DOWN): mz -= 1.0
	if Input.is_physical_key_pressed(KEY_D) or Input.is_physical_key_pressed(KEY_RIGHT): mx += 1.0
	if Input.is_physical_key_pressed(KEY_A) or Input.is_physical_key_pressed(KEY_LEFT): mx -= 1.0
	mx += touch_move.x
	mz += touch_move.y
	var ln := minf(1.0, sqrt(mx * mx + mz * mz))
	var sprint := (Input.is_key_pressed(KEY_SHIFT) or touch_sprint) and ln > 0.05 and stamina > 1.0
	if sprint:
		stamina = maxf(0.0, stamina - dt * 30.0)
	else:
		stamina = minf(100.0, stamina + dt * 13.0)
	ui.set_stamina(stamina)
	var seq := net.send_input(mx, mz, sprint, cam_yaw)   # authoritative movement happens on the server
	# local prediction so it feels instant
	_apply_human_move(player, mx, mz, sprint, cam_yaw, dt)
	_pred_hist.append({ "seq": seq, "pos": player.pos, "vel": player.vel, "mx": mx, "mz": mz, "sprint": sprint, "yaw": cam_yaw, "dt": dt, "t": _now() })
	while _pred_hist.size() > PRED_HIST_MAX:
		_pred_hist.pop_front()
	# Ease the last correction away (see _render_off); steady walking keeps it ~0 (no lag).
	_render_off = _render_off.lerp(Vector3.ZERO, clampf(dt / REND_SMOOTH, 0.0, 1.0))
	if player.group:
		player.group.position = _client_render_pos()
		if player.vel.length_squared() > 0.5:
			player.group.rotation.y = lerp_angle(player.group.rotation.y, atan2(player.vel.x, player.vel.z), 1.0 - pow(0.001, dt))
		player.group.animate(time_ms, player.vel.length())

func _client_reconcile_local(server_pos: Vector3, server_yaw: float, server_spd: float, server_flags: int, server_hp: int, ack_seq: int) -> void:
	if player == null:
		return
	player.hp = server_hp
	player.slow_timer = SLOW_TIME if (server_flags & (1 << 6)) != 0 else 0.0
	var server_vel := Vector3.ZERO
	if server_spd > 0.04:
		server_vel = Vector3(sin(server_yaw), 0, cos(server_yaw)) * server_spd
	if ack_seq <= 0 or _pred_hist.is_empty():
		_client_authority_fallback(server_pos, server_vel)
		return
	var ack_idx := -1
	for i in _pred_hist.size():
		if int((_pred_hist[i] as Dictionary).get("seq", 0)) == ack_seq:
			ack_idx = i
	if ack_idx < 0:
		_client_authority_fallback(server_pos, server_vel)
		return
	var ack_frame: Dictionary = _pred_hist[ack_idx]
	var predicted_pos: Vector3 = ack_frame.get("pos", player.pos)
	var error := server_pos - predicted_pos
	if net_log:
		var em := error.length()
		_nl_skew = lerpf(_nl_skew, em, 0.1)
		_nl_skew_max = maxf(_nl_skew_max, em)
		_nl_rtt = lerpf(_nl_rtt, (_now() - float(ack_frame.get("t", _now()))) * 1000.0, 0.1)
		if em > RECONCILE_EPS:
			_nl_snaps += 1
	if error.length() <= RECONCILE_EPS:
		var pending_small: Array = []
		for j in range(ack_idx + 1, _pred_hist.size()):
			pending_small.append(_pred_hist[j])
		_pred_hist = pending_small
		return
	# Re-anchor the SIM to the host, but keep the DRAWN position continuous: stash where we
	# were drawing, snap the sim + replay pending inputs, then make _render_off the leftover
	# so mesh/camera ease over instead of jolting. A big correction (respawn) just snaps.
	var vis_before := _client_render_pos()
	player.pos = server_pos
	player.vel = server_vel
	var pending: Array = []
	for j in range(ack_idx + 1, _pred_hist.size()):
		var st: Dictionary = _pred_hist[j]
		_apply_human_move(player, float(st.get("mx", 0.0)), float(st.get("mz", 0.0)), bool(st.get("sprint", false)), float(st.get("yaw", 0.0)), float(st.get("dt", 0.0)))
		st["pos"] = player.pos
		st["vel"] = player.vel
		pending.append(st)
	_pred_hist = pending
	if error.length() > REND_SNAP_DIST:
		_render_off = Vector3.ZERO                       # teleport/respawn — let it snap
	else:
		_render_off = vis_before - player.pos
		if _render_off.length() > REND_OFF_MAX:
			_render_off = _render_off.normalized() * REND_OFF_MAX
	if player.group:
		player.group.position = _client_render_pos()
		if player.vel.length_squared() > 0.5:
			player.group.rotation.y = atan2(player.vel.x, player.vel.z)

func _client_authority_fallback(server_pos: Vector3, server_vel: Vector3) -> void:
	if player == null:
		return
	if player.pos.distance_to(server_pos) <= LOCAL_TRUST_SNAP_DIST:
		return
	player.pos = server_pos
	player.vel = server_vel
	_render_off = Vector3.ZERO     # emergency snap (lost history) — no easing
	_pred_hist.clear()
	if player.group:
		player.group.position = player.pos
		if player.vel.length_squared() > 0.5:
			player.group.rotation.y = atan2(player.vel.x, player.vel.z)

# CLIENT: render each known remote actor from its own keyframe buffer. Interpolate when
# two host-clock keyframes bracket render time; briefly extrapolate from the newest
# sample during a transport stall. A ghost is removed only when its stream goes stale.
func _client_render_remote(dt: float) -> void:
	var host_now := _est_host_time()
	var render_t := host_now - INTERP_DELAY
	for nid in _net_actors.keys():
		if nid == local_net_id:
			continue
		var a = _net_actors[nid]
		if host_now - float(a["last_t"]) > GHOST_STALE:
			if ghosts.has(nid) and is_instance_valid(ghosts[nid]):
				ghosts[nid].queue_free()
			ghosts.erase(nid)
			_net_actors.erase(nid)
			continue
		var buf: Array = a["buf"]
		if buf.is_empty():
			continue
		if net_log:
			_nl_render_frames += 1
			_nl_buf_sum += buf.size()
		var pos: Vector3
		var yaw: float
		var spd: float
		var newest: Dictionary = buf[buf.size() - 1]
		if render_t >= float(newest["t"]):
			var age: float = minf(render_t - float(newest["t"]), EXTRAP_MAX)
			if net_log:
				_nl_extrap_frames += 1
				if render_t - float(newest["t"]) >= EXTRAP_MAX:
					_nl_underruns += 1
			yaw = float(newest["yaw"])
			spd = float(newest["spd"])
			pos = (newest["pos"] as Vector3) + Vector3(sin(yaw), 0, cos(yaw)) * spd * age
		else:
			var k0: Dictionary = buf[0]
			var k1: Dictionary = buf[0]
			for k in buf:
				if float(k["t"]) <= render_t:
					k0 = k
				else:
					k1 = k
					break
			var span: float = float(k1["t"]) - float(k0["t"])
			var alpha: float = clampf((render_t - float(k0["t"])) / span, 0.0, 1.0) if span > 0.0001 else 0.0
			pos = (k0["pos"] as Vector3).lerp(k1["pos"], alpha)
			yaw = lerp_angle(float(k0["yaw"]), float(k1["yaw"]), alpha)
			spd = lerpf(float(k0["spd"]), float(k1["spd"]), alpha)
		if net_log and player:
			_nl_seen_min = minf(_nl_seen_min, _client_render_pos().distance_to(pos))
		var g := _client_get_ghost(nid, int(a["flags"]))
		g.visible = (int(a["flags"]) & (1 << 4)) != 0
		g.position = pos
		if spd > 0.5:
			g.rotation.y = lerp_angle(g.rotation.y, yaw, 1.0 - pow(0.001, dt))
		g.animate(time_ms, spd)

func _client_update_hud() -> void:
	ui.set_hearts(player.hp, maxi(BASE_HP, player.hp))
	if bool(_net_rt.get(local_el, false)):
		ui.set_objective("Escort your twin home to your cave!")
	elif bool(_net_rk.get(local_el, false)):
		ui.set_objective("Free your twin at the zoo cage")
	else:
		ui.set_objective("Find your %s key" % ELEMENTS[local_el]["label"])
	var entries: Array = []
	for el in ["fire", "water", "grass"]:
		entries.append({ "el": el, "label": ELEMENTS[el]["label"], "score": _scores[el], "alive": true, "me": el == local_el })
	ui.set_board(entries)

# ---- QA telemetry reporting (no-op unless net_log) -------------------------------------
# GUEST: once a second, summarise own-avatar smoothness + ghost health and ship it to the
# host (and print locally). `skew` is the headline number: how far the host's authoritative
# position of me sits from where I predicted myself — i.e. how forgiving the catch must be.
func _nl_guest_tick(dt: float) -> void:
	_nl_accum += dt
	if _nl_accum < 1.0:
		return
	_nl_accum = 0.0
	var rf: int = maxi(1, _nl_render_frames)
	var ex := 100.0 * float(_nl_extrap_frames) / float(rf)
	var buf := _nl_buf_sum / float(rf)
	var seen := _nl_seen_min if _nl_seen_min < 1.0e8 else -1.0
	print("[netlog g#%d] skew %.2f/%.2f u  rtt %dms  extrap %.0f%%  underrun %d  buf %.1f  snaps %d  seen-min %.2f  snap %d±%dms" % [
		local_net_id, _nl_skew, _nl_skew_max, int(_nl_rtt), ex, _nl_underruns, buf, _nl_snaps, seen, int(_nl_snap_ms), int(_nl_snap_jit)])
	if net:
		net.send_dbg({
			"skew": snappedf(_nl_skew, 0.01), "smax": snappedf(_nl_skew_max, 0.01),
			"rtt": int(_nl_rtt), "ex": snappedf(ex, 0.1), "ur": _nl_underruns,
			"buf": snappedf(buf, 0.1), "seen": snappedf(seen, 0.01), "snaps": _nl_snaps,
			"sdt": int(_nl_snap_ms), "sjit": int(_nl_snap_jit),
		})
	_nl_skew_max = 0.0; _nl_snaps = 0; _nl_render_frames = 0; _nl_extrap_frames = 0
	_nl_underruns = 0; _nl_buf_sum = 0.0; _nl_seen_min = 1.0e9

# HOST: track how close the host avatar authoritatively got to each guest (the truth that
# the forgiving catch radius is measured against), and a slow alive-heartbeat.
func _nl_host_tick(dt: float) -> void:
	if player != null:
		for ch in actors:
			if not _is_remote_human(ch) or not ch.alive:
				continue
			var d: float = player.pos.distance_to(ch.pos)
			var cur := float(_nl_host_auth.get(ch.net_id, -1.0))
			if cur < 0.0 or d < cur:
				_nl_host_auth[ch.net_id] = d
	_nl_accum += dt
	if _nl_accum >= 5.0:
		_nl_accum = 0.0
		print("[netlog] host alive — actors=%d snap=%.0fHz (waiting for guest reports…)" % [actors.size(), SNAP_HZ])

# HOST: a guest's per-second report arrived (relayed). Print one unified line, annotated
# with the host's own authoritative closest-approach so the visual-vs-real gap is visible.
func host_on_dbg(from: int, m: Dictionary) -> void:
	var nid := 0
	if peer_actor.has(from):
		nid = peer_actor[from].net_id
	var auth := float(_nl_host_auth.get(nid, -1.0))
	var auth_s := ("%.2f" % auth) if auth >= 0.0 else "n/a"
	print("[netlog] guest#%d  skew %.2f/%.2f u  rtt %dms  extrap %s%%  underrun %s  buf %s  snaps %s  seen-min %s u | host-auth-min %s u  snap %s±%sms" % [
		from, float(m.get("skew", 0.0)), float(m.get("smax", 0.0)), int(m.get("rtt", 0)),
		str(m.get("ex", 0)), str(m.get("ur", 0)), str(m.get("buf", 0)), str(m.get("snaps", 0)),
		str(m.get("seen", 0)), auth_s, str(m.get("sdt", 0)), str(m.get("sjit", 0))])
	_nl_host_auth[nid] = -1.0   # fresh window for the next second

# CLIENT: build/position/hide the team keys from snapshot meta (kp = un-held keys).
func _client_sync_keys(kp: Dictionary) -> void:
	for el in ["fire", "water", "grass"]:
		var present: bool = kp.has(el)
		if present and not key_nodes.has(el):
			var node := _make_key_node(el)
			add_child(node)
			key_nodes[el] = node
		if key_nodes.has(el):
			var node: Node3D = key_nodes[el]
			if present:
				node.position = Vector3(kp[el][0], 1.0, kp[el][1])
				node.visible = true
			else:
				node.visible = false   # picked up → hide

# GUEST: the host told us the round is over. Tear down the networked view, then show
# the end screen.
func _on_match_ended(reason: String, winner_el: String, standings: Array) -> void:
	_client_clear()
	_show_end_screen(reason, winner_el, standings)

# Shared end screen (guest + host). Reads local_el for the "me"/"your team" wording.
func _show_end_screen(reason: String, winner_el: String, standings: Array) -> void:
	standings.sort_custom(func(a, b): return a["score"] > b["score"])
	var out: Array = []
	for i in standings.size():
		var s: Dictionary = standings[i]
		out.append({
			"label": ELEMENTS[s["el"]]["label"], "color": MeshLib.rgb(GameUI.UI_COLORS[s["el"]]),
			"score": s["score"], "me": s["el"] == local_el, "alive": true, "winner": bool(s.get("winner", false)),
		})
	var title := "Round over"
	var sub := "Final standings above."
	if reason == "rescued":
		if winner_el == local_el:
			title = "Your team freed %s!  🎉" % ELEMENTS[winner_el]["label"]
			sub = "You brought your twin safely home. Rescue complete!"
		else:
			title = "%s team wins!" % ELEMENTS[winner_el]["label"]
			sub = "%s completed their rescue first." % ELEMENTS[winner_el]["label"]
	ui.show_end(out, title, sub)

# Dev/test hook (no GUI): connect to a local server and exercise the full lobby
# handshake — create → pick element → start — logging each step, then quit.
#   godot --headless --path . -- testclient            (create a room)
#   godot --headless --path . -- testclient join ABCD  (join room ABCD)
func _ready_testclient() -> void:
	mode = Mode.CLIENT
	Engine.max_fps = 60
	_start_net()
	var args := OS.get_cmdline_user_args()
	var action := "join" if args.has("join") else "create"
	var label := "B-join" if action == "join" else "A-host"
	var my_el := "fire" if action == "join" else "water"
	var code := "TEST"   # fixed code so two separate processes meet in the same room
	get_tree().create_timer(22.0).timeout.connect(func() -> void:
		print("[%s] timeout — quitting" % label); get_tree().quit())
	# host moves +z, joiner moves +x → distinct paths so each clearly sees the other move
	var st := { "picked": false, "started": false, "other": 0, "mx": (1.0 if action == "join" else 0.0), "mz": (0.0 if action == "join" else 1.0) }
	net.joined_room.connect(func(c: String) -> void: print("[%s] joined room %s" % [label, c]))
	net.join_failed.connect(func(r: String) -> void: print("[%s] JOIN FAILED: %s" % [label, r]); get_tree().quit())
	net.connection_lost.connect(func() -> void: print("[%s] connection lost" % label); get_tree().quit())
	net.lobby_changed.connect(func(players: Array, _my_id: int, _admin_id: int, _c: String) -> void:
		if not st["picked"]:
			st["picked"] = true
			net.choose_element(my_el)
		if action == "create" and not st["started"] and players.size() >= 2:
			st["started"] = true
			print("[%s] 2 players in lobby — starting match" % label)
			net.start_match())
	net.match_starting.connect(func(_s: int, _h: Array, ids: Dictionary) -> void:
		var mine := net.my_id
		local_net_id = int(ids.get(str(mine), ids.get(mine, 0)))
		for pid in ids:
			if int(pid) != mine:
				st["other"] = int(ids[pid])
		print("[%s] MATCH STARTING my_net_id=%d other_net_id=%d" % [label, local_net_id, st["other"]])
		var tk := Timer.new(); tk.wait_time = 0.6; tk.autostart = true; add_child(tk)
		tk.timeout.connect(func() -> void:
			net.send_input(st["mx"], st["mz"], false, 0.0)
			if _net_actors.is_empty(): return
			var me_a = _net_actors.get(local_net_id, null)
			var ot_a = _net_actors.get(st["other"], null)
			var mp: Vector3 = (me_a["buf"][me_a["buf"].size() - 1]["pos"]) if me_a and not me_a["buf"].is_empty() else Vector3.ZERO
			var op: Vector3 = (ot_a["buf"][ot_a["buf"].size() - 1]["pos"]) if ot_a and not ot_a["buf"].is_empty() else Vector3.ZERO
			print("[%s] me=(%.1f,%.1f) OTHER#%d=(%.1f,%.1f) tracked=%d" % [label,
				mp.x, mp.z, st["other"], op.x, op.z, _net_actors.size()])))
	var tport := NetManager.DEFAULT_PORT
	if OS.has_environment("TEST_PORT"):
		tport = int(OS.get_environment("TEST_PORT"))
	var turl := "ws://127.0.0.1:%d" % tport
	if OS.has_environment("TEST_URL"):
		turl = OS.get_environment("TEST_URL")
	print("[%s] connecting (%s, code=%s, el=%s) url=%s…" % [label, action, code, my_el, turl])
	net.connect_to(turl, label, action, code)

# Turn on QA telemetry from a flag: ?netlog=1 (web), or NET_LOG / `-- nettest` (native).
# Off by default → production play prints nothing and sends no dbg messages.
func _read_net_log_flag() -> void:
	if OS.get_cmdline_user_args().has("nettest") or OS.has_environment("NET_LOG"):
		net_log = true
		return
	if OS.has_feature("web"):
		var v: Variant = JavaScriptBridge.eval("(new URLSearchParams(location.search)).get('netlog')", true)
		if v != null and str(v) == "1":
			net_log = true

# Dev/QA hook: a REAL authoritative host + guest, headless, over a local relay (drive two
# processes — see scripts/nettest.ps1). Unlike `testclient` (lobby smoke-test, both CLIENT),
# the host here is mode=HOST → _host_process simulates + broadcasts, and the guest is
# mode=CLIENT → predict/reconcile/interp. Movement is injected through touch_move/cam_yaw
# (the same fields real avatars read); telemetry streams to the host terminal.
#   godot --headless --path . -- nettest         (the host/authority, element water)
#   godot --headless --path . -- nettest join    (a guest, element fire — water's prey)
func _ready_nettest() -> void:
	var args := OS.get_cmdline_user_args()
	var is_host := not args.has("join")
	net_log = true
	mode = Mode.HOST if is_host else Mode.CLIENT
	Engine.max_fps = 60                 # don't free-run headless at 1000s of fps
	var label := "HOST" if is_host else "GUEST"
	var my_el := "water" if is_host else "fire"   # water preys fire → catches actually fire
	_ready_visual()                     # build world/camera/ui/net + wire online signals
	var run_s := 24.0
	if OS.has_environment("NETTEST_SECS"):
		run_s = float(OS.get_environment("NETTEST_SECS"))
	get_tree().create_timer(run_s).timeout.connect(func() -> void:
		print("[%s] done after %.0fs — quitting" % [label, run_s]); get_tree().quit())
	net.join_failed.connect(func(r: String) -> void:
		print("[%s] JOIN FAILED: %s" % [label, r]); get_tree().quit())
	net.connection_lost.connect(func() -> void:
		print("[%s] connection lost — quitting" % label); get_tree().quit())
	net.lobby_changed.connect(func(players: Array, _mi: int, _ai: int, _c: String) -> void:
		if not _nt_picked:
			_nt_picked = true
			net.choose_element(my_el)
		if is_host and not _nt_started and players.size() >= 2:
			_nt_started = true
			print("[HOST] 2 players in lobby — starting match")
			net.start_match())
	net.match_starting.connect(func(_s: int, _h: Array, _ids: Dictionary) -> void:
		print("[GUEST] match starting (my_net_id=%d)" % local_net_id))
	var drive := Timer.new()
	drive.wait_time = 1.0 / 30.0
	drive.autostart = true
	add_child(drive)
	drive.timeout.connect(_nt_drive.bind(is_host))
	var port := NetManager.DEFAULT_PORT
	if OS.has_environment("TEST_PORT"):
		port = int(OS.get_environment("TEST_PORT"))
	var url := "ws://127.0.0.1:%d" % port
	print("[%s] connecting el=%s url=%s …" % [label, my_el, url])
	net.connect_to(url, label, ("create" if is_host else "join"), "TEST")

# Inject scripted movement each tick (30Hz). GUEST walks a continuous circle (forward + slow
# turn) so prediction/interp run hard; HOST idles briefly (measure pure skew), then chases
# the guest so catches fire and we see the visual-vs-authoritative closing distance.
func _nt_drive(is_host: bool) -> void:
	if not running:
		return
	_nt_run_t += 1.0 / 30.0
	if is_host:
		var tgt: GameChar = null
		for ch in actors:
			if _is_remote_human(ch) and ch.alive:
				tgt = ch
				break
		if _nt_run_t > 6.0 and tgt != null and player != null:
			var to := tgt.pos - player.pos
			cam_yaw = atan2(-to.x, -to.z)     # face the target (fwd = (-sin,-cos) in _apply_human_move)
			touch_move = Vector2(0, 1)
		else:
			touch_move = Vector2.ZERO
	else:
		cam_yaw = _nt_run_t * 1.0             # slow turn → walk a circle
		touch_move = Vector2(0, 1)
		touch_sprint = OS.has_environment("NETTEST_SPRINT")   # stress the worst-case gap

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
