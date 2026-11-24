class_name SkyBuilder
extends Object
# Builds the SKYFALL ISLES world. The whole static world — every isle, bridge,
# the Sky Spire with its ramps, pads, gate and bell, the sky stream, the vine
# and the vents — is AUTHORED IN BLENDER (tools/blender/*.py) and arrives as one
# file, models/sky/skyfall_world.glb, which this builder simply loads at the
# origin. Godot only adds what a modelling tool cannot: the collision data
# (read from the col_* helper nodes), the cloud-sea / smog shaders, the
# golden-hour lighting, and the SkyView that animates named nodes.
# If the GLB is missing the builder falls back to MeshLib primitives placed from
# SkyLayout, so the game still runs while assets are in progress.

const DIR := "res://models/sky/"

static var _root: Node3D
static var _game
static var _saved_env: Dictionary = {}
static var _scene_cache: Dictionary = {}
static var _paint_mat: StandardMaterial3D
static var _glow_mat: StandardMaterial3D
static var _water_mat: ShaderMaterial

# ------------------------------------------------------------------ entry
static func build(game) -> void:
	SkyLayout.ensure()
	_game = game
	_root = game.world_root
	apply_environment(game)
	var view := SkyView.new()
	view.name = "SkyView"
	view.game = game
	_root.add_child(view)
	_cloud_sea(view)
	var world := instance("skyfall_world")
	if world != null:
		world.name = "SkyfallWorld"
		_root.add_child(world)
		_adopt(world, view)
	else:
		_build_fallback(view)
	_register_sanctums()
	# cages + task stones: placed clear of the Blender props, then made solid
	SkyQuests.place(game.obstacles)
	for cp in SkyQuests.CAGE_SPOTS:
		game.obstacles.append({ "x": cp.x, "z": cp.z, "r": SkyQuests.CAGE_R })
	for k in range(1, SkyQuests.TASK_TIERS + 1):
		var sp := SkyQuests.stone_pos(k)
		game.obstacles.append({ "x": sp.x, "z": sp.y, "r": SkyQuests.STONE_R })
	view.setup()
	game.sky_view = view

# ------------------------------------------------------------------ GLB helpers
static func has_asset(name: String) -> bool:
	return ResourceLoader.exists(DIR + name + ".glb")

# A fresh instance of a Blender-made asset (null when the GLB is missing).
static func instance(name: String) -> Node3D:
	if not _scene_cache.has(name):
		_scene_cache[name] = load(DIR + name + ".glb") if has_asset(name) else null
	var ps = _scene_cache[name]
	if ps == null:
		return null
	var n := (ps as PackedScene).instantiate() as Node3D
	if n != null:
		apply_materials(n)
	return n

# One lit vertex-colour material + one glowing one for every sky asset (the GLBs
# carry only two materials, sky_paint and sky_glow, and all colour is painted
# per-vertex in Blender).
static func paint_mat() -> StandardMaterial3D:
	if _paint_mat == null:
		var m := StandardMaterial3D.new()
		m.vertex_color_use_as_albedo = true
		m.vertex_color_is_srgb = false
		m.roughness = 1.0
		m.metallic_specular = 0.0
		_paint_mat = m
	return _paint_mat

static func glow_mat() -> StandardMaterial3D:
	if _glow_mat == null:
		var m := StandardMaterial3D.new()
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.vertex_color_use_as_albedo = true
		m.vertex_color_is_srgb = false
		m.albedo_color = Color(1.25, 1.2, 1.1)
		_glow_mat = m
	return _glow_mat

