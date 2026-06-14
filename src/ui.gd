class_name GameUI
extends CanvasLayer
# All on-screen UI: start screen with element cards, HUD, radar, toast,
# countdown and the end-of-round standings. Built entirely in code.

signal element_selected(el: String)
signal play_again()
signal task_assigned(task: String)

# --- online multiplayer ---
signal online_pressed()                                  # start screen → open online panel
signal host_requested(player_name: String)               # online panel → host a new room
signal join_requested(player_name: String, code: String) # online panel → join a room
signal back_pressed()                                     # online/lobby → back to start
signal lobby_element_picked(el: String)                  # lobby → pick / change element
signal lobby_start_pressed()                             # lobby → admin starts the match
signal copy_invite_pressed()                             # lobby → copy a shareable invite link

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
var hearts_box: HBoxContainer
var hearts_tex: Texture2D
var status_label: Label
var channel_box: PanelContainer
var channel_label: Label
var channel_fill: ColorRect
var stam_fill: ColorRect
var toast_label: Label
var countdown_label: Label
var end_title: Label
var standings_box: VBoxContainer
var end_sub: Label

var task_root: Control
var task_icons: Array = []        # [TextureRect] one per task button

# --- online panel + lobby ---
var online_root: Control
var lobby_root: Control
var online_name: LineEdit
var online_code: LineEdit
var online_status: Label
var lobby_code_label: Label
var lobby_list: VBoxContainer
var lobby_start_btn: Button
var _icon_viewports: Array = []   # SubViewports backing the icons (freed on re-setup)

var _toast_timer := 0.0

# Set by Game before the node enters the tree: on phones the HUD + clan task
# buttons are drawn twice as large so they're readable / tappable.
var mobile := false

func _ready() -> void:
	layer = 10
	_build_background()
	_build_start()
	_build_online()
	_build_lobby()
	_build_hud()
	_build_radar()
	_build_toast_countdown()
	_build_end()
	_build_task_buttons()
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

	var title := _make_label("ELEMENTAL RESCUE", 54, _c(0xfff1e0))
	v.add_child(title)
	var tag := _make_label(
		"Your twin is locked in a zoo cage. Find your key, free them, and walk them home\nto your cave — while your rival and CO₂ try to send you back. Pick your element:",
		16, Color(1, 1, 1, 0.92))
	v.add_child(tag)

	var cards := HBoxContainer.new()
	cards.add_theme_constant_override("separation", 16)
	cards.alignment = BoxContainer.ALIGNMENT_CENTER
	v.add_child(cards)
	_add_card(cards, "fire", "FIRE", "catches Leaf\nflees Water")
	_add_card(cards, "water", "WATER", "catches Fire\nflees Leaf\nswims full speed")
	_add_card(cards, "grass", "LEAF", "catches Water\nflees Fire")

	var online_btn := _action_button("🌐  PLAY ONLINE WITH FRIENDS", 360, 50)
	online_btn.pressed.connect(func() -> void: online_pressed.emit())
	v.add_child(_center(online_btn))

	var hint := _make_label(
		"Hearts: a touch from your rival or CO₂ costs a heart — at zero you're sent home (you're never out)\n"
		+ "Training totem by your cave: earn an extra heart   ·   Clan hall: teach 20s for a clan of 10, then click them to assign tasks\n"
		+ "Whoever hits you (or your clan) is slowed 5s   ·   each element has its own colour-matched key — only you can take yours\n"
		+ "Find your key → free your twin at its cage → lead it into your cave to WIN\n"
		+ "Grab a black stone (Pac-Man power-up): chase & eat your predator, CO₂ ignore you — but O₂ hunt you\n"
		+ "Sip white O₂ to supercharge your sprint (slower drain, faster recovery)\n"
		+ "WASD move   ·   Shift sprint   ·   drag mouse to look",
		13, Color(1, 1, 1, 0.85))
	v.add_child(hint)

