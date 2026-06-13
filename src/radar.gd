class_name RadarControl
extends Control
# Top-right circular minimap. Recreates the canvas radar from the prototype.

var range_ := 70.0
var river_x1 := 2.0
var river_x2 := 14.0
var bridges: Array = []
var caves: Array = []           # [{ "x","z","r","fill":Color }, ...]

var player_pos := Vector2.ZERO
var player_yaw := 0.0
var blips: Array = []           # [{ "pos":Vector2, "color":Color, "o2":bool }, ...]

func setup(rx1: float, rx2: float, brs: Array, cvs: Array) -> void:
	river_x1 = rx1
	river_x2 = rx2
	bridges = brs
	caves = cvs
	custom_minimum_size = Vector2(140, 140)
	size = Vector2(140, 140)

func update_data(ppos: Vector2, pyaw: float, b: Array) -> void:
	player_pos = ppos
	player_yaw = pyaw
	blips = b
	queue_redraw()

func _draw() -> void:
	var W := 140.0
	var C := W / 2.0
	var scale := (C - 8.0) / range_
	var px := player_pos.x
	var pz := player_pos.y
	var to_x := func(wx: float) -> float: return C + (wx - px) * scale
	var to_z := func(wz: float) -> float: return C + (wz - pz) * scale

	draw_circle(Vector2(C, C), C - 3.0, Color(1, 1, 1, 0.94))
	# river band (clamped vertically so it stays inside the dial)
	var rx: float = to_x.call(river_x1)
	var rw := (river_x2 - river_x1) * scale
	draw_rect(Rect2(rx, 3, rw, W - 6), Color(0.741, 0.824, 0.937))
	# bridges
	for br in bridges:
		var half: float = br["half"]
		draw_rect(Rect2(rx - 2, to_z.call(br["z"] - half), rw + 4, half * 2.0 * scale), Color(0.812, 0.71, 0.604))
	# caves
	for c in caves:
		var d := Vector2(c["x"] - px, c["z"] - pz).length()
		if d > range_ + c["r"]:
			continue
		var cc: Color = c["fill"]
		draw_circle(Vector2(to_x.call(c["x"]), to_z.call(c["z"])), c["r"] * scale, Color(cc.r, cc.g, cc.b, 0.33))
		draw_arc(Vector2(to_x.call(c["x"]), to_z.call(c["z"])), c["r"] * scale, 0, TAU, 24, cc, 1.5)
	# actors
	for b in blips:
		var bp: Vector2 = b["pos"]
		if Vector2(bp.x - px, bp.y - pz).length() > range_:
			continue
		var p := Vector2(to_x.call(bp.x), to_z.call(bp.y))
		var rad := 3.0 if b["o2"] else 4.2
		draw_circle(p, rad, b["color"])
		if b["o2"]:
			draw_arc(p, rad, 0, TAU, 12, Color(0.604, 0.596, 0.659), 1.0)
	# player arrow at centre, pointing toward facing
	var ang := atan2(sin(player_yaw), -cos(player_yaw))
	var pts := PackedVector2Array([Vector2(0, -7.5), Vector2(5.5, 5.5), Vector2(-5.5, 5.5)])
	var rot := Transform2D(ang, Vector2(C, C))
	var tp := PackedVector2Array()
	for p in pts:
		tp.append(rot * p)
	draw_colored_polygon(tp, Color(0.949, 0.635, 0.235))
	var outline := tp.duplicate()
	outline.append(tp[0])
	draw_polyline(outline, Color.WHITE, 1.5)
	# dial border
	draw_arc(Vector2(C, C), C - 3.0, 0, TAU, 48, Color(0.227, 0.208, 0.314, 0.25), 2.0)
