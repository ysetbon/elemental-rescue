class_name GameUI
extends CanvasLayer
# All on-screen UI: start screen with element cards, HUD, radar, toast,
# countdown and the end-of-round standings. Built entirely in code.

signal element_selected(el: String)
signal world_selected(kind: String)      # intro page: "castle" | "town"
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
var worlds_root: Control                 # intro page 1: pick a world (then start_root picks the element)
var _tag_label: Label = null             # element-page tagline (world-specific wording)
var _hint_label: Label = null            # element-page how-to-play footer (world-specific)
var sky_box: PanelContainer = null       # Skyfall Isles: round clock + eclipse + smog countdowns
var sky_clock: Label = null
var sky_eclipse: Label = null
var sky_smog: Label = null
var whiteout: ColorRect = null           # Skyfall Isles: falling through the clouds
var hint_box: PanelContainer = null      # context hint popup ("[E] Climb your vine ladder…")
var hint_key: PanelContainer = null
var hint_key_label: Label = null
var hint_label: Label = null
var mote_row: HBoxContainer = null       # Skyfall Isles: "Sun Motes" + one drawn pip per mote
var _mote_state := Vector3i(-1, -1, -1)
var end_root: Control
var hud_root: Control
var radar: RadarControl
var radar_mask: Panel

var timer_label: Label
var board_box: HBoxContainer
var board_labels := {}
var role_label: Label
var cave_label: Label
var hearts_box: HBoxContainer
var hearts_tex: Texture2D
var _hearts_cur := -1
var _hearts_max := -1
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
var online_center: CenterContainer   # online panel wrapper — shifted up so the mobile keyboard doesn't hide the fields
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
	# Mobile: lift the PLAY ONLINE panel above the on-screen keyboard so the code/name field you're
	# typing into stays visible. On WEB the soft keyboard is the browser's (Godot's
	# virtual_keyboard_get_height() returns 0), so we read window.visualViewport — it shrinks when
	# the keyboard opens. We shift by the keyboard's FRACTION of the viewport (scale-independent).
	if online_center and online_root and online_root.visible:
		var frac := 0.0
		if OS.has_feature("web"):
			var v: Variant = JavaScriptBridge.eval("(function(){var vv=window.visualViewport;if(!vv)return 0.0;return Math.max(0.0,(window.innerHeight-vv.height)/Math.max(1,window.innerHeight));})()", true)
			if typeof(v) == TYPE_FLOAT or typeof(v) == TYPE_INT:
				frac = clampf(float(v), 0.0, 0.85)
		else:
			var win_h := float(DisplayServer.window_get_size().y)
			if win_h > 0.0:
				frac = clampf(float(DisplayServer.virtual_keyboard_get_height()) / win_h, 0.0, 0.85)
		var want := -get_viewport().get_visible_rect().size.y * frac
		if not is_equal_approx(online_center.offset_bottom, want):
			online_center.offset_bottom = want

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

const TAGLINES := {
	"castle": "Your twin is caged in the old dungeon yard. Your key is locked in your rival's castle:\nraid it, free your twin, and walk them home to your keep. Pick your element:",
	"town": "Your twin is caged at the old zoo. Your key lies near your rival's camp:\nsteal it, free your twin, and walk them home to your cave. Pick your element:",
	"sky": "ASCENT — light your Spark from three Sun Motes, climb the Sky Spire,\nand ring the Sky Bell three times before anyone else. Pick your element:",
}

# the how-to-play footer of the element page, per world
const HINT_RESCUE := "Hearts: a touch from your rival or CO₂ costs a heart — at zero you're sent home (you're never out)\n" \
	+ "Training totem in your garden: earn an extra heart   ·   Clan hall in your courtyard: teach to summon a clan, then click them to assign tasks\n" \
	+ "Whoever hits you (or your clan) is slowed 5s   ·   your key sits on the treasury pedestal inside the castle of the element that EATS you\n" \
	+ "Steal your key → free your twin at the dungeon yard → bring them to the glowing circle behind your tower to WIN\n" \
	+ "Grab a black stone (Pac-Man power-up): chase & eat your predator, CO₂ ignore you — but O₂ hunt you\n" \
	+ "Sip white O₂ to supercharge your sprint (slower drain, faster recovery)\n" \
	+ "WASD move   ·   Shift sprint   ·   drag mouse to look"
