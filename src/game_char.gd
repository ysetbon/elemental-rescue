class_name GameChar
extends RefCounted
# Logical state for one actor (element / O2 / CO2). The visual rig lives in
# `group`; we copy pos -> group every frame, mirroring the original prototype.

var kind: String = "element"      # "element" | "o2" | "co2"
var el: String = ""               # "fire" | "water" | "grass" (elements only)
var is_player: bool = false
var group: CharVisual = null

var pos := Vector3.ZERO
var vel := Vector3.ZERO
var speed: float = 11.0
var alive: bool = true
var score: int = 0

# --- rescue-mode combat / roles ---
var max_hp: int = 1               # trained durability (player grows this)
var hp: int = 1                   # current hearts; 0 -> sent home
var slow_timer: float = 0.0       # >0 = movement halved (got punished for a hit)
var invuln_timer: float = 0.0     # >0 = can't be hit (just respawned / just hit)
var ally: bool = false            # recruited clan member
var is_twin: bool = false         # the rescued caged twin (escort objective)
var follow_angle: float = 0.0     # spread slot for allies with no target
var role: String = ""             # ally job: "" idle | "protect" | "attack" | "fetch"
var selected: bool = false        # ally is currently selected for task assignment
var co_timer: float = 0.0         # co2 only: >0 means it's spent (CO, gray, harmless)
var respawn_timer: float = 0.0    # o2 only: >0 while consumed and waiting to reappear

var cave_time: float = 0.0
var cave_cooldown: float = 0.0

var wander_target := Vector3.ZERO
var wander_timer: float = 0.0

var radar_color := Color.WHITE