func _add_card(parent: Node, el: String, name_: String, rel: String, online := false) -> void:
	var s := 2.0 if mobile else 1.0   # phones get twice-as-big tappable element cards
	var btn := Button.new()
	btn.custom_minimum_size = Vector2(160, 150) * s
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
	btn.add_theme_font_size_override("font_size", int(16 * s))
	btn.text = name_ + "\n\n" + rel
	btn.autowrap_mode = TextServer.AUTOWRAP_WORD
	if online:
		btn.pressed.connect(func() -> void: lobby_element_picked.emit(el))
	else:
		btn.pressed.connect(func() -> void: element_selected.emit(el))
	parent.add_child(btn)

# --------------------------------------------------------- online UI helpers
func _action_button(text: String, w: int = 240, h: int = 52, bg: int = 0xf2a55a, fg: int = 0x5a3a20) -> Button:
	var s := 1.5 if mobile else 1.0
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(w, h) * s
	var sb := StyleBoxFlat.new()
	sb.bg_color = _c(bg)
	sb.set_corner_radius_all(14)
	sb.set_content_margin_all(8)
	b.add_theme_stylebox_override("normal", sb)
	var sbh := sb.duplicate()
	sbh.bg_color = _c(bg).lightened(0.12)
	b.add_theme_stylebox_override("hover", sbh)
	b.add_theme_stylebox_override("pressed", sbh)
	var sbd := sb.duplicate()
	sbd.bg_color = Color(0.5, 0.5, 0.55, 0.6)
	b.add_theme_stylebox_override("disabled", sbd)
	b.add_theme_color_override("font_color", _c(fg))
	b.add_theme_color_override("font_hover_color", _c(fg))
	b.add_theme_color_override("font_pressed_color", _c(fg))
	b.add_theme_font_size_override("font_size", int(18 * s))
	return b

func _line_edit(placeholder: String, maxlen: int = 0) -> LineEdit:
	var s := 1.5 if mobile else 1.0
	var le := LineEdit.new()
	le.placeholder_text = placeholder
	le.alignment = HORIZONTAL_ALIGNMENT_CENTER
	le.custom_minimum_size = Vector2(260, 44) * s
	le.add_theme_font_size_override("font_size", int(18 * s))
	if maxlen > 0:
		le.max_length = maxlen
	return le

# center a fixed-size control inside a VBoxContainer (which otherwise stretches children)
func _center(c: Control) -> Control:
	c.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	return c

func _build_online() -> void:
	online_root = Control.new()
	online_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	online_root.visible = false
	add_child(online_root)
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	online_root.add_child(center)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 14)
	v.alignment = BoxContainer.ALIGNMENT_CENTER
	center.add_child(v)
	v.add_child(_make_label("PLAY ONLINE", 46, _c(0xfff1e0)))
	v.add_child(_make_label(
		"Host a game and share the code with up to 6 friends,\nor join with a code someone sent you.",
		16, Color(1, 1, 1, 0.9)))
	online_name = _line_edit("Your name", 16)
	v.add_child(_center(online_name))
	var hostb := _action_button("HOST NEW GAME", 260)
	hostb.pressed.connect(func() -> void: host_requested.emit(online_name.text))
	v.add_child(_center(hostb))
	v.add_child(_make_label("— or —", 14, Color(1, 1, 1, 0.7)))
	online_code = _line_edit("Enter code", 8)
	v.add_child(_center(online_code))
	var joinb := _action_button("JOIN GAME", 260, 52, 0x5d93e8, 0xffffff)
	joinb.pressed.connect(func() -> void: join_requested.emit(online_name.text, online_code.text))
	v.add_child(_center(joinb))
	online_status = _make_label("", 15, _c(0xffd9b0))
	v.add_child(online_status)
	var backb := _action_button("← BACK", 150, 44, 0x6a6276, 0xffffff)
	backb.pressed.connect(func() -> void: back_pressed.emit())
	v.add_child(_center(backb))

