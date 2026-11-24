class_name SkyQuests
extends RefCounted
# ASCENT — tier tasks, the task isles and caged helpers.
#
# TIER TASKS. Lighting your Spark opens tier 1. From there every terrace (tiers
# 1..4) keeps its stair AND your shortcut pad locked until that tier's task is
# done. Each tier has a task stone: walk up to it and press E (or stand beside
# it) to be given the task. The four tasks are all different:
#   tier 1  RESCUE  free a caged friend (Roost Rock, the wild isles, Heart Isle)
#   tier 2  BEACON  light the lighthouse on Beacon Isle (stand in its ring for 3 s)
#   tier 3  KEY     fetch the Sun Key from the Sun Shrine and carry it back to the stone
#   tier 4  SEAL    stand on the Sun Seal on that terrace for 6 s without being tagged
# Tasks are per element TEAM and stay done for the round, so a tier you unlocked
# is still open after you are knocked down. Rivals do the same tasks. A task whose
# isle the smog sea has swallowed is not a dead end: the Sun Key drifts to safe
# ground like the motes do, and the beacon task is waived.
#
# CAGED HELPERS. Each cage holds a small elemental. Anyone can free it (press E /
# stand beside the cage) and it then works for the team that freed it:
#   - if it can eat one of your rivals it CHASES that rival, circling it and
#     darting in to slow it (plus a small shove on open ground) every few seconds;
#   - otherwise (it would only eat your own element) it GUARDS you: it stays at
#     your side and throws itself at smog clouds, spending their oxygen.
# Like the smog, hunters do not climb above tier 2. A helper lasts until it has
# soaked two smog clouds, a rival that eats its element touches it, or it tires.
#
# WIND CHIMES (a bonus, not a task): one hangs on each terrace 1..4 and mends a
# heart when a hurt climber touches it, then rests for a while.

const TASK_TIERS := 4
const TASK_TITLE := ["", "free a caged friend", "light the beacon on Beacon Isle", "fetch the Sun Key from the Sun Shrine", "hold the Sun Seal"]
const STONE_REL_ANG := 80.0      # the task stone sits this far round from the tier's stair
const STONE_REACH := 2.7
const STONE_R := 0.55
const USE_DWELL := 0.7           # stand this long beside a stone / cage to use it (no key needed)
const CAGE_REACH := 2.9
const CAGE_REFILL := 30.0        # an emptied cage holds a new captive after this long
const CAGE_R := 1.15
const BEACON_OFF := 4.4          # the lighting ring: this far from Beacon Isle's centre, toward Heart Isle
const BEACON_R := 2.6
const BEACON_TIME := 3.0
const KEY_PICK := 2.6
const SEAL_REL_ANG := 250.0
const SEAL_R := 2.0
const SEAL_TIME := 6.0
const CHIME_REL_ANG := 115.0
const CHIME_PICK := 1.9
const CHIME_REST := 40.0
const HELPER_MAX := 2            # per team; freeing a third sends the oldest home
const HELPER_SCALE := 0.6
const HELPER_HP := 2
const HELPER_LIFE := 90.0
const HELPER_TAG_CD := 9.0
const HELPER_SLOW := 3.5
const HELPER_SHOVE := 3.0
const HELPER_MAX_TIER := 2
const ELS := ["fire", "water", "grass"]
const CH_STONE := 1
const CH_CAGE := 2
const CH_BEACON := 3
const CH_SEAL := 4
const CH_LABEL := ["", "Reading the task stone", "Opening the cage", "Lighting the beacon", "Holding the Sun Seal"]

static var CAGE_SPOTS: Array = []      # [Vector3] — fixed per world build (see place())

var m                                  # ModeAscent
var g                                  # Game
var done := { "fire": 0, "water": 0, "grass": 0 }      # tasks finished = highest tier whose way up is open
var active := { "fire": 0, "water": 0, "grass": 0 }    # the task a team has been given (0 = none yet)
var freed := { "fire": 0, "water": 0, "grass": 0 }     # cages a team has opened this round
var key_state := { "fire": 0, "water": 0, "grass": 0 } # 0 none | 1 lying somewhere | 2 carried
var key_pos := { "fire": Vector3.ZERO, "water": Vector3.ZERO, "grass": Vector3.ZERO }
var _key_rel := { "fire": 0.0, "water": 0.0, "grass": 0.0 }
var beacon_el := ""                    # the team that lit the lighthouse last (its lamp shows their colour)
var cages: Array = []                  # [{ "pos": Vector3, "el": String ("" = empty), "refill": float }]
var chime_rest: Array = [0.0, 0.0, 0.0, 0.0]            # per terrace 1..4: seconds until the chime sounds again
var helpers: Array = []                # [GameChar] — small freed elementals (is_twin; state in .ai)
var helper_team := {}                  # net_id -> team element (mirrored to guests for the ring colour)
var chan_view: Array = [0, 0.0]        # GUEST: my own channel [kind, 0..1] as the host sees it

func _init(mode) -> void:
	m = mode
	g = mode.g

