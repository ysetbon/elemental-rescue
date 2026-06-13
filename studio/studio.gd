extends Node3D
# ── Banner Studio ───────────────────────────────────────────────────────────
# Compose the README banner by hand, then snap the photo.
#
#   SHIFT            select the NEXT thing to control (TAB = previous)
#   WASD / arrows    move the selected thing (camera-relative)
#   Q / E            turn it       R / F   raise / lower it
#   drag mouse       look around   — only while you are the WHITE camera
#   ENTER            take the photo — only while you are the WHITE camera
#   P                print every position to the Output log (paste into game.gd)
#
# The view is ALWAYS from the white camera-character's eyes — that's the photo.
# Select an elemental / house / leaf to slide it around inside the frame; select
# the white camera to move/turn the shot itself.

const EYE_H := 1.6
const MOVE_SPEED := 9.0

var camera: Camera3D
var world: Node3D
var entities: Array = []          # [{ "node": Node3D, "name": String, "kind": String }]
var sel := 0
var cam_node: Node3D              # the (hidden) white O₂ — the photographer
var cam_yaw := PI + 0.12
var cam_pitch := -0.12
var dragging := false
var time_ms := 0.0
var hud: Label
var marker: Node3D
var _autoshot := false
var _shot_done := false

func _ready() -> void:
	_autoshot = OS.get_cmdline_user_args().has("shot")
	DisplayServer.window_set_size(Vector2i(1280, 460))
	_build_environment()
	world = Node3D.new(); add_child(world)
	camera = Camera3D.new(); camera.fov = 46; camera.far = 900; add_child(camera)
	_build_ground_river()
	_build_trees()
	_spawn_camera_char()     # entity 0 — you start as the camera
	_spawn_elementals()      # 1, 2, 3
	_build_houses()
	_build_leaves()
	_build_marker()
	_build_hud()
	_update_camera()

# ------------------------------------------------------------------ environment
func _build_environment() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	var shader := Shader.new(); shader.code = Game.SKY_SHADER
	var smat := ShaderMaterial.new(); smat.shader = shader
	sky.sky_material = smat
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = MeshLib.rgb(Game.AMBIENT_COLOR)
	env.ambient_light_energy = Game.AMBIENT_ENERGY
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	env.fog_enabled = true
	env.fog_light_color = MeshLib.rgb(Game.FOG_COLOR)
	env.fog_density = Game.FOG_DENSITY
	env.fog_sky_affect = 0.0
	var we := WorldEnvironment.new(); we.environment = env; add_child(we)
	var sun := DirectionalLight3D.new()
	sun.light_color = MeshLib.rgb(Game.SUN_COLOR)
	sun.light_energy = Game.SUN_ENERGY
	add_child(sun)
	sun.look_at_from_position(Game.SUN_FROM, Vector3.ZERO, Vector3.UP)

# ------------------------------------------------------------------ static world
func _build_ground_river() -> void:
	var gp := PlaneMesh.new(); gp.size = Vector2(600, 600)
	world.add_child(MeshLib.mi(gp, MeshLib.lit_mat(MeshLib.rgb(0xdce7f4))))
	var wmat := StandardMaterial3D.new()
	wmat.albedo_color = MeshLib.rgb(0xc4d6ef)
	wmat.metallic = 0.25; wmat.roughness = 0.05; wmat.metallic_specular = 0.9
	var rp := PlaneMesh.new(); rp.size = Vector2(18.0, 160.0)
	var river := MeshLib.mi(rp, wmat)
	river.position = Vector3(-19.0, 0.05, -55.0)
	world.add_child(river)
	for cx in [-9.8, -28.2]:
		var curb := MeshLib.box(1.0, 0.3, 160.0, MeshLib.lit_mat(MeshLib.rgb(0xfafbfe)))
		curb.position = Vector3(cx, 0.13, -55.0)
		world.add_child(curb)

func _build_trees() -> void:
	_make_tree(-30.0, 7.0, 1.35)
	_make_tree(20.0, -16.0, 1.0)
	for k in [1, 3, 5]:
		_make_tree(-36.0, 12.0 - k * 11.0 - 2.5, 1.1)

func _make_tree(x: float, z: float, s: float) -> void:
	var trunk := MeshLib.cyl(0.1 * s, 0.14 * s, 0.7 * s, MeshLib.lit_mat(MeshLib.rgb(0x8a7866)))
	trunk.position = Vector3(x, 0.35 * s, z)
	world.add_child(trunk)
	var body := MeshLib.sphere(0.75 * s, MeshLib.lit_mat(MeshLib.rgb(0x44604f)), 14, 12)
	body.scale = Vector3(1, 2.9, 1)
	body.position = Vector3(x, 0.6 * s + 2.0 * s, z)
	world.add_child(body)

