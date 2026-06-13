extends Node3D
# Throwaway rig check: builds the REAL in-game character (body + procedural legs)
# via MeshLib and renders it front-on with a world-space Y grid, so we can see
# whether the legs meet the body mesh. Optional "walk" arg renders the bob peak.
# Run: godot --path . _rigcheck.tscn -- fire
#      godot --path . _rigcheck.tscn -- water walk

var which := "fire"
var walk := false
var iso := false
var t := 0.0
var done := false

func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a in ["fire", "water", "grass"]: which = a
		if a == "walk": walk = true
		if a == "iso": iso = true

	RenderingServer.set_default_clear_color(Color(0.62, 0.78, 0.92))

	var sun := DirectionalLight3D.new()
	add_child(sun)
	sun.look_at_from_position(Vector3(2.5, 3.5, 4.0), Vector3.ZERO, Vector3.UP)
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.7, 0.7, 0.75)
	e.ambient_light_energy = 1.0
	env.environment = e
	add_child(env)

	var g: CharVisual
	if which == "fire": g = MeshLib.build_flame()
	elif which == "water": g = MeshLib.build_droplet()
	else: g = MeshLib.build_leaf()
	add_child(g)
	if walk:
		g.animate(75.0, 13.0)   # ~peak of the body bob, mid stride
	_report(g)

	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = 4.0
	add_child(cam)
	if iso:
		cam.position = Vector3(2.6, 1.9, 3.2)   # 3/4 view to read forward (z) offset
	else:
		cam.position = Vector3(0, 1.5, 4)
	cam.look_at(Vector3(0, 1.5, 0), Vector3.UP)
	cam.current = true

	var cl := CanvasLayer.new()
	add_child(cl)
	var grid := Grid.new()
	grid.cam_size = cam.size
	grid.cam_y = 1.5
	grid.set_anchors_preset(Control.PRESET_FULL_RECT)
	cl.add_child(grid)

func _report(g: CharVisual) -> void:
	# body mesh world AABB (overall) + underside y sampled near the leg x-columns
	for mi in g.find_children("*", "MeshInstance3D", true, false):
		if mi.mesh == null or mi.material_override == null:
			continue   # skip the dark leg/foot prims (they use material_override too)
	var body_mi: MeshInstance3D = null
	for mi in g.find_children("*", "MeshInstance3D", true, false):
		if mi.mesh and mi.mesh.get_surface_count() > 0 and mi.mesh.get_aabb().size.y > 1.0:
			body_mi = mi
	if body_mi:
		var ab := body_mi.mesh.get_aabb()
		var xf := body_mi.global_transform
		var lo := INF
		var hi := -INF
		for cx in [ab.position.x, ab.position.x + ab.size.x]:
			for cy in [ab.position.y, ab.position.y + ab.size.y]:
				for cz in [ab.position.z, ab.position.z + ab.size.z]:
					var wy := (xf * Vector3(cx, cy, cz)).y
					lo = minf(lo, wy)
					hi = maxf(hi, wy)
		print("BODY world-y: min=%.3f max=%.3f  (scale=%.3f)" % [lo, hi, body_mi.global_transform.basis.get_scale().y])
		# body underside world-y directly above each leg column (x=±gap, z~0)
		var verts: PackedVector3Array = body_mi.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
		for hx in [-0.42, -0.38, -0.32, -0.22, 0.0, 0.22, 0.32, 0.38, 0.42]:
			var under := INF
			for v in verts:
				var w := xf * v
				if absf(w.x - hx) < 0.05 and absf(w.z) < 0.18:
					under = minf(under, w.y)
			if under < INF:
				print("    underside at x=%.2f : y=%.3f" % [hx, under])
	for i in g.legs.size():
		var hip: Node3D = g.legs[i].hip
		print("  leg %d hip world=%s" % [i, str(hip.global_position)])

func _process(delta: float) -> void:
	t += delta
	if t > 0.5 and not done:
		done = true
		var img := get_viewport().get_texture().get_image()
		img.save_png("res://_rig_%s%s%s.png" % [which, "_iso" if iso else "", "_walk" if walk else ""])
		get_tree().quit()

class Grid extends Control:
	var cam_size := 4.0
	var cam_y := 1.5
	func _draw() -> void:
		var W := size.x
		var H := size.y
		var half_v := cam_size / 2.0
		var half_h := half_v * (W / H)
		var font := ThemeDB.fallback_font
		# horizontal lines = world Y
		for i in range(-2, 30):
			var v := i * 0.2
			var sy := H / 2.0 - ((v - cam_y) / half_v) * (H / 2.0)
			var major := (i % 5 == 0)
			var col := Color(0, 0, 0, 0.12)
			if i == 0: col = Color(0.85, 0, 0, 0.7)   # ground (y=0)
			elif major: col = Color(0, 0, 0, 0.32)
			draw_line(Vector2(0, sy), Vector2(W, sy), col, 1.0)
			if major or i == 0:
				draw_string(font, Vector2(6, sy - 3), "y=%.1f" % v, HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color(0.05, 0.05, 0.05))
		# vertical lines = world X
		for i in range(-10, 11):
			var v := i * 0.2
			var sx := W / 2.0 + (v / half_h) * (W / 2.0)
			var col := Color(0, 0, 0, 0.12)
			if i == 0: col = Color(0.85, 0, 0, 0.4)
			elif i % 5 == 0: col = Color(0, 0, 0, 0.3)
			draw_line(Vector2(sx, 0), Vector2(sx, H), col, 1.0)
