class_name SkyView
extends Node3D
# Everything that MOVES in the Skyfall Isles world: Sun Motes, Spark orbs, the
# swinging bell, the gate lanterns, windmill sails, grown seed vines, the smog
# front, the eclipse tint and the predator/prey rim glows. It only reads state
# (from ModeAscent, authoritative or mirrored) and animates nodes — the models
# themselves are the Blender assets in models/sky/.

var game
var named: Dictionary = {}            # node name -> Node3D inside the Blender world scene
var cloud_mat: ShaderMaterial = null
var smog_mat: ShaderMaterial = null
var _sky_mat: ShaderMaterial = null

var _mote_nodes: Array = []           # parallel to mode.motes
var _mote_mats := {}                  # el -> { "body": Material, "beam": Material }
var _vine_nodes: Array = []           # per seed gap: Node3D holding the vine segments
var _front: MultiMeshInstance3D = null
var _front_n := 30
var _front_r := -1.0
var _eclipse := 0.0
var _bell_t := 99.0
var _door: MeshInstance3D = null
var _pad_glows: Array = []            # [{ node, k, el }]
var _bell_player: AudioStreamPlayer = null
var _rim_mats := {}
var _base_amb := Color.WHITE
var _base_sun := Color.WHITE
var _base_fog := Color.WHITE
var _t := 0.0
# tier tasks + cages (SkyQuests)
var _stones: Array = []               # [{ node, rune, k }]
var _cages: Array = []                # [{ root, bars, captive, el }]
var _chimes: Array = []               # [Node3D] for terraces 1..4
var _locks: Array = []                # [MeshInstance3D] shimmer across the stair foot of tiers 1..4
var _key_node: Node3D = null
var _seal_glow: Node = null
var _lamp_light: OmniLight3D = null

func mode():
	return game.sky

func setup() -> void:
	var env: Environment = game.world_env.environment if game.world_env else null
	if env != null:
		_sky_mat = env.sky.sky_material as ShaderMaterial
		_base_amb = env.ambient_light_color
		_base_fog = env.fog_light_color
	if game.sun_light:
		_base_sun = game.sun_light.light_color
	for el in ["fire", "water", "grass"]:
		var c: Color = MeshLib.rgb(game.ELEMENTS[el]["glow"]).lerp(MeshLib.rgb(game.ELEMENTS[el]["color"]), 0.45)
		var beam := MeshLib.unlit_mat(MeshLib.rgb(game.ELEMENTS[el]["color"]), 0.24)
		beam.cull_mode = BaseMaterial3D.CULL_DISABLED
		_mote_mats[el] = { "body": SkyBuilder.tinted_glow(c * 1.15), "beam": beam }
	_build_vines()
	_build_front()
	_build_door_and_pads()
	_build_quest_props()
	_build_bell_sound()

func _exit_tree() -> void:
	for cg in _cages:
		var cap = cg["captive"]
		if cap != null and is_instance_valid(cap):
			cap.queue_free()

func reset_round() -> void:
	for n in _mote_nodes:
		if is_instance_valid(n):
			n.queue_free()
	_mote_nodes.clear()
	_bell_t = 99.0

# ------------------------------------------------------------------ builders
func _build_vines() -> void:
	for i in SkyLayout.SEEDS.size():
		var sd: Dictionary = SkyLayout.SEEDS[i]
		var a := Vector2(sd["ax"], sd["az"])
		var b := Vector2(sd["bx"], sd["bz"])
		var dir := (b - a).normalized()
		# only the gap itself (rim to rim) gets vine
		var hr: float = SkyLayout.HOME_R
		var a_in := sqrt(hr * hr - SkyLayout.SEED_OFF * SkyLayout.SEED_OFF) - 0.8
		var b_in := sqrt(SkyLayout.HEART_R * SkyLayout.HEART_R - SkyLayout.SEED_OFF * SkyLayout.SEED_OFF) - 0.8
		var p0 := a + dir * a_in
		var p1 := b - dir * b_in
		var holder := Node3D.new()
		holder.position = Vector3(p0.x, 0.0, p0.y)
		holder.rotation.y = atan2(dir.x, dir.y)        # local +Z runs along the gap
		holder.visible = false
		holder.set_meta("len", p0.distance_to(p1))
		add_child(holder)
		var n := int(ceil(p0.distance_to(p1) / 4.0))
		for s in n:
			var seg := SkyBuilder.instance("vine_bridge_segment")
			if seg == null:
				seg = MeshLib.box(2.4, 0.25, 4.0, MeshLib.lit_mat(MeshLib.rgb(0x5f8f3e)))
				seg.position.y = -0.13
			seg.position.z = 2.0 + float(s) * 4.0
			holder.add_child(seg)
		_vine_nodes.append(holder)

