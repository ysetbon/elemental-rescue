class_name TouchControls
extends CanvasLayer

# On-screen touch controls for phones: an analog joystick (bottom-left) that
# drives movement and a SPRINT button (bottom-right). They feed Game.touch_move
# / Game.touch_sprint, which _update_player() folds into the normal movement.
#
# Shown only on touch devices (or forced with ?touch=1 on web, ?touch=0 hides).
# On desktop the node stays hidden and does nothing, so the keyboard game is
# completely unaffected. Look-around still works by dragging elsewhere on screen
# (Godot emulates mouse from touch); these controls consume only their own
# touches so they never spin the camera.

var game: Game

var _pad: Control

var _enabled := false             # device should show controls at all
var _forced := false              # explicitly forced via ?touch=1 (testing)
var _use_mouse := false           # let the mouse drive the controls (desktop / forced)
var _home := Vector2.ZERO         # resting joystick centre (bottom-left)
var _sprint_c := Vector2.ZERO     # sprint button centre (bottom-right)
const UI_SCALE := 2.0             # phone controls are drawn this much bigger
const BASE_R := 80.0 * UI_SCALE
const KNOB_R := 38.0 * UI_SCALE
const TRAVEL := 62.0 * UI_SCALE
const SPRINT_R := 66.0 * UI_SCALE
const DEADZONE := 9.0 * UI_SCALE
const GRAB_R := BASE_R * 1.2       # only a touch this close to the joystick grabs it

# Active interaction. Index is the touch finger id, or -1 for the mouse
# (desktop testing). -2 means "not held".
var _joy_idx := -2
var _joy_origin := Vector2.ZERO
var _knob := Vector2.ZERO
var _sprint_idx := -2

func _ready() -> void:
	layer = 10
	_pad = Control.new()
	_pad.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_pad.set_anchors_preset(Control.PRESET_FULL_RECT)
	_pad.draw.connect(_on_draw)
	add_child(_pad)
	_pad.visible = false
	_enabled = _resolve_enabled()
	# Drive with the mouse on desktop, or whenever testing via ?touch=1 (even on
	# a touchscreen laptop). On a real phone touch drives it and the emulated
	# mouse is blocked so the camera never spins.
	_use_mouse = _forced or not _detect_touch()
	visible = _enabled
	get_viewport().size_changed.connect(_recompute)
	_recompute()

static func _touch_param() -> Variant:
	# ?touch=1 / ?touch=0 on web overrides auto-detection (used for testing).
	if OS.has_feature("web"):
		return JavaScriptBridge.eval("(new URLSearchParams(location.search)).get('touch')", true)
	return null

# Godot's DisplayServer.is_touchscreen_available() is unreliable in the web export
# (many phone browsers report false), which is why the joystick went missing on
# mobile. But asking only "does the browser expose touch?" is too broad the other
# way: plenty of desktops report navigator.maxTouchPoints > 0 (a phantom touch
# digitiser — e.g. Windows machines report 10) while being driven by a mouse, so
# they wrongly got the joystick. So a session counts as touch only when it's a real
# phone/tablet: the UA says mobile, OR it has touch AND lacks a desktop-style
# pointer — a precise "fine" pointer that can hover, i.e. a mouse. A touchscreen
# laptop with a mouse keeps the keyboard game; a phone/tablet (incl. iPad, whose UA
# looks like desktop Safari) still gets the controls.
static func _web_has_touch() -> bool:
	if not OS.has_feature("web"):
		return false
	var r = JavaScriptBridge.eval(
		"(function(){" +
		"var d=navigator.userAgentData,u=navigator.userAgent||'';" +
		"var m=(d&&typeof d.mobile==='boolean')?d.mobile:" +
		"/Android|iPhone|iPad|iPod|IEMobile|BlackBerry|Opera Mini|Mobile/i.test(u);" +
		"var mm=window.matchMedia;" +
		"var fine=!!(mm&&mm('(pointer: fine)').matches);" +
		"var hover=!!(mm&&mm('(any-hover: hover)').matches);" +
		"var t=('ontouchstart' in window)||navigator.maxTouchPoints>0||navigator.msMaxTouchPoints>0;" +
		"return (m||(t&&!(fine&&hover)))?1:0;})()", true)
	return r != null and int(r) == 1

# Best-effort: is this a phone/tablet (touch) session? Used here and by the HUD.
static func _detect_touch() -> bool:
	return DisplayServer.is_touchscreen_available() or _web_has_touch()

# Is this a touch/phone session? Shared by the HUD so it scales to match.
static func is_touch_session() -> bool:
	var qp = _touch_param()
	if qp != null:
		return str(qp) != "0"
	return _detect_touch()

func _resolve_enabled() -> bool:
	var qp = _touch_param()
	if qp != null:
		_forced = str(qp) != "0"
		return _forced
	return _detect_touch()

func _recompute() -> void:
	var s := get_viewport().get_visible_rect().size
	_home = Vector2(40.0 + BASE_R, s.y - 40.0 - BASE_R)
	_sprint_c = Vector2(s.x - 44.0 - SPRINT_R, s.y - 52.0 - SPRINT_R)
	if _pad:
		_pad.queue_redraw()

