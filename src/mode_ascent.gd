class_name ModeAscent
extends RefCounted
# ASCENT — the game mode of the Skyfall Isles world.
# Light your Spark from three Sun Motes, climb the Sky Spire, ring the Sky Bell
# three times before anyone else.
#
# This object owns every Skyfall rule (world rules: eclipse, shove, falling,
# element routes, the rising smog sea; mode rules: motes, the spire's tier
# layer, shortcut pads, the bell, the win) plus the rival AI. game.gd only calls
# the hooks below; the map itself is data in SkyLayout and the visuals live in
# SkyBuilder (static world, authored in Blender) / SkyView (moving things).
#
# Authority: single-player and the online HOST run tick(); online guests mirror
# the slow state through apply_meta() and predict their own avatar with the very
# same constrain().

# ------------------------------------------------------------------ tuning
const ASCENT_ROUND_TIME := 480.0
const ASCENT_HP := 3
const ECLIPSE_EVERY := 75.0
const ECLIPSE_TIME := 15.0
const ASCENT_MOTES_NEEDED := 3
const ASCENT_RAID_MOTES := 1
const MOTE_PICK_DIST := 2.6
const MOTE_RELOCATE_DELAY := 2.0
const SPIRE_TIERS := SkyLayout.SPIRE_TIERS
const SPIRE_TIER_H := SkyLayout.SPIRE_TIER_H
const SPIRE_OUTER_R := SkyLayout.SPIRE_OUTER_R
const SPIRE_GROUND_R := SkyLayout.SPIRE_GROUND_R
const SPIRE_RAMP_A0 := SkyLayout.SPIRE_RAMP_A0
const SPIRE_RAMP_STEP := SkyLayout.SPIRE_RAMP_STEP
const SPIRE_RAMP_ARC := SkyLayout.SPIRE_RAMP_ARC
const SHORTCUT_OFFSETS := SkyLayout.SHORTCUT_OFFSETS
const SHORTCUT_CHARGE := 0.35
const SHORTCUT_COOLDOWN := 4.0
const SPIRE_HIT_DROP := 1
const CO2_MAX_TIER := 2
const BELL_RING_TIME := 2.0
const BELL_RINGS_TO_WIN := 3
const BELL_SETTLE := 4.0
const BELL_ZONE_R := SkyLayout.BELL_ZONE_R
const SMOG_RISE_EVERY := 60.0
const SMOG_RISE_R := [152.0, 136.0, 120.0, 104.0, 84.0, 60.0, 34.0]
const SMOG_RISE_LERP := 4.0
const SMOG_HIT_EVERY := 2.0
const SMOG_SLOW := 0.6
const SHOVE_DIST := 6.0

const SHOVE_TIME := 0.3          # the 6 m shove plays out over this long
const FALL_TIME := 3.0           # seconds from stepping off an edge to respawning
const FALL_CAM_TIME := 1.0       # the camera follows the fall this long, then white-out
const PAD_FLIGHT := 0.75
const AI_SPEED := 0.9            # rivals jog a touch slower than a (sprint-capable) human…
const AI_GATHER_SPEED := 0.62    # …and stroll while hunting motes, so a human who hustles gets there first
const AI_FLEE_BOOST := 1.22      # but they bolt when something that eats them is close
const N_SMOG := 4                # single-player CO₂ smog clouds / O₂ breeze bubbles in this world
const N_BUBBLES := 10
const GAS_SPEED := 0.8           # smog clouds / breeze bubbles move at 80% of their castle-world speed
const ELS := ["fire", "water", "grass"]
const SHORT_NAME := { "fire": "vent", "water": "lift", "grass": "vine" }
const PAD_NAME := { "fire": "fire vent", "water": "water lift", "grass": "vine ladder" }
const PAD_KEY_REACH := 2.6       # press E this close to your own pad and you climb at once
const HINT_REACH := 4.8          # how close before the "what do I press" popup appears
const BUSY_NONE := 0
const BUSY_FALL := 1
const BUSY_FLY := 2

# ------------------------------------------------------------------ state
var g                                 # the Game node
var view = null                       # SkyView (null on a visual-less server)
var elapsed := 0.0                    # seconds since GO
var over := false
var motes: Array = []                 # [{ el, pos:Vector3, taken, rel_t, from:Vector3, to:Vector3, drift }]
var motes_el := { "fire": 0, "water": 0, "grass": 0 }    # Sun Motes absorbed, per element team
var rings_el := { "fire": 0, "water": 0, "grass": 0 }    # completed bell rings, per element team
var tier_el := { "fire": 0, "water": 0, "grass": 0 }     # highest tier a member stands on right now
var bell_settle := 0.0                # >0: the bell is still swinging, no ring counts
var seed_until: Array = [0.0, 0.0]    # elapsed-time each seed vine stays grown until
var seed_grow: Array = [0.0, 0.0]     # 0..1 grow channel (a Leaf is standing on a seed)
var seed_cd: Array = [0.0, 0.0]
var ping := {}                        # last bell ringer { x, z, el, t } — shown on every radar
var ring_view := 0.0                  # the local player's ring channel 0..1 (HUD)
var autopilot := false                # debug: the AI drives the local player too
var _door_msg_cd := 0.0
var _last_eclipse := false
var _last_rise := 0
var _was_lit := false
var _fall_view := 0.0                 # seconds the local player has been falling (camera + white-out)

func _init(game) -> void:
	g = game
	SkyLayout.ensure()

# ------------------------------------------------------------------ clocks
func eclipse_active() -> bool:
	return elapsed >= ECLIPSE_EVERY and fmod(elapsed, ECLIPSE_EVERY) < ECLIPSE_TIME

func eclipse_left() -> float:
	return maxf(0.0, ECLIPSE_TIME - fmod(elapsed, ECLIPSE_EVERY)) if eclipse_active() else 0.0

func eclipse_in() -> float:
	return ECLIPSE_EVERY - fmod(elapsed, ECLIPSE_EVERY)

# seconds until the food chain next flips (either way)
func flip_in() -> float:
	return eclipse_left() if eclipse_active() else eclipse_in()

func smog_idx() -> int:
	return mini(int(elapsed / SMOG_RISE_EVERY), SMOG_RISE_R.size())

func smog_goal() -> float:
	return SkyLayout.smog_target(smog_idx(), SMOG_RISE_R)

# the safe radius right now (the sea front rolls in over SMOG_RISE_LERP seconds)
func smog_r() -> float:
	var idx := smog_idx()
	if idx <= 0:
		return 190.0
	var prev := SkyLayout.smog_target(idx - 1, SMOG_RISE_R)
	var t := clampf((elapsed - float(idx) * SMOG_RISE_EVERY) / SMOG_RISE_LERP, 0.0, 1.0)
	return lerpf(prev, SkyLayout.smog_target(idx, SMOG_RISE_R), t)

func next_rise_in() -> float:
	if smog_idx() >= SMOG_RISE_R.size():
		return -1.0
	return float(smog_idx() + 1) * SMOG_RISE_EVERY - elapsed

func home_sunk(_el: String) -> bool:
	return smog_r() < SkyLayout.HOME_DIST + SkyLayout.SANCTUM_R - 0.5

func time_left() -> float:
	return maxf(0.0, ASCENT_ROUND_TIME - elapsed)

func lit(el: String) -> bool:
	return int(motes_el.get(el, 0)) >= ASCENT_MOTES_NEEDED

func vines_mask() -> int:
	var m := 0
	for i in seed_until.size():
		if float(seed_until[i]) > elapsed:
			m |= 1 << i
	return m

static func flat(v: Vector3) -> Vector3:
	return Vector3(v.x, 0.0, v.z)

static func radius(p: Vector3) -> float:
	return sqrt(p.x * p.x + p.z * p.z)

static func flat_dist(a: Vector3, b: Vector3) -> float:
	var dx := a.x - b.x
	var dz := a.z - b.z
	return sqrt(dx * dx + dz * dz)

# ------------------------------------------------------------------ round setup
func start_round() -> void:
	elapsed = 0.0
	over = false
	bell_settle = 0.0
	seed_until = [0.0, 0.0]
	seed_grow = [0.0, 0.0]
	seed_cd = [0.0, 0.0]
	ping = {}
	ring_view = 0.0
	_last_eclipse = false
	_last_rise = 0
	_was_lit = false
	stats = {}
	for el in ELS:
		motes_el[el] = 0
		rings_el[el] = 0
		tier_el[el] = 0
	motes.clear()
	if g.mode != g.Mode.CLIENT:
		_place_motes()
	if view:
		view.reset_round()

func setup_actor(ch: GameChar) -> void:
	ch.max_hp = ASCENT_HP
	ch.hp = ASCENT_HP
	ch.tier = 0
	ch.busy = BUSY_NONE
	ch.in_ramp = false
	ch.ai = {}

func spawn_pos(el: String, idx: int) -> Vector3:
	var h: Dictionary = SkyLayout.NODES["h_" + el]
	if idx == 0:
		return Vector3(h["x"], 0.0, h["z"])
	var a := float(idx) * 2.4
	return Vector3(h["x"] + cos(a) * 3.0, 0.0, h["z"] + sin(a) * 3.0)