func _build_front() -> void:
	var src := SkyBuilder.instance("smog_sea_front")
	var mesh: Mesh = null
	var mat: Material = MeshLib.lit_mat(MeshLib.rgb(0x6c6578))
	if src != null:
		var mi := _first_mesh(src)
		if mi != null:
			mesh = mi.mesh.duplicate()
			for s in mesh.get_surface_count():
				mesh.surface_set_material(s, SkyBuilder.paint_mat())
			mat = null
		src.queue_free()
	if mesh == null:
		var sm := SphereMesh.new()
		sm.radius = 8.0; sm.height = 9.0; sm.radial_segments = 10; sm.rings = 5
		mesh = sm
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh
	mm.instance_count = _front_n
	_front = MultiMeshInstance3D.new()
	_front.multimesh = mm
	if mat != null:
		_front.material_override = mat
	_front.visible = false
	add_child(_front)

func _first_mesh(n: Node) -> MeshInstance3D:
	if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
		return n
	for c in n.get_children():
		var r := _first_mesh(c)
		if r != null:
			return r
	return null

func _build_door_and_pads() -> void:
	# the spire door: a shimmer across the foot of ramp 1 until YOUR Spark is lit
	var a := SkyLayout.ramp_ang(0)
	var r: float = SkyLayout.tier_inner(0) + float(SkyLayout.SPIRE_RAMP_RUN[0]) + 0.1
	var w := 2.0 * r * sin(deg_to_rad(SkyLayout.SPIRE_RAMP_ARC * 0.5))
	var dm := MeshLib.unlit_mat(MeshLib.rgb(0x4fd1dc), 0.34)
	dm.cull_mode = BaseMaterial3D.CULL_DISABLED
	_door = MeshLib.box(w, 3.6, 0.12, dm)
	_door.position = SkyLayout.pol3(a, r, 1.8)
	_door.rotation.y = PI / 2.0 - deg_to_rad(a)
	add_child(_door)
	for el in ["fire", "water", "grass"]:
		var pm := MeshLib.unlit_mat(MeshLib.rgb(game.ELEMENTS[el]["glow"]), 0.55)
		for k in SkyLayout.SPIRE_TIERS:
			var pp := SkyLayout.pad_pos(k, el)
			var disc := MeshLib.disc(SkyLayout.SHORTCUT_R, pm, 20)
			disc.position = Vector3(pp.x, float(k) * SkyLayout.SPIRE_TIER_H + 0.09, pp.y)
			add_child(disc)
			_pad_glows.append({ "node": disc, "k": k, "el": el })

func _prop(asset: String, fallback: Callable) -> Node3D:
	var n := SkyBuilder.instance(asset)
	if n == null:
		n = fallback.call()
	add_child(n)
	return n