const HINT_SKY := "Three Sun Motes in your colour float on the outer isles — one is always on your PREY's home isle. Touch all three to light your Spark\n" \
	+ "A lit Spark opens the Sky Spire: climb the stairs, or step on your own shortcut pad (Fire vent · Water lift · Leaf vine ladder) and press E\n" \
	+ "Each terrace has a TASK STONE: read it (E) and do its task to unlock the way up   ·   open a CAGE (E) for a little helper — any but the element that eats you\n" \
	+ "Stand in the ring on the top platform for 2s to ring the bell — first to 3 rings wins   ·   a tag on the spire costs a heart AND a tier\n" \
	+ "A predator's touch shoves you 6 m — mind the edges: walk off and you fall through the clouds\n" \
	+ "Every 75s the ECLIPSE reverses the food chain for 15s   ·   every minute the smog sea rises and swallows the outer isles\n" \
	+ "Fire rides thermal vents · Water surfs sky streams · Leaf walks vines and can grow a vine bridge on a seed (stand 1.5s)\n" \
	+ "WASD move   ·   Shift sprint   ·   drag mouse to look"

# Intro page 1 — pick one of the two worlds (aerial snapshot on each card).
func _build_worlds() -> void:
	worlds_root = Control.new()
	worlds_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(worlds_root)
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	worlds_root.add_child(center)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 20)
	v.alignment = BoxContainer.ALIGNMENT_CENTER
	center.add_child(v)
	v.add_child(_make_label("ELEMENTAL RESCUE", 54, _c(0xfff1e0)))
	v.add_child(_make_label("Choose your world:", 20, Color(1, 1, 1, 0.92)))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 24)
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	v.add_child(row)
	# NOTE: the card images live in art/ (not docs/) — the Web export preset excludes docs/*
	_add_world_card(row, "castle", "CASTLE KINGDOM",
		"Three huge walled castles — raid the treasury,\nfree your twin, escort them home to your keep",
		"res://art/world_castle.png")
	_add_world_card(row, "town", "TWILIGHT TOWN",
		"The original cozy map — school, playground\nand the old zoo where your twin waits",
		"res://art/world_town.png")
	var sky_col := _add_world_card(row, "sky", "SKYFALL ISLES",
		"ASCENT — floating isles over a cloud sea:\nlight your Spark, climb the spire, ring the bell",
		"res://art/world_sky.png")
	# Ascent has more rules than the rescue worlds: a link to the illustrated briefing
	# page sits under its card (it opens in the browser — nothing is shown in-game).
	var s := 1.15 if mobile else 1.0
	var link := Button.new()
	link.text = "How to play Ascent — open the briefing"
	link.custom_minimum_size = Vector2(340, 40) * s
	link.add_theme_font_size_override("font_size", int(15 * s))
	link.add_theme_color_override("font_color", _c(0x5a3a20))
	link.add_theme_color_override("font_hover_color", _c(0x5a3a20))
	link.add_theme_color_override("font_pressed_color", _c(0x5a3a20))
	link.add_theme_color_override("font_focus_color", _c(0x5a3a20))
	var lsb := StyleBoxFlat.new()
	lsb.bg_color = Color(1, 1, 1, 0.82)
	lsb.set_corner_radius_all(14)
	lsb.set_border_width_all(2)
	lsb.border_color = _c(0xf2a55a)
	link.add_theme_stylebox_override("normal", lsb)
	var lsb_h := lsb.duplicate()
	lsb_h.bg_color = Color(1, 1, 1, 1.0)
	link.add_theme_stylebox_override("hover", lsb_h)
	link.add_theme_stylebox_override("pressed", lsb_h)
	link.add_theme_stylebox_override("focus", lsb_h)
	link.pressed.connect(_open_briefing)
	sky_col.add_child(link)