# Home sanctum — or Heart Isle's ground ring at your home's angle once the smog
# sea has swallowed the sanctum.
func respawn_pos(el: String) -> Vector3:
	if home_sunk(el):
		return SkyLayout.pol3(float(SkyLayout.HOME_ANG[el]) + randf_range(-5.0, 5.0), 23.2)
	var h: Dictionary = SkyLayout.NODES["h_" + el]
	return Vector3(h["x"] + randf_range(-2.0, 2.0), 0.0, h["z"] + randf_range(-2.0, 2.0))

func _spot_on(id: String, min_d: float, max_frac: float) -> Vector3:
	var is_: Dictionary = SkyLayout.NODES[id]
	var p := Vector3(is_["x"], 0.0, is_["z"])
	for _i in 30:
		var a := randf() * TAU
		var d := randf_range(min_d, maxf(min_d, float(is_["r"]) * max_frac))
		var q := Vector3(is_["x"] + cos(a) * d, 0.0, is_["z"] + sin(a) * d)
		if not g._spot_blocked(q.x, q.z):
			return q
		p = q
	return p

func _place_motes() -> void:
	var pool := ["i30", "i150", "i270", "ih_fire", "ih_water", "ih_grass", "w30", "w150", "w270"]
	for el in ELS:
		# the raid mote: always on your PREY's home isle, outside its sanctum's wall
		for _r in ASCENT_RAID_MOTES:
			_add_mote(el, _spot_on("h_" + String(g.ELEMENTS[el]["prey"]), 10.0, 0.74))
		var opts: Array = pool.filter(func(id): return id != "ih_" + el)
		opts.shuffle()
		for i in (ASCENT_MOTES_NEEDED - ASCENT_RAID_MOTES):
			_add_mote(el, _spot_on(opts[i], 0.0, 0.55))

func _add_mote(el: String, p: Vector3) -> void:
	motes.append({ "el": el, "pos": p, "taken": false, "rel_t": 0.0, "drift": -1.0, "from": p, "to": p })

# Anywhere over the map (smog clouds and breeze bubbles drift across the gaps).
func random_air_spot(min_r: float = 0.0) -> Vector3:
	var lo := maxf(min_r, 30.0)
	var a := randf() * TAU
	var d := sqrt(randf()) * (minf(smog_goal(), 160.0) - lo) + lo
	return Vector3(cos(a) * d, 0.0, sin(a) * d)

# A walkable spot on an outer isle (meteor shards).
func random_ground_spot() -> Vector3:
	var ids := ["w30", "w150", "w270", "i30", "i150", "i270", "ih_fire", "ih_water", "ih_grass", "h_fire", "h_water", "h_grass"]
	var id: String = ids[randi() % ids.size()]
	return _spot_on(id, 8.0 if id.begins_with("h_") else 0.0, 0.7)

# ------------------------------------------------------------------ movement layer
# Terrain speed factor in the sky world (replaces the river drag).
func terrain_mult(ch: GameChar) -> float:
	if ch.kind != "element" or ch.tier != 0:
		return 1.0
	var m := 1.0
	if SkyLayout.on_stream(ch.pos.x, ch.pos.z):
		m = SkyLayout.STREAM_BOOST if ch.el == "water" else SkyLayout.STREAM_WADE
	if radius(ch.pos) > smog_r():
		m *= SMOG_SLOW
	return m

# Called at the end of Game.resolve_collisions for EVERY mover. Keeps an actor on
# its tier's terrace band, walks it up/down the stair wedges, starts a fall when
# it leaves the ground layer, and sets its standing height.
func constrain(ch: GameChar) -> void:
	if ch.kind != "element":
		_constrain_gas(ch)
		return
	if ch.busy != BUSY_NONE:
		return
	var x := ch.pos.x
	var z := ch.pos.z
	var r := sqrt(x * x + z * z)
	var k := ch.tier
	if k == 0 and r > SkyLayout.HEART_R:
		# out on the isles: the walkable test, nothing else
		ch.in_ramp = false
		ch.pos.y = 0.0
		if not SkyLayout.on_ground(x, z, ch.el, vines_mask(), 0.25):
			_start_fall(ch)
		return
	var ang := SkyLayout.ang_of(x, z)
	if r < 0.001:
		r = 0.001
	var nr := r
	var nang := ang
	# ---- the outer edge of a terrace (tiers 1..5): parapet, except the stair gap
	if k >= 1:
		var ro := SkyLayout.tier_outer(k)
		if r > ro - SkyLayout.SPIRE_PARAPET:
			if SkyLayout.in_sector(ang, k - 1):
				if r > ro:
					k -= 1                       # down the stair you came up
					ch.tier = k
					ch.tier_at = elapsed
					ch.in_ramp = true
			else:
				nr = ro - SkyLayout.SPIRE_PARAPET
	# ---- the wall of the next drum + the stair wedge that climbs it (tiers 0..4)
	if k < SPIRE_TIERS:
		var R := SkyLayout.tier_inner(k)
		var run := float(SkyLayout.SPIRE_RAMP_RUN[k])
		var insec := SkyLayout.in_sector(nang, k)
		if nr < R:
			if insec and ch.in_ramp:
				_stat("ramp_climbs")
				k += 1                           # top of the stair: the next terrace
				ch.in_ramp = false
				_enter_tier(ch, k)
			else:
				nr = R                           # a wall (only a stair you stepped onto at its foot leads up)
		elif nr <= R + run and insec:
			if not ch.in_ramp:
				if nr >= R + run - SkyLayout.SPIRE_RAMP_MOUTH:
					if k == 0 and not lit(ch.el):
						nr = R + run + 0.05      # the spire door stays shut
						_door_closed(ch)
					else:
						ch.in_ramp = true
				else:
					# walked into the stair's flank — slide along its side
					var d := SkyLayout.ang_diff(SkyLayout.ramp_ang(k), nang)
					nang = SkyLayout.ramp_ang(k) + (SPIRE_RAMP_ARC * 0.5 + 0.4) * (1.0 if d >= 0.0 else -1.0)
		else:
			ch.in_ramp = false
	else:
		ch.in_ramp = false
	if nr != r or nang != ang:
		var p := SkyLayout.pol(nang, nr)
		ch.pos.x = p.x
		ch.pos.z = p.y
	ch.pos.y = SkyLayout.height_at(ch.tier, ch.pos.x, ch.pos.z)

func _constrain_gas(ch: GameChar) -> void:
	var r := radius(ch.pos)
	var lim := 171.0
	if r > lim:
		ch.pos.x *= lim / r
		ch.pos.z *= lim / r
		r = lim
	# breeze bubbles stay off the spire; smog is heavy and never climbs past CO2_MAX_TIER
	var inner: float = (float(SPIRE_OUTER_R[CO2_MAX_TIER]) + 0.6) if ch.kind == "co2" else (SkyLayout.HEART_R + 1.0)
	if r < inner:
		if r < 0.01:
			ch.pos.x = inner
			ch.pos.z = 0.0
		else:
			ch.pos.x *= inner / r
			ch.pos.z *= inner / r
		r = inner
	ch.tier = SkyLayout.tier_for_radius(r, CO2_MAX_TIER) if ch.kind == "co2" else 0
	ch.pos.y = float(ch.tier) * SPIRE_TIER_H

func _enter_tier(ch: GameChar, k: int) -> void:
	ch.tier = k
	ch.tier_at = elapsed
	if ch.is_player and g.ui and k > 0:
		g.ui.toast("Bell platform! Stand in the glowing ring to ring." if k == SPIRE_TIERS else "Tier %d of %d" % [k, SPIRE_TIERS])

func _door_closed(ch: GameChar) -> void:
	if ch.is_player and g.ui and _door_msg_cd <= 0.0:
		_door_msg_cd = 3.0
		g.ui.toast("The spire door opens only for a lit Spark — gather %d Sun Motes." % ASCENT_MOTES_NEEDED)

func _start_fall(ch: GameChar) -> void:
	if g.mode == g.Mode.CLIENT:
		return                                   # the host decides; the busy flag arrives by snapshot
	_stat("falls")
	if _trace:
		var pth: Array = ch.ai.get("path", [])
		print("[fall %s] %s%s at (%.1f,%.1f) vel=(%.1f,%.1f) kb=%.2f flee=%s vines=%d next=%s" % [g._fmt_time(elapsed), ch.el, "*" if ch.is_human else "",
			ch.pos.x, ch.pos.z, ch.vel.x, ch.vel.z, ch.kb_t, str(ch.ai.get("flee", false)), vines_mask(), str(pth[0]) if not pth.is_empty() else "-"])
	ch.busy = BUSY_FALL
	ch.busy_t = FALL_TIME
	ch.ring_prog = 0.0
	ch.kb_t = 0.0
	ch.in_ramp = false
	if ch.is_player and g.ui:
		g.ui.toast("You fell through the clouds!")

func _launch(ch: GameChar, to: Vector3, to_tier: int, dur: float, arc: float) -> void:
	ch.busy = BUSY_FLY
	ch.busy_t = 0.0
	ch.fly_dur = dur
	ch.fly_from = ch.pos
	ch.fly_to = to
	ch.fly_tier = to_tier
	ch.fly_arc = arc
	ch.vel = Vector3.ZERO
	ch.in_ramp = false
	ch.ring_prog = 0.0