# Task stones, cages, wind chimes, the Sun Key, the Sun Seal and the task locks.
func _build_quest_props() -> void:
	var gold := Color(0.98, 0.76, 0.18)
	for k in range(1, SkyQuests.TASK_TIERS + 1):
		var y := float(k) * SkyLayout.SPIRE_TIER_H
		var sp := SkyQuests.stone_pos(k)
		var stone := _prop("task_stone", func(): return MeshLib.box(0.9, 1.5, 0.6, MeshLib.lit_mat(MeshLib.rgb(0x9a8f80))))
		stone.position = Vector3(sp.x, y, sp.y)
		stone.rotation.y = PI / 2.0 - deg_to_rad(SkyLayout.ang_of(sp.x, sp.y))     # the tablet faces out, toward the terrace
		_stones.append({ "node": stone, "rune": stone.find_child("rune", true, false), "k": k })
		var cp := SkyQuests.chime_pos(k)
		var chime := _prop("wind_chime", func(): return MeshLib.box(0.3, 0.9, 0.3, MeshLib.unlit_mat(Color.WHITE)))
		chime.position = Vector3(cp.x, y, cp.y)
		_chimes.append(chime)
		# the lock: a shimmer across the foot of this tier's stair until the task is done
		var a := SkyLayout.ramp_ang(k)
		var r: float = SkyLayout.tier_inner(k) + float(SkyLayout.SPIRE_RAMP_RUN[k]) + 0.1
		var w := 2.0 * r * sin(deg_to_rad(SkyLayout.SPIRE_RAMP_ARC * 0.5))
		var lm := MeshLib.unlit_mat(gold, 0.34)
		lm.cull_mode = BaseMaterial3D.CULL_DISABLED
		var lock := MeshLib.box(w, 3.2, 0.12, lm)
		lock.position = SkyLayout.pol3(a, r, y + 1.6)
		lock.rotation.y = PI / 2.0 - deg_to_rad(a)
		add_child(lock)
		_locks.append(lock)
	for i in SkyQuests.CAGE_SPOTS.size():
		var p: Vector3 = SkyQuests.CAGE_SPOTS[i]
		var cage := _prop("helper_cage", func(): return MeshLib.cyl(1.1, 1.1, 0.2, MeshLib.lit_mat(MeshLib.rgb(0x6b5a48)), 12))
		cage.position = p
		# the padlock faces the open ground: outward on Heart Isle, toward the isle's middle elsewhere
		var face := SkyLayout.ang_of(p.x, p.z)
		var node := SkyLayout.node_of(p.x, p.z)
		if node != "heart" and node != "":
			var is_: Dictionary = SkyLayout.NODES[node]
			face = SkyLayout.ang_of(float(is_["x"]) - p.x, float(is_["z"]) - p.z)
		cage.rotation.y = PI / 2.0 - deg_to_rad(face)
		# a sign over a cage that is still locked for you (hidden once it opens)
		var sign: Label3D = null
		if i < SkyQuests.CAGE_NEED.size() and int(SkyQuests.CAGE_NEED[i]) > 0:
			sign = Label3D.new()
			sign.text = SkyQuests.CAGE_NEED_SIGN[int(SkyQuests.CAGE_NEED[i])]
			sign.billboard = BaseMaterial3D.BILLBOARD_ENABLED
			sign.font_size = 56
			sign.pixel_size = 0.009
			sign.outline_size = 14
			sign.modulate = Color(1.0, 0.86, 0.45)
			sign.outline_modulate = Color(0.2, 0.14, 0.1, 0.95)
			sign.position = p + Vector3(0, 4.3, 0)
			sign.visible = false
			add_child(sign)
		_cages.append({ "root": cage, "bars": cage.find_child("bars", true, false), "captive": null, "el": "", "sign": sign })
	_key_node = _prop("sun_key", func(): return MeshLib.box(0.3, 1.0, 0.1, MeshLib.unlit_mat(gold)))
	SkyBuilder.set_override(_key_node, SkyBuilder.tinted_glow(gold * 1.15))
	_key_node.visible = false
	var sl := SkyQuests.seal_pos()
	var seal := _prop("sun_seal", func(): return MeshLib.disc(SkyQuests.SEAL_R, MeshLib.lit_mat(MeshLib.rgb(0xb9a98c)), 24))
	# the terrace is narrower than the seal's rim: shrink it to sit inside the band
	seal.scale = Vector3.ONE * minf(1.0, (SkyLayout.tier_outer(4) - SkyLayout.tier_inner(4)) * 0.5 / 2.2 * 0.94)
	seal.position = Vector3(sl.x, 4.0 * SkyLayout.SPIRE_TIER_H + 0.02, sl.y)
	_seal_glow = seal.find_child("seal_glow", true, false)
	# the lighthouse lamp throws real light once somebody has lit it
	var lamp = named.get("beacon_lamp")
	if lamp != null and is_instance_valid(lamp):
		_lamp_light = OmniLight3D.new()
		_lamp_light.omni_range = 26.0
		_lamp_light.light_energy = 0.0
		_lamp_light.shadow_enabled = false
		_lamp_light.position = Vector3(0, 0.6, 0)
		(lamp as Node3D).add_child(_lamp_light)

