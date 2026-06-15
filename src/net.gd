class_name NetManager
extends Node
# Online multiplayer transport for Elemental Rescue — HOST-AUTHORITY over a dumb relay.
#
# One player's browser is the HOST: it runs the whole game (spawns the world, moves
# everyone from their input, decides catches/rescue) and streams snapshots out. Every
# other player is a GUEST: it sends its input and renders the snapshots it gets back.
# A tiny Node relay (server.js) just shuttles messages between them — it knows nothing
# about the game. This mirrors how AniRacers does online play.
#
#   guest browsers ── ws ──▶ [relay] ◀── ws ── HOST browser (the authority)
#
# We talk to the relay with a raw WebSocketPeer and plain JSON messages (NOT Godot's
# high-level @rpc multiplayer — that needs a real listening server, which a browser
# can't be). Every player keeps the same `my_id` the relay assigned; that id is the
# actor's peer_id on the host, so input and snapshots line up.

signal joined_room(code: String)                       # we're in a room (host or guest)
signal join_failed(reason: String)                     # rejected / couldn't connect
signal lobby_changed(players: Array, my_id: int, admin_id: int, code: String)
signal match_starting(world_seed: int, humans: Array, net_ids: Dictionary)  # guest: round starting
signal match_ended(reason: String, winner_el: String, standings: Array)
signal connection_lost()                               # host vanished / socket dropped

const MAX_PLAYERS := 7
const DEFAULT_PORT := 8910        # local relay port (used to build the editor/native URL)
const CODE_LEN := 4
const MSG_SNAP := 1               # binary WebSocket frame tag (byte 0): world-position snapshot
const MAX_PACKETS_PER_FRAME := 8   # keep relay bursts from monopolizing a rendered frame

var game: Node = null

# --- transport ---
var _ws: WebSocketPeer = null
var _open := false
var role := ""                    # "host" | "guest" | ""  (empty until in a room)
var my_id := 0                    # relay-assigned id; also our actor's peer_id
var my_name := "Player"
var current_code := ""            # the room code (for display / invite links)
var _pending_action := ""         # "create" | "join", sent once the socket opens
var _pending_code := ""

# Guest input send-throttle. _client_predict_local calls send_input every rendered
# frame (could be 60-144 Hz); the host only ever uses the latest input before each sim
# step, so flooding the relay is wasted uplink. We cap steady-state sends to ~30 Hz but
# fire instantly on any meaningful change, so key presses/releases are never delayed.
const INPUT_MIN_MS := 33
var _li_mx := 0.0
var _li_mz := 0.0
var _li_sp := false
var _li_yaw := 0.0
var _li_t := 0

# --- host-side room state ---
var admin_id := 0                 # the host's id (== my_id on the host)
var started := false
var lobby: Dictionary = {}        # id -> { "name": String, "el": String }

# ------------------------------------------------------------------ lifecycle
func connect_to(url: String, name_: String, action: String, code: String) -> void:
	_reset_state()
	my_name = name_.strip_edges()
	if my_name == "":
		my_name = "Player"
	_pending_action = action
	_pending_code = code.strip_edges().to_upper()
	_ws = WebSocketPeer.new()
	var err := _ws.connect_to_url(url)
	if err != OK:
		_ws = null
		join_failed.emit("Couldn't start connection (%s)" % error_string(err))

func leave() -> void:
	if _ws != null:
		_ws.close()
	_reset_state()

func _reset_state() -> void:
	_ws = null
	_open = false
	role = ""
	my_id = 0
	admin_id = 0
	started = false
	current_code = ""
	lobby.clear()
	_pending_action = ""
	_pending_code = ""

func _process(_dt: float) -> void:
	if _ws == null:
		return
	_ws.poll()
	var st := _ws.get_ready_state()
	if st == WebSocketPeer.STATE_OPEN:
		if not _open:
			_open = true
			_on_open()
		var processed := 0
		while _ws.get_available_packet_count() > 0 and processed < MAX_PACKETS_PER_FRAME:
			processed += 1
			var pkt := _ws.get_packet()
			if _ws.was_string_packet():
				_on_text(pkt.get_string_from_utf8())   # control + meta stay JSON
			else:
				_on_bin(pkt)                            # hot path: binary position snapshots
	elif st == WebSocketPeer.STATE_CLOSED:
		var was_in_room := role != "" or _open
		_ws = null
		if was_in_room and role == "guest":
			connection_lost.emit()
		elif _pending_action != "" and not _open:
			join_failed.emit("Couldn't reach the server. It may be waking up — try again in a minute.")
		_reset_state()