# ------------------------------------------------------------------ rule hooks
# Game._take_hit calls this right after the heart is deducted.
func on_hit(victim: GameChar, attacker: GameChar) -> void:
	victim.ring_prog = 0.0
	victim.pad_t = 0.0
	if attacker != null and attacker.kind == "element":
		attacker.slow_timer = g.SLOW_TIME        # counter-slow, whoever the victim is
	if victim.kind != "element":
		return
	if victim.tier > 0:
		# on the spire a tag costs height instead of a shove
		_stat("tier_drops")
		var nt: int = maxi(0, victim.tier - SPIRE_HIT_DROP)
		var ang := SkyLayout.ang_of(victim.pos.x, victim.pos.z)
		var p := SkyLayout.pol(ang, SkyLayout.band_mid(nt))
		victim.tier = nt
		victim.tier_at = elapsed
		victim.pos = Vector3(p.x, 0.0, p.y)
		victim.in_ramp = SkyLayout.in_wedge(nt, p.x, p.y) and (nt > 0 or lit(victim.el))
		victim.pos.y = SkyLayout.height_at(nt, p.x, p.y)
		victim.vel = Vector3.ZERO
		if victim.is_player and g.ui:
			g.ui.toast("%s knocked you down to %s!" % [g._name_of(attacker), ("tier %d" % nt) if nt > 0 else "the ground"])
	elif attacker != null and attacker.kind == "element":
		var d := flat(victim.pos - attacker.pos)
		if d.length() < 0.05:
			d = Vector3(randf() - 0.5, 0.0, randf() - 0.5)
		_stat("shoves")
		victim.kb_vel = d.normalized() * (SHOVE_DIST / SHOVE_TIME)
		victim.kb_t = SHOVE_TIME

# Game._respawn calls this (0 hearts → home, keeping the Spark and its motes).
func on_respawn(ch: GameChar) -> void:
	_stat("knockouts")
	ch.tier = 0
	ch.busy = BUSY_NONE
	ch.in_ramp = false
	ch.kb_t = 0.0
	ch.ring_prog = 0.0
	ch.pad_t = 0.0
	ch.smog_t = 0.0
	ch.vent_lock = false
	ch.ai = {}
	ch.pos = respawn_pos(ch.el)
	if ch.group:
		ch.group.position = ch.pos

# may `a` and `b` touch at all? (same tier, neither mid-flight / falling)
func same_layer(a: GameChar, b: GameChar) -> bool:
	return a.tier == b.tier and a.busy == BUSY_NONE and b.busy == BUSY_NONE

# ------------------------------------------------------------------ authority tick
func tick(dt: float) -> void:
	if over:
		return
	elapsed += dt
	_door_msg_cd = maxf(0.0, _door_msg_cd - dt)
	bell_settle = maxf(0.0, bell_settle - dt)
	if not ping.is_empty():
		ping["t"] = float(ping["t"]) + dt
		if float(ping["t"]) > 4.0:
			ping = {}
	for el in ELS:
		tier_el[el] = 0
	for ch in g.actors:
		_tick_actor(ch, dt)
		if ch.alive and ch.busy == BUSY_NONE:
			tier_el[ch.el] = maxi(int(tier_el[ch.el]), ch.tier)
	_tick_seeds(dt)
	_tick_motes(dt)
	_announce()
	if autopilot or _trace:
		_debug_log(dt)
	if elapsed >= ASCENT_ROUND_TIME:
		_finish_on_time()

func _tick_actor(ch: GameChar, dt: float) -> void:
	if not ch.alive:
		return
	ch.pad_cd = maxf(0.0, ch.pad_cd - dt)
	if ch.busy == BUSY_FALL:
		ch.busy_t -= dt
		ch.vel *= pow(0.25, dt)
		ch.pos.x += ch.vel.x * dt
		ch.pos.z += ch.vel.z * dt
		ch.pos.y -= (5.0 + (FALL_TIME - ch.busy_t) * 22.0) * dt
		if ch.busy_t <= 0.0:
			_land_after_fall(ch)
		return
	if ch.busy == BUSY_FLY:
		ch.busy_t += dt
		var t := clampf(ch.busy_t / maxf(ch.fly_dur, 0.01), 0.0, 1.0)
		var e := t * t * (3.0 - 2.0 * t)
		ch.pos = ch.fly_from.lerp(ch.fly_to, e)
		ch.pos.y += sin(PI * t) * ch.fly_arc
		if t >= 1.0:
			ch.busy = BUSY_NONE
			ch.pos = ch.fly_to
			ch.vel = Vector3.ZERO
			if ch.fly_tier != ch.tier:
				_enter_tier(ch, ch.fly_tier)
			ch.in_ramp = SkyLayout.in_wedge(ch.tier, ch.pos.x, ch.pos.z)
		return
	if ch.kb_t > 0.0:
		var step := minf(dt, ch.kb_t)
		ch.kb_t -= dt
		ch.pos.x += ch.kb_vel.x * step
		ch.pos.z += ch.kb_vel.z * step
		g.resolve_collisions(ch)
		if ch.busy != BUSY_NONE:
			return
	# the smog sea: swallowed ground costs a heart every SMOG_HIT_EVERY seconds
	if ch.tier == 0 and radius(ch.pos) > smog_r():
		ch.smog_t += dt
		if ch.smog_t >= SMOG_HIT_EVERY:
			ch.smog_t = 0.0
			_smog_hit(ch)
			if not ch.alive or ch.busy != BUSY_NONE:
				return
	else:
		ch.smog_t = 0.0
	if ch.tier == 0:
		_tick_pickup(ch)
		_tick_vent(ch, dt)
	_tick_pad(ch, dt)
	_tick_bell(ch, dt)

func _land_after_fall(ch: GameChar) -> void:
	ch.busy = BUSY_NONE
	ch.tier = 0
	ch.in_ramp = false
	ch.vel = Vector3.ZERO
	ch.invuln_timer = g.HIT_INVULN
	ch.smog_t = 0.0
	ch.vent_lock = false
	ch.ai = {}
	ch.pos = respawn_pos(ch.el)
	if ch.group:
		ch.group.position = ch.pos

func _smog_hit(ch: GameChar) -> void:
	_stat("smog_hits")
	ch.hp -= 1
	if ch.hp <= 0:
		g._respawn(ch)
		if ch.is_player and g.ui:
			g.ui.toast("The smog sea took your last heart — respawned.")
	elif ch.is_player and g.ui:
		g.ui.toast("Smog!  %d hearts left — get to higher ground" % ch.hp)
	if ch.is_player:
		g._update_hud_hearts()

func _tick_pickup(ch: GameChar) -> void:
	for m in motes:
		if m["taken"] or m["el"] != ch.el:
			continue
		if flat_dist(ch.pos, m["pos"]) < MOTE_PICK_DIST:
			m["taken"] = true
			motes_el[ch.el] = int(motes_el[ch.el]) + 1
			ch.score += 10
			if ch.is_player and g.ui:
				_toast_motes(ch.el)

func _toast_motes(el: String) -> void:
	var n := int(motes_el[el])
	if n >= ASCENT_MOTES_NEEDED:
		g.ui.toast("Your Spark is LIT! Climb the Sky Spire on Heart Isle.")
	else:
		g.ui.toast("Sun Mote absorbed  %d / %d" % [n, ASCENT_MOTES_NEEDED])

func _tick_vent(ch: GameChar, dt: float) -> void:
	var p2 := Vector2(ch.pos.x, ch.pos.z)
	var dh := p2.distance_to(SkyLayout.VENT_HOME)
	var dc := p2.distance_to(SkyLayout.VENT_HEART)
	if ch.vent_lock:
		if dh > SkyLayout.VENT_R + 1.4 and dc > SkyLayout.VENT_R + 1.4:
			ch.vent_lock = false
		return
	if dh < SkyLayout.VENT_R or dc < SkyLayout.VENT_R:
		ch.vent_t += dt
		if ch.vent_t >= SkyLayout.VENT_DWELL:
			ch.vent_t = 0.0
			ch.vent_lock = true
			if ch.el != "fire":
				# only Fire rides the thermal — everyone else just gets a puff and a small hop
				_launch(ch, ch.pos, 0, 0.5, 1.5)
				return
			_stat("vent_flights")
			var to: Vector2 = SkyLayout.VENT_HEART if dh < dc else SkyLayout.VENT_HOME
			_launch(ch, Vector3(to.x, 0.0, to.y), 0, SkyLayout.VENT_FLIGHT, 16.0)
			if ch.is_player and g.ui:
				g.ui.toast("WHOOSH — thermal vent!")
	else:
		ch.vent_t = 0.0

