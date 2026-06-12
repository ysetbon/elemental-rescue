class_name GameUI
extends CanvasLayer
# All on-screen UI: start screen with element cards, HUD, radar, toast,
# countdown and the end-of-round standings. Built entirely in code.

signal element_selected(el: String)
signal play_again()

const UI_COLORS := { "fire": 0xf0541a, "water": 0x5d93e8, "grass": 0x55b06a }
const TEXT := Color(0.227, 0.208, 0.314)

var bg: TextureRect
var start_root: Control
var end_root: Control
var hud_root: Control
var radar: RadarControl

var timer_label: Label
var board_box: HBoxContainer
var board_labels := {}
var role_label: Label
var cave_label: Label
var stam_fill: ColorRect
var toast_label: Label
var countdown_label: Label
var end_title: Label
var standings_box: VBoxContainer
var end_sub: Label

var _toast_timer := 0.0

func _ready() -> void:
	layer = 10
	_build_background()
	_build_start()
	_build_hud()
	_build_radar()
	_build_toast_countdown()
	_build_end()
	# HUD / radar / overlays must not eat mouse so drag-look works over them
	for n in [hud_root, radar, toast_label, countdown_label]:
		_ignore_mouse(n)
	show_start()

func _ignore_mouse(n: Node) -> void:
	if n is Control:
		(n as Control).mouse_filter = Control.MOUSE_FILTER_IGNORE
	for c in n.get_children():
		_ignore_mouse(c)

func _process(delta: float) -> void:
	if _toast_timer > 0.0:
		_toast_timer -= delta
		if _toast_timer <= 0.0:
			toast_label.modulate.a = 0.0

# --------------------------------------------------------------- builders
func _twilight_gradient() -> GradientTexture2D:
	var grad := Gradient.new()
	grad.offsets = PackedFloat32Array([0.0, 0.25, 0.42, 0.5, 0.55, 0.62, 1.0])
	grad.colors = PackedColorArray([
		_c(0x5f64cc), _c(0x7577d2), _c(0x9486d6), _c(0xc79fd0),
		_c(0xeab3c4), _c(0xf8d2c6), _c(0xf8d8cc)])
	var tex := GradientTexture2D.new()
	tex.gradient = grad
	tex.width = 8
	tex.height = 256
	tex.fill_from = Vector2(0, 0)
	tex.fill_to = Vector2(0, 1)
	return tex

func _c(h: int) -> Color:
	return Color8((h >> 16) & 0xff, (h >> 8) & 0xff, h & 0xff, 255)

func _build_background() -> void:
	bg = TextureRect.new()
	bg.texture = _twilight_gradient()
	bg.stretch_mode = TextureRect.STRETCH_SCALE
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

func _make_label(text: String, size: int, col: Color = TEXT) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", col)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	return l

func _build_start() -> void:
	start_root = Control.new()
	start_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(start_root)
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	start_root.add_child(center)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 18)
	v.alignment = BoxContainer.ALIGNMENT_CENTER
	center.add_child(v)

	var title := _make_label("ELEMENTAL TAG", 54, _c(0xfff1e0))
	v.add_child(title)
	var tag := _make_label(
		"A huge twilight world — a river, a sleepy pastel town, caves, a school, a playground,\neven a zoo — a points war between three elements while CO₂ hunts everyone.",
		16, Color(1, 1, 1, 0.92))
	v.add_child(tag)

	var cards := HBoxContainer.new()
	cards.add_theme_constant_override("separation", 16)
	cards.alignment = BoxContainer.ALIGNMENT_CENTER
	v.add_child(cards)
	_add_card(cards, "fire", "FIRE", "catches Leaf\nflees Water")
	_add_card(cards, "water", "WATER", "catches Fire\nflees Leaf\nswims full speed")
	_add_card(cards, "grass", "LEAF", "catches Water\nflees Fire")

	var hint := _make_label(
		"O₂ ×6 = +5 pts (no respawns)   ·   CO₂ ×3 hunts every element   ·   prey catch = +15\n"
		+ "Home caves: only you enter yours, safe 30s then ejected + 10s lockout   ·   Grey caves block CO₂\n"
		+ "School breaks line of sight   ·   River slows everyone but Water (three bridges)\n"
		+ "WASD move   ·   Shift sprint   ·   drag mouse to look   ·   most points when the clock ends wins.",
		13, Color(1, 1, 1, 0.85))
	v.add_child(hint)

