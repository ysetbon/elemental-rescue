class_name NetManager
extends Node
# Online multiplayer transport + lobby/room management for Elemental Rescue.
#
# Lives at /root/Game/Net (created by game.gd in _ready) so that @rpc node paths
# match on the dedicated server and on every browser client.
#
# Topology: ONE authoritative dedicated server (a headless copy of the game,
# `--server`) and many web clients over WebSocket (wss:// in production, ws://
# for local testing). The server owns a single room gated by a short code: the
# admin "hosts" (reserves the code) and friends "join" with it. All gameplay is
# decided on the server; clients render snapshots (P3+).
#
# This file is the lobby/handshake layer (Phase 0). Per-frame input and snapshot
# replication are layered on in later phases.

signal joined_room(code: String)                       # client: server accepted us
signal join_failed(reason: String)                     # client: rejected / error
signal lobby_changed(players: Array, my_id: int, admin_id: int, code: String)
signal match_starting(world_seed: int, humans: Array)  # client: round is starting
signal connection_lost()                               # client: server vanished

const MAX_PLAYERS := 7
const DEFAULT_PORT := 8910
const CODE_LEN := 4

var game: Node = null

# --- server-side room state ---
var room_code: String = ""
var started: bool = false
var admin_peer: int = 0
var lobby: Dictionary = {}        # peer_id -> { "name": String, "el": String }

# --- client-side state ---
var is_server: bool = false
var my_name: String = "Player"
var current_code: String = ""     # the code this client is in (for display/sharing)
var _pending_action := ""         # "create" | "join", run once connected
var _pending_code := ""

# ------------------------------------------------------------------ server
func setup_server(port: int) -> void:
	is_server = true
	var peer := WebSocketMultiplayerPeer.new()
	var err := peer.create_server(port, "*")
	if err != OK:
		push_error("[net] create_server(%d) failed: %s" % [port, error_string(err)])
		return
	multiplayer.multiplayer_peer = peer
	if not multiplayer.peer_connected.is_connected(_on_peer_connected):
		multiplayer.peer_connected.connect(_on_peer_connected)
	if not multiplayer.peer_disconnected.is_connected(_on_peer_disconnected):
		multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	print("[net] dedicated server listening on port %d" % port)

func _on_peer_connected(id: int) -> void:
	print("[net] peer connected: ", id)   # they still have to create/join

func _on_peer_disconnected(id: int) -> void:
	if not lobby.has(id):
		return
	lobby.erase(id)
	if id == admin_peer:
		# hand the room to whoever's left, or close it if empty
		admin_peer = lobby.keys()[0] if lobby.size() > 0 else 0
	if lobby.is_empty():
		room_code = ""
		started = false
		admin_peer = 0
		print("[net] room empty — reset")
	else:
		_broadcast_lobby()

# ------------------------------------------------------------------ client
func connect_to(url: String, name_: String, action: String, code: String) -> void:
	is_server = false
	my_name = name_.strip_edges()
	if my_name == "":
		my_name = "Player"
	_pending_action = action
	_pending_code = code.strip_edges().to_upper()
	var peer := WebSocketMultiplayerPeer.new()
	var err := peer.create_client(url)
	if err != OK:
		join_failed.emit("Couldn't start connection (%s)" % error_string(err))
		return
	multiplayer.multiplayer_peer = peer
	if not multiplayer.connected_to_server.is_connected(_on_connected):
		multiplayer.connected_to_server.connect(_on_connected)
	if not multiplayer.connection_failed.is_connected(_on_connect_failed):
		multiplayer.connection_failed.connect(_on_connect_failed)
	if not multiplayer.server_disconnected.is_connected(_on_server_disconnected):
		multiplayer.server_disconnected.connect(_on_server_disconnected)

func _on_connected() -> void:
	if _pending_action == "create":
		_req_create.rpc_id(1, _pending_code, my_name)
	else:
		_req_join.rpc_id(1, _pending_code, my_name)

func _on_connect_failed() -> void:
	join_failed.emit("Couldn't reach the server. It may be waking up — try again in a minute.")
	_reset_peer()