func _build_lobby() -> void:
	lobby_root = Control.new()
	lobby_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	lobby_root.visible = false
	add_child(lobby_root)
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	lobby_root.add_child(center)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 12)
	v.alignment = BoxContainer.ALIGNMENT_CENTER
	center.add_child(v)
	lobby_code_label = _make_label("ROOM —", 44, _c(0xfff1e0))
	v.add_child(lobby_code_label)
	var copyb := _action_button("🔗 COPY INVITE LINK", 300, 46, 0x5db0a0, 0xffffff)
	copyb.pressed.connect(func() -> void: copy_invite_pressed.emit())
	v.add_child(_center(copyb))
	v.add_child(_make_label(
		"Send the link (or the code above) to up to 6 friends — they tap it to join.\n"
		+ "Pick your element (you can all pick the same one); NPCs fill the other teams so it stays fair.",
		15, Color(1, 1, 1, 0.9)))
	var cards := HBoxContainer.new()
	cards.add_theme_constant_override("separation", 14)
	cards.alignment = BoxContainer.ALIGNMENT_CENTER
	v.add_child(cards)
	_add_card(cards, "fire", "FIRE", "catches Leaf\nflees Water", true)
	_add_card(cards, "water", "WATER", "catches Fire\nflees Leaf", true)
	_add_card(cards, "grass", "LEAF", "catches Water\nflees Fire", true)
	lobby_list = VBoxContainer.new()
	lobby_list.add_theme_constant_override("separation", 4)
	lobby_list.alignment = BoxContainer.ALIGNMENT_CENTER
	v.add_child(lobby_list)
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 14)
	v.add_child(row)
	lobby_start_btn = _action_button("START GAME", 220, 56, 0x55b06a, 0xffffff)
	lobby_start_btn.pressed.connect(func() -> void: lobby_start_pressed.emit())
	row.add_child(lobby_start_btn)
	var leaveb := _action_button("LEAVE", 150, 56, 0x6a6276, 0xffffff)
	leaveb.pressed.connect(func() -> void: back_pressed.emit())
	row.add_child(leaveb)

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
	timer_label.text = "Find your key"

	# hearts = a row of little element-figure icons (filled = colour, empty = faded)
	var hearts_pill := _pill_panel(v)
	var hrow := HBoxContainer.new()
	hrow.add_theme_constant_override("separation", 5)
	hearts_pill.add_child(hrow)
	var hlbl := _make_label_left("Lives", 15)
	hrow.add_child(hlbl)
	hearts_box = HBoxContainer.new()
	hearts_box.add_theme_constant_override("separation", 3)
	hrow.add_child(hearts_box)

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
	status_label = _pill(v)
	status_label.text = ""
	cave_label = _pill(v)
	cave_label.visible = false

	# channel bar (self-training / clan teaching progress)
	channel_box = _pill_panel(v)
	channel_box.visible = false
	var cv := VBoxContainer.new()
	channel_box.add_child(cv)
	channel_label = _make_label_left("", 13)
	cv.add_child(channel_label)
	var ctrack := ColorRect.new()
	ctrack.color = Color(0.227, 0.208, 0.314, 0.14)
	ctrack.custom_minimum_size = Vector2(170, 8)
	cv.add_child(ctrack)
	channel_fill = ColorRect.new()
	channel_fill.color = _c(0x49b36a)
	channel_fill.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	channel_fill.size = Vector2(0, 8)
	ctrack.add_child(channel_fill)

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

	if mobile:
		hud_root.scale = Vector2(2, 2)   # grows down-right from the top-left corner

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

# --------------------------------------------------------- clan task buttons
const TASK_DEFS := [
	{ "task": "protect", "label": "Protect me" },
	{ "task": "attack", "label": "Attack prey" },
	{ "task": "fetch", "label": "Fetch key" },
]