func _add_card(parent: Node, el: String, name_: String, rel: String) -> void:
	var btn := Button.new()
	btn.custom_minimum_size = Vector2(160, 150)
	var col := _c(UI_COLORS[el])
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(1, 1, 1, 0.93)
	sb.set_corner_radius_all(18)
	sb.set_border_width_all(3)
	sb.border_color = col
	btn.add_theme_stylebox_override("normal", sb)
	var sb_h := sb.duplicate()
	sb_h.bg_color = Color(1, 1, 1, 1.0)
	btn.add_theme_stylebox_override("hover", sb_h)
	btn.add_theme_stylebox_override("pressed", sb_h)
	btn.add_theme_color_override("font_color", TEXT)
	btn.add_theme_color_override("font_hover_color", col)
	btn.add_theme_color_override("font_pressed_color", col)
	btn.add_theme_font_size_override("font_size", 16)
	btn.text = name_ + "\n\n" + rel
	btn.autowrap_mode = TextServer.AUTOWRAP_WORD
	btn.pressed.connect(func() -> void: element_selected.emit(el))
	parent.add_child(btn)

func _build_hud() -> void:
	hud_root = Control.new()
	hud_root.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	hud_root.position = Vector2(12, 12)
	add_child(hud_root)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)
	hud_root.add_child(v)

	timer_label = _pill(v)
	timer_label.add_theme_font_size_override("font_size", 20)
	timer_label.text = "Time 4:00"

	var board_pill := _pill_panel(v)
	board_box = HBoxContainer.new()
	board_box.add_theme_constant_override("separation", 12)
	board_pill.add_child(board_box)
	for el in ["fire", "water", "grass"]:
		var lbl := _make_label("", 15, _c(UI_COLORS[el]))
		board_labels[el] = lbl
		board_box.add_child(lbl)

	role_label = _pill(v)
	role_label.text = ""
	cave_label = _pill(v)
	cave_label.visible = false

	var stam_pill := _pill_panel(v)
	var sv := VBoxContainer.new()
	stam_pill.add_child(sv)
	sv.add_child(_make_label_left("Sprint", 13))
	var track := ColorRect.new()
	track.color = Color(0.227, 0.208, 0.314, 0.14)
	track.custom_minimum_size = Vector2(170, 8)
	sv.add_child(track)
	stam_fill = ColorRect.new()
	stam_fill.color = _c(0xf0541a)
	stam_fill.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	stam_fill.size = Vector2(170, 8)
	track.add_child(stam_fill)

func _make_label_left(text: String, size: int, col: Color = TEXT) -> Label:
	var l := _make_label(text, size, col)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	return l

func _pill_panel(parent: Node) -> PanelContainer:
	var p := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(1, 1, 1, 0.9)
	sb.set_corner_radius_all(12)
	sb.content_margin_left = 14; sb.content_margin_right = 14
	sb.content_margin_top = 8; sb.content_margin_bottom = 8
	p.add_theme_stylebox_override("panel", sb)
	parent.add_child(p)
	return p

func _pill(parent: Node) -> Label:
	var p := _pill_panel(parent)
	var l := _make_label_left("", 14)
	p.add_child(l)
	return l

func _build_radar() -> void:
	radar = RadarControl.new()
	radar.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	radar.position = Vector2(-152, 12)
	add_child(radar)

func _build_toast_countdown() -> void:
	toast_label = _make_label("", 16)
	toast_label.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	toast_label.position = Vector2(0, 64)
	toast_label.modulate.a = 0.0
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(1, 1, 1, 0.92)
	sb.set_corner_radius_all(12)
	sb.set_content_margin_all(10)
	toast_label.add_theme_stylebox_override("normal", sb)
	add_child(toast_label)

	countdown_label = _make_label("", 110, Color.WHITE)
	countdown_label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	countdown_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	add_child(countdown_label)