# Your own shortcut pad (opposite the ramp) carries you up one tier.
func _tick_pad(ch: GameChar, dt: float) -> void:
	var k := ch.tier
	if k >= SPIRE_TIERS or ch.pad_cd > 0.0 or (k == 0 and not lit(ch.el)) or radius(ch.pos) > SkyLayout.HEART_R:
		ch.pad_t = 0.0
		return
	var pp := SkyLayout.pad_pos(k, ch.el)
	var pd := Vector2(ch.pos.x, ch.pos.z).distance_to(pp)
	# the local player may also just press E next to the pad (see the hint popup)
	var keyed: bool = ch.is_player and pd < PAD_KEY_REACH and _climb_pressed()
	if pd < SkyLayout.SHORTCUT_R or keyed:
		ch.pad_t += dt
		if ch.pad_t >= SHORTCUT_CHARGE or keyed:
			_stat("pad_lifts")
			ch.pad_t = 0.0
			ch.pad_cd = SHORTCUT_COOLDOWN
			var land := SkyLayout.pol(SkyLayout.pad_ang(k, ch.el), maxf(1.6, SkyLayout.tier_inner(k) - 1.3))
			_launch(ch, Vector3(land.x, float(k + 1) * SPIRE_TIER_H, land.y), k + 1, PAD_FLIGHT, 1.2)
	else:
		ch.pad_t = 0.0

func _climb_pressed() -> bool:
	return Input.is_physical_key_pressed(KEY_E) or Input.is_physical_key_pressed(KEY_SPACE)

# What can the player use right here, and what do they press? Returns [key, text]
# for the top-left hint popup (key "" = no key cap, text "" = no popup).
func _context_hint(p: GameChar) -> Array:
	if p.busy != BUSY_NONE or not p.alive or not g.running:
		return ["", ""]
	var el := p.el
	var k := p.tier
	var me := Vector2(p.pos.x, p.pos.z)
	var r := me.length()
	# keys only where a keyboard drives this avatar's pad directly (guests' pads
	# charge on the host, phones have no keys) — everyone can simply stand on it
	var keys: bool = g.mode != g.Mode.CLIENT and not g.mobile
	if k >= SPIRE_TIERS:
		if r > BELL_ZONE_R and bell_settle <= 0.0:
			return ["", "Step into the glowing ring and hold still for 2 s to ring the bell"]
		return ["", ""]
	if r <= SkyLayout.HEART_R + 1.0:
		# ---- the three shortcut pads on this tier (vent / lift / vine ladder)
		var near_el := ""
		var bd := HINT_REACH
		for e in ELS:
			var d := me.distance_to(SkyLayout.pad_pos(k, e))
			if d < bd:
				bd = d
				near_el = e
		if near_el != "":
			if near_el != el:
				return ["", "That is %s's %s — only %s can ride it. Yours is the %s (your glowing pad on this tier)" % [
					g.ELEMENTS[near_el]["label"], PAD_NAME[near_el], g.ELEMENTS[near_el]["label"], PAD_NAME[el]]]
			if k == 0 and not lit(el):
				return ["", "Your %s — it wakes up once your Spark is lit (3 Sun Motes)" % PAD_NAME[el]]
			if p.pad_cd > 0.0:
				return ["", "Your %s is recharging… %ds" % [PAD_NAME[el], int(ceil(p.pad_cd))]]
			var up := ("the bell platform" if k + 1 >= SPIRE_TIERS else "tier %d" % (k + 1))
			if keys:
				return ["E", "Climb your %s up to %s  (or just stand on the pad)" % [PAD_NAME[el], up]]
			return ["", "Stand on the glowing pad to ride your %s up to %s" % [PAD_NAME[el], up]]
		# ---- the stair up from this tier (tier 0: the spire door)
		var R := SkyLayout.tier_inner(k)
		var run := float(SkyLayout.SPIRE_RAMP_RUN[k])
		var arc := absf(SkyLayout.ang_diff(SkyLayout.ang_of(me.x, me.y), SkyLayout.ramp_ang(k))) * deg_to_rad(1.0) * r
		if arc < R * deg_to_rad(SPIRE_RAMP_ARC * 0.5) + 3.0 and r < R + run + 3.5 and r >= R - 0.2:
			if k == 0 and not lit(el):
				return ["", "The spire door — it opens once your Spark is lit (3 Sun Motes)"]
			var up2 := ("the bell platform" if k + 1 >= SPIRE_TIERS else "tier %d" % (k + 1))
			return ["W" if keys else "", "Walk up the stairs to %s" % up2]
	if k == 0:
		# ---- thermal vents
		for v in [SkyLayout.VENT_HOME, SkyLayout.VENT_HEART]:
			if me.distance_to(v) < HINT_REACH:
				if el != "fire":
					return ["", "Fire's thermal vent — only Fire can ride it (you just get a hop)"]
				return ["", "Thermal vent — stand on it and it flings you to %s" % ("Heart Isle" if v == SkyLayout.VENT_HOME else "Ember Crag")]
		# ---- seed gaps
		for i in SkyLayout.SEEDS.size():
			var sd: Dictionary = SkyLayout.SEEDS[i]
			if me.distance_to(sd["ma"]) < HINT_REACH or me.distance_to(sd["mb"]) < HINT_REACH:
				var left := float(seed_until[i]) - elapsed
				if left > 0.0:
					return ["", "The vine bridge is up — cross now!  %ds left" % int(ceil(left))]
				if el == "grass":
					return ["", "Seed — stand on it for 1.5 s to grow a vine bridge across the gap (anyone may cross for 10 s)"]
				return ["", "A sprouting seed — only a Leaf can grow the vine bridge here"]
		# ---- the private routes, where they leave an isle
		var node := SkyLayout.node_of(me.x, me.y)
		if node != "":
			var is_: Dictionary = SkyLayout.NODES[node]
			var rim: bool = me.distance_to(Vector2(is_["x"], is_["z"])) > float(is_["r"]) - 6.0
			if rim and SkyLayout.seg_dist(me.x, me.y, SkyLayout.VINE["ax"], SkyLayout.VINE["az"], SkyLayout.VINE["bx"], SkyLayout.VINE["bz"]) < SkyLayout.VINE_HW + 2.5:
				if el == "grass":
					return ["W" if keys else "", "Your vine — walk it straight to %s" % ("Heart Isle" if node == "h_grass" else "Canopy Grove")]
				return ["", "Leaf's vine — only Leaf can walk it. Step on it and you fall!"]
			if rim and SkyLayout.seg_dist(me.x, me.y, SkyLayout.STREAM["ax"], SkyLayout.STREAM["az"], SkyLayout.STREAM["bx"], SkyLayout.STREAM["bz"]) < SkyLayout.STREAM_HW + 1.5:
				if el == "water":
					return ["W" if keys else "", "Your sky stream — surf it at double speed"]
				return ["", "Water's sky stream — you can wade across, but slowly"]
	return ["", ""]

func _tick_bell(ch: GameChar, dt: float) -> void:
	if ch.tier != SPIRE_TIERS or radius(ch.pos) > BELL_ZONE_R or bell_settle > 0.0:
		ch.ring_prog = 0.0
		return
	ch.ring_prog += dt / BELL_RING_TIME
	if ch.ring_prog >= 1.0:
		_ring(ch)

func _ring(ch: GameChar) -> void:
	_stat("rings")
	rings_el[ch.el] = int(rings_el[ch.el]) + 1
	bell_settle = BELL_SETTLE
	ch.score += 50
	for a in g.actors:
		a.ring_prog = 0.0
	ping = { "x": ch.pos.x, "z": ch.pos.z, "el": ch.el, "t": 0.0 }
	_on_ring_event(ch.el, int(rings_el[ch.el]))
	if int(rings_el[ch.el]) >= BELL_RINGS_TO_WIN:
		_finish(ch.el, "ascent")

# shared by the authority (a real ring) and guests (a ring seen in meta)
func _on_ring_event(el: String, n: int) -> void:
	if view:
		view.ring_bell()
	if g.ui:
		var mine: bool = g.player != null and g.player.el == el
		g.ui.toast("%s rang the Sky Bell!  %d / %d" % [("You" if mine and g.mode == g.Mode.SINGLE else g.ELEMENTS[el]["label"]), n, BELL_RINGS_TO_WIN])

func _tick_seeds(dt: float) -> void:
	for i in SkyLayout.SEEDS.size():
		seed_cd[i] = maxf(0.0, float(seed_cd[i]) - dt)
		var active: bool = float(seed_until[i]) > elapsed
		if active:
			seed_grow[i] = 0.0
			if float(seed_until[i]) - elapsed < dt * 1.5:
				seed_cd[i] = SkyLayout.SEED_COOLDOWN
			continue
		var sd: Dictionary = SkyLayout.SEEDS[i]
		var on := false
		if float(seed_cd[i]) <= 0.0:
			for ch in g.by_el.get("grass", []):
				if not ch.alive or ch.busy != BUSY_NONE or ch.tier != 0:
					continue
				var p := Vector2(ch.pos.x, ch.pos.z)
				if p.distance_to(sd["ma"]) < SkyLayout.SEED_R or p.distance_to(sd["mb"]) < SkyLayout.SEED_R:
					on = true
					break
		if on:
			seed_grow[i] = float(seed_grow[i]) + dt / SkyLayout.SEED_GROW
			if float(seed_grow[i]) >= 1.0:
				_stat("seed_vines")
				seed_grow[i] = 0.0
				seed_until[i] = elapsed + SkyLayout.SEED_LIFE
				if g.ui and g.player and g.player.el == "grass":
					g.ui.toast("A vine bridge grows — %ds, and anyone may cross!" % int(SkyLayout.SEED_LIFE))
		else:
			seed_grow[i] = 0.0