func _process(_dt: float) -> void:
	if game == null:
		return
	# Show the joystick + sprint by PER-DEVICE detection only (_enabled), in online
	# AND single-player alike. A desktop session — host OR guest — never gets the
	# on-screen buttons; a phone/tablet always does. One invite link serves both:
	# each player's own device decides. The ?touch=1 / ?touch=0 link override still
	# forces it either way for the rare browser whose touch detection is wrong.
	var want := _enabled and game.running and game.player != null and game.player.alive
	if want != _pad.visible:
		_pad.visible = want
		if not want:
			_reset_all()

# --------------------------------------------------------------------- input
func _input(event: InputEvent) -> void:
	if not _pad.visible:
		return
	if event is InputEventScreenTouch:
		var claimed := _press(event.index, event.position) if event.pressed else _release(event.index)
		if claimed:
			get_viewport().set_input_as_handled()
	elif event is InputEventScreenDrag:
		if event.index == _joy_idx:
			_drag_joy(event.position)
			get_viewport().set_input_as_handled()
		elif event.index == _sprint_idx:
			get_viewport().set_input_as_handled()
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if _use_mouse:                     # drive controls with the mouse
			var claimed := _press(-1, event.position) if event.pressed else _release(-1)
			if claimed:
				get_viewport().set_input_as_handled()
		elif _block_mouse():               # mobile: block the emulated mouse twin of a control touch
			get_viewport().set_input_as_handled()
	elif event is InputEventMouseMotion:
		if _use_mouse:
			if _joy_idx == -1:
				_drag_joy(event.position)
				get_viewport().set_input_as_handled()
		elif _block_mouse():
			get_viewport().set_input_as_handled()

func _block_mouse() -> bool:
	# Godot only emulates the mouse from finger 0; block it when finger 0 is on a control.
	return _joy_idx == 0 or _sprint_idx == 0

func _press(idx: int, pos: Vector2) -> bool:
	# In the clan command view a tap on a clan member must select it, even when the
	# member is drawn under the joystick or sprint button. Don't claim the touch in
	# that case — let it fall through to Game's selection (the emulated mouse). Empty
	# ground still drives the controls, so you can walk away / flee mid-assign.
	if game and game.touch_selects_clan(pos):
		return false
	if _sprint_idx == -2 and pos.distance_to(_sprint_c) <= SPRINT_R * 1.25:
		_sprint_idx = idx
		if game:
			game.touch_sprint = true
		_pad.queue_redraw()
		return true
	# Only the joystick's own area activates it — not the whole bottom-left of the
	# screen as before. A press elsewhere is left for the camera / clan selection.
	if _joy_idx == -2 and pos.distance_to(_home) <= GRAB_R:
		_joy_idx = idx
		_joy_origin = _clamp_origin(pos)
		_drag_joy(pos)
		return true
	return false

func _release(idx: int) -> bool:
	var claimed := false
	if idx == _sprint_idx:
		_sprint_idx = -2
		if game:
			game.touch_sprint = false
		claimed = true
	if idx == _joy_idx:
		_joy_idx = -2
		_knob = Vector2.ZERO
		if game:
			game.touch_move = Vector2.ZERO
		claimed = true
	if claimed:
		_pad.queue_redraw()
	return claimed

func _drag_joy(pos: Vector2) -> void:
	var off := (pos - _joy_origin).limit_length(TRAVEL)
	if off.length() < DEADZONE:
		off = Vector2.ZERO
	_knob = off
	var v := off / TRAVEL
	if game:
		game.touch_move = Vector2(v.x, -v.y)   # screen-up (-y) -> forward
	_pad.queue_redraw()

func _clamp_origin(pos: Vector2) -> Vector2:
	var s := get_viewport().get_visible_rect().size
	return Vector2(clampf(pos.x, BASE_R + 6.0, s.x - BASE_R - 6.0), clampf(pos.y, BASE_R + 6.0, s.y - BASE_R - 6.0))

func _reset_all() -> void:
	_joy_idx = -2
	_sprint_idx = -2
	_knob = Vector2.ZERO
	if game:
		game.touch_move = Vector2.ZERO
		game.touch_sprint = false
	if _pad:
		_pad.queue_redraw()

# ---------------------------------------------------------------------- draw
func _on_draw() -> void:
	var origin := _home if _joy_idx == -2 else _joy_origin
	var a := 0.85 if _joy_idx == -2 else 1.0
	# dark translucent fill + white ring reads on both light and dark scenery
	_pad.draw_circle(origin, BASE_R, Color(0.10, 0.10, 0.16, 0.24 * a))
	_pad.draw_arc(origin, BASE_R, 0.0, TAU, 64, Color(1, 1, 1, 0.70 * a), 3.5 * UI_SCALE, true)
	_pad.draw_circle(origin + _knob, KNOB_R, Color(1, 1, 1, 0.78 * a))
	_pad.draw_arc(origin + _knob, KNOB_R, 0.0, TAU, 48, Color(0.10, 0.10, 0.16, 0.55 * a), 2.5 * UI_SCALE, true)

	var on := _sprint_idx != -2
	_pad.draw_circle(_sprint_c, SPRINT_R, Color(0.94, 0.33, 0.10, 0.88 if on else 0.52))
	_pad.draw_arc(_sprint_c, SPRINT_R, 0.0, TAU, 64, Color(1, 1, 1, 0.85), 3.5 * UI_SCALE, true)
	var font := ThemeDB.fallback_font
	var fs := int(19 * UI_SCALE)
	var tw := font.get_string_size("SPRINT", HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	_pad.draw_string(font, _sprint_c + Vector2(-tw * 0.5, fs * 0.35), "SPRINT", HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(1, 1, 1, 1.0))