# The Ascent briefing is a web page shipped next to the web build (web/briefing.html).
const BRIEFING_URL := "https://elemental-rescue.onrender.com/briefing.html"
func _open_briefing() -> void:
	if OS.has_feature("web"):
		# a new tab beside the game; if the browser blocks the pop-up, go there in this tab
		# (the page has a link back to the game)
		JavaScriptBridge.eval("(function(){var u=new URL('briefing.html',location.href).href;var w=window.open(u,'_blank');if(!w){location.href=u;}})()", true)
		return
	var local := ProjectSettings.globalize_path("res://web/briefing.html")
	OS.shell_open(local if FileAccess.file_exists(local) else BRIEFING_URL)

# Adds a world card in its own column and returns that column (for extras under the card).
func _add_world_card(parent: Node, kind: String, name_: String, desc: String, img_path: String) -> VBoxContainer:
	var s := 1.15 if mobile else 1.0   # three cards must still fit a phone's width
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 10)
	col.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	parent.add_child(col)
	var btn := Button.new()
	btn.custom_minimum_size = Vector2(340, 292) * s
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(1, 1, 1, 0.93)
	sb.set_corner_radius_all(18)
	sb.set_border_width_all(3)
	sb.border_color = _c(0xf2a55a)
	btn.add_theme_stylebox_override("normal", sb)
	var sb_h := sb.duplicate()
	sb_h.bg_color = Color(1, 1, 1, 1.0)
	sb_h.border_color = _c(0xf2a55a).lightened(0.15)
	btn.add_theme_stylebox_override("hover", sb_h)
	btn.add_theme_stylebox_override("pressed", sb_h)
	var v := VBoxContainer.new()
	v.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	v.offset_left = 12; v.offset_right = -12; v.offset_top = 12; v.offset_bottom = -12
	v.add_theme_constant_override("separation", 8)
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	btn.add_child(v)
	if ResourceLoader.exists(img_path):
		var tr := TextureRect.new()
		tr.texture = load(img_path)
		tr.custom_minimum_size = Vector2(316, 172) * s
		tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
		tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
		v.add_child(tr)
	v.add_child(_make_label(name_, int(24 * s), _c(0x5a3a20)))
	v.add_child(_make_label(desc, int(13 * s), Color(0.28, 0.24, 0.3, 0.95)))
	btn.pressed.connect(func() -> void:
		world_selected.emit(kind)
		_show_element_page(kind))
	col.add_child(btn)
	return col

# Intro page 2 — the world is chosen; pick your element (or go online).
func _show_element_page(kind: String) -> void:
	_hide_all()
	bg.visible = true
	start_root.visible = true
	countdown_label.text = ""
	if _tag_label != null:
		_tag_label.text = TAGLINES.get(kind, TAGLINES["castle"])
	if _hint_label != null:
		_hint_label.text = HINT_SKY if kind == "sky" else HINT_RESCUE

func _build_start() -> void:
	_build_worlds()
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
	var tag := _make_label(TAGLINES["castle"], 16, Color(1, 1, 1, 0.92))
	_tag_label = tag
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

	var back_btn := Button.new()
	back_btn.flat = true
	back_btn.text = "←  change world"
	back_btn.add_theme_font_size_override("font_size", 14)
	back_btn.add_theme_color_override("font_color", Color(1, 1, 1, 0.8))
	back_btn.add_theme_color_override("font_hover_color", Color(1, 1, 1, 1.0))
	back_btn.pressed.connect(func() -> void: show_start())
	v.add_child(_center(back_btn))

	var hint := _make_label(HINT_RESCUE, 13, Color(1, 1, 1, 0.85))
	_hint_label = hint
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
	var s := 2.0 if mobile else 1.0
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
	var s := 2.0 if mobile else 1.0
	var le := LineEdit.new()
	le.placeholder_text = placeholder
	le.alignment = HORIZONTAL_ALIGNMENT_CENTER
	le.custom_minimum_size = Vector2(260, 48) * s
	le.add_theme_font_size_override("font_size", int(18 * s))
	le.virtual_keyboard_enabled = true   # bring up the on-screen keyboard on mobile/web
	le.context_menu_enabled = true
	if maxlen > 0:
		le.max_length = maxlen
	return le