# Motes on swallowed ground drift to safe ground after MOTE_RELOCATE_DELAY.
func _tick_motes(dt: float) -> void:
	var sr := smog_r()
	for m in motes:
		if m["taken"]:
			continue
		if float(m["drift"]) >= 0.0:
			m["drift"] = float(m["drift"]) + dt / 1.6
			var t := clampf(float(m["drift"]), 0.0, 1.0)
			m["pos"] = (m["from"] as Vector3).lerp(m["to"], t * t * (3.0 - 2.0 * t))
			if t >= 1.0:
				m["drift"] = -1.0
			continue
		if radius(m["pos"]) > sr - 1.0:
			m["rel_t"] = float(m["rel_t"]) + dt
			if float(m["rel_t"]) >= MOTE_RELOCATE_DELAY:
				m["rel_t"] = 0.0
				_stat("mote_relocations")
				m["from"] = m["pos"]
				m["to"] = _safe_mote_spot(m["pos"])
				m["drift"] = 0.0
		else:
			m["rel_t"] = 0.0

func _safe_mote_spot(from: Vector3) -> Vector3:
	var goal := smog_goal()
	var best := ""
	var bd := INF
	for is_ in SkyLayout.ISLES:
		if String(is_["id"]) == "heart" or float(is_["d"]) + float(is_["r"]) * 0.75 > goal - 2.0:
			continue
		var d := flat_dist(from, Vector3(is_["x"], 0.0, is_["z"]))
		if d < bd:
			bd = d; best = is_["id"]
	if best == "":
		# only Heart Isle is left: its ground ring, on the side the mote came from
		var a := SkyLayout.ang_of(from.x, from.z) + randf_range(-25.0, 25.0)
		if SkyLayout.in_sector(a, 0):
			a += 30.0                # not on the door stair
		return SkyLayout.pol3(a, 24.6)
	var is2: Dictionary = SkyLayout.NODES[best]
	var min_d := 10.0 if String(is2["kind"]) == "home" else 0.0
	for _i in 30:
		var p := _spot_on(best, min_d, 0.7)
		if radius(p) < goal - 2.5:
			return p
	return _spot_on(best, min_d, 0.7)

func _announce() -> void:
	if g.ui == null:
		return
	var ec := eclipse_active()
	if ec != _last_eclipse:
		_last_eclipse = ec
		g.ui.toast("ECLIPSE! The food chain is REVERSED for %ds" % int(ECLIPSE_TIME) if ec else "The eclipse has passed — the chain is back to normal")
	var idx := smog_idx()
	if idx != _last_rise:
		_last_rise = idx
		if idx > 0:
			g.ui.toast("The smog sea rises!  Safe ground shrinks to %dm" % int(smog_goal()))

var _dbg_t := 0.0
var _trace := OS.has_environment("ASCENT_LOG")
var stats := {}                       # QA counters (falls, drops, shoves, rings, pads, vents, seeds, smog hits, KOs)
func _stat(k: String) -> void:
	stats[k] = int(stats.get(k, 0)) + 1
# QA trace for hands-off rounds (`-- autostart fire sky autopilot`): one line every 15 s.
func _debug_log(dt: float) -> void:
	_dbg_t -= dt
	if _dbg_t > 0.0:
		return
	_dbg_t = 5.0 if OS.has_environment("ASCENT_TRACE") else 15.0
	var parts: Array = []
	for ch in g.actors:
		parts.append("%s%s hp%d T%d m%d r%d (%.0f,%.0f)%s" % [ch.el.substr(0, 1).to_upper(), "*" if ch.is_human else "", ch.hp, ch.tier,
			int(motes_el[ch.el]), int(rings_el[ch.el]), ch.pos.x, ch.pos.z, [" ", " FALL", " FLY"][ch.busy]])
	print("[ascent %s] ecl=%s smog=%.0f | %s" % [g._fmt_time(elapsed), str(eclipse_active()), smog_r(), " | ".join(parts)])
	if OS.has_environment("ASCENT_TRACE"):
		for ch in g.actors:
			var pth: Array = ch.ai.get("path", [])
			var nxt := str(pth[0]) if not pth.is_empty() else "-"
			print("   %s vel=%.1f in_ramp=%s cave_t=%.0f cd=%.0f path=%d next=%s node=%s onground=%s" % [ch.el, ch.vel.length(), str(ch.in_ramp), ch.cave_time, ch.cave_cooldown,
				pth.size(), nxt, SkyLayout.node_of(ch.pos.x, ch.pos.z), str(SkyLayout.on_ground(ch.pos.x, ch.pos.z, ch.el, vines_mask()))])

# ------------------------------------------------------------------ winning
# The current standing of an element team: (rings, tier, earliest arrival).
func _standing(el: String) -> Dictionary:
	var best_tier := 0
	var at := INF
	for ch in g.by_el.get(el, []):
		if ch.busy != BUSY_NONE:
			continue
		if ch.tier > best_tier or (ch.tier == best_tier and ch.tier_at < at):
			best_tier = ch.tier
			at = ch.tier_at
	return { "el": el, "tier": best_tier, "rings": int(rings_el[el]), "at": at }

func _finish_on_time() -> void:
	# 8:00 — the highest Spark wins: tier, then rings, then who reached that tier first
	var rows: Array = []
	for el in ELS:
		rows.append(_standing(el))
	rows.sort_custom(func(a, b):
		if a["tier"] != b["tier"]: return a["tier"] > b["tier"]
		if a["rings"] != b["rings"]: return a["rings"] > b["rings"]
		return a["at"] < b["at"])
	_finish(rows[0]["el"], "ascent_time")

func _finish(winner_el: String, reason: String) -> void:
	if over:
		return
	over = true
	var standings: Array = []
	for el in ELS:
		var s := _standing(el)
		standings.append({
			"el": el, "score": (10000 if el == winner_el else 0) + int(s["rings"]) * 100 + int(s["tier"]) * 10 + int(motes_el[el]),
			"winner": el == winner_el,
			"detail": "bell %d/%d   ·   tier %d   ·   motes %d" % [int(s["rings"]), BELL_RINGS_TO_WIN, int(s["tier"]), int(motes_el[el])],
		})
	print("[ascent] round over at %s — %s wins (%s)  rings=%s motes=%s  stats=%s" % [
		g._fmt_time(elapsed), winner_el, reason, str(rings_el), str(motes_el), str(stats)])
	g._sky_end(reason, winner_el, standings)

# ------------------------------------------------------------------ rival AI
# GATHER (Dijkstra over the isle graph incl. your own element route) → TO_SPIRE →
# CLIMB (toward the ramp or your own pad, whichever is closer in angle) → RING.
# Returns the wish direction (zero = stand still).
func ai_dir(ch: GameChar, dt: float) -> Vector3:
	var st: Dictionary = ch.ai
	st["path_t"] = float(st.get("path_t", 0.0)) - dt
	st["chase_cd"] = float(st.get("chase_cd", 0.0)) - dt
	var chase_t := float(st.get("chase_t", 0.0))
	var safe_home: bool = g.inside_own_cave(ch) and ch.tier == 0
	var threat_pos := Vector3.ZERO
	var td := 13.0
	var prey: GameChar = null
	var pd := 12.0
	for o in g.actors:
		if o == ch or not o.alive or o.busy != BUSY_NONE or o.tier != ch.tier:
			continue
		var d := flat_dist(ch.pos, o.pos)
		var o_home: bool = o.tier == 0 and g.inside_own_cave(o)
		if g._eats(o.el, ch.el) and d < td and not safe_home and not o_home:
			td = d; threat_pos = o.pos
		elif g._eats(ch.el, o.el) and o.invuln_timer <= 0.0 and d < pd and not o_home:
			pd = d; prey = o
	for n in g.npcs:
		if n.kind == "co2" and n.alive and n.co_timer <= 0.0 and n.tier == ch.tier and not safe_home:
			var d2 := flat_dist(ch.pos, n.pos)
			if d2 < minf(td, 11.0):
				td = d2; threat_pos = n.pos
	var dir := Vector3.ZERO
	if prey != null and float(st["chase_cd"]) <= 0.0 and chase_t < 2.5:
		st["chase_t"] = chase_t + dt
		dir = flat(prey.pos + prey.vel * 0.25 - ch.pos)
	else:
		if chase_t >= 2.5:
			st["chase_t"] = 0.0
			st["chase_cd"] = 3.0
		if prey == null:
			st["chase_t"] = 0.0
		# a beat to gloat over each new mote, and a breather after being chased down a stair
		# (otherwise prey yo-yos on the stair in front of a predator that holds the terrace)
		var seen := int(st.get("motes_seen", 0))
		if int(motes_el[ch.el]) > seen:
			st["motes_seen"] = int(motes_el[ch.el])
			st["hold"] = 1.6
		if ch.tier < int(st.get("last_tier", 0)) and bool(st.get("flee", false)):
			st["hold"] = 2.5
		st["last_tier"] = ch.tier
		st["hold"] = float(st.get("hold", 0.0)) - dt
		dir = Vector3.ZERO if float(st["hold"]) > 0.0 else _goal_dir(ch)
	if dir.length_squared() > 1e-6:
		dir = dir.normalized()
	st["flee"] = td < 13.0 and ch.invuln_timer <= 0.0
	if td < 13.0 and ch.invuln_timer <= 0.0:
		var away := flat(ch.pos - threat_pos)
		if away.length_squared() > 1e-6:
			dir = dir * 0.6 + away.normalized() * ((13.0 - td) / 13.0 * 1.6)
			if dir.length_squared() > 1e-6:
				dir = dir.normalized()
	if ch.tier == 0 and dir != Vector3.ZERO:
		dir = _edge_safe(ch, dir)
	return dir