func _build_end() -> void:
	end_root = Control.new()
	end_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(end_root)
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	end_root.add_child(center)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 18)
	v.alignment = BoxContainer.ALIGNMENT_CENTER
	center.add_child(v)
	end_title = _make_label("", 60, Color.WHITE)
	v.add_child(end_title)
	standings_box = VBoxContainer.new()
	standings_box.add_theme_constant_override("separation", 8)
	v.add_child(standings_box)
	end_sub = _make_label("", 16, Color(1, 1, 1, 0.92))
	v.add_child(end_sub)
	var btn := Button.new()
	btn.text = "Play again"
	btn.custom_minimum_size = Vector2(200, 56)
	btn.add_theme_font_size_override("font_size", 18)
	var sb := StyleBoxFlat.new()
	sb.bg_color = _c(0xf2a55a)
	sb.set_corner_radius_all(14)
	btn.add_theme_stylebox_override("normal", sb)
	btn.add_theme_color_override("font_color", _c(0x5a3a20))
	btn.pressed.connect(func() -> void: play_again.emit())
	var hb := HBoxContainer.new()
	hb.alignment = BoxContainer.ALIGNMENT_CENTER
	hb.add_child(btn)
	v.add_child(hb)

# --------------------------------------------------------------- screen state
func show_start() -> void:
	bg.visible = true
	start_root.visible = true
	end_root.visible = false
	hud_root.visible = false
	radar.visible = false
	countdown_label.text = ""

func show_hud() -> void:
	bg.visible = false
	start_root.visible = false
	end_root.visible = false
	hud_root.visible = true
	radar.visible = true

func show_end(rows: Array, title: String, sub: String) -> void:
	bg.visible = true
	end_root.visible = true
	hud_root.visible = false
	radar.visible = false
	start_root.visible = false
	end_title.text = title
	end_sub.text = sub
	for c in standings_box.get_children():
		c.queue_free()
	for r in rows:
		var row := PanelContainer.new()
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color(1, 1, 1, 0.88)
		sb.set_corner_radius_all(12)
		sb.set_content_margin_all(10)
		if r["me"]:
			sb.set_border_width_all(2)
			sb.border_color = _c(0xf2a23c)
		row.add_theme_stylebox_override("panel", sb)
		var hb := HBoxContainer.new()
		hb.custom_minimum_size = Vector2(260, 0)
		row.add_child(hb)
		var nm := _make_label_left((("★ " if r["winner"] else "") + r["label"] + ("" if r["alive"] else "  (out)")), 18, r["color"])
		nm.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		hb.add_child(nm)
		var sc := _make_label(str(r["score"]) + " pts", 18, TEXT)
		hb.add_child(sc)
		standings_box.add_child(row)

# --------------------------------------------------------------- live updates
func set_timer(text: String) -> void:
	timer_label.text = text

func set_board(entries: Array) -> void:
	for e in entries:
		var lbl: Label = board_labels[e["el"]]
		lbl.text = e["label"] + " " + str(e["score"])
		lbl.modulate.a = 1.0 if e["alive"] else 0.35
		if e["me"]:
			lbl.add_theme_color_override("font_color", _c(0xf2a23c))
		else:
			lbl.add_theme_color_override("font_color", _c(UI_COLORS[e["el"]]))

func set_role(text: String) -> void:
	role_label.text = text

func set_cave(text: String) -> void:
	cave_label.visible = text != ""
	cave_label.text = text

func set_stamina(pct: float) -> void:
	stam_fill.size.x = 170.0 * clampf(pct, 0.0, 100.0) / 100.0

func toast(msg: String) -> void:
	toast_label.text = msg
	toast_label.modulate.a = 1.0
	_toast_timer = 1.9

func set_countdown(text: String) -> void:
	countdown_label.text = text