func _on_open() -> void:
	if _pending_action == "create":
		_send({ "t": "create", "code": _pending_code, "name": my_name })
	else:
		_send({ "t": "join", "code": _pending_code, "name": my_name })

func _send(obj: Dictionary) -> void:
	if _ws != null and _ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
		_ws.send_text(JSON.stringify(obj))

# ------------------------------------------------------------------ inbound
func _on_text(text: String) -> void:
	var parsed = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		return
	var m: Dictionary = parsed
	match String(m.get("t", "")):
		"room":     _on_room(m)
		"err":      _on_err(m)
		"guest_join": _on_guest_join(m)     # host
		"guest_leave": _on_guest_leave(m)   # host
		"el":       _on_guest_el(m)         # host
		"in":       _on_guest_input(m)      # host
		"lobby":    _on_lobby(m)            # guest
		"start":    _on_start(m)            # guest
		"meta":     _on_meta(m)             # guest: slow status (scores/objective/keys)
		"end":      _on_end(m)              # guest
		"host_gone": _on_host_gone()        # guest

func _on_room(m: Dictionary) -> void:
	my_id = int(m.get("you", 0))
	current_code = String(m.get("code", _pending_code))
	_pending_action = ""
	if bool(m.get("host", false)):
		role = "host"
		admin_id = my_id
		lobby[my_id] = { "name": _unique_name(my_name), "el": "fire" }
		joined_room.emit(current_code)
		_emit_lobby_local()
	else:
		role = "guest"
		joined_room.emit(current_code)   # the lobby list arrives next via "lobby"

func _on_err(m: Dictionary) -> void:
	join_failed.emit(String(m.get("m", "Couldn't join.")))
	leave()

# ---- host: roster management ----
func _on_guest_join(m: Dictionary) -> void:
	if role != "host":
		return
	var id := int(m.get("id", 0))
	if id == 0:
		return
	lobby[id] = { "name": _unique_name(String(m.get("name", "Player"))), "el": "fire" }
	_broadcast_lobby()
	_emit_lobby_local()

func _on_guest_leave(m: Dictionary) -> void:
	if role != "host":
		return
	var id := int(m.get("id", 0))
	if not lobby.has(id):
		return
	lobby.erase(id)
	if game and game.has_method("host_remove_peer"):
		game.host_remove_peer(id)
	_broadcast_lobby()
	_emit_lobby_local()

func _on_guest_el(m: Dictionary) -> void:
	if role != "host":
		return
	var id := int(m.get("from", 0))
	var el := String(m.get("el", ""))
	if started or not lobby.has(id):
		return
	if el in ["fire", "water", "grass"]:
		lobby[id]["el"] = el
		_broadcast_lobby()
		_emit_lobby_local()

func _on_guest_input(m: Dictionary) -> void:
	if role != "host" or game == null:
		return
	game.server_set_input(int(m.get("from", 0)), float(m.get("mx", 0.0)), float(m.get("mz", 0.0)), bool(m.get("sp", false)), float(m.get("yaw", 0.0)))

# ---- guest: receive host broadcasts ----
func _on_lobby(m: Dictionary) -> void:
	current_code = String(m.get("code", current_code))
	lobby_changed.emit(m.get("players", []), my_id, int(m.get("admin", 0)), current_code)

func _on_start(m: Dictionary) -> void:
	match_starting.emit(int(m.get("seed", 0)), m.get("humans", []), m.get("netids", {}))

# guest: a binary frame arrived (positions). Route by the 1-byte tag, decode the raw
# float32 payload, and hand it to the game (no JSON on the hot path).
func _on_bin(pkt: PackedByteArray) -> void:
	if game == null or pkt.size() < 1:
		return
	match pkt[0]:
		MSG_SNAP:
			var floats := pkt.slice(1).to_float32_array()
			game.client_on_snapshot(floats, {})

# guest: slow status payload (scores / objective / key positions), delivered as its own
# JSON message (~6Hz) now that positions ride a separate binary frame.
func _on_meta(m: Dictionary) -> void:
	if game:
		game.client_on_meta(m.get("meta", {}))