# ------------------------------------------------------------------ entities
func _spawn_camera_char() -> void:
	cam_node = MeshLib.build_o2()
	cam_node.position = Vector3(3.5, 1.4, 15.0)
	cam_node.visible = false      # you're looking out through his eyes
	add_child(cam_node)
	entities.append({ "node": cam_node, "name": "Camera (white O₂)", "kind": "camera" })

func _spawn_elementals() -> void:
	var specs := [
		["Fire", "fire", Vector3(-0.5, 0, -13.0)],
		["Water", "water", Vector3(3.5, 0, -6.5)],
		["Leaf", "grass", Vector3(9.0, 0, -8.5)],
	]
	for s in specs:
		var ch: CharVisual
		if s[1] == "fire": ch = MeshLib.build_flame()
		elif s[1] == "water": ch = MeshLib.build_droplet()
		else: ch = MeshLib.build_leaf()
		var p: Vector3 = s[2]
		ch.position = p
		ch.rotation.y = atan2(cam_node.position.x - p.x, cam_node.position.z - p.z)
		add_child(ch)
		entities.append({ "node": ch, "name": s[0], "kind": "element" })

func _make_house(col: Color, roofcol: Color, win_dir: float) -> Node3D:
	var g := Node3D.new()
	var w := 7.0; var d := 6.0; var h := 3.4
	var body := MeshLib.box(w, h, d, MeshLib.lit_mat(col)); body.position.y = h * 0.5; g.add_child(body)
	var prism := PrismMesh.new(); prism.size = Vector3(w + 1.0, h * 0.55, d + 1.0)
	var roof := MeshLib.mi(prism, MeshLib.lit_mat(roofcol)); roof.position.y = h + h * 0.27; g.add_child(roof)
	var win := MeshLib.box(0.12, 1.3, 1.6, MeshLib.unlit_mat(MeshLib.rgb(0xfbfaf4)))
	win.position = Vector3(win_dir * (w * 0.5 + 0.07), h * 0.52, 0)
	g.add_child(win)
	return g

func _build_houses() -> void:
	var hc := [0xefa07f, 0xe98a5f, 0xf3c9a4, 0xf4f1e8]
	var rc := [0x675f5c, 0xd2603c, 0x5e5863, 0x4e4b57]
	var zz := 12.0
	var i := 0
	while zz > -74.0:
		var hg := _make_house(MeshLib.rgb(hc[i % 4]), MeshLib.rgb(rc[i % 4]), 1.0)
		hg.position = Vector3(-32.5, 0, zz)
		add_child(hg)
		entities.append({ "node": hg, "name": "House L%d" % (i + 1), "kind": "house" })
		zz -= 11.0; i += 1
	var rh := [
		[25.0, -9.0, 0xefa07f, 0xd2603c], [13.0, -52.0, 0xf3c9a4, 0x5e5863], [17.5, -58.0, 0xe98a5f, 0x675f5c],
	]
	var j := 0
	for r in rh:
		var hg := _make_house(MeshLib.rgb(r[2]), MeshLib.rgb(r[3]), -1.0)
		hg.position = Vector3(r[0], 0, r[1])
		add_child(hg)
		entities.append({ "node": hg, "name": "House R%d" % (j + 1), "kind": "house" })
		j += 1

func _build_leaves() -> void:
	var mesh := WorldBuilder._make_windleaf_mesh()
	var tones := [0x5e9450, 0x6aa55e, 0x4f8a45, 0x6fa85c]
	var spots := [
		Vector3(1.5, 6.0, -16.0), Vector3(3.8, 6.6, -15.0),
		Vector3(11.0, 6.4, -12.0), Vector3(13.5, 5.7, -10.0), Vector3(15.5, 4.9, -9.0),
		Vector3(0.5, 0.7, -6.0), Vector3(4.5, 0.45, -2.6), Vector3(11.0, 1.0, -3.2),
	]
	var i := 0
	for p in spots:
		var mat := MeshLib.unlit_mat(MeshLib.rgb(tones[i % 4]), 0.96)
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		var m := MeshLib.mi(mesh, mat)
		m.position = p
		m.rotation = Vector3(0.7 + i * 0.4, i * 0.8, 0.5 + i * 0.3)
		m.scale = Vector3.ONE * (0.55 + (i % 3) * 0.12)
		add_child(m)
		entities.append({ "node": m, "name": "Leaf-fly %d" % (i + 1), "kind": "foliage" })
		i += 1

func _build_marker() -> void:
	marker = MeshLib.sphere(0.35, MeshLib.unlit_mat(MeshLib.rgb(0xffe14d), 0.92), 12, 8)
	add_child(marker)

# ------------------------------------------------------------------ loop
func _process(delta: float) -> void:
	time_ms += delta * 1000.0
	if _autoshot and not _shot_done and time_ms > 1500.0:
		_shot_done = true
		_do_autoshot()
		return
	_handle_movement(delta)
	for e in entities:
		if e["kind"] == "element":
			(e["node"] as CharVisual).animate(time_ms, 11.0)
	_update_camera()
	_update_marker()
	_update_hud()