# ------------------------------------------------------------------ geometry
static func stone_pos(k: int) -> Vector2:
	return SkyLayout.pol(SkyLayout.ramp_ang(k) + STONE_REL_ANG, SkyLayout.tier_inner(k) + 1.1)

static func chime_pos(k: int) -> Vector2:
	return SkyLayout.pol(SkyLayout.ramp_ang(k) + CHIME_REL_ANG, SkyLayout.band_mid(k))

static func seal_pos() -> Vector2:
	return SkyLayout.pol(SkyLayout.ramp_ang(4) + SEAL_REL_ANG, SkyLayout.band_mid(4))

static func isle_pos(id: String) -> Vector2:
	SkyLayout.ensure()
	var is_: Dictionary = SkyLayout.NODES[id]
	return Vector2(is_["x"], is_["z"])

# where you stand to light the lighthouse: in front of its door, on the Heart Isle side
static func beacon_pos() -> Vector2:
	var c := isle_pos("beacon")
	return c - c.normalized() * BEACON_OFF

# the Sun Key's resting place: the shrine altar
static func shrine_pos() -> Vector3:
	var c := isle_pos("shrine")
	return Vector3(c.x, 0.0, c.y)

# Seven cages: two on Roost Rock, one on each wild isle, two against the spire wall
# on Heart Isle (which the smog sea never reaches). Called once per world build,
# BEFORE the cages' own colliders are registered, so every cage stands clear of
# the Blender props; the result is the same on the host and on every guest.
static func place(obstacles: Array) -> void:
	SkyLayout.ensure()
	CAGE_SPOTS.clear()
	var rc := isle_pos("roost")
	var lat := Vector2(-rc.y, rc.x).normalized()
	for s in [1.0, -1.0]:
		var p: Vector2 = rc + lat * (4.6 * s)
		CAGE_SPOTS.append(Vector3(p.x, 0.0, p.y))
	for id in ["w30", "w150", "w270"]:
		var is_: Dictionary = SkyLayout.NODES[id]
		var c := Vector2(is_["x"], is_["z"])
		var pick := c
		var found := false
		for d in [5.0, 7.5, 3.0, 10.0]:
			for a in [90.0, -90.0, 55.0, -55.0, 125.0, -125.0, 0.0, 180.0]:
				var q: Vector2 = c + SkyLayout.pol(float(is_["ang"]) + a, d)
				if not found and _clear(q, obstacles):
					pick = q
					found = true
		CAGE_SPOTS.append(Vector3(pick.x, 0.0, pick.y))
	for base in [60.0, 172.0]:
		var pick2 := SkyLayout.pol(base, 21.4)
		for off in [0.0, -7.0, 7.0, -14.0, 14.0]:
			var q2 := SkyLayout.pol(base + off, 21.4)
			if _clear(q2, obstacles):
				pick2 = q2
				break
		CAGE_SPOTS.append(Vector3(pick2.x, 0.0, pick2.y))

static func _clear(p: Vector2, obstacles: Array) -> bool:
	for o in obstacles:
		if Vector2(float(o["x"]) - p.x, float(o["z"]) - p.y).length() < float(o["r"]) + CAGE_R + 1.3:
			return false
	return true

func reset() -> void:
	for el in ELS:
		done[el] = 0
		active[el] = 0
		freed[el] = 0
		key_state[el] = 0
		key_pos[el] = Vector3.ZERO
		_key_rel[el] = 0.0
	for h in helpers:
		if h.group and is_instance_valid(h.group) and not h.group.is_queued_for_deletion():
			h.group.queue_free()
	helpers.clear()
	helper_team.clear()
	beacon_el = ""
	chan_view = [0, 0.0]
	chime_rest = [0.0, 0.0, 0.0, 0.0]
	if CAGE_SPOTS.is_empty():
		place([])
	cages.clear()
	var first := ["water", "fire", "grass", "fire", "water", "grass", "fire"]
	for i in CAGE_SPOTS.size():
		cages.append({ "pos": CAGE_SPOTS[i], "el": first[i % first.size()], "refill": 0.0 })

# May this team go up from tier k?  (tier 0: a lit Spark; tiers 1..4: that tier's task)
func can_go_up(el: String, k: int) -> bool:
	if k <= 0:
		return m.lit(el)
	if k > TASK_TIERS:
		return false
	return int(done.get(el, 0)) >= k

# the tier whose task this team has to do next (5 = none left)
func frontier(el: String) -> int:
	return int(done[el]) + 1

# has the smog sea swallowed a task isle?
func lost(id: String) -> bool:
	var is_: Dictionary = SkyLayout.NODES[id]
	return float(is_["d"]) + float(is_["r"]) * 0.3 > m.smog_goal()

# What the freed captive will do for `team`.
func helper_job(captive_el: String, team: String) -> String:
	var tel: String = g._prey_of(captive_el)
	if tel != team:
		return "chase and slow %s for you" % g.ELEMENTS[tel]["label"]
	return "guard you against the smog clouds"

func helper_count(team: String) -> int:
	var n := 0
	for nid in helper_team:
		if String(helper_team[nid]) == team:
			n += 1
	return n

