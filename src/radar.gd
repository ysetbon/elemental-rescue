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
var has_river := true           # false in the sky world
var sky_on := false             # Skyfall Isles: draw isles / bridges / spire rings / the smog circle
var sky_smog_r := 190.0
var sky_el := ""                # local element (its private route is drawn)
var sky_vines := 0              # bitmask of grown seed vines

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

	draw_circle(Vector2(C, C), C - 3.0, Color(1, 1, 1, 0.94) if not sky_on else Color(0.86, 0.91, 0.95, 0.94))
	if sky_on:
		_draw_sky(C, scale, px, pz)
	elif has_river:
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
		if b.has("ping"):
			# the bell ringer: pinged on EVERY radar, clamped to the dial's rim when far away
			var off := Vector2(bp.x - px, bp.y - pz)
			if off.length() > range_:
				off = off.normalized() * range_
			var pp := Vector2(C + off.x * scale, C + off.y * scale)
			var k := fmod(float(b["ping"]), 1.0)
			draw_arc(pp, 4.0 + k * 12.0, 0, TAU, 20, Color(b["color"].r, b["color"].g, b["color"].b, 1.0 - k), 2.0)
			draw_circle(pp, 3.0, b["color"])
			continue
		if Vector2(bp.x - px, bp.y - pz).length() > range_:
			continue
		var p := Vector2(to_x.call(bp.x), to_z.call(bp.y))
		if b.has("shape"):
			if String(b["shape"]) == "cage_shut":
				# a cage whose captive eats you (you cannot open it): just a thin outline
				draw_rect(Rect2(p - Vector2(3.6, 3.6), Vector2(7.2, 7.2)), Color(b["color"].r, b["color"].g, b["color"].b, 0.75), false, 1.4)
			elif String(b["shape"]) == "cage":
				# a cage with a friend inside: a barred square in the captive's colour
				draw_rect(Rect2(p - Vector2(4.5, 4.5), Vector2(9, 9)), Color(1, 1, 1, 0.9))
				draw_rect(Rect2(p - Vector2(3.2, 3.2), Vector2(6.4, 6.4)), b["color"])
				draw_rect(Rect2(p - Vector2(4.5, 4.5), Vector2(9, 9)), Color(0.25, 0.22, 0.3), false, 1.2)
			else:
				# a task marker (stone, Sun Key, beacon, seal): a gold diamond
				var dm := PackedVector2Array([p + Vector2(0, -6.5), p + Vector2(5.2, 0), p + Vector2(0, 6.5), p + Vector2(-5.2, 0)])
				draw_colored_polygon(dm, b["color"])
				dm.append(dm[0])
				draw_polyline(dm, Color.WHITE, 1.4)
			continue
		if b.has("mote"):
			# a Sun Mote: a little four-point star in your colour
			draw_colored_polygon(PackedVector2Array([p + Vector2(0, -5.5), p + Vector2(1.6, -1.6), p + Vector2(5.5, 0), p + Vector2(1.6, 1.6),
				p + Vector2(0, 5.5), p + Vector2(-1.6, 1.6), p + Vector2(-5.5, 0), p + Vector2(-1.6, -1.6)]), b["color"])
			draw_circle(p, 1.6, Color.WHITE)
			continue
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

# Skyfall Isles: the isles, plank bridges, element routes, spire rings and the smog circle.
func _draw_sky(C: float, scale: float, px: float, pz: float) -> void:
	var o := Vector2(C - px * scale, C - pz * scale)     # world origin on the dial
	var lim := range_ + 30.0
	for b in SkyLayout.BRIDGES:
		_sky_line(o, scale, b, Color(0.61, 0.48, 0.32), 2.5, px, pz, lim)
	_sky_line(o, scale, SkyLayout.STREAM, Color(0.43, 0.61, 0.91, 0.8), 3.0, px, pz, lim)
	if sky_el == "grass":
		_sky_line(o, scale, SkyLayout.VINE, Color(0.37, 0.56, 0.24), 1.6, px, pz, lim)
	for i in SkyLayout.SEEDS.size():
		if (sky_vines & (1 << i)) != 0:
			_sky_line(o, scale, SkyLayout.SEEDS[i], Color(0.45, 0.72, 0.3), 1.6, px, pz, lim)
	for is_ in SkyLayout.ISLES:
		if Vector2(is_["x"] - px, is_["z"] - pz).length() > lim + float(is_["r"]):
			continue
		var c := o + Vector2(is_["x"], is_["z"]) * scale
		var fill := Color(0.92, 0.87, 0.77)
		if String(is_["kind"]) == "home":
			var hc: Color = MeshLib.rgb(Game.ELEMENTS[is_["el"]]["color"])
			fill = fill.lerp(hc, 0.35)
		draw_circle(c, float(is_["r"]) * scale, fill)
		draw_arc(c, float(is_["r"]) * scale, 0, TAU, 28, Color(0.55, 0.47, 0.36, 0.8), 1.0)
	# the spire: one ring per tier, the bell platform filled
	if Vector2(px, pz).length() < lim + 26.0:
		for k in SkyLayout.SPIRE_OUTER_R.size():
			draw_arc(o, float(SkyLayout.SPIRE_OUTER_R[k]) * scale, 0, TAU, 28, Color(0.42, 0.36, 0.28, 0.75), 1.0)
		draw_circle(o, float(SkyLayout.SPIRE_OUTER_R[4]) * scale, Color(0.12, 0.56, 0.6, 0.45))
	# the smog sea front (everything outside it is swallowed)
	if sky_smog_r < 186.0:
		draw_arc(o, sky_smog_r * scale, 0, TAU, 64, Color(0.42, 0.37, 0.5, 0.9), 2.0)
		draw_arc(o, (sky_smog_r + 5.0) * scale, 0, TAU, 64, Color(0.42, 0.37, 0.5, 0.35), 5.0)

func _sky_line(o: Vector2, scale: float, s: Dictionary, col: Color, w: float, px: float, pz: float, lim: float) -> void:
	if SkyLayout.seg_dist(px, pz, s["ax"], s["az"], s["bx"], s["bz"]) > lim:
		return
	draw_line(o + Vector2(s["ax"], s["az"]) * scale, o + Vector2(s["bx"], s["bz"]) * scale, col, w)
