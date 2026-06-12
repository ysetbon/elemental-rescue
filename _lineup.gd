extends Node3D
# Throwaway: renders the three elemental characters side by side on a soft
# backdrop and saves docs/characters.png for the README.

var t := 0.0
var done := false

func _ready() -> void:
	RenderingServer.set_default_clear_color(Color(0.85, 0.91, 0.97))

	var sun := DirectionalLight3D.new()
	add_child(sun)
	sun.light_energy = 1.15
	sun.look_at_from_position(Vector3(3.5, 5.0, 6.0), Vector3.ZERO, Vector3.UP)
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.80, 0.84, 0.90)
	e.ambient_light_energy = 1.0
	env.environment = e
	add_child(env)

	# soft ground slab so the characters feel grounded (kept close to the
	# backdrop tone so it reads as a gentle floor rather than a hard white band)
	var ground := MeshLib.box(60, 0.2, 60, MeshLib.lit_mat(MeshLib.rgb(0xc7d6e8)))
	ground.position.y = -0.1
	add_child(ground)

	var order := ["fire", "water", "leaf"]
	var xs := [-2.8, 0.0, 2.8]
	for i in 3:
		var g: CharVisual
		if order[i] == "fire": g = MeshLib.build_flame()
		elif order[i] == "water": g = MeshLib.build_droplet()
		else: g = MeshLib.build_leaf()
		g.position = Vector3(xs[i], 0, 0)
		g.rotation.y = 0.18 * (1 - i)   # slight turn-in toward center
		add_child(g)
		MeshLib.add_blob_shadow(g, 1.25)

	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = 4.7
	add_child(cam)
	cam.position = Vector3(0, 1.55, 9)
	cam.look_at(Vector3(0, 1.45, 0), Vector3.UP)
	cam.current = true

func _process(delta: float) -> void:
	t += delta
	if t > 0.6 and not done:
		done = true
		var img := get_viewport().get_texture().get_image()
		img.save_png("res://docs/characters.png")
		get_tree().quit()