# ------------------------------------------------------------------ authority tick
func tick(dt: float) -> void:
	for c in cages:
		if String(c["el"]) == "" and float(c["refill"]) > 0.0:
			c["refill"] = float(c["refill"]) - dt
			if float(c["refill"]) <= 0.0:
				c["el"] = ELS[randi() % ELS.size()]
	for i in chime_rest.size():
		chime_rest[i] = maxf(0.0, float(chime_rest[i]) - dt)
	for ch in g.actors:
		if ch.alive and ch.busy == m.BUSY_NONE:
			_tick_actor(ch, dt)
		else:
			ch.ai.erase("chan")
	for t in ELS:
		if int(active[t]) == 2 and lost("beacon"):
			_complete(t, 2, "The smog sea took Beacon Isle — the task stone lets you pass.")
	_tick_keys(dt)
	for h in helpers.duplicate():
		_update_helper(h, dt)
	_helper_contacts()

func _tick_actor(ch: GameChar, dt: float) -> void:
	var t := ch.el
	var me := Vector2(ch.pos.x, ch.pos.z)
	var n := frontier(t)
	var pressed: bool = ch.is_player and m._climb_pressed()
	var chan := 0
	var frac := 0.0
	# ---- the task stone on my frontier tier
	if n <= TASK_TIERS and ch.tier == n and int(active[t]) != n and me.distance_to(stone_pos(n)) < STONE_REACH:
		chan = CH_STONE
		ch.ai["use_t"] = float(ch.ai.get("use_t", 0.0)) + dt
		frac = float(ch.ai["use_t"]) / USE_DWELL
		if pressed or frac >= 1.0:
			ch.ai["use_t"] = 0.0
			_accept(t, n)
	# ---- a cage with someone in it
	if ch.tier == 0 and chan == 0:
		for i in cages.size():
			var c: Dictionary = cages[i]
			if String(c["el"]) != "" and m.flat_dist(ch.pos, c["pos"]) < CAGE_REACH:
				chan = CH_CAGE
				ch.ai["use_t"] = float(ch.ai.get("use_t", 0.0)) + dt
				frac = float(ch.ai["use_t"]) / USE_DWELL
				if pressed or frac >= 1.0:
					ch.ai["use_t"] = 0.0
					_free_cage(i, ch)
				break
	if chan == 0:
		ch.ai["use_t"] = 0.0
	# ---- the task in progress
	match int(active[t]):
		2:
			if ch.tier == 0 and me.distance_to(beacon_pos()) < BEACON_R:
				ch.ai["hold_t"] = float(ch.ai.get("hold_t", 0.0)) + dt
				chan = CH_BEACON
				frac = float(ch.ai["hold_t"]) / BEACON_TIME
				if frac >= 1.0:
					ch.ai["hold_t"] = 0.0
					beacon_el = t
					_complete(t, 2, "The beacon burns in your colour — tier 2 is open!")
			else:
				ch.ai["hold_t"] = 0.0
		3:
			if int(key_state[t]) == 1 and ch.tier == 0 and m.flat_dist(ch.pos, key_pos[t]) < KEY_PICK:
				key_state[t] = 2
				if _mine(t):
					g.ui.toast("You have the Sun Key — carry it back up to the tier 3 task stone")
			elif int(key_state[t]) == 2 and ch.tier == 3 and me.distance_to(stone_pos(3)) < STONE_REACH + 0.6:
				_complete(t, 3, "The Sun Key turns in the stone — tier 3 is open!")
		4:
			if ch.tier == 4 and me.distance_to(seal_pos()) < SEAL_R:
				ch.ai["hold_t"] = float(ch.ai.get("hold_t", 0.0)) + dt
				chan = CH_SEAL
				frac = float(ch.ai["hold_t"]) / SEAL_TIME
				if frac >= 1.0:
					ch.ai["hold_t"] = 0.0
					_complete(t, 4, "The Sun Seal is yours — the way to the bell is open!")
			else:
				ch.ai["hold_t"] = 0.0
	# ---- wind chimes: a hurt climber who touches one gets a heart back
	if ch.tier >= 1 and ch.tier <= TASK_TIERS and ch.hp < ch.max_hp and float(chime_rest[ch.tier - 1]) <= 0.0 \
			and me.distance_to(chime_pos(ch.tier)) < CHIME_PICK:
		chime_rest[ch.tier - 1] = CHIME_REST
		ch.hp += 1
		ch.score += 5
		m._stat("chimes")
		if ch.is_player and g.ui:
			g.ui.toast("The wind chime mends a heart")
			g._update_hud_hearts()
	if chan != 0:
		ch.ai["chan"] = [chan, clampf(frac, 0.0, 1.0)]
	else:
		ch.ai.erase("chan")

func _mine(t: String) -> bool:
	return g.ui != null and g.player != null and g.player.el == t

func _accept(t: String, n: int) -> void:
	active[t] = n
	m._stat("tasks_given")
	if _mine(t):
		g.ui.toast("Tier %d task: %s" % [n, TASK_TITLE[n]])
	match n:
		1:
			if int(freed[t]) > 0:
				_complete(t, 1, "You have already freed a friend — tier 1 is open!")
		2:
			if lost("beacon"):
				_complete(t, 2, "The smog sea took Beacon Isle — the task stone lets you pass.")
		3:
			key_state[t] = 1
			key_pos[t] = m._safe_mote_spot(shrine_pos()) if lost("shrine") else shrine_pos()
			_key_rel[t] = 0.0