# center a fixed-size control inside a VBoxContainer (which otherwise stretches children)
func _center(c: Control) -> Control:
	c.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	return c

# label whose font is doubled on mobile/touch (online + lobby screens)
func _olabel(text: String, size: int, col: Color = TEXT) -> Label:
	return _make_label(text, int(size * (2.0 if mobile else 1.0)), col)

func _build_online() -> void:
	online_root = Control.new()
	online_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	online_root.visible = false
	add_child(online_root)
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	online_root.add_child(center)
	online_center = center
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 14)
	v.alignment = BoxContainer.ALIGNMENT_CENTER
	center.add_child(v)
	v.add_child(_olabel("PLAY ONLINE", 46, _c(0xfff1e0)))
	v.add_child(_olabel(
		"Host a game and share the code with up to 6 friends,\nor join with a code someone sent you.",
		16, Color(1, 1, 1, 0.9)))
	online_name = _line_edit("Your name", 16)
	v.add_child(_center(online_name))
	var hostb := _action_button("HOST NEW GAME", 260)
	hostb.pressed.connect(func() -> void: host_requested.emit(online_name.text))
	v.add_child(_center(hostb))
	v.add_child(_olabel("— or —", 14, Color(1, 1, 1, 0.7)))
	online_code = _line_edit("Enter code", 8)
	v.add_child(_center(online_code))
	var joinb := _action_button("JOIN GAME", 260, 52, 0x5d93e8, 0xffffff)
	joinb.pressed.connect(func() -> void: join_requested.emit(online_name.text, online_code.text))
	v.add_child(_center(joinb))
	# Mobile: the on-screen keyboard covers the on-canvas buttons, and tapping a
	# button while the (experimental) virtual keyboard is up gets swallowed — so
	# JOIN/HOST would appear to do nothing. Let the keyboard's own "Go/Enter" key
	# submit, and drop focus so it closes (any following button tap is then clean).
	online_code.text_submitted.connect(func(_t: String) -> void:
		online_code.release_focus()
		join_requested.emit(online_name.text, online_code.text))
	online_name.text_submitted.connect(func(_t: String) -> void:
		online_name.release_focus())
	online_status = _olabel("", 15, _c(0xffd9b0))
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
	lobby_code_label = _olabel("ROOM —", 44, _c(0xfff1e0))
	v.add_child(lobby_code_label)
	var copyb := _action_button("🔗 COPY INVITE LINK", 300, 46, 0x5db0a0, 0xffffff)
	copyb.pressed.connect(func() -> void: copy_invite_pressed.emit())
	v.add_child(_center(copyb))
	v.add_child(_olabel(
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
	whiteout = ColorRect.new()
	whiteout.color = Color(1, 1, 1, 0)
	whiteout.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	whiteout.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(whiteout)
	hud_root = Control.new()
	hud_root.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	hud_root.position = Vector2(12, 12)
	add_child(hud_root)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)
	hud_root.add_child(v)

	timer_label = _pill(v)
	timer_label.add_theme_font_size_override("font_size", 16)
	# cap the objective's width so long lines wrap to two — otherwise this pill
	# drags every pill below it out to the same width
	timer_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	timer_label.custom_minimum_size = Vector2(190, 0)
	timer_label.text = "Find your key"

	# context hint: pops up when you are near something you can use (a ladder, a
	# lift, stairs…) and says what to press / do. Hidden otherwise.
	hint_box = PanelContainer.new()
	var hsb := StyleBoxFlat.new()
	hsb.bg_color = Color(1.0, 0.95, 0.78, 0.97)
	hsb.set_corner_radius_all(12)
	hsb.set_border_width_all(2)
	hsb.border_color = _c(0xf2a23c)
	hsb.content_margin_left = 10; hsb.content_margin_right = 12
	hsb.content_margin_top = 7; hsb.content_margin_bottom = 7
	hint_box.add_theme_stylebox_override("panel", hsb)
	hint_box.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	hint_box.visible = false
	v.add_child(hint_box)
	var hrow2 := HBoxContainer.new()
	hrow2.add_theme_constant_override("separation", 9)
	hint_box.add_child(hrow2)
	hint_key = PanelContainer.new()
	var ksb := StyleBoxFlat.new()
	ksb.bg_color = _c(0x3a3550)
	ksb.set_corner_radius_all(7)
	ksb.border_width_bottom = 3
	ksb.border_color = _c(0x211d30)
	ksb.content_margin_left = 9; ksb.content_margin_right = 9
	ksb.content_margin_top = 2; ksb.content_margin_bottom = 3
	hint_key.add_theme_stylebox_override("panel", ksb)
	hint_key.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	hrow2.add_child(hint_key)
	hint_key_label = _make_label("E", 17, Color.WHITE)
	hint_key.add_child(hint_key_label)
	hint_label = _make_label_left("", 14, _c(0x5a3a20))
	hint_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	hint_label.custom_minimum_size = Vector2(250, 0)
	hrow2.add_child(hint_label)

	# Skyfall Isles clocks (hidden in the other worlds)
	sky_box = _pill_panel(v)
	sky_box.visible = false
	var skv := VBoxContainer.new()
	skv.add_theme_constant_override("separation", 1)
	sky_box.add_child(skv)
	sky_clock = _make_label_left("", 15)
	skv.add_child(sky_clock)
	sky_eclipse = _make_label_left("", 13, _c(0x6b4fb3))
	skv.add_child(sky_eclipse)
	sky_smog = _make_label_left("", 12, _c(0x6c6578))
	skv.add_child(sky_smog)
	# Sun Mote pips: drawn dots, not glyphs (the web build's font has no symbol glyphs)
	mote_row = HBoxContainer.new()
	mote_row.add_theme_constant_override("separation", 6)
	skv.add_child(mote_row)
	mote_row.add_child(_make_label_left("Sun Motes", 12))

	# hearts = a row of little element-figure icons (filled = colour, empty = faded)
	var hearts_pill := _pill_panel(v)
	var hrow := HBoxContainer.new()
	hrow.add_theme_constant_override("separation", 5)
	hearts_pill.add_child(hrow)
	var hlbl := _make_label_left("Lives", 13)
	hrow.add_child(hlbl)
	hearts_box = HBoxContainer.new()
	hearts_box.add_theme_constant_override("separation", 3)
	hrow.add_child(hearts_box)

	var board_pill := _pill_panel(v)
	board_box = HBoxContainer.new()
	board_box.add_theme_constant_override("separation", 12)
	board_pill.add_child(board_box)
	for el in ["fire", "water", "grass"]:
		var lbl := _make_label("", 13, _c(UI_COLORS[el]))
		board_labels[el] = lbl
		board_box.add_child(lbl)

	role_label = _pill(v)
	role_label.text = ""
	status_label = _pill(v)
	status_label.text = ""
	cave_label = _pill(v)
	cave_label.visible = false
	(cave_label.get_parent() as Control).visible = false   # no empty pill until there is text

	# channel bar (self-training / clan teaching progress)
	channel_box = _pill_panel(v)
	channel_box.visible = false
	var cv := VBoxContainer.new()
	channel_box.add_child(cv)
	channel_label = _make_label_left("", 12)
	cv.add_child(channel_label)
	var ctrack := ColorRect.new()
	ctrack.color = Color(0.227, 0.208, 0.314, 0.14)
	ctrack.custom_minimum_size = Vector2(150, 8)
	cv.add_child(ctrack)
	channel_fill = ColorRect.new()
	channel_fill.color = _c(0x49b36a)
	channel_fill.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	channel_fill.size = Vector2(0, 8)
	ctrack.add_child(channel_fill)

	var stam_pill := _pill_panel(v)
	var sv := VBoxContainer.new()
	stam_pill.add_child(sv)
	sv.add_child(_make_label_left("Sprint", 12))
	var track := ColorRect.new()
	track.color = Color(0.227, 0.208, 0.314, 0.14)
	track.custom_minimum_size = Vector2(150, 8)
	sv.add_child(track)
	stam_fill = ColorRect.new()
	stam_fill.color = _c(0xf0541a)
	stam_fill.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	stam_fill.size = Vector2(150, 8)
	track.add_child(stam_fill)

	if mobile:
		hud_root.scale = Vector2(2, 2)   # grows down-right from the top-left corner
	else:
		# desktop: the 1280×720 canvas stretches up to the window, which made the
		# stat pills read oversized — render the whole stack at 3/4 size instead
		hud_root.scale = Vector2(0.75, 0.75)

func _make_label_left(text: String, size: int, col: Color = TEXT) -> Label:
	var l := _make_label(text, size, col)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	return l

func _pill_panel(parent: Node) -> PanelContainer:
	var p := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(1, 1, 1, 0.9)
	sb.set_corner_radius_all(12)
	sb.content_margin_left = 12; sb.content_margin_right = 12
	sb.content_margin_top = 6; sb.content_margin_bottom = 6
	p.add_theme_stylebox_override("panel", sb)
	p.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN   # hug content, don't match the widest pill
	parent.add_child(p)
	return p

func _pill(parent: Node) -> Label:
	var p := _pill_panel(parent)
	var l := _make_label_left("", 13)
	p.add_child(l)
	return l

func _build_radar() -> void:
	# the dial is a round mask (clip_children) so map content never spills past its rim
	radar_mask = Panel.new()
	var msb := StyleBoxFlat.new()
	msb.bg_color = Color.WHITE
	msb.set_corner_radius_all(67)
	msb.corner_detail = 16
	radar_mask.add_theme_stylebox_override("panel", msb)
	radar_mask.clip_children = CanvasItem.CLIP_CHILDREN_ONLY
	radar_mask.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	radar_mask.position = Vector2(-149, 15)
	radar_mask.size = Vector2(134, 134)
	radar_mask.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(radar_mask)
	radar = RadarControl.new()
	radar.position = Vector2(-3, -3)
	radar_mask.add_child(radar)

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
	if worlds_root: worlds_root.visible = false
	end_root.visible = false
	hud_root.visible = false
	radar.visible = false
	if radar_mask: radar_mask.visible = false
	if whiteout: whiteout.color.a = 0.0
	if task_root: task_root.visible = false
	if online_root: online_root.visible = false
	if lobby_root: lobby_root.visible = false

func show_start() -> void:
	_hide_all()
	bg.visible = true
	worlds_root.visible = true    # page 1: pick a world; picking shows the element page
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
		lobby_list.add_child(_olabel(txt, 18, _c(UI_COLORS[p["el"]])))
	lobby_start_btn.visible = (my_id == admin_id)
	lobby_start_btn.disabled = players.is_empty()

func show_hud() -> void:
	_hide_all()
	bg.visible = false
	hud_root.visible = true
	radar.visible = true
	radar_mask.visible = true
	if sky_box: sky_box.visible = false   # the sky world re-shows it every frame (set_sky_info)
	if hint_box: hint_box.visible = false

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
		var sc := _make_label(String(r["detail"]) if r.has("detail") else str(r["score"]) + " pts", 18, TEXT)
		hb.add_child(sc)
		standings_box.add_child(row)

# --------------------------------------------------------------- live updates
func set_timer(text: String) -> void:
	timer_label.text = text

func set_board(entries: Array) -> void:
	for e in entries:
		var lbl: Label = board_labels[e["el"]]
		lbl.text = String(e["text"]) if e.has("text") else e["label"] + " " + str(e["score"])
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
	if cur == _hearts_cur and max_hp == _hearts_max and hearts_box.get_child_count() == max_hp:
		return
	_hearts_cur = cur
	_hearts_max = max_hp
	while hearts_box.get_child_count() > max_hp:
		var c := hearts_box.get_child(hearts_box.get_child_count() - 1)
		hearts_box.remove_child(c)
		c.queue_free()
	while hearts_box.get_child_count() < max_hp:
		var tr := TextureRect.new()
		tr.texture = hearts_tex
		tr.custom_minimum_size = Vector2(28, 28)
		tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
		hearts_box.add_child(tr)
	for i in hearts_box.get_child_count():
		var tr := hearts_box.get_child(i) as TextureRect
		if tr == null:
			continue
		tr.modulate = Color(0.55, 0.55, 0.6, 0.4) if i >= cur else Color(1, 1, 1, 1)

func set_status(text: String) -> void:
	status_label.text = text

func set_channel(label: String, pct: float) -> void:
	if pct < 0.0:
		channel_box.visible = false
		return
	channel_box.visible = true
	channel_label.text = label + "  " + str(int(round(pct * 100.0))) + "%"
	channel_fill.size.x = 150.0 * clampf(pct, 0.0, 1.0)

func set_cave(text: String) -> void:
	cave_label.visible = text != ""
	(cave_label.get_parent() as Control).visible = text != ""   # hide the pill too, not just its label
	cave_label.text = text

func set_stamina(pct: float) -> void:
	stam_fill.size.x = 150.0 * clampf(pct, 0.0, 100.0) / 100.0

func toast(msg: String) -> void:
	toast_label.text = msg
	toast_label.modulate.a = 1.0
	_toast_timer = 1.9

func set_countdown(text: String) -> void:
	countdown_label.text = text

# Skyfall Isles: round clock, eclipse countdown (violet + bold while it is ON) and the smog sea.
func set_sky_info(clock: String, eclipse: String, eclipse_on: bool, smog: String) -> void:
	if sky_box == null:
		return
	sky_box.visible = true
	sky_clock.text = "TIME  " + clock
	sky_eclipse.text = eclipse
	sky_eclipse.add_theme_color_override("font_color", _c(0xd0392b) if eclipse_on else _c(0x6b4fb3))
	sky_smog.text = smog

func set_whiteout(a: float) -> void:
	if whiteout:
		whiteout.color.a = clampf(a, 0.0, 1.0)

# Skyfall Isles: n of `total` Sun Motes absorbed — filled pips in the element's colour.
func set_mote_pips(n: int, total: int, col: Color) -> void:
	if mote_row == null:
		return
	var key := Vector3i(n, total, int(col.to_rgba32() & 0x7fffffff))
	if key == _mote_state:
		return
	_mote_state = key
	while mote_row.get_child_count() > 1:
		var c := mote_row.get_child(mote_row.get_child_count() - 1)
		mote_row.remove_child(c)
		c.queue_free()
	for i in total:
		var pip := Panel.new()
		pip.custom_minimum_size = Vector2(13, 13)
		pip.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		pip.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var sb := StyleBoxFlat.new()
		sb.set_corner_radius_all(7)
		sb.set_border_width_all(2)
		sb.border_color = col.darkened(0.15)
		sb.bg_color = col if i < n else Color(col.r, col.g, col.b, 0.12)
		pip.add_theme_stylebox_override("panel", sb)
		mote_row.add_child(pip)

# Context hint popup (top-left, under the objective). `key` is drawn as a key cap
# ("E", "W") — pass "" for a hint with no key. Empty text hides the popup.
func set_hint(key: String, text: String) -> void:
	if hint_box == null:
		return
	hint_box.visible = text != ""
	if text == "":
		return
	hint_key.visible = key != ""
	hint_key_label.text = key
	hint_label.text = text
