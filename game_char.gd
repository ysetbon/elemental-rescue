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

var cave_time: float = 0.0
var cave_cooldown: float = 0.0

var wander_target := Vector3.ZERO
var wander_timer: float = 0.0

var radar_color := Color.WHITE