func _build_task_buttons() -> void:
	var s := 2.0 if mobile else 1.0   # phones get twice-as-big tappable buttons
	task_root = Control.new()
	task_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	task_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(task_root)
	# centred horizontally, near the top so they're easy to reach
	var cc := CenterContainer.new()
	cc.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	cc.offset_top = 84.0
	cc.offset_bottom = 84.0 + 130.0 * s
	cc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	task_root.add_child(cc)
	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", int(14 * s))
	hb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cc.add_child(hb)
	for def in TASK_DEFS:
		var btn := Button.new()
		btn.custom_minimum_size = Vector2(78, 90) * s
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color(1, 1, 1, 0.94)
		sb.set_corner_radius_all(int(14 * s))
		sb.set_border_width_all(int(2 * s))
		sb.border_color = _c(0xf2a23c)
		btn.add_theme_stylebox_override("normal", sb)
		var sb_h := sb.duplicate(); sb_h.bg_color = Color(1, 1, 1, 1.0)
		btn.add_theme_stylebox_override("hover", sb_h)
		btn.add_theme_stylebox_override("pressed", sb_h)
		var t: String = def["task"]
		btn.pressed.connect(func() -> void: task_assigned.emit(t))
		# figure icon (filled in by setup_task_icons)
		var icon := TextureRect.new()
		icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
		icon.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		icon.offset_bottom = -20.0 * s
		btn.add_child(icon)
		task_icons.append(icon)
		# tiny caption
		var lbl := _make_label(def["label"], int(11 * s), TEXT)
		lbl.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
		lbl.offset_top = -18.0 * s
		lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		btn.add_child(lbl)
		hb.add_child(btn)
	task_root.visible = false

func show_task_buttons(on: bool) -> void:
	if task_root:
		task_root.visible = on

# Render the real game figures into the three button icons (with legs, as before),
# and the player's own figure — front view, legs stripped — as the life icon.
func setup_task_icons(my_el: String, predator_el: String, prey_el: String) -> void:
	for v in _icon_viewports:
		if is_instance_valid(v): v.queue_free()
	_icon_viewports.clear()
	if task_icons.size() >= 3:
		task_icons[0].texture = _figure_icon([_el_model(predator_el), MeshLib.build_co2()], false).get_texture()
		task_icons[1].texture = _figure_icon([_el_model(prey_el)], false).get_texture()
		var key := MeshLib.key_node(_c(UI_COLORS[my_el]))
		key.position.y = 1.25; key.scale = Vector3.ONE * 1.5
		task_icons[2].texture = _figure_icon([key], false).get_texture()
	# your own figure, front-facing, WITHOUT its legs/feet → the life icon
	hearts_tex = _figure_icon([_el_model(my_el)], true).get_texture()

func _el_model(el: String) -> Node3D:
	if el == "fire": return MeshLib.build_flame()
	if el == "water": return MeshLib.build_droplet()
	return MeshLib.build_leaf()

# A small transparent 3D viewport that frames the figure(s) facing the camera.
func _figure_icon(models: Array, strip_legs: bool) -> SubViewport:
	var vp := SubViewport.new()
	vp.size = Vector2i(160, 160)
	vp.transparent_bg = true
	vp.own_world_3d = true
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(vp)
	var root := Node3D.new()
	vp.add_child(root)
	var we := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_CLEAR_COLOR
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.86, 0.87, 0.93)
	env.ambient_light_energy = 1.6
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	we.environment = env
	root.add_child(we)
	var sun := DirectionalLight3D.new()
	sun.light_energy = 1.15
	root.add_child(sun)
	sun.look_at_from_position(Vector3(-3, 5, 4), Vector3.ZERO, Vector3.UP)
	var n := models.size()
	for i in n:
		var m: Node3D = models[i]
		if strip_legs:
			_strip_legs(m)
		m.position.x = (float(i) - (n - 1) / 2.0) * 1.95
		m.rotation.y = 0.0                       # face +Z, toward the camera
		if n > 1: m.scale *= 0.82
		root.add_child(m)
	var cam := Camera3D.new()
	cam.fov = 34
	root.add_child(cam)
	cam.look_at_from_position(Vector3(0, 1.5, 6.0), Vector3(0, 1.35, 0), Vector3.UP)
	_icon_viewports.append(vp)
	return vp