func _complete(t: String, n: int, msg: String = "") -> void:
	done[t] = maxi(int(done[t]), n)
	active[t] = 0
	if n == 3:
		key_state[t] = 0
	m._stat("tasks_done")
	if m._trace:
		print("[quest %s] %s finished the tier %d task" % [g._fmt_time(m.elapsed), t, n])
	for ch in g.by_el.get(t, []):
		ch.score += 20
	if _mine(t):
		g.ui.toast(msg if msg != "" else "Task done — tier %d's stairs and your %s are open!" % [n, m.PAD_NAME[t]])

# a Sun Key left on swallowed ground drifts to safe ground, like the motes
func _tick_keys(dt: float) -> void:
	var sr: float = m.smog_r()
	for t in ELS:
		if int(key_state[t]) != 1:
			continue
		if m.radius(key_pos[t]) > sr - 1.0:
			_key_rel[t] = float(_key_rel[t]) + dt
			if float(_key_rel[t]) >= m.MOTE_RELOCATE_DELAY:
				_key_rel[t] = 0.0
				key_pos[t] = m._safe_mote_spot(key_pos[t])
		else:
			_key_rel[t] = 0.0

func on_hit(victim: GameChar) -> void:
	victim.ai["hold_t"] = 0.0
	victim.ai["use_t"] = 0.0

# ------------------------------------------------------------------ cages + helpers
func _free_cage(i: int, by: GameChar) -> void:
	var c: Dictionary = cages[i]
	var el: String = c["el"]
	c["el"] = ""
	c["refill"] = CAGE_REFILL
	m._stat("cages_freed")
	var team := by.el
	freed[team] = int(freed[team]) + 1
	var h: GameChar = g.make_character("element", el)
	h.is_twin = true            # friendly, never a catch target; guests draw it small
	h.max_hp = 999
	h.hp = 999
	h.tier = 0
	h.pos = c["pos"]
	h.ai = { "team": team, "hp": HELPER_HP, "tag_cd": 2.0, "life": HELPER_LIFE, "leap_cd": 0.0, "phase": randf() * TAU, "stuck": 0.0 }
	if h.group:
		h.group.position = h.pos
		h.group.scale = Vector3.ONE * HELPER_SCALE
	var mine: Array = helpers.filter(func(x): return String(x.ai.get("team", "")) == team)
	if mine.size() >= HELPER_MAX:
		_poof(mine[0])
	helpers.append(h)
	helper_team[h.net_id] = team
	if _mine(team):
		g.ui.toast("You freed a little %s — it will %s!" % [g.ELEMENTS[el]["label"], helper_job(el, team)])
	if int(active[team]) == 1:
		_complete(team, 1, "A friend is free — tier 1's stairs and your %s are open!" % m.PAD_NAME[team])

func _poof(h: GameChar) -> void:
	helpers.erase(h)
	helper_team.erase(h.net_id)
	h.alive = false
	if h.group and is_instance_valid(h.group):
		h.group.queue_free()
	h.group = null

func _hurt(h: GameChar) -> void:
	h.ai["hp"] = int(h.ai.get("hp", 1)) - 1
	if int(h.ai["hp"]) <= 0:
		if _mine(String(h.ai.get("team", ""))):
			g.ui.toast("Your little %s is spent — free another from a cage" % g.ELEMENTS[h.el]["label"])
		_poof(h)

# the team member a helper serves: the human if there is one
func _lead(team: String) -> GameChar:
	var best: GameChar = null
	for ch in g.by_el.get(team, []):
		if not ch.alive:
			continue
		if ch.is_human:
			return ch
		if best == null:
			best = ch
	return best