func _on_end(m: Dictionary) -> void:
	started = false
	match_ended.emit(String(m.get("reason", "")), String(m.get("win", "")), m.get("standings", []))

func _on_host_gone() -> void:
	connection_lost.emit()
	leave()

# ------------------------------------------------------------------ outbound API
# (called by game.gd; mirrors the old API so game.gd's wiring is unchanged.)

func choose_element(el: String) -> void:
	if role == "host":
		if started or not lobby.has(my_id):
			return
		if el in ["fire", "water", "grass"]:
			lobby[my_id]["el"] = el
			_broadcast_lobby()
			_emit_lobby_local()
	else:
		_send({ "t": "el", "el": el })

# Host only: spawn the match locally (host is the authority) and tell guests to start.
func start_match() -> void:
	if role != "host" or started or lobby.is_empty():
		return
	started = true
	var world_seed := randi()
	var humans: Array = []
	for id in lobby:
		humans.append({ "peer": id, "el": lobby[id]["el"], "name": lobby[id]["name"], "local": id == my_id })
	if game and game.has_method("host_start_match"):
		game.host_start_match(world_seed, humans)
	var mapping: Dictionary = {}
	if game:
		for pid in game.peer_actor:
			mapping[pid] = game.peer_actor[pid].net_id
	_send({ "t": "start", "seed": world_seed, "humans": humans, "netids": mapping })

# Guest -> host: per-frame input.
func send_input(mx: float, mz: float, sprint: bool, yaw: float) -> void:
	if role != "guest":
		return
	var now := Time.get_ticks_msec()
	var changed := absf(mx - _li_mx) > 0.04 or absf(mz - _li_mz) > 0.04 \
		or sprint != _li_sp or absf(wrapf(yaw - _li_yaw, -PI, PI)) > 0.03
	if not changed and (now - _li_t) < INPUT_MIN_MS:
		return
	_li_mx = mx; _li_mz = mz; _li_sp = sprint; _li_yaw = yaw; _li_t = now
	_send({ "t": "in", "mx": mx, "mz": mz, "sp": sprint, "yaw": yaw })

# Host -> guests: positions as a compact BINARY frame (raw float32, no JSON ~2.5× smaller);
# the bulky-but-slow meta (scores/objective/keys) rides its own JSON message when present.
func broadcast_snapshot(adata: PackedFloat32Array, meta: Dictionary) -> void:
	if role != "host":
		return
	if not meta.is_empty():
		_send({ "t": "meta", "meta": meta })            # slow data, JSON, ~6Hz
	if adata.size() > 0:
		var frame := PackedByteArray([MSG_SNAP])
		frame.append_array(adata.to_byte_array())        # raw float32 bytes
		_send_bin(frame)

func _send_bin(bytes: PackedByteArray) -> void:
	if _ws != null and _ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
		_ws.send(bytes)                                  # PackedByteArray -> WRITE_MODE_BINARY frame

# Host -> guests: round over.
func broadcast_end(reason: String, winner_el: String, standings: Array) -> void:
	if role != "host":
		return
	started = false
	_send({ "t": "end", "reason": reason, "win": winner_el, "standings": standings })

# ------------------------------------------------------------------ helpers
func _broadcast_lobby() -> void:
	_send({ "t": "lobby", "players": _roster(), "admin": admin_id, "code": current_code })

func _emit_lobby_local() -> void:
	lobby_changed.emit(_roster(), my_id, admin_id, current_code)

func _roster() -> Array:
	var players: Array = []
	for id in lobby:
		players.append({ "id": id, "name": lobby[id]["name"], "el": lobby[id]["el"] })
	return players

# make a lobby name unique ("Player", "Player 2", …) so the host can tell joiners
# apart even when several arrive through the same invite link
func _unique_name(base: String) -> String:
	var n := base.strip_edges()
	if n == "":
		n = "Player"
	var taken := {}
	for id in lobby:
		taken[lobby[id]["name"]] = true
	if not taken.has(n):
		return n
	var i := 2
	while taken.has("%s %d" % [n, i]):
		i += 1
	return "%s %d" % [n, i]

static func gen_code() -> String:
	var letters := "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"   # no easily-confused chars
	var s := ""
	for i in CODE_LEN:
		s += letters[randi() % letters.length()]
	return s