# Hide a character's procedural legs/arms so it reads as a clean front portrait.
func _strip_legs(m: Node3D) -> void:
	if not (m is CharVisual):
		return
	var cv := m as CharVisual
	for leg in cv.legs:
		if leg is Dictionary and leg.has("hip") and is_instance_valid(leg["hip"]):
			(leg["hip"] as Node3D).visible = false
	for arm in cv.arms:
		if arm is Node3D and is_instance_valid(arm):
			(arm as Node3D).visible = false

# --------------------------------------------------------------- screen state
func _hide_all() -> void:
	start_root.visible = false
	end_root.visible = false
	hud_root.visible = false
	radar.visible = false
	if task_root: task_root.visible = false
	if online_root: online_root.visible = false
	if lobby_root: lobby_root.visible = false

func show_start() -> void:
	_hide_all()
	bg.visible = true
	start_root.visible = true
	countdown_label.text = ""

func show_online_panel() -> void:
	_hide_all()
	bg.visible = true
	online_root.visible = true
	online_status.text = ""

func set_online_status(text: String) -> void:
	if online_status:
		online_status.text = text

func set_join_code(code: String) -> void:
	if online_code:
		online_code.text = code

func show_lobby(players: Array, my_id: int, admin_id: int, code: String) -> void:
	_hide_all()
	bg.visible = true
	lobby_root.visible = true
	lobby_code_label.text = "ROOM  " + code
	for c in lobby_list.get_children():
		c.queue_free()
	var el_names := { "fire": "Fire", "water": "Water", "grass": "Leaf" }
	for p in players:
		var mine: bool = int(p["id"]) == my_id
		var is_admin: bool = int(p["id"]) == admin_id
		var txt := ("★ " if is_admin else "•  ") + str(p["name"]) + (" (you)" if mine else "") \
			+ "   —   " + str(el_names.get(p["el"], p["el"]))
		lobby_list.add_child(_make_label(txt, 18, _c(UI_COLORS[p["el"]])))
	lobby_start_btn.visible = (my_id == admin_id)
	lobby_start_btn.disabled = players.is_empty()

func show_hud() -> void:
	_hide_all()
	bg.visible = false
	hud_root.visible = true
	radar.visible = true

func show_end(rows: Array, title: String, sub: String) -> void:
	_hide_all()
	bg.visible = true
	end_root.visible = true
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

func set_objective(text: String) -> void:
	timer_label.text = "🎯 " + text

func set_hearts(cur: int, max_hp: int) -> void:
	if hearts_box == null:
		return
	while hearts_box.get_child_count() > 0:
		var c := hearts_box.get_child(0)
		hearts_box.remove_child(c)
		c.queue_free()
	for i in max_hp:
		var tr := TextureRect.new()
		tr.texture = hearts_tex
		tr.custom_minimum_size = Vector2(28, 28)
		tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
		if i >= cur:
			tr.modulate = Color(0.55, 0.55, 0.6, 0.4)   # a lost life — faded
		hearts_box.add_child(tr)

func set_status(text: String) -> void:
	status_label.text = text

func set_channel(label: String, pct: float) -> void:
	if pct < 0.0:
		channel_box.visible = false
		return
	channel_box.visible = true
	channel_label.text = label + "  " + str(int(round(pct * 100.0))) + "%"
	channel_fill.size.x = 170.0 * clampf(pct, 0.0, 1.0)

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