# Never steer off an edge: probe ahead and rotate away from the void; on a bridge,
# lean back toward its centre line.
func _edge_safe(ch: GameChar, dir: Vector3) -> Vector3:
	var vm := vines_mask()
	if ch.el == "fire" and Vector2(ch.pos.x, ch.pos.z).distance_to(SkyLayout.VENT_HOME) < 5.0:
		return dir
	var look := 3.6
	var out := dir
	if not SkyLayout.on_ground(ch.pos.x + dir.x * look, ch.pos.z + dir.z * look, ch.el, vm):
		var base := atan2(dir.z, dir.x)
		var found := false
		for off in [25.0, -25.0, 50.0, -50.0, 80.0, -80.0, 120.0, -120.0, 160.0, -160.0]:
			var t: float = base + deg_to_rad(off)
			if SkyLayout.on_ground(ch.pos.x + cos(t) * look, ch.pos.z + sin(t) * look, ch.el, vm):
				out = Vector3(cos(t), 0.0, sin(t))
				found = true
				break
		if not found:
			return Vector3.ZERO
	if SkyLayout.node_of(ch.pos.x, ch.pos.z) == "":
		# on a bridge / route: there is only forward or back. Lock the heading to the
		# span's axis (so a panicked swerve can't carry us over the side) and lean
		# back toward its centre line.
		var best_d := INF
		var best_s: Dictionary = {}
		var pull := Vector3.ZERO
		for s in _segments_for(ch.el, vm):
			var q := _closest_on(ch.pos.x, ch.pos.z, s)
			var d := Vector2(q.x - ch.pos.x, q.y - ch.pos.z).length()
			if d < best_d:
				best_d = d
				best_s = s
				pull = Vector3(q.x - ch.pos.x, 0.0, q.y - ch.pos.z)
		if best_d < 6.0:
			var axis := Vector3(float(best_s["bx"]) - float(best_s["ax"]), 0.0, float(best_s["bz"]) - float(best_s["az"])).normalized()
			var along := dir.dot(axis)
			if absf(along) < 0.25:
				along = ch.vel.dot(axis)
			out = axis * (1.0 if along >= 0.0 else -1.0)
			if best_d > 0.25:
				out = (out + pull.normalized() * clampf(best_d / 1.2, 0.0, 1.3)).normalized()
	return out

func _segments_for(el: String, vm: int) -> Array:
	var out: Array = SkyLayout.BRIDGES.duplicate()
	out.append(SkyLayout.STREAM)
	if el == "grass":
		out.append(SkyLayout.VINE)
	for i in SkyLayout.SEEDS.size():
		if (vm & (1 << i)) != 0:
			out.append(SkyLayout.SEEDS[i])
	return out

static func _closest_on(px: float, pz: float, s: Dictionary) -> Vector2:
	var a := Vector2(s["ax"], s["az"])
	var b := Vector2(s["bx"], s["bz"])
	var v := b - a
	var l2 := v.length_squared()
	var t := 0.0 if l2 < 1e-9 else clampf((Vector2(px, pz) - a).dot(v) / l2, 0.0, 1.0)
	return a + v * t

func _goal_dir(ch: GameChar) -> Vector3:
	if ch.tier > 0:
		return _spire_dir(ch)
	if lit(ch.el):
		if radius(ch.pos) <= SkyLayout.HEART_R:
			return _spire_dir(ch)
		return _follow(ch, "heart", null)
	# GATHER: the cheapest of my remaining motes by path cost
	var st: Dictionary = ch.ai
	var tgt = st.get("target")
	if float(st["path_t"]) <= 0.0 or tgt == null or bool(tgt["taken"]) or String(tgt["el"]) != ch.el:
		var mine: Array = motes.filter(func(m): return m["el"] == ch.el and not m["taken"])
		if mine.is_empty():
			return Vector3.ZERO
		var res := SkyLayout.dijkstra(_starts_for(ch), ch.el, smog_goal())
		var best = null
		var bc := INF
		for m in mine:
			var nid := _mote_node(m)
			var is_: Dictionary = SkyLayout.NODES[nid]
			var c: float = float(res["D"][nid]) + flat_dist(m["pos"], Vector3(is_["x"], 0.0, is_["z"])) * 0.3
			if c < bc:
				bc = c; best = m
		st["target"] = best
		var mp: Vector3 = best["pos"]
		st["path"] = _build_path(ch, _mote_node(best), Vector2(mp.x, mp.z))
		st["path_t"] = 0.6 + randf() * 0.3
	return _follow_path(ch)

func _mote_node(m: Dictionary) -> String:
	var p: Vector3 = m["to"] if float(m["drift"]) >= 0.0 else m["pos"]
	var id := SkyLayout.node_of(p.x, p.z)
	if id != "":
		return id
	var bd := INF
	for is_ in SkyLayout.ISLES:
		var d := flat_dist(p, Vector3(is_["x"], 0.0, is_["z"])) - float(is_["r"])
		if d < bd:
			bd = d; id = is_["id"]
	return id

func _starts_for(ch: GameChar) -> Array:
	var n := SkyLayout.node_of(ch.pos.x, ch.pos.z)
	if n != "":
		return [{ "id": n, "c": 0.0 }]
	var vm := vines_mask()
	var best = null
	var bd := INF
	for e in SkyLayout.EDGES:
		var kind := String(e["kind"])
		if kind == "vent" or (kind == "vine" and ch.el != "grass") or (kind == "seed" and (vm & (1 << int(e["idx"]))) == 0):
			continue
		var s: Dictionary = _edge_seg(e)
		var d := SkyLayout.seg_dist(ch.pos.x, ch.pos.z, s["ax"], s["az"], s["bx"], s["bz"])
		if d < bd:
			bd = d; best = e
	if best == null:
		return [{ "id": "heart", "c": 0.0 }]
	var A: Dictionary = SkyLayout.NODES[best["a"]]
	var B: Dictionary = SkyLayout.NODES[best["b"]]
	return [
		{ "id": best["a"], "c": flat_dist(ch.pos, Vector3(A["x"], 0.0, A["z"])), "via": best["b"], "e": best },
		{ "id": best["b"], "c": flat_dist(ch.pos, Vector3(B["x"], 0.0, B["z"])), "via": best["a"], "e": best },
	]

# the walkable centre line of a graph edge
func _edge_seg(e: Dictionary) -> Dictionary:
	if String(e["kind"]) == "seed":
		return SkyLayout.SEEDS[int(e["idx"])]
	var A: Dictionary = SkyLayout.NODES[e["a"]]
	var B: Dictionary = SkyLayout.NODES[e["b"]]
	return { "ax": A["x"], "az": A["z"], "bx": B["x"], "bz": B["z"], "hw": 2.0 }

# where edge `e` leaves isle `id` (toward the other end), on the isle's ground
func _port(e: Dictionary, id: String) -> Vector2:
	var other: String = e["b"] if String(e["a"]) == id else e["a"]
	if String(e["kind"]) == "seed":
		var sd: Dictionary = SkyLayout.SEEDS[int(e["idx"])]
		return sd["mb"] if id == "heart" else sd["ma"]
	return SkyLayout.port_on(id, other)

func _build_path(ch: GameChar, target_id: String, final_pt) -> Array:
	var starts := _starts_for(ch)
	var res := SkyLayout.dijkstra(starts, ch.el, smog_goal())
	if is_inf(float(res["D"][target_id])):
		return []
	var chain: Array = []
	var cur := target_id
	while cur != "":
		var p = res["P"].get(cur)
		chain.push_front({ "id": cur, "e": p["e"] if p != null else null })
		cur = p["from"] if p != null else ""
	var pts: Array = []
	for s in starts:
		if s["id"] == chain[0]["id"] and s.has("via"):
			pts.append({ "p": _port(s["e"], s["id"]) })     # mid-bridge: finish crossing first
	for i in chain.size() - 1:
		var e: Dictionary = chain[i + 1]["e"]
		var from_id: String = chain[i]["id"]
		var to_id: String = chain[i + 1]["id"]
		match String(e["kind"]):
			"vent":
				pts.append({ "p": SkyLayout.VENT_HOME if from_id == "h_fire" else SkyLayout.VENT_HEART, "vent": true })
				return _with_ring(ch, pts)
			"seed":
				pts.append({ "p": _port(e, from_id), "seed": int(e["idx"]) })
				pts.append({ "p": _port(e, to_id) })
			_:
				pts.append({ "p": _port(e, from_id) })
				pts.append({ "p": _port(e, to_id) })
	if final_pt != null:
		pts.append({ "p": final_pt })
	return _with_ring(ch, pts)