func _update_quests(m, dt: float) -> void:
	var q: SkyQuests = m.quests
	if q == null:
		return
	var my_el: String = m._local_el()
	var me: GameChar = game.player
	var my_col: Color = MeshLib.rgb(game.ELEMENTS[my_el]["glow"]) if my_el != "" else Color.WHITE
	var gold := Color(0.98, 0.76, 0.18)
	var dim := Color(0.26, 0.27, 0.33)
	var pulse := 0.75 + 0.25 * sin(_t * 4.0)
	var front := q.frontier(my_el) if my_el != "" else 99
	var act := int(q.active.get(my_el, 0)) if my_el != "" else 0
	# ---- task stones: gold = it has a task for you, your colour = that task is running, dim = done / not yet
	for st in _stones:
		var k := int(st["k"])
		var c := dim
		if k == front:
			c = (my_col * 1.1) if act == k else gold * (0.8 + 0.5 * pulse)
		elif k < front:
			c = Color(0.45, 0.8, 0.55)
		if st["rune"] != null and is_instance_valid(st["rune"]):
			_set_tint(st["rune"], "rune", c)
		if k - 1 < _locks.size():
			var lock: MeshInstance3D = _locks[k - 1]
			lock.visible = my_el != "" and not q.can_go_up(my_el, k)
			if lock.visible:
				(lock.material_override as StandardMaterial3D).albedo_color.a = 0.24 + 0.1 * sin(_t * 3.0 + float(k))
	# ---- wind chimes sway; a resting one hangs dull
	for i in _chimes.size():
		var ch: Node3D = _chimes[i]
		var resting: bool = float(q.chime_rest[i]) > 0.0
		ch.rotation.z = sin(_t * 1.7 + float(i) * 1.3) * (0.03 if resting else 0.1)
		ch.rotation.y += dt * (0.15 if resting else 0.6)
		_set_tint(ch, "chime", Color(0.4, 0.42, 0.48) if resting else Color(1.0, 0.92, 0.7))
	# ---- cages: bars + a small captive while someone is inside
	for i in mini(_cages.size(), q.cages.size()):
		var cg: Dictionary = _cages[i]
		var el: String = q.cages[i]["el"]
		if el != String(cg["el"]):
			cg["el"] = el
			var old = cg["captive"]
			if old != null and is_instance_valid(old):
				old.queue_free()
			cg["captive"] = null
			if el != "":
				var cap: CharVisual = game._build_char_visual("element", el)
				cap.scale = Vector3.ONE * 0.5
				var root: Node3D = cg["root"]
				cap.position = root.position + Vector3(0, 0.16, 0)
				cap.rotation.y = root.rotation.y
				cg["captive"] = cap
		# an opened cage folds down flat (bars gone, its dome resting on the base) until a new captive arrives
		var croot: Node3D = cg["root"]
		croot.scale.y = lerpf(croot.scale.y, 1.0 if el != "" else 0.22, clampf(dt * 7.0, 0.0, 1.0))
		var bars = cg["bars"]
		if bars != null and is_instance_valid(bars):
			(bars as Node3D).visible = el != "" or croot.scale.y > 0.6
		if cg["sign"] != null:
			(cg["sign"] as Label3D).visible = el != "" and my_el != "" and not q.cage_unlocked(i, my_el)
		var cv = cg["captive"]
		if cv != null and is_instance_valid(cv):
			(cv as Node3D).position.y = 0.16 + absf(sin(_t * 3.0 + float(i))) * 0.12     # hopping to be let out
			(cv as CharVisual).animate(game.time_ms, 0.0)
	# ---- the Sun Key: on the altar (or wherever it drifted), or over my head while I carry it
	var ks := int(q.key_state.get(my_el, 0)) if my_el != "" else 0
	_key_node.visible = ks != 0 and (ks == 1 or (me != null and me.group != null))
	if _key_node.visible:
		if ks == 1:
			var kp: Vector3 = q.key_pos[my_el]
			var on_altar: bool = kp.distance_to(SkyQuests.shrine_pos()) < 0.5
			_key_node.position = Vector3(kp.x, (0.75 if on_altar else 0.25) + sin(_t * 2.4) * 0.15, kp.z)
			_key_node.scale = Vector3.ONE * 1.25
		else:
			_key_node.position = me.pos + Vector3(0, 2.5 + sin(_t * 3.0) * 0.1, 0)
			_key_node.scale = Vector3.ONE * 0.8
		_key_node.rotation.y += dt * 1.8
	var ag = named.get("altar_glow")
	if ag != null and is_instance_valid(ag):
		_set_tint(ag, "altar", gold * (0.9 + 0.5 * pulse) if ks == 1 else Color(0.85, 0.7, 0.4))
	# ---- the Sun Seal glows while its task runs
	if _seal_glow != null and is_instance_valid(_seal_glow):
		var sc := dim
		if act == 4:
			sc = gold * (0.8 + 0.5 * pulse)
		elif front > 4:
			sc = Color(0.45, 0.8, 0.55)
		_set_tint(_seal_glow, "seal", sc)
	# ---- the lighthouse: its lamp burns in the colour of whoever lit it last; the ring calls you during the task
	var lamp = named.get("beacon_lamp")
	if lamp != null and is_instance_valid(lamp):
		var lc := Color(0.3, 0.32, 0.4)
		if q.beacon_el != "":
			lc = MeshLib.rgb(game.ELEMENTS[q.beacon_el]["glow"]) * (1.15 + 0.2 * sin(_t * 2.0))
		_set_tint(lamp, "lamp", lc)
		if _lamp_light != null:
			_lamp_light.light_energy = 2.2 if q.beacon_el != "" else 0.0
			_lamp_light.light_color = lc
	var ring = named.get("beacon_ring")
	if ring != null and is_instance_valid(ring):
		_set_tint(ring, "ring", gold * (0.8 + 0.5 * pulse) if act == 2 else dim)
	# ---- helpers wear a ring in their team's colour (host: the actor's body, guests: its ghost)
	for nid in q.helper_team:
		var node: Node3D = null
		if game.mode == game.Mode.CLIENT:
			node = game.ghosts.get(nid)
		else:
			for h in q.helpers:
				if h.net_id == nid:
					node = h.group
		if node == null or not is_instance_valid(node) or node.has_meta("team_ring"):
			continue
		var tm := TorusMesh.new()
		tm.inner_radius = 1.5; tm.outer_radius = 1.85
		tm.rings = 20; tm.ring_segments = 4
		var tr := MeshInstance3D.new()
		tr.mesh = tm
		tr.position.y = 0.15
		tr.scale = Vector3(1.0, 0.3, 1.0)
		tr.material_override = MeshLib.unlit_mat(MeshLib.rgb(game.ELEMENTS[q.helper_team[nid]]["glow"]), 0.9)
		node.add_child(tr)
		node.set_meta("team_ring", tr)