func _update_helper(h: GameChar, dt: float) -> void:
	var st: Dictionary = h.ai
	var team: String = st.get("team", "")
	st["life"] = float(st["life"]) - dt
	st["tag_cd"] = maxf(0.0, float(st["tag_cd"]) - dt)
	st["leap_cd"] = maxf(0.0, float(st["leap_cd"]) - dt)
	if h.slow_timer > 0.0:
		h.slow_timer = maxf(0.0, h.slow_timer - dt)
	if float(st["life"]) <= 0.0:
		if _mine(team):
			g.ui.toast("Your little %s has gone home to rest" % g.ELEMENTS[h.el]["label"])
		_poof(h)
		return
	if h.busy == m.BUSY_FLY:
		m.advance_fly(h, dt)
		return
	var lead := _lead(team)
	if lead == null or lead.busy != m.BUSY_NONE:
		h.vel = Vector3.ZERO
		return
	# ---- job: chase the rival it can eat, else guard its leader
	var target: GameChar = null
	var tel: String = g._prey_of(h.el)
	if tel != team:
		var bd := 1.0e20
		for a in g.by_el.get(tel, []):
			if not a.alive or a.busy != m.BUSY_NONE or a.tier > HELPER_MAX_TIER:
				continue
			if a.tier == 0 and g.inside_own_cave(a):
				continue
			var d: float = m.flat_dist(h.pos, a.pos) + (0.0 if a.tier == h.tier else 12.0)
			if d < bd:
				bd = d
				target = a
	var anchor: GameChar = target if target != null else lead
	var anchor_tier: int = mini(anchor.tier, HELPER_MAX_TIER) if tel != team else anchor.tier
	var goal: Vector3 = anchor.pos
	if target != null:
		if float(st["tag_cd"]) > 0.0:
			var oa: float = m.elapsed * 2.2 + float(st["phase"])        # circle the rival between darts
			goal = target.pos + Vector3(cos(oa), 0.0, sin(oa)) * 3.2
		elif h.tier == target.tier and m.flat_dist(h.pos, target.pos) < 2.0:
			_helper_tag(h, target)
	else:
		var cloud: GameChar = null
		var cd := 13.0
		for n in g.npcs:
			if n.kind == "co2" and n.alive and n.co_timer <= 0.0 and n.tier == lead.tier and n.tier == h.tier:
				var d2: float = m.flat_dist(lead.pos, n.pos)
				if d2 < cd:
					cd = d2
					cloud = n
		if cloud != null:
			goal = cloud.pos                                            # throw itself at the smog
		else:
			var ga: float = m.elapsed * 1.4 + float(st["phase"])
			goal = lead.pos + Vector3(cos(ga), 0.0, sin(ga)) * 2.6
	# ---- on another tier, far away or stuck at an edge: leap to the anchor
	if (h.tier != anchor_tier or m.flat_dist(h.pos, anchor.pos) > 28.0 or float(st["stuck"]) > 0.8) and float(st["leap_cd"]) <= 0.0:
		if h.tier != anchor_tier or anchor_tier == anchor.tier:
			_helper_leap(h, anchor, anchor_tier)
			return
	if h.tier != anchor.tier:
		h.vel = Vector3.ZERO           # a hunter whose leader climbed past tier 2 waits below
		return
	var to := Vector3(goal.x - h.pos.x, 0.0, goal.z - h.pos.z)
	var dist := to.length()
	if dist < 0.25:
		h.vel = Vector3.ZERO
	else:
		var dir := to / dist
		var sp: float = h.speed * 1.05 * g._slow_mult(h)
		var step := minf(dist, sp * dt)
		var nx := h.pos.x + dir.x * step
		var nz := h.pos.z + dir.z * step
		var ok := true
		if h.tier == 0:
			ok = SkyLayout.on_ground(nx, nz, h.el, m.vines_mask(), 0.0) and (nx * nx + nz * nz) > 20.4 * 20.4
		else:
			var r := sqrt(nx * nx + nz * nz)
			var lo: float = SkyLayout.tier_inner(h.tier) + 0.6
			var hi: float = SkyLayout.tier_outer(h.tier) - 0.6
			if r > 0.01 and (r < lo or r > hi):
				var k := clampf(r, lo, hi) / r
				nx *= k
				nz *= k
		if ok:
			h.pos.x = nx
			h.pos.z = nz
			h.vel = dir * sp
			st["stuck"] = 0.0
		else:
			h.vel = Vector3.ZERO
			st["stuck"] = float(st["stuck"]) + dt
	h.pos.y = float(h.tier) * SkyLayout.SPIRE_TIER_H

func _helper_leap(h: GameChar, anchor: GameChar, to_tier: int) -> void:
	var a := randf() * TAU
	var p := Vector3(anchor.pos.x + cos(a) * 2.4, 0.0, anchor.pos.z + sin(a) * 2.4)
	if to_tier == 0:
		if not SkyLayout.on_ground(p.x, p.z, h.el, m.vines_mask(), 0.0) or (p.x * p.x + p.z * p.z) < 20.6 * 20.6:
			p = Vector3(anchor.pos.x, 0.0, anchor.pos.z)
	else:
		var r := maxf(0.01, sqrt(p.x * p.x + p.z * p.z))
		var k := clampf(r, SkyLayout.tier_inner(to_tier) + 0.7, SkyLayout.tier_outer(to_tier) - 0.7) / r
		p.x *= k
		p.z *= k
	p.y = float(to_tier) * SkyLayout.SPIRE_TIER_H
	m._launch(h, p, to_tier, 0.55, 2.6)
	h.ai["leap_cd"] = 2.5
	h.ai["stuck"] = 0.0