func _on_server_disconnected() -> void:
	connection_lost.emit()
	_reset_peer()

func _reset_peer() -> void:
	multiplayer.multiplayer_peer = null

# convenience for the UI/game
func leave() -> void:
	_reset_peer()
	lobby.clear()
	room_code = ""
	current_code = ""
	started = false

func choose_element(el: String) -> void:
	_req_set_element.rpc_id(1, el)

func start_match() -> void:
	_req_start.rpc_id(1)

static func gen_code() -> String:
	var letters := "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"   # no easily-confused chars
	var s := ""
	for i in CODE_LEN:
		s += letters[randi() % letters.length()]
	return s

# ===================================================================
#  RPCs — server side (called by clients via rpc_id(1, ...))
# ===================================================================
@rpc("any_peer", "reliable")
func _req_create(code: String, name_: String) -> void:
	var sender := multiplayer.get_remote_sender_id()
	if room_code != "":
		_reject.rpc_id(sender, "A game already exists here. Ask the host for the code and tap Join.")
		return
	room_code = code.strip_edges().to_upper()
	if room_code == "":
		room_code = gen_code()
	admin_peer = sender
	lobby[sender] = { "name": name_, "el": "fire" }
	_accept.rpc_id(sender, room_code)
	_broadcast_lobby()
	print("[net] room %s created by %d" % [room_code, sender])

@rpc("any_peer", "reliable")
func _req_join(code: String, name_: String) -> void:
	var sender := multiplayer.get_remote_sender_id()
	var want := code.strip_edges().to_upper()
	if room_code == "" or want != room_code:
		_reject.rpc_id(sender, "No game with that code. Check it with the host.")
		return
	if started:
		_reject.rpc_id(sender, "That game already started.")
		return
	if lobby.size() >= MAX_PLAYERS:
		_reject.rpc_id(sender, "Game is full (%d players)." % MAX_PLAYERS)
		return
	lobby[sender] = { "name": name_, "el": "fire" }
	_accept.rpc_id(sender, room_code)
	_broadcast_lobby()

@rpc("any_peer", "reliable")
func _req_set_element(el: String) -> void:
	var sender := multiplayer.get_remote_sender_id()
	if started or not lobby.has(sender):
		return
	if el in ["fire", "water", "grass"]:
		lobby[sender]["el"] = el
		_broadcast_lobby()

@rpc("any_peer", "reliable")
func _req_start() -> void:
	var sender := multiplayer.get_remote_sender_id()
	if sender != admin_peer or started or lobby.is_empty():
		return
	started = true
	var world_seed := randi()
	var humans: Array = []
	for pid in lobby:
		humans.append({ "peer": pid, "el": lobby[pid]["el"], "name": lobby[pid]["name"] })
	_match_started.rpc(world_seed, humans)
	if game and game.has_method("server_start_match"):
		game.server_start_match(world_seed, humans)   # P2+ spins up the sim
	print("[net] match started, seed=%d, humans=%d" % [world_seed, humans.size()])

func _broadcast_lobby() -> void:
	var players: Array = []
	for pid in lobby:
		players.append({ "id": pid, "name": lobby[pid]["name"], "el": lobby[pid]["el"] })
	_lobby_state.rpc(players, admin_peer, room_code)

# ===================================================================
#  RPCs — client side (called by the server via rpc / rpc_id)
# ===================================================================
@rpc("authority", "reliable")
func _accept(code: String) -> void:
	current_code = code
	joined_room.emit(code)

@rpc("authority", "reliable")
func _reject(reason: String) -> void:
	join_failed.emit(reason)
	_reset_peer()

@rpc("authority", "reliable")
func _lobby_state(players: Array, admin_id: int, code: String) -> void:
	current_code = code
	lobby_changed.emit(players, multiplayer.get_unique_id(), admin_id, code)

@rpc("authority", "reliable")
func _match_started(world_seed: int, humans: Array) -> void:
	match_starting.emit(world_seed, humans)