# The bell is synthesised (a strike + inharmonic partials) — no audio asset needed.
func _build_bell_sound() -> void:
	if DisplayServer.get_name() == "headless":
		return
	var rate := 22050
	var secs := 3.2
	var n := int(rate * secs)
	var data := PackedByteArray()
	data.resize(n * 2)
	var f0 := 196.0
	var parts := [[0.5, 0.30, 1.0], [1.0, 0.55, 1.4], [1.19, 0.42, 1.9], [1.5, 0.22, 2.2], [2.0, 0.34, 2.6], [2.51, 0.18, 3.2], [3.0, 0.12, 4.0], [4.2, 0.08, 5.2]]
	for i in n:
		var t := float(i) / float(rate)
		var v := 0.0
		for p in parts:
			v += sin(TAU * f0 * float(p[0]) * t) * float(p[1]) * exp(-t * float(p[2]))
		v *= minf(1.0, t * 400.0) * 0.42
		var s := int(clampf(v, -1.0, 1.0) * 32000.0)
		data.encode_s16(i * 2, s)
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = rate
	wav.stereo = false
	wav.data = data
	_bell_player = AudioStreamPlayer.new()
	_bell_player.stream = wav
	_bell_player.volume_db = -4.0
	add_child(_bell_player)

func ring_bell() -> void:
	_bell_t = 0.0
	if _bell_player != null:
		_bell_player.play()