static func tinted_glow(c: Color, alpha: float = 1.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.vertex_color_use_as_albedo = true
	m.albedo_color = Color(c.r, c.g, c.b, alpha)
	if alpha < 1.0:
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	return m

static func apply_materials(n: Node) -> void:
	if n is MeshInstance3D:
		var mi := n as MeshInstance3D
		if mi.mesh != null:
			for s in mi.mesh.get_surface_count():
				var src := mi.mesh.surface_get_material(s)
				var nm := String(src.resource_name).to_lower() if src != null else ""
				mi.set_surface_override_material(s, glow_mat() if nm.contains("glow") else paint_mat())
	for c in n.get_children():
		apply_materials(c)

static func set_override(n: Node, mat: Material) -> void:
	if n is MeshInstance3D:
		var mi := n as MeshInstance3D
		if mi.mesh != null:
			for s in mi.mesh.get_surface_count():
				mi.set_surface_override_material(s, mat)
	for c in n.get_children():
		set_override(c, mat)

# scrolling water for the sky stream, the atoll waterfall and the up-flowing lifts
const WATER_SHADER := """
shader_type spatial;
render_mode unshaded, cull_disabled, blend_mix;
uniform float speed = 0.6;
uniform vec3 deep : source_color = vec3(0.34, 0.56, 0.92);
uniform vec3 foam : source_color = vec3(0.86, 0.94, 1.0);
void fragment() {
	float v = UV.y * 3.0 - TIME * speed;
	float w = sin((UV.x * 5.0 + sin(v * 2.1) * 0.35) * 6.2831);
	float streak = smoothstep(0.55, 1.0, sin(v * 6.2831 + w * 0.9) * 0.5 + 0.5);
	float edge = smoothstep(0.38, 0.5, abs(UV.x - 0.5));
	ALBEDO = mix(deep, foam, clamp(streak * 0.55 + edge * 0.6, 0.0, 1.0));
	ALPHA = 0.86;
}
"""

static func water_mat(speed: float = 0.6) -> ShaderMaterial:
	var sh := Shader.new()
	sh.code = WATER_SHADER
	var m := ShaderMaterial.new()
	m.shader = sh
	m.set_shader_parameter("speed", speed)
	return m

# ------------------------------------------------------------------ the Blender world
static func _adopt(world: Node3D, view) -> void:
	# name -> node for everything the game animates or reads
	var all: Array = []
	_collect(world, all)
	for n in all:
		var nm := String(n.name)
		var low := nm.to_lower()
		if low.begins_with("col_"):
			if not low.begins_with("col_tier"):
				_register_col(n)
			(n as Node3D).visible = false
			continue
		view.named[nm] = n
		if low.begins_with("waterfall"):
			set_override(n, water_mat(1.1))
		elif low.begins_with("flow"):
			set_override(n, water_mat(-1.4))      # the lifts flow UP
	# the stream ribbon scrolls toward Heart Isle
	var rs := world.find_child("route_stream", true, false)
	if rs != null:
		set_override(rs, water_mat(0.9))
	for group in ["bridges", "route_stream", "route_vine"]:
		var gn := world.find_child(group, true, false)
		if gn != null:
			_batch(gn)
	# the per-tier collision is analytic (SkyLayout); everything else walkable is data too

static func _collect(n: Node, out: Array) -> void:
	for c in n.get_children():
		out.append(c)
		_collect(c, out)

# A col_* helper → one blocking circle (centre + radius from its world AABB).
static func _register_col(n: Node) -> void:
	var mi := n as MeshInstance3D
	if mi == null or mi.mesh == null:
		return
	var aabb: AABB = mi.global_transform * mi.mesh.get_aabb()
	var c := aabb.get_center()
	var r := maxf(aabb.size.x, aabb.size.z) * 0.5
	_game.obstacles.append({ "x": c.x, "z": c.z, "r": r })

# Collapse the hundreds of repeated segment nodes (same mesh, same materials) into
# one MultiMesh per mesh — bridges alone are ~270 identical plank segments.
static func _batch(parent: Node) -> void:
	var groups := {}
	var kids: Array = []
	_collect(parent, kids)
	for k in kids:
		var mi := k as MeshInstance3D
		if mi == null or mi.mesh == null or mi.get_child_count() > 0:
			continue
		var key := mi.mesh.get_instance_id()
		if not groups.has(key):
			groups[key] = []
		(groups[key] as Array).append(mi)
	for key in groups:
		var list: Array = groups[key]
		if list.size() < 4:
			continue
		var first: MeshInstance3D = list[0]
		var mesh := first.mesh
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = mesh
		mm.instance_count = list.size()
		for i in list.size():
			mm.set_instance_transform(i, (list[i] as MeshInstance3D).global_transform)
		# multimesh instances can't carry per-surface overrides → bake them into a mesh copy
		var m2 := mesh.duplicate() as Mesh
		for s in m2.get_surface_count():
			var ov := first.get_surface_override_material(s)
			if ov != null:
				m2.surface_set_material(s, ov)
		mm.mesh = m2
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		mmi.name = String(parent.name) + "_batch"
		_root.add_child(mmi)
		for mi in list:
			(mi as Node).queue_free()

static func _register_sanctums() -> void:
	for el in ["fire", "water", "grass"]:
		var h: Dictionary = SkyLayout.NODES["h_" + el]
		var col: Color = MeshLib.rgb(_game.ELEMENTS[el]["color"])
		var cave := {
			"x": h["x"], "z": h["z"], "r": SkyLayout.SANCTUM_R, "owner": el,
			"openAngle": deg_to_rad(float(SkyLayout.HOME_ANG[el]) + 180.0), "radarFill": col,
		}
		_game.caves.append(cave)
		_game.cave_by_owner[el] = cave
		# the safe zone reads as a soft glowing disc + a tall light pillar, like the keeps
		var glow := MeshLib.disc(SkyLayout.SANCTUM_R, MeshLib.unlit_mat(col, 0.07), 28)
		glow.position = Vector3(h["x"], 0.06, h["z"])
		_root.add_child(glow)
		var bm := CylinderMesh.new()
		bm.top_radius = 0.3; bm.bottom_radius = 0.3; bm.height = 70.0
		bm.radial_segments = 8; bm.cap_top = false; bm.cap_bottom = false
		var beam_mat := MeshLib.unlit_mat(col, 0.16)
		beam_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		var beam := MeshLib.mi(bm, beam_mat)
		beam.position = Vector3(h["x"], 35.0, h["z"])
		_root.add_child(beam)

# ------------------------------------------------------------------ sky, light, clouds
const SKY_SHADER := """
shader_type sky;
uniform float eclipse = 0.0;
void sky() {
	vec3 d = normalize(EYEDIR);
	float t = clamp((1.0 - d.y) * 0.5, 0.0, 1.0);
	// golden hour: deep teal-blue zenith -> soft lilac -> peach -> molten gold at the horizon
	vec3 col = vec3(0.20, 0.36, 0.66);
	col = mix(col, vec3(0.36, 0.50, 0.78), smoothstep(0.00, 0.22, t));
	col = mix(col, vec3(0.66, 0.62, 0.80), smoothstep(0.22, 0.38, t));
	col = mix(col, vec3(0.96, 0.72, 0.62), smoothstep(0.38, 0.47, t));
	col = mix(col, vec3(1.00, 0.80, 0.50), smoothstep(0.46, 0.52, t));
	col = mix(col, vec3(1.00, 0.88, 0.70), smoothstep(0.52, 0.62, t));
	col = mix(col, vec3(0.98, 0.90, 0.84), smoothstep(0.62, 1.00, t));
	vec3 sd = normalize(vec3(-0.80, 0.20, 0.34));
	float ds = distance(d, sd);
	float glow = smoothstep(0.75, 0.0, ds);
	col += vec3(1.0, 0.72, 0.36) * glow * glow * 0.55 * (1.0 - eclipse);
	float disc = smoothstep(0.075, 0.062, ds);
	col = mix(col, vec3(1.0, 0.97, 0.86), disc * (1.0 - eclipse));
	// the eclipse: violet dusk, a black disc with a thin corona
	vec3 ecl = col * vec3(0.42, 0.30, 0.62) + vec3(0.07, 0.03, 0.14);
	ecl += vec3(0.80, 0.62, 1.0) * smoothstep(0.16, 0.07, ds) * 0.75;
	ecl = mix(ecl, vec3(0.03, 0.01, 0.06), smoothstep(0.072, 0.064, ds));
	COLOR = mix(col, ecl, eclipse);
}
"""

static func apply_environment(game) -> void:
	var we: WorldEnvironment = game.world_env
	if we == null or we.environment == null:
		return
	var env: Environment = we.environment
	if _saved_env.is_empty():
		_saved_env = {
			"sky_mat": env.sky.sky_material, "amb": env.ambient_light_color, "amb_e": env.ambient_light_energy,
			"fog": env.fog_light_color,
			"sun_c": game.sun_light.light_color if game.sun_light else Color.WHITE,
			"sun_e": game.sun_light.light_energy if game.sun_light else 1.0,
			"sun_x": game.sun_light.global_transform if game.sun_light else Transform3D(),
			"far": game.camera.far if game.camera else 900.0,
		}
	var sh := Shader.new()
	sh.code = SKY_SHADER
	var sm := ShaderMaterial.new()
	sm.shader = sh
	env.sky.sky_material = sm
	env.ambient_light_color = Color(0.80, 0.78, 0.92)
	env.ambient_light_energy = 0.78
	env.fog_light_color = Color(0.99, 0.84, 0.72)
	env.fog_density = game.FOG_DENSITY
	if game.sun_light:
		game.sun_light.light_color = Color(1.0, 0.90, 0.72)
		game.sun_light.light_energy = 0.95
		game.sun_light.look_at_from_position(Vector3(-120.0, 62.0, 52.0), Vector3.ZERO, Vector3.UP)
	if game.camera:
		game.camera.far = 1400.0

# Leaving the sky world: put the twilight sky / light back for castle + town.
static func restore_environment(game) -> void:
	if _saved_env.is_empty():
		return
	var we: WorldEnvironment = game.world_env
	if we != null and we.environment != null:
		var env: Environment = we.environment
		env.sky.sky_material = _saved_env["sky_mat"]
		env.ambient_light_color = _saved_env["amb"]
		env.ambient_light_energy = _saved_env["amb_e"]
		env.fog_light_color = _saved_env["fog"]
	if game.sun_light:
		game.sun_light.light_color = _saved_env["sun_c"]
		game.sun_light.light_energy = _saved_env["sun_e"]
		game.sun_light.global_transform = _saved_env["sun_x"]
	if game.camera:
		game.camera.far = _saved_env["far"]
	_saved_env = {}

const CLOUD_SHADER := """
shader_type spatial;
render_mode unshaded, cull_disabled;
uniform sampler2D noise_tex : repeat_enable, filter_linear_mipmap;
uniform float eclipse = 0.0;
varying vec3 wpos;
void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}
void fragment() {
	vec2 p = wpos.xz;
	float a = texture(noise_tex, p * 0.0035 + vec2(TIME * 0.004, TIME * 0.0015)).r;
	float b = texture(noise_tex, p * 0.011 - vec2(TIME * 0.006, -TIME * 0.003)).r;
	float c = texture(noise_tex, p * 0.031 + vec2(-TIME * 0.009, TIME * 0.007)).r;
	float n = a * 0.55 + b * 0.30 + c * 0.15;
	float puff = smoothstep(0.30, 0.78, n);
	vec3 shade = vec3(0.74, 0.66, 0.86);
	vec3 mid = vec3(0.99, 0.84, 0.76);
	vec3 lit = vec3(1.0, 0.97, 0.90);
	vec3 col = mix(shade, mid, smoothstep(0.0, 0.55, puff));
	col = mix(col, lit, smoothstep(0.55, 1.0, puff));
	col = mix(col, col * vec3(0.46, 0.36, 0.70) + vec3(0.05, 0.02, 0.10), eclipse);
	float dist = length(p - CAMERA_POSITION_WORLD.xz);
	vec3 haze = mix(vec3(0.99, 0.86, 0.74), vec3(0.34, 0.25, 0.50), eclipse);
	ALBEDO = mix(col, haze, smoothstep(260.0, 640.0, dist));
}
"""

const SMOG_SHADER := """
shader_type spatial;
render_mode unshaded, cull_disabled, blend_mix, depth_draw_never;
uniform sampler2D noise_tex : repeat_enable, filter_linear_mipmap;
uniform float safe_r = 190.0;
varying vec3 wpos;
void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}
void fragment() {
	vec2 p = wpos.xz;
	float r = length(p);
	float n = texture(noise_tex, p * 0.012 + vec2(TIME * 0.012, -TIME * 0.008)).r * 0.6
		+ texture(noise_tex, p * 0.037 - vec2(TIME * 0.02, TIME * 0.011)).r * 0.4;
	float edge = smoothstep(safe_r - 2.0 - n * 5.0, safe_r + 4.0, r);
	// nothing before the first rise; melt into the cloud sea past the map's rim
	float on = 1.0 - smoothstep(184.0, 189.5, safe_r);
	float rim = 1.0 - smoothstep(196.0, 250.0, r);
	ALBEDO = mix(vec3(0.34, 0.29, 0.42), vec3(0.52, 0.47, 0.58), n);
	ALPHA = edge * (0.62 + n * 0.3) * on * rim;
}
"""

static func noise_texture() -> Texture2D:
	if ResourceLoader.exists(DIR + "cloud_noise.png"):
		return load(DIR + "cloud_noise.png")
	# no baked texture yet → a small generated one
	var nz := FastNoiseLite.new()
	nz.frequency = 0.012
	var nt := NoiseTexture2D.new()
	nt.width = 256; nt.height = 256
	nt.seamless = true
	nt.noise = nz
	return nt

static func _cloud_sea(view) -> void:
	var tex := noise_texture()
	var pm := PlaneMesh.new()
	pm.size = Vector2(2400.0, 2400.0)
	var sh := Shader.new()
	sh.code = CLOUD_SHADER
	var cm := ShaderMaterial.new()
	cm.shader = sh
	cm.set_shader_parameter("noise_tex", tex)
	var sea := MeshLib.mi(pm, cm)
	sea.position.y = -17.0
	sea.name = "CloudSea"
	_root.add_child(sea)
	view.cloud_mat = cm
	# the smog sea: a ring of murk above the swallowed ground, hole = the safe radius
	var sp := PlaneMesh.new()
	sp.size = Vector2(520.0, 520.0)
	var ssh := Shader.new()
	ssh.code = SMOG_SHADER
	var sm := ShaderMaterial.new()
	sm.shader = ssh
	sm.set_shader_parameter("noise_tex", tex)
	var smog := MeshLib.mi(sp, sm)
	smog.position.y = 1.15
	smog.name = "SmogSea"
	_root.add_child(smog)
	view.smog_mat = sm

# ------------------------------------------------------------------ fallback (no GLB yet)
static func _build_fallback(view) -> void:
	var rock := MeshLib.lit_mat(MeshLib.rgb(0xc9b79a))
	var under := MeshLib.lit_mat(MeshLib.rgb(0x8a7a6a))
	for is_ in SkyLayout.ISLES:
		var r: float = is_["r"]
		var mat: Material = rock
		if String(is_["kind"]) == "home":
			mat = MeshLib.lit_mat(MeshLib.rgb(_game.ELEMENTS[is_["el"]]["color"]).lerp(MeshLib.rgb(0xc9b79a), 0.6))
		var top := MeshLib.cyl(r, r * 0.92, 1.2, mat, 40)
		top.position = Vector3(is_["x"], -0.6, is_["z"])
		_root.add_child(top)
		var cone := MeshLib.cyl(r * 0.9, 0.4, r * 1.3, under, 18)
		cone.position = Vector3(is_["x"], -1.2 - r * 0.65, is_["z"])
		_root.add_child(cone)
	var wood := MeshLib.lit_mat(MeshLib.rgb(0x9c7a52))
	for b in SkyLayout.BRIDGES:
		_fallback_strip(Vector2(b["ax"], b["az"]), Vector2(b["bx"], b["bz"]), 4.0, wood)
	_fallback_strip(Vector2(SkyLayout.STREAM["ax"], SkyLayout.STREAM["az"]), Vector2.ZERO, 6.0, MeshLib.unlit_mat(MeshLib.rgb(0x6d9ce9), 0.8))
	_fallback_strip(Vector2(SkyLayout.VINE["ax"], SkyLayout.VINE["az"]), Vector2.ZERO, 2.4, MeshLib.lit_mat(MeshLib.rgb(0x5f8f3e)))
	var stone := MeshLib.lit_mat(MeshLib.rgb(0xe3d8c4))
	for k in SkyLayout.SPIRE_TIERS:
		var R: float = SkyLayout.SPIRE_OUTER_R[k]
		var drum := MeshLib.cyl(R, R, SkyLayout.SPIRE_TIER_H, stone, 48)
		drum.position.y = float(k) * SkyLayout.SPIRE_TIER_H + SkyLayout.SPIRE_TIER_H * 0.5
		_root.add_child(drum)
		# the stair up from tier k
		var run: float = SkyLayout.SPIRE_RAMP_RUN[k]
		var a := SkyLayout.ramp_ang(k)
		var mid := SkyLayout.pol3(a, R + run * 0.5, float(k) * SkyLayout.SPIRE_TIER_H + 3.0)
		var w := 2.0 * (R + run * 0.5) * sin(deg_to_rad(SkyLayout.SPIRE_RAMP_ARC * 0.5))
		var ramp := MeshLib.box(w, 0.4, sqrt(run * run + 36.0), MeshLib.lit_mat(MeshLib.rgb(0xcbbfa6)))
		ramp.position = mid
		ramp.rotation.y = PI / 2.0 - deg_to_rad(a)
		ramp.rotate_object_local(Vector3.RIGHT, -atan2(SkyLayout.SPIRE_TIER_H, run))
		_root.add_child(ramp)
	for el in ["fire", "water", "grass"]:
		var pm := MeshLib.unlit_mat(MeshLib.rgb(_game.ELEMENTS[el]["color"]), 0.8)
		for k in SkyLayout.SPIRE_TIERS:
			var pp := SkyLayout.pad_pos(k, el)
			var pad := MeshLib.disc(SkyLayout.SHORTCUT_R, pm, 16)
			pad.position = Vector3(pp.x, float(k) * SkyLayout.SPIRE_TIER_H + 0.08, pp.y)
			_root.add_child(pad)
	for v in [SkyLayout.VENT_HOME, SkyLayout.VENT_HEART]:
		var vent := MeshLib.disc(1.5, MeshLib.unlit_mat(MeshLib.rgb(0xff7a2a), 0.9), 16)
		vent.position = Vector3(v.x, 0.1, v.y)
		_root.add_child(vent)
	var bell := MeshLib.cyl(0.5, 1.1, 1.6, MeshLib.lit_mat(MeshLib.rgb(0xb8862e)), 14)
	bell.name = "bell_body"
	bell.position = Vector3(0.0, float(SkyLayout.SPIRE_TIERS) * SkyLayout.SPIRE_TIER_H + 2.4, 0.0)
	_root.add_child(bell)
	view.named["bell_body"] = bell

static func _fallback_strip(a: Vector2, b: Vector2, width: float, mat: Material) -> void:
	var d := b - a
	var box := MeshLib.box(width, 0.3, d.length(), mat)
	var mid := (a + b) * 0.5
	box.position = Vector3(mid.x, -0.16, mid.y)
	box.rotation.y = atan2(d.x, d.y)
	_root.add_child(box)

# ------------------------------------------------------------------ gas + props
# CO2 in the sky world is a drifting smog cloud; O2 a breeze bubble. Same actors,
# same chemistry — only the body differs (both Blender-made).
static func build_gas_visual(kind: String) -> CharVisual:
	var g := CharVisual.new()
	var body := Node3D.new()
	g.add_child(body)
	g.body = body
	var name := "smog_cloud" if kind == "co2" else "breeze_bubble"
	var model := instance(name)
	if model == null:
		var c: Color = MeshLib.rgb(0x6c6578) if kind == "co2" else MeshLib.rgb(0xdff4ff)
		var s := MeshLib.sphere(1.3 if kind == "co2" else 0.8, MeshLib.lit_mat(c), 12, 8)
		s.position.y = 1.6
		model = s
	body.add_child(model)
	if kind == "co2":
		# the charge: a violet ember inside the cloud. It goes out when the cloud has
		# spent its oxygen on a tag (harmless grey CO) — Game toggles "spare_o".
		var core := MeshLib.sphere(0.42, MeshLib.unlit_mat(MeshLib.rgb(0xb07cff), 0.9), 10, 6)
		core.position.y = 1.6
		body.add_child(core)
		g.set_meta("spare_o", core)
		g.set_meta("spare_bond", core)
	var phase := randf() * TAU
	g.extra = func(t: float) -> void:
		model.position.y = sin(t * 0.0021 + phase) * 0.25
		model.rotation.y = t * 0.0004 + phase
	return g

static func build_shard() -> Node3D:
	var n := Node3D.new()
	var m := instance("meteor_shard")
	if m == null:
		var rock := MeshLib.sphere(0.55, MeshLib.unlit_mat(MeshLib.rgb(0x2a2733)), 8, 5)
		rock.scale = Vector3(0.9, 1.5, 0.8)
		m = rock
	m.position.y = -0.45
	n.add_child(m)
	var halo := MeshLib.disc(0.95, MeshLib.unlit_mat(MeshLib.rgb(0x6a5f86), 0.4), 18)
	halo.position.y = -0.4
	n.add_child(halo)
	return n