func _helper_tag(h: GameChar, target: GameChar) -> void:
	h.ai["tag_cd"] = HELPER_TAG_CD
	m._stat("helper_tags")
	target.slow_timer = maxf(target.slow_timer, HELPER_SLOW)
	if target.tier == 0:
		# a small shove too — but never one that could carry the rival over an edge
		var d := Vector3(target.pos.x - h.pos.x, 0.0, target.pos.z - h.pos.z)
		if d.length() < 0.05:
			d = Vector3(1, 0, 0)
		d = d.normalized()
		var ex := target.pos.x + d.x * (HELPER_SHOVE + 1.5)
		var ez := target.pos.z + d.z * (HELPER_SHOVE + 1.5)
		if SkyLayout.node_of(target.pos.x, target.pos.z) != "" and SkyLayout.node_of(ex, ez) != "":
			target.kb_vel = d * (HELPER_SHOVE / m.SHOVE_TIME)
			target.kb_t = m.SHOVE_TIME
	if g.ui == null or g.player == null:
		return
	var nm: String = g.ELEMENTS[h.el]["label"]
	if target == g.player:
		if g._eats(g.player.el, h.el):
			g.ui.toast("A little %s slowed you — touch it to send it home" % nm)
		else:
			g.ui.toast("A little %s slowed you — it cannot follow above tier %d" % [nm, HELPER_MAX_TIER])
	elif _mine(String(h.ai.get("team", ""))):
		g.ui.toast("Your little %s slowed %s!" % [nm, g.ELEMENTS[target.el]["label"]])

# smog clouds and rivals touching helpers
func _helper_contacts() -> void:
	for h in helpers.duplicate():
		if h.busy != m.BUSY_NONE:
			continue
		var team: String = h.ai.get("team", "")
		var gone := false
		for n in g.npcs:
			if n.kind == "co2" and n.alive and n.co_timer <= 0.0 and n.tier == h.tier and m.flat_dist(h.pos, n.pos) < 2.3:
				g._co2_to_co(n)                 # the helper soaks the cloud's oxygen
				m._stat("helper_guards")
				if _mine(team):
					g.ui.toast("Your little %s soaked up a smog cloud!" % g.ELEMENTS[h.el]["label"])
				_hurt(h)
				gone = not helpers.has(h)
				break
		if gone:
			continue
		for a in g.actors:
			if a.alive and a.busy == m.BUSY_NONE and a.el != team and a.tier == h.tier and g._eats(a.el, h.el) \
					and m.flat_dist(h.pos, a.pos) < 2.2:
				if a.is_player and g.ui != null:
					g.ui.toast("You sent the little %s home" % g.ELEMENTS[h.el]["label"])
				m._stat("helpers_sent_home")
				_poof(h)
				break

# ------------------------------------------------------------------ rival AI
# An errand on the ground layer (a cage to open, the beacon, a Sun Key to pick up):
# { "pt": Vector2, "stop": float, "key": String }, or {} for none.
func ground_errand(ch: GameChar) -> Dictionary:
	var t := ch.el
	match int(active[t]):
		1:
			var best := -1
			var bd := 1.0e20
			for i in cages.size():
				var c: Dictionary = cages[i]
				if String(c["el"]) == "":
					continue
				var cp: Vector3 = c["pos"]
				if m.radius(cp) > m.smog_goal() - 3.0:
					continue                    # not into the smog for it
				var d: float = m.flat_dist(ch.pos, cp)
				if d < bd:
					bd = d
					best = i
			if best >= 0:
				var p: Vector3 = cages[best]["pos"]
				return { "pt": Vector2(p.x, p.z), "stop": CAGE_REACH - 0.8, "key": "cage%d" % best }
		2:
			return { "pt": beacon_pos(), "stop": 1.0, "key": "beacon" }
		3:
			if int(key_state[t]) == 1:
				var kp: Vector3 = key_pos[t]
				return { "pt": Vector2(kp.x, kp.z), "stop": 0.6, "key": "key" }
	return {}

# Quest business on the spire for a rival: null = nothing to do here, carry on climbing.
func spire_dir(ch: GameChar):
	var t := ch.el
	var k := ch.tier
	if k <= 0:
		return null
	if not ground_errand(ch).is_empty():
		return _descend_dir(ch)
	var n := frontier(t)
	if n > TASK_TIERS or k < n:
		return null
	if int(active[t]) != n:
		return _to_point(ch, stone_pos(n), 1.9)
	match n:
		3:
			if int(key_state[t]) == 2:
				return _to_point(ch, stone_pos(3), 1.9)
		4:
			return _to_point(ch, seal_pos(), 0.7)
	return Vector3.ZERO      # e.g. waiting for a cage to refill

# walk round the terrace (outside the stair's foot) to a point on this tier
func _to_point(ch: GameChar, p: Vector2, stop: float) -> Vector3:
	var x := ch.pos.x
	var z := ch.pos.z
	var to := Vector3(p.x - x, 0.0, p.y - z)
	if to.length() <= stop:
		return Vector3.ZERO
	var r := maxf(0.001, sqrt(x * x + z * z))
	var ang := SkyLayout.ang_of(x, z)
	var d := SkyLayout.ang_diff(ang, SkyLayout.ang_of(p.x, p.y))
	if absf(d) * deg_to_rad(1.0) * r < 4.5:
		return to
	var k := ch.tier
	var rc := minf(SkyLayout.tier_inner(k) + float(SkyLayout.SPIRE_RAMP_RUN[k]) + 0.4, SkyLayout.tier_outer(k) - 0.5)
	return ModeAscent._tangent(ang, d, r, rc)

