extends Node3D
# Throwaway inspection scene: renders one GLB flat-on (orthographic, lit) with a
# model-space coordinate grid so we can read off exact feature positions.
# Run: godot --path . _inspect.tscn -- fire        (front view)
#      godot --path . _inspect.tscn -- fire side   (side view, shows Z depth)

const MODELS := { "fire": "res://archive/old_models/Fire.glb", "water": "res://archive/old_models/Water.glb", "grass": "res://archive/old_models/Leaf.glb", "leaf2": "res://archive/old_models/Leaf2.glb" }

var which := "fire"
var side := false
var t := 0.0
var done := false

func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if MODELS.has(a): which = a
		if a == "side": side = true

	RenderingServer.set_default_clear_color(Color(0.95, 0.95, 0.97))

	var sun := DirectionalLight3D.new()
	add_child(sun)
	sun.look_at_from_position(Vector3(2.5, 3.0, 4.0), Vector3.ZERO, Vector3.UP)
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.65, 0.65, 0.7)
	e.ambient_light_energy = 1.0
	env.environment = e
	add_child(env)

	var inst: Node3D = load(MODELS[which]).instantiate()
	add_child(inst)
	if which == "leaf2":
		# apply the real leg-swing shader so we can see what counts as a "leg".
		# tokens: ampNN (amp*100), phaseNN (phase*100), legtopNN (-leg_top*100)
		var amp := 0.0
		var phase := 0.0
		var leg_top := -0.5
		for a in OS.get_cmdline_user_args():
			if a.begins_with("amp"): amp = float(a.substr(3)) / 100.0
			elif a.begins_with("phase"): phase = float(a.substr(5)) / 100.0
			elif a.begins_with("legtop"): leg_top = -float(a.substr(6)) / 100.0
		var albedo_tex: Texture2D = null
		var emis_tex: Texture2D = null
		for child in inst.find_children("*", "MeshInstance3D", true, false):
			var mi := child as MeshInstance3D
			var src: Material = mi.mesh.surface_get_material(0) if mi.mesh else null
			if src == null: src = mi.get_active_material(0)
			if src is BaseMaterial3D:
				albedo_tex = (src as BaseMaterial3D).albedo_texture
				if (src as BaseMaterial3D).emission_enabled:
					emis_tex = (src as BaseMaterial3D).emission_texture
			var sm := ShaderMaterial.new()
			sm.shader = MeshLib._tex_leg_shader()
			sm.set_shader_parameter("tex_albedo", albedo_tex)
			if emis_tex: sm.set_shader_parameter("tex_emis", emis_tex)
			sm.set_shader_parameter("emis_energy", 0.0)
			sm.set_shader_parameter("leg_top", leg_top)
			sm.set_shader_parameter("hip_y", -0.55)
			sm.set_shader_parameter("hip_z", -0.2)
			sm.set_shader_parameter("u_phase", phase)
			sm.set_shader_parameter("u_amp", amp)
			mi.material_override = sm
		_finish_setup()
		return
	# simple lit material so the sculpted eyes/smile/legs are clearly visible
	var sh := Shader.new()
	sh.code = """
shader_type spatial;
render_mode cull_disabled;
varying vec3 vp;
void vertex() { vp = VERTEX; }
void fragment() {
	vec3 n = normalize(cross(dFdx(vp), dFdy(vp)));
	float l = clamp(dot(n, normalize(vec3(0.35,0.7,0.6)))*0.5+0.5, 0.0, 1.0);
	ALBEDO = vec3(0.85,0.55,0.25) * (0.35 + 0.75*l);
}
"""
	for child in inst.find_children("*", "MeshInstance3D", true, false):
		var mat := ShaderMaterial.new()
		mat.shader = sh
		(child as MeshInstance3D).material_override = mat
	_finish_setup()

func _finish_setup() -> void:
	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = 2.2
	add_child(cam)
	if side:
		cam.position = Vector3(3, 0, 0)
	else:
		cam.position = Vector3(0, 0, 3)
	cam.look_at(Vector3.ZERO, Vector3.UP)
	cam.current = true

	var cl := CanvasLayer.new()
	add_child(cl)
	var grid := Grid.new()
	grid.cam_size = cam.size
	grid.side = side
	grid.which = which
	grid.set_anchors_preset(Control.PRESET_FULL_RECT)
	cl.add_child(grid)

func _process(delta: float) -> void:
	t += delta
	if t > 0.7 and not done:
		done = true
		var img := get_viewport().get_texture().get_image()
		img.save_png("res://_grid_%s%s.png" % [which, "_side" if side else ""])
		get_tree().quit()

class Grid extends Control:
	var cam_size := 2.2
	var side := false
	var which := "fire"
	func _draw() -> void:
		var W := size.x
		var H := size.y
		var half_v := cam_size / 2.0
		var half_h := half_v * (W / H)
		var font := ThemeDB.fallback_font
		# vertical lines = model X (front) or Z (side)
		for i in range(-10, 11):
			var v := i * 0.1
			var sx := W / 2.0 + (v / half_h) * (W / 2.0)
			var major := (i % 2 == 0)
			var col := Color(0, 0, 0, 0.12)
			if i == 0: col = Color(0.85, 0, 0, 0.6)
			elif major: col = Color(0, 0, 0, 0.3)
			draw_line(Vector2(sx, 0), Vector2(sx, H), col, 1.0)
			if major:
				var lbl := ("z=%.1f" if side else "x=%.1f") % v
				draw_string(font, Vector2(sx + 2, H - 8), lbl, HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color(0.1, 0.1, 0.1))
		# horizontal lines = model Y (height)
		for i in range(-10, 11):
			var v := i * 0.1
			var sy := H / 2.0 - (v / half_v) * (H / 2.0)
			var major := (i % 2 == 0)
			var col := Color(0, 0, 0, 0.12)
			if i == 0: col = Color(0.85, 0, 0, 0.6)
			elif major: col = Color(0, 0, 0, 0.3)
			draw_line(Vector2(0, sy), Vector2(W, sy), col, 1.0)
			if major:
				draw_string(font, Vector2(6, sy - 3), "y=%.1f" % v, HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color(0.1, 0.1, 0.1))
		var title := "%s  —  %s view (red = center, grid = 0.1 units)" % [which, "SIDE" if side else "FRONT"]
		draw_string(font, Vector2(W / 2.0 - 180, 22), title, HORIZONTAL_ALIGNMENT_LEFT, -1, 18, Color(0.1, 0.1, 0.1))