# ------------------------------------------------------------------ per frame
func update(dt: float) -> void:
	var m = mode()
	if m == null:
		return
	_t += dt
	_update_eclipse(m, dt)
	_update_smog(m)
	_update_motes(m, dt)
	_update_bell(m, dt)
	_update_props(m, dt)
	_update_quests(m, dt)
	_update_actor_fx(m)

func _update_eclipse(m, dt: float) -> void:
	var want := 1.0 if m.eclipse_active() else 0.0
	_eclipse = move_toward(_eclipse, want, dt / 1.2)
	if _sky_mat:
		_sky_mat.set_shader_parameter("eclipse", _eclipse)
	if cloud_mat:
		cloud_mat.set_shader_parameter("eclipse", _eclipse)
	var env: Environment = game.world_env.environment if game.world_env else null
	if env != null:
		env.ambient_light_color = _base_amb.lerp(Color(0.50, 0.38, 0.78), _eclipse)
		env.fog_light_color = _base_fog.lerp(Color(0.36, 0.26, 0.54), _eclipse)
	if game.sun_light:
		game.sun_light.light_color = _base_sun.lerp(Color(0.62, 0.48, 0.95), _eclipse)

func _update_smog(m) -> void:
	var r: float = m.smog_r()
	if smog_mat:
		smog_mat.set_shader_parameter("safe_r", r)
	if _front == null:
		return
	_front.visible = r < 185.0
	if not _front.visible or absf(r - _front_r) < 0.05:
		return
	_front_r = r
	var seg_w := TAU * r / float(_front_n)
	var sx := seg_w / 16.0 * 1.12
	var sy := clampf(0.7 + r / 150.0, 0.8, 1.7)
	for i in _front_n:
		var a := TAU * float(i) / float(_front_n)
		var basis := Basis(Vector3.UP, PI / 2.0 - a) * Basis.from_scale(Vector3(sx, sy, minf(sx, 1.4)))
		_front.multimesh.set_instance_transform(i, Transform3D(basis, Vector3(cos(a) * (r + 2.5), 0.0, sin(a) * (r + 2.5))))

func _make_mote(el: String) -> Node3D:
	var n := Node3D.new()
	var body := SkyBuilder.instance("sun_mote")
	if body == null:
		var s := MeshLib.sphere(0.4, _mote_mats[el]["body"], 10, 6)
		s.position.y = 1.4
		body = s
	else:
		SkyBuilder.set_override(body, _mote_mats[el]["body"])
	body.name = "body"
	n.add_child(body)
	var bm := CylinderMesh.new()
	bm.top_radius = 0.22; bm.bottom_radius = 0.22; bm.height = 46.0
	bm.radial_segments = 6; bm.cap_top = false; bm.cap_bottom = false
	var beam := MeshLib.mi(bm, _mote_mats[el]["beam"])
	beam.position.y = 24.0
	beam.name = "beam"
	n.add_child(beam)
	n.set_meta("el", el)
	add_child(n)
	return n

func _update_motes(m, dt: float) -> void:
	var my_el: String = m._local_el()
	while _mote_nodes.size() < m.motes.size():
		_mote_nodes.append(null)
	for i in m.motes.size():
		var mo: Dictionary = m.motes[i]
		var n = _mote_nodes[i]
		if n == null or not is_instance_valid(n) or String(n.get_meta("el")) != String(mo["el"]):
			if n != null and is_instance_valid(n):
				n.queue_free()
			n = _make_mote(mo["el"])
			_mote_nodes[i] = n
		n.visible = not mo["taken"]
		if not n.visible:
			continue
		var p: Vector3 = mo["pos"]
		n.position = n.position.lerp(Vector3(p.x, 0.0, p.z), clampf(dt * 8.0, 0.0, 1.0)) if n.position.distance_to(Vector3(p.x, 0.0, p.z)) < 30.0 else Vector3(p.x, 0.0, p.z)
		var body: Node3D = n.get_node("body")
		body.position.y = sin(_t * 2.2 + float(i)) * 0.18
		body.rotation.y += dt * 1.5
		var mine := String(mo["el"]) == my_el
		(n.get_node("beam") as Node3D).visible = mine      # only YOUR motes carry the far-off light pillar
		body.scale = Vector3.ONE * (1.25 if mine else 0.9)