static func _on_heart_ground(p: Vector2) -> bool:
	var r := p.length()
	return r >= 18.0 and r <= SkyLayout.HEART_R + 1.0

# two waypoints on Heart Isle's ground ring are joined around the spire, not through it
func _with_ring(ch: GameChar, pts: Array) -> Array:
	var out: Array = []
	var cur := Vector2(ch.pos.x, ch.pos.z)
	for q in pts:
		var qp: Vector2 = q["p"]
		if _on_heart_ground(cur) and _on_heart_ground(qp):
			var t1 := SkyLayout.ang_of(cur.x, cur.y)
			var d := SkyLayout.ang_diff(t1, SkyLayout.ang_of(qp.x, qp.y))
			var steps := int(ceil(absf(d) / 22.0))
			for i in range(1, steps):
				out.append({ "p": SkyLayout.pol(t1 + d * float(i) / float(steps), 24.7) })
		out.append(q)
		cur = qp
	return out

func _follow(ch: GameChar, node_id: String, final_pt) -> Vector3:
	var st: Dictionary = ch.ai
	if float(st["path_t"]) <= 0.0 or not st.has("path"):
		st["path"] = _build_path(ch, node_id, final_pt)
		st["path_t"] = 0.6 + randf() * 0.3
	return _follow_path(ch)

func _follow_path(ch: GameChar) -> Vector3:
	var path: Array = ch.ai.get("path", [])
	var me := Vector2(ch.pos.x, ch.pos.z)
	while not path.is_empty():
		var w: Dictionary = path[0]
		var d := me.distance_to(w["p"])
		if w.has("seed"):
			# stand on the seed until the vine has grown (and has time left to cross)
			if d < 1.0:
				if float(seed_until[int(w["seed"])]) - elapsed > 6.5:
					path.pop_front()
					continue
				return Vector3.ZERO
			break
		if d < (0.8 if w.has("vent") else 2.2):
			if w.has("vent"):
				return Vector3.ZERO                  # stand on the pad until it flings us
			path.pop_front()
			continue
		break
	if path.is_empty():
		return Vector3.ZERO
	var p: Vector2 = path[0]["p"]
	return Vector3(p.x - ch.pos.x, 0.0, p.y - ch.pos.z)

# Someone who eats me holds the summit and the chain is about to flip → wait it out.
func _should_hold(ch: GameChar) -> bool:
	if ch.tier < 2 or flip_in() > 10.0:
		return false
	for o in g.actors:
		if o != ch and o.alive and o.busy == BUSY_NONE and o.tier > ch.tier and o.tier >= SPIRE_TIERS - 1 and g._eats(o.el, ch.el):
			return true
	return false

func _spire_dir(ch: GameChar) -> Vector3:
	var k := ch.tier
	var x := ch.pos.x
	var z := ch.pos.z
	var r := maxf(0.001, sqrt(x * x + z * z))
	if k >= SPIRE_TIERS:
		return Vector3.ZERO if r < 1.8 else Vector3(-x, 0.0, -z)
	if _should_hold(ch):
		return Vector3.ZERO
	var ang := SkyLayout.ang_of(x, z)
	var R := SkyLayout.tier_inner(k)
	var run := float(SkyLayout.SPIRE_RAMP_RUN[k])
	var ro := SkyLayout.tier_outer(k)
	var rc := minf(R + run + 0.4, ro - 0.5)             # circle outside the stair's foot
	var d_ramp := SkyLayout.ang_diff(ang, SkyLayout.ramp_ang(k))
	var d_pad := SkyLayout.ang_diff(ang, SkyLayout.pad_ang(k, ch.el))
	if ch.pad_cd <= 0.0 and absf(d_pad) < absf(d_ramp):
		var pp := SkyLayout.pad_pos(k, ch.el)
		if absf(d_pad) * deg_to_rad(1.0) * r < 5.0:
			var to := Vector3(pp.x - x, 0.0, pp.y - z)
			return Vector3.ZERO if to.length() < 0.5 else to
		return _tangent(ang, d_pad, r, rc)
	if ch.in_ramp or absf(d_ramp) < SPIRE_RAMP_ARC * 0.5 - 3.0:
		# on / in front of the stair: straight at the wall, centring on the stair
		var th := deg_to_rad(ang)
		var s := signf(d_ramp)
		return Vector3(-cos(th), 0.0, -sin(th)) + Vector3(-sin(th), 0.0, cos(th)) * s * minf(0.5, absf(d_ramp) / 8.0)
	return _tangent(ang, d_ramp, r, rc)

static func _tangent(ang: float, d: float, r: float, rc: float) -> Vector3:
	var s := 1.0 if d >= 0.0 else -1.0
	var th := deg_to_rad(ang)
	var radial := clampf((rc - r) * 0.5, -1.0, 1.0)
	return Vector3(-sin(th) * s + cos(th) * radial, 0.0, cos(th) * s + sin(th) * radial)

# Move an AI rival one step.
func update_ai(ch: GameChar, dt: float) -> void:
	if ch.busy != BUSY_NONE or ch.kb_t > 0.0:
		return
	var dir := ai_dir(ch, dt)
	if dir == Vector3.ZERO:
		ch.vel *= pow(0.02, dt)
	else:
		if ch.tier == 0 and radius(ch.pos) > SkyLayout.HEART_R:
			dir = g._avoidance_and_walls(ch, dir)
		var pace := AI_SPEED if (ch.tier > 0 or lit(ch.el)) else AI_GATHER_SPEED
		if bool(ch.ai.get("flee", false)):
			pace = AI_SPEED * AI_FLEE_BOOST
		var target: Vector3 = dir.normalized() * (ch.speed * pace * g.terrain_mult(ch) * g._slow_mult(ch))
		ch.vel = ch.vel.lerp(target, 1.0 - pow(0.0005, dt))
	ch.vel.y = 0.0
	var px := ch.pos.x
	var pz := ch.pos.z
	ch.pos.x += ch.vel.x * dt
	ch.pos.z += ch.vel.z * dt
	# a rival never WALKS off an edge by itself (a shove or a withered vine still drops it)
	if ch.tier == 0 and not SkyLayout.on_ground(ch.pos.x, ch.pos.z, ch.el, vines_mask(), 0.2) \
			and SkyLayout.on_ground(px, pz, ch.el, vines_mask(), 0.2):
		ch.pos.x = px
		ch.pos.z = pz
		ch.vel = Vector3.ZERO
	g.resolve_collisions(ch)

# Debug autopilot: the same brain steers the local human through the normal input
# path (camera yaw + the touch joystick), so a whole round can be played hands-off.
func drive_autopilot(dt: float) -> void:
	var p: GameChar = g.player
	if p == null or not p.alive or p.busy != BUSY_NONE:
		g.touch_move = Vector2.ZERO
		return
	var dir := ai_dir(p, dt)
	if dir == Vector3.ZERO:
		g.touch_move = Vector2.ZERO
		return
	g.cam_yaw = atan2(-dir.x, -dir.z)
	g.touch_move = Vector2(0.0, 1.0)

# ------------------------------------------------------------------ per-frame (all modes)
# Visuals + HUD from the (authoritative or mirrored) state.
func frame(dt: float) -> void:
	if g.mode == g.Mode.CLIENT and g.running:
		elapsed += dt
		bell_settle = maxf(0.0, bell_settle - dt)
		if not ping.is_empty():
			ping["t"] = float(ping["t"]) + dt
			if float(ping["t"]) > 4.0:
				ping = {}
		_announce()
	if g.mode == g.Mode.CLIENT and g.net_log and g.running and g.player != null:
		_dbg_t -= dt
		if _dbg_t <= 0.0:
			_dbg_t = 15.0
			var me: GameChar = g.player
			var seen := 0
			for mo in motes:
				if not mo["taken"]:
					seen += 1
			print("[ascent-guest %s] me=%s hp%d T%d busy%d (%.0f,%.0f,y%.1f)  motes=%s rings=%s tiers=%s  motes-left=%d bell=%.1f ecl=%s smog=%.0f ghosts=%d" % [
				g._fmt_time(elapsed), me.el, me.hp, me.tier, me.busy, me.pos.x, me.pos.z, me.pos.y, str(motes_el), str(rings_el), str(tier_el),
				seen, bell_settle, str(eclipse_active()), smog_r(), g.ghosts.size()])
	var lp: GameChar = g.player
	_fall_view = (_fall_view + dt) if (lp != null and lp.busy == BUSY_FALL) else 0.0
	if view:
		view.update(dt)
	_update_hud()

# the chase camera stops following a fall after FALL_CAM_TIME (the avatar drops out of view)
func fall_frozen() -> bool:
	return _fall_view > FALL_CAM_TIME

func _local_el() -> String:
	if g.player:
		return g.player.el
	return String(g.local_el)