# back down the stair we came up (its gap in the parapet is at the lower tier's stair angle)
func _descend_dir(ch: GameChar) -> Vector3:
	var k := ch.tier
	var x := ch.pos.x
	var z := ch.pos.z
	var r := maxf(0.001, sqrt(x * x + z * z))
	var ang := SkyLayout.ang_of(x, z)
	var d := SkyLayout.ang_diff(ang, SkyLayout.ramp_ang(k - 1))
	if absf(d) < 4.0:
		var th := deg_to_rad(ang)
		return Vector3(cos(th), 0.0, sin(th)) + Vector3(-sin(th), 0.0, cos(th)) * clampf(d / 8.0, -0.5, 0.5)
	return ModeAscent._tangent(ang, d, r, SkyLayout.tier_outer(k) - 0.8)

# ------------------------------------------------------------------ per frame (host + guests)
func frame(_dt: float) -> void:
	for h in helpers:
		if h.group == null or not is_instance_valid(h.group):
			continue
		h.group.position = h.pos
		if h.vel.length_squared() > 0.5:
			h.group.rotation.y = lerp_angle(h.group.rotation.y, atan2(h.vel.x, h.vel.z), 0.25)
		h.group.animate(g.time_ms, h.vel.length())

# the local player's channel bar: [label, 0..1] or [] for none
func channel(p: GameChar) -> Array:
	var c: Array = chan_view if g.mode == g.Mode.CLIENT else p.ai.get("chan", [0, 0.0])
	var kind := int(c[0])
	# a stone / cage press is instant with a key — only show the dwell once it is clearly running
	if kind == 0 or ((kind == CH_STONE or kind == CH_CAGE) and float(c[1]) < 0.15):
		return []
	return [CH_LABEL[kind], float(c[1])]

# ------------------------------------------------------------------ HUD
func task_text(el: String) -> String:
	match int(active[el]):
		1:
			return "Tier 1 task: free a caged friend — cages are the squares on the radar"
		2:
			return "Tier 2 task: light the lighthouse on Beacon Isle — stand in its ring for %d s" % int(BEACON_TIME)
		3:
			if int(key_state[el]) == 2:
				return "Carry the Sun Key back up to the tier 3 task stone"
			return "Tier 3 task: fetch the Sun Key from the Sun Shrine — the gold diamond on the radar"
		4:
			return "Tier 4 task: stand on the Sun Seal on this terrace for %d s" % int(SEAL_TIME)
	return ""

# Objective line while a task gates the way (or "" when none does).
func objective(el: String, tier: int) -> String:
	var txt := task_text(el)
	if txt != "":
		return txt
	var n := frontier(el)
	if n <= TASK_TIERS and tier == n:
		return "Tier %d is locked — read the task stone on this terrace (the gold diamond on the radar)" % n
	return ""

func status_bits(el: String) -> String:
	var s := ""
	var hc := helper_count(el)
	if hc > 0:
		s += "   ·   Friends %d/%d" % [hc, HELPER_MAX]
	if int(key_state[el]) == 2:
		s += "   ·   Sun Key"
	return s

# Context hint near quest things: [key, text] or [] for none.
func hint(p: GameChar) -> Array:
	var el := p.el
	var me := Vector2(p.pos.x, p.pos.z)
	var keys: bool = g.mode != g.Mode.CLIENT and not g.mobile
	var n := frontier(el)
	if n <= TASK_TIERS and p.tier == n and me.distance_to(stone_pos(n)) < m.HINT_REACH:
		if int(active[el]) != n:
			return ["E" if keys else "", "Read the task stone to get tier %d's task%s" % [n, "" if keys else " — stand beside it"]]
		if n == 3 and int(key_state[el]) == 2:
			return ["", "Touch the task stone with the Sun Key"]
		return ["", task_text(el)]
	if p.tier == 0:
		for c in cages:
			if m.flat_dist(p.pos, c["pos"]) < m.HINT_REACH:
				if String(c["el"]) == "":
					return ["", "This cage is empty — a new friend arrives in %ds" % int(ceil(float(c["refill"])))]
				return ["E" if keys else "", "Free the little %s — it will %s%s" % [g.ELEMENTS[c["el"]]["label"], helper_job(c["el"], el), "" if keys else " (stand beside the cage)"]]
		if int(key_state[el]) == 1 and m.flat_dist(p.pos, key_pos[el]) < m.HINT_REACH + 2.0:
			return ["", "The Sun Key — touch it, then carry it back up to the tier 3 task stone"]
		if me.distance_to(beacon_pos()) < m.HINT_REACH + 1.0:
			if int(active[el]) == 2:
				return ["", "Stand in the glowing ring for %d s to light the beacon — a tag resets it" % int(BEACON_TIME)]
			if int(done[el]) < 2:
				return ["", "The lighthouse. The tier 2 task stone will send you here to light it"]
	if int(active[el]) == 4 and p.tier == 4 and me.distance_to(seal_pos()) < m.HINT_REACH:
		return ["", "Stand on the Sun Seal for %d s — a tag resets it" % int(SEAL_TIME)]
	if p.tier >= 1 and p.tier <= TASK_TIERS and p.hp < p.max_hp and me.distance_to(chime_pos(p.tier)) < m.HINT_REACH:
		if float(chime_rest[p.tier - 1]) > 0.0:
			return ["", "The wind chime is resting"]
		return ["", "Touch the wind chime to mend a heart"]
	return []