func _update_bell(m, dt: float) -> void:
	_bell_t += dt
	var bb = named.get("bell_body")
	if bb != null and is_instance_valid(bb):
		var amp := 0.55 * exp(-_bell_t * 0.75) if _bell_t < 6.0 else 0.0
		bb.rotation.x = sin(_bell_t * 5.2) * amp
		var cl = named.get("clapper")
		if cl != null and is_instance_valid(cl):
			cl.rotation.x = -sin(_bell_t * 5.2 + 0.9) * amp * 1.3
	var inlay = named.get("ring_inlay")
	if inlay != null and is_instance_valid(inlay):
		var ringing := false
		for el in m.ELS:
			if int(m.tier_el[el]) >= m.SPIRE_TIERS:
				ringing = true
		var pulse := 0.6 + 0.4 * sin(_t * (9.0 if ringing and m.bell_settle <= 0.0 else 2.0))
		var c := Color(0.55, 0.95, 1.0) if m.bell_settle <= 0.0 else Color(1.0, 0.6, 0.4)
		_set_tint(inlay, "inlay", c * pulse)

func _set_tint(n: Node, key: String, c: Color) -> void:
	var mat: StandardMaterial3D = n.get_meta("tint_" + key) if n.has_meta("tint_" + key) else null
	if mat == null:
		mat = SkyBuilder.tinted_glow(c)
		n.set_meta("tint_" + key, mat)
		SkyBuilder.set_override(n, mat)
	mat.albedo_color = c

func _update_props(m, dt: float) -> void:
	var my_el: String = m._local_el()
	var sails = named.get("sails")
	if sails != null and is_instance_valid(sails):
		sails.rotate_object_local(Vector3(0, 0, 1), dt * 0.7)
	# gate lanterns: one lights per mote in MY Spark
	var n_m := int(m.motes_el.get(my_el, 0)) if my_el != "" else 0
	var lit_col: Color = MeshLib.rgb(game.ELEMENTS[my_el]["glow"]) * 1.2 if my_el != "" else Color.WHITE
	for i in 3:
		var ln = named.get("lantern_%d" % (i + 1))
		if ln != null and is_instance_valid(ln):
			_set_tint(ln, "lantern", lit_col if i < n_m else Color(0.22, 0.24, 0.3))
	if _door:
		_door.visible = my_el != "" and not m.lit(my_el)
		if _door.visible:
			(_door.material_override as StandardMaterial3D).albedo_color.a = 0.26 + 0.1 * sin(_t * 3.0)
	var me: GameChar = game.player
	for pg in _pad_glows:
		var node: MeshInstance3D = pg["node"]
		var mine: bool = pg["el"] == my_el
		node.visible = mine and m.quests.can_go_up(my_el, int(pg["k"]))
		if node.visible and me != null:
			var ready: bool = me.pad_cd <= 0.0
			node.scale = Vector3.ONE * ((1.0 + 0.12 * sin(_t * 5.0)) if ready and me.tier == int(pg["k"]) else 0.85)
	# seed vines grow out of the home-side seed, wither when their time is up
	for i in _vine_nodes.size():
		var holder: Node3D = _vine_nodes[i]
		var left: float = float(m.seed_until[i]) - float(m.elapsed)
		var grow := 0.0
		if left > 0.0:
			grow = clampf((SkyLayout.SEED_LIFE - left) / 0.5, 0.0, 1.0) * clampf(left / 0.8, 0.0, 1.0)
		holder.visible = grow > 0.01
		if holder.visible:
			holder.scale = Vector3(lerpf(0.4, 1.0, grow), 1.0, 1.0)
			var blink: bool = left < 2.5 and fmod(_t, 0.3) < 0.12
			holder.visible = not blink
		for side in ["a", "b"]:
			var sn = named.get("seed_%d_%s" % [i, side])
			if sn != null and is_instance_valid(sn):
				var g := float(m.seed_grow[i])
				sn.scale = Vector3.ONE * (1.0 + g * 0.9 + (0.08 * sin(_t * 4.0) if my_el == "grass" else 0.0))