func _handle_movement(dt: float) -> void:
	var e: Dictionary = entities[sel]
	var node: Node3D = e["node"]
	var cb := camera.global_transform.basis
	var fwd := -cb.z; fwd.y = 0
	if fwd.length() > 0.001: fwd = fwd.normalized()
	var right := cb.x; right.y = 0
	if right.length() > 0.001: right = right.normalized()
	var mv := Vector3.ZERO
	if Input.is_physical_key_pressed(KEY_W) or Input.is_physical_key_pressed(KEY_UP): mv += fwd
	if Input.is_physical_key_pressed(KEY_S) or Input.is_physical_key_pressed(KEY_DOWN): mv -= fwd
	if Input.is_physical_key_pressed(KEY_D) or Input.is_physical_key_pressed(KEY_RIGHT): mv += right
	if Input.is_physical_key_pressed(KEY_A) or Input.is_physical_key_pressed(KEY_LEFT): mv -= right
	if mv.length() > 0.0:
		node.position += mv.normalized() * MOVE_SPEED * dt
	if Input.is_physical_key_pressed(KEY_R): node.position.y += 3.5 * dt
	if Input.is_physical_key_pressed(KEY_F): node.position.y = maxf(0.0, node.position.y - 3.5 * dt)
	var dr := 0.0
	if Input.is_physical_key_pressed(KEY_Q): dr += 1.0
	if Input.is_physical_key_pressed(KEY_E): dr -= 1.0
	if dr != 0.0:
		if e["kind"] == "camera": cam_yaw += dr * 1.5 * dt
		else: node.rotation.y += dr * 1.5 * dt

func _update_camera() -> void:
	cam_node.rotation.y = cam_yaw
	var eye: Vector3 = cam_node.position + Vector3(0, EYE_H, 0)
	var look := Vector3(sin(cam_yaw) * cos(cam_pitch), sin(cam_pitch), cos(cam_yaw) * cos(cam_pitch))
	camera.position = eye
	camera.look_at(eye + look, Vector3.UP)

func _update_marker() -> void:
	var e: Dictionary = entities[sel]
	if e["kind"] == "camera":
		marker.visible = false
		return
	marker.visible = true
	var top := 3.2
	if e["kind"] == "house": top = 5.6
	elif e["kind"] == "foliage": top = 1.0
	marker.position = (e["node"] as Node3D).position + Vector3(0, top + 0.6 + sin(time_ms * 0.006) * 0.15, 0)

# ------------------------------------------------------------------ input
func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		dragging = event.pressed
	elif event is InputEventMouseMotion and dragging and entities[sel]["kind"] == "camera":
		cam_yaw -= event.relative.x * 0.005
		cam_pitch = clampf(cam_pitch - event.relative.y * 0.005, -1.2, 1.0)
	elif event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_SHIFT:
				sel = (sel + 1) % entities.size()
			KEY_TAB:
				sel = (sel - 1 + entities.size()) % entities.size()
			KEY_ENTER, KEY_KP_ENTER:
				if entities[sel]["kind"] == "camera":
					_capture()
			KEY_P:
				_print_positions()

func _capture() -> void:
	hud.visible = false
	marker.visible = false
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.save_png("res://studio_banner.png")
	hud.visible = true
	print("📸 saved  res://studio_banner.png")
	_print_positions()

func _do_autoshot() -> void:
	hud.visible = false
	marker.visible = false
	_update_camera()
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png("res://studio_banner.png")
	print("📸 saved  res://studio_banner.png")
	get_tree().quit()

func _print_positions() -> void:
	print("──────── studio layout ────────")
	print("CAMERA  pos=%s  yaw=%.3f  pitch=%.3f" % [cam_node.position, cam_yaw, cam_pitch])
	for e in entities:
		if e["kind"] == "camera":
			continue
		var n: Node3D = e["node"]
		print("%-10s pos=%s  rotY=%.3f" % [e["name"], n.position, n.rotation.y])

# ------------------------------------------------------------------ hud
func _build_hud() -> void:
	var cl := CanvasLayer.new(); add_child(cl)
	hud = Label.new()
	hud.position = Vector2(12, 10)
	hud.add_theme_font_size_override("font_size", 16)
	hud.add_theme_color_override("font_color", Color(1, 1, 1))
	hud.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	hud.add_theme_constant_override("outline_size", 5)
	cl.add_child(hud)

func _update_hud() -> void:
	var e: Dictionary = entities[sel]
	var line3 := "drag = look   ·   ENTER = take the photo" if e["kind"] == "camera" else "switch to the white Camera to take the photo"
	hud.text = "Controlling:  %s   (%d/%d)\nSHIFT next · TAB prev · WASD move · Q/E turn · R/F up/down · P print\n%s" % [e["name"], sel + 1, entities.size(), line3]