# Why the way up is shut on tier k (k >= 1), for the stair / pad hints.
func locked_text(el: String, k: int) -> String:
	if int(active[el]) == k:
		return "Locked until this tier's task is done: %s" % TASK_TITLE[k]
	return "Locked. Tier %d has a task first — read the task stone on this terrace" % k

func radar_blips(blips: Array, el: String, tier: int) -> void:
	for c in cages:
		if String(c["el"]) != "":
			var cp: Vector3 = c["pos"]
			blips.append({ "pos": Vector2(cp.x, cp.z), "color": MeshLib.rgb(g.ELEMENTS[c["el"]]["color"]), "o2": false, "shape": "cage" })
	var gold := Color(0.98, 0.76, 0.18)
	if int(key_state[el]) == 1:
		var kp: Vector3 = key_pos[el]
		blips.append({ "pos": Vector2(kp.x, kp.z), "color": gold, "o2": false, "shape": "quest" })
	if int(active[el]) == 2:
		blips.append({ "pos": beacon_pos(), "color": gold, "o2": false, "shape": "quest" })
	var n := frontier(el)
	if n <= TASK_TIERS and tier == n and (int(active[el]) != n or (n == 3 and int(key_state[el]) == 2)):
		blips.append({ "pos": stone_pos(n), "color": gold, "o2": false, "shape": "quest" })
	if int(active[el]) == 4 and tier == 4:
		blips.append({ "pos": seal_pos(), "color": gold, "o2": false, "shape": "quest" })

# ------------------------------------------------------------------ online
func pack() -> Dictionary:
	var cg: Array = []
	for c in cages:
		cg.append(-1 if String(c["el"]) == "" else int(m._EL_IDX[c["el"]]))
	var ky: Array = []
	for t in ELS:
		var kp: Vector3 = key_pos[t]
		ky.append([int(key_state[t]), snappedf(kp.x, 0.1), snappedf(kp.z, 0.1)])
	var sp := {}
	for ch in g.actors:
		if ch.is_human and ch.ai.has("chan"):
			var c2: Array = ch.ai["chan"]
			sp[ch.net_id] = [int(c2[0]), snappedf(float(c2[1]), 0.01)]
	var ht := {}
	for h in helpers:
		ht[h.net_id] = int(m._EL_IDX[String(h.ai.get("team", "fire"))])
	var cr := 0
	for i in chime_rest.size():
		if float(chime_rest[i]) > 0.0:
			cr |= 1 << i
	return {
		"d": [int(done["fire"]), int(done["water"]), int(done["grass"])],
		"a": [int(active["fire"]), int(active["water"]), int(active["grass"])],
		"k": ky, "g": cg, "s": sp, "h": ht, "c": cr,
		"b": -1 if beacon_el == "" else int(m._EL_IDX[beacon_el]),
	}

func apply(d: Dictionary) -> void:
	var dd: Array = d.get("d", [0, 0, 0])
	var aa: Array = d.get("a", [0, 0, 0])
	var ky: Array = d.get("k", [])
	var my: String = m._local_el()
	for i in ELS.size():
		var t: String = ELS[i]
		var prev_done := int(done[t])
		var prev_active := int(active[t])
		var prev_key := int(key_state[t])
		done[t] = int(dd[i])
		active[t] = int(aa[i])
		if i < ky.size():
			var e: Array = ky[i]
			key_state[t] = int(e[0])
			key_pos[t] = Vector3(float(e[1]), 0.0, float(e[2]))
		if t == my and g.ui != null:
			if int(done[t]) > prev_done:
				g.ui.toast("Task done — tier %d's stairs and your %s are open!" % [int(done[t]), m.PAD_NAME[t]])
			elif int(active[t]) != prev_active and int(active[t]) != 0:
				g.ui.toast("Tier %d task: %s" % [int(active[t]), TASK_TITLE[int(active[t])]])
			elif int(key_state[t]) == 2 and prev_key == 1:
				g.ui.toast("You have the Sun Key — carry it back up to the tier 3 task stone")
	var cg: Array = d.get("g", [])
	if cages.size() != cg.size():
		reset()
	for i in mini(cages.size(), cg.size()):
		cages[i]["el"] = "" if int(cg[i]) < 0 else ELS[int(cg[i])]
	var sp: Dictionary = d.get("s", {})
	var mine = sp.get(str(g.local_net_id), [0, 0.0])
	chan_view = [int(mine[0]), float(mine[1])]
	var prev_n := helper_count(my) if my != "" else 0
	helper_team.clear()
	var ht: Dictionary = d.get("h", {})
	for k in ht:
		helper_team[int(k)] = ELS[int(ht[k])]
	if my != "" and g.ui != null and helper_count(my) > prev_n:
		g.ui.toast("You freed a little friend — it is on your side!")
	var cr := int(d.get("c", 0))
	for i in chime_rest.size():
		chime_rest[i] = 1.0 if (cr & (1 << i)) != 0 else 0.0
	var b := int(d.get("b", -1))
	beacon_el = "" if b < 0 else ELS[b]