func _update_hud() -> void:
	var ui = g.ui
	var p: GameChar = g.player
	if ui == null or p == null:
		return
	var el := p.el
	var n := int(motes_el[el])
	var k := p.tier
	var obj := ""
	if n < ASCENT_MOTES_NEEDED:
		obj = "Gather your Sun Motes  %d / %d  —  one is on %s" % [n, ASCENT_MOTES_NEEDED, SkyLayout.HOME_NAME[String(g.ELEMENTS[el]["prey"])]]
	elif k == 0:
		obj = "Spark lit!  Enter the Sky Spire — the door ramp, or your %s pad" % SHORT_NAME[el]
	elif k < SPIRE_TIERS:
		obj = "Climb!  Tier %d / %d  —  ramp, or your %s pad on the far side" % [k, SPIRE_TIERS, SHORT_NAME[el]]
	else:
		obj = "Ring the Sky Bell — stand in the ring  (%d / %d)" % [int(rings_el[el]), BELL_RINGS_TO_WIN]
	if p.busy == BUSY_FALL:
		obj = "Falling through the clouds…"
	ui.set_objective(obj)
	# (no emoji / symbol glyphs in HUD text: the web build's font has none — the mote
	# pips are real drawn dots, see GameUI.set_mote_pips)
	ui.set_mote_pips(n, ASCENT_MOTES_NEEDED, MeshLib.rgb(GameUI.UI_COLORS[el]))
	var s := "Tier %d/%d   ·   Bell %d/%d" % [k, SPIRE_TIERS, int(rings_el[el]), BELL_RINGS_TO_WIN]
	if g.o2_charges > 0:
		s += "   ·   Breeze %d/%d" % [g.o2_charges, g.O2_CHARGE_CAP]
	if g._is_disguised():
		s += "   ·   Shard %ds" % int(ceil(g.disguise_timer))
	ui.set_status(s)
	ui.set_hearts(p.hp, maxi(p.max_hp, p.hp))
	# the role line follows the chain: it flips for the 15 s of an eclipse
	ui.set_role("%s: %s — catch %s, flee %s" % ["ECLIPSE" if eclipse_active() else "You", g.ELEMENTS[el]["label"],
		g.ELEMENTS[g._prey_of(el)]["label"], g.ELEMENTS[g._pred_of(el)]["label"]])
	# clocks
	var ec := eclipse_active()
	var etxt := ("ECLIPSE!  CHAIN REVERSED  %s" % g._fmt_time(ceil(eclipse_left()))) if ec else ("ECLIPSE IN  %s" % g._fmt_time(ceil(eclipse_in())))
	var nr := next_rise_in()
	var stxt := ("SMOG RISES IN  %s   ·   safe %dm" % [g._fmt_time(ceil(nr)), int(smog_goal())]) if nr >= 0.0 else "SMOG SEA AT ITS PEAK"
	if radius(p.pos) > smog_r() and p.tier == 0 and p.busy == BUSY_NONE:
		stxt = "IN THE SMOG — a heart every %ds!" % int(SMOG_HIT_EVERY)
	ui.set_sky_info(g._fmt_time(ceil(time_left())), etxt, ec, stxt)
	var entries: Array = []
	for e in ELS:
		entries.append({ "el": e, "label": g.ELEMENTS[e]["label"], "score": 0, "alive": true, "me": e == el,
			"text": "%s  T%d · %d/%d" % [g.ELEMENTS[e]["label"], int(tier_el[e]), int(rings_el[e]), BELL_RINGS_TO_WIN] })
	ui.set_board(entries)
	var hint := _context_hint(p)
	ui.set_hint(hint[0], hint[1])
	ui.radar.sky_smog_r = smog_r()
	ui.radar.sky_el = el
	ui.radar.sky_vines = vines_mask()
	# channel bar: ringing / pad charge / seed growing
	var rp := p.ring_prog if g.mode != g.Mode.CLIENT else ring_view
	var sg := 0.0
	if el == "grass":
		for i in seed_grow.size():
			sg = maxf(sg, float(seed_grow[i]))
	if rp > 0.0:
		ui.set_channel("Ringing the Sky Bell", rp)
	elif k == SPIRE_TIERS and bell_settle > 0.0 and radius(p.pos) <= BELL_ZONE_R:
		ui.set_channel("The bell is swinging…", 1.0 - bell_settle / BELL_SETTLE)
	elif sg > 0.0:
		ui.set_channel("Growing a vine bridge", sg)
	else:
		ui.set_channel("", -1.0)
	# fall: camera follows for a second, then the clouds white everything out
	var wo := 0.0
	if p.busy == BUSY_FALL:
		wo = clampf((_fall_view - FALL_CAM_TIME * 0.6) / 0.6, 0.0, 1.0)
	ui.set_whiteout(wo)
	var lit_now := lit(el)
	if g.mode == g.Mode.CLIENT and lit_now and not _was_lit:
		ui.toast("Your Spark is LIT! Climb the Sky Spire on Heart Isle.")
	_was_lit = lit_now

# Extra radar markers: my uncollected motes, the spire door / my pad, the bell ping.
func radar_blips(blips: Array) -> void:
	var el := _local_el()
	if el == "":
		return
	var col: Color = MeshLib.rgb(g.ELEMENTS[el]["color"])
	for m in motes:
		if not m["taken"] and m["el"] == el:
			var mp: Vector3 = m["pos"]
			blips.append({ "pos": Vector2(mp.x, mp.z), "color": col, "o2": false, "mote": true })
	if not ping.is_empty():
		blips.append({ "pos": Vector2(ping["x"], ping["z"]), "color": MeshLib.rgb(g.ELEMENTS[ping["el"]]["color"]), "o2": false, "ping": float(ping["t"]) })

# ------------------------------------------------------------------ online
const _EL_IDX := { "fire": 0, "water": 1, "grass": 2 }

# HOST → guests, riding the ~6 Hz "meta" message.
func pack_meta() -> Dictionary:
	var ml: Array = []
	for m in motes:
		var mp: Vector3 = m["pos"]
		ml.append([int(_EL_IDX[m["el"]]), snappedf(mp.x, 0.1), snappedf(mp.z, 0.1), 1 if m["taken"] else 0])
	var rp := {}
	for ch in g.actors:
		if ch.is_human and ch.ring_prog > 0.0:
			rp[ch.net_id] = snappedf(ch.ring_prog, 0.01)
	var d := {
		"t": snappedf(elapsed, 0.01),
		"m": ml,
		"mc": [int(motes_el["fire"]), int(motes_el["water"]), int(motes_el["grass"])],
		"rg": [int(rings_el["fire"]), int(rings_el["water"]), int(rings_el["grass"])],
		"tr": [int(tier_el["fire"]), int(tier_el["water"]), int(tier_el["grass"])],
		"bs": snappedf(bell_settle, 0.01),
		"sv": [snappedf(maxf(0.0, float(seed_until[0]) - elapsed), 0.1), snappedf(maxf(0.0, float(seed_until[1]) - elapsed), 0.1)],
		"sg": [snappedf(float(seed_grow[0]), 0.01), snappedf(float(seed_grow[1]), 0.01)],
		"rp": rp,
	}
	if not ping.is_empty():
		d["pg"] = [snappedf(float(ping["x"]), 0.1), snappedf(float(ping["z"]), 0.1), int(_EL_IDX[ping["el"]]), snappedf(float(ping["t"]), 0.1)]
	return d

# GUEST: mirror the host's Ascent state.
func apply_meta(d: Dictionary) -> void:
	var t := float(d.get("t", elapsed))
	if absf(t - elapsed) > 0.35:
		elapsed = t
	var ml: Array = d.get("m", [])
	while motes.size() < ml.size():
		_add_mote("fire", Vector3.ZERO)
	for i in ml.size():
		var e: Array = ml[i]
		var m: Dictionary = motes[i]
		m["el"] = ELS[int(e[0])]
		m["pos"] = Vector3(float(e[1]), 0.0, float(e[2]))
		m["taken"] = int(e[3]) != 0
	var mc: Array = d.get("mc", [0, 0, 0])
	var rg: Array = d.get("rg", [0, 0, 0])
	var tr: Array = d.get("tr", [0, 0, 0])
	var my_el := _local_el()
	for i in ELS.size():
		var el: String = ELS[i]
		var prev_m := int(motes_el[el])
		var prev_r := int(rings_el[el])
		motes_el[el] = int(mc[i])
		rings_el[el] = int(rg[i])
		tier_el[el] = int(tr[i])
		if int(rg[i]) > prev_r:
			_on_ring_event(el, int(rg[i]))
		if el == my_el and int(mc[i]) > prev_m and int(mc[i]) < ASCENT_MOTES_NEEDED and g.ui:
			g.ui.toast("Sun Mote absorbed  %d / %d" % [int(mc[i]), ASCENT_MOTES_NEEDED])
	bell_settle = float(d.get("bs", 0.0))
	var sv: Array = d.get("sv", [0.0, 0.0])
	var sg: Array = d.get("sg", [0.0, 0.0])
	for i in mini(sv.size(), seed_until.size()):
		seed_until[i] = (elapsed + float(sv[i])) if float(sv[i]) > 0.0 else 0.0
		seed_grow[i] = float(sg[i]) if i < sg.size() else 0.0
	var rp: Dictionary = d.get("rp", {})
	ring_view = float(rp.get(str(g.local_net_id), 0.0))
	if d.has("pg"):
		var pg: Array = d["pg"]
		ping = { "x": float(pg[0]), "z": float(pg[1]), "el": ELS[int(pg[2])], "t": float(pg[3]) }
	else:
		ping = {}