# Spark orbs + predator/prey rim glows on every element body (actors or guest ghosts).
func _update_actor_fx(m) -> void:
	var my_el: String = m._local_el()
	if game.mode == game.Mode.CLIENT:
		for nid in game.ghosts:
			var gnode = game.ghosts[nid]
			if not is_instance_valid(gnode):
				continue
			var fl := int((game._net_actors.get(nid, {}) as Dictionary).get("flags", 0))
			if (fl & 3) != 0 or (fl & (1 << 9)) != 0:
				continue
			_fx_for(m, gnode, game._EL_NAME[(fl >> 2) & 3], my_el, false)
		if game.player and game.player.group:
			_fx_for(m, game.player.group, game.player.el, my_el, true)
	else:
		for ch in game.actors:
			if ch.group and is_instance_valid(ch.group):
				_fx_for(m, ch.group, ch.el, my_el, ch == game.player)

func _fx_for(m, node: Node3D, el: String, my_el: String, is_me: bool) -> void:
	if el == "":
		return
	# ---- the Spark: appears with the first mote, ignites at three
	var n_m := int(m.motes_el.get(el, 0))
	var orb: Node3D = node.get_meta("spark") if node.has_meta("spark") else null
	if n_m > 0 and (orb == null or not is_instance_valid(orb)):
		orb = SkyBuilder.instance("spark_orb")
		if orb == null:
			orb = MeshLib.sphere(0.22, MeshLib.unlit_mat(Color.WHITE), 8, 6)
		var col: Color = MeshLib.rgb(game.ELEMENTS[el]["glow"])
		SkyBuilder.set_override(orb, SkyBuilder.tinted_glow(col * 1.2))
		for i in 3:
			var sk := orb.find_child("socket_%d" % (i + 1), true, false)
			if sk != null:
				SkyBuilder.set_override(sk, SkyBuilder.tinted_glow(MeshLib.rgb(game.ELEMENTS[el]["color"])))
		node.add_child(orb)
		node.set_meta("spark", orb)
	if orb != null and is_instance_valid(orb):
		orb.visible = n_m > 0
		if orb.visible:
			var lit: bool = n_m >= m.ASCENT_MOTES_NEEDED
			var ph := _t * (3.2 if lit else 1.6) + float(node.get_instance_id() % 7)
			var inv := 1.0 / maxf(0.01, node.scale.x)
			orb.position = Vector3(cos(ph) * 1.25, 2.1 + sin(ph * 1.7) * 0.18, sin(ph) * 1.25) * inv
			orb.scale = Vector3.ONE * (2.1 if lit else 1.2) * inv
			orb.rotation.y = -ph * 2.0
			for i in 3:
				var sk := orb.find_child("socket_%d" % (i + 1), true, false)
				if sk != null:
					(sk as Node3D).visible = i < n_m
	# ---- rim glow: red = it eats you right now, green = you eat it (flips in an eclipse)
	var rim: MeshInstance3D = node.get_meta("rim") if node.has_meta("rim") else null
	var rel := 0
	if not is_me and my_el != "" and el != my_el:
		rel = 1 if game._eats(el, my_el) else (2 if game._eats(my_el, el) else 0)
	if rel == 0:
		if rim != null and is_instance_valid(rim):
			rim.visible = false
		return
	if rim == null or not is_instance_valid(rim):
		var tm := TorusMesh.new()
		tm.inner_radius = 1.25; tm.outer_radius = 1.5
		tm.rings = 24; tm.ring_segments = 4
		rim = MeshInstance3D.new()
		rim.mesh = tm
		rim.position.y = 0.12
		rim.scale = Vector3(1.0, 0.25, 1.0)
		node.add_child(rim)
		node.set_meta("rim", rim)
	rim.visible = true
	rim.material_override = _rim_mat(rel)

func _rim_mat(rel: int) -> StandardMaterial3D:
	if not _rim_mats.has(rel):
		_rim_mats[rel] = MeshLib.unlit_mat(Color(1.0, 0.28, 0.22) if rel == 1 else Color(0.35, 0.95, 0.45), 0.85)
	return _rim_mats[rel]
