class_name CharVisual
extends Node3D
# Visual rig for a walking character: body + jointed stick legs/arms.
# Mirrors the runAnim() logic from the original HTML game.

var legs: Array = []        # [{ "hip": Node3D, "knee": Node3D }, ...]
var arms: Array = []        # [Node3D, ...]  (shoulder pivots)
var body: Node3D = null     # bobbing body group (mesh + face)
var extra: Callable = Callable()   # optional per-frame extra animation: func(t_ms)
var leg_shader: ShaderMaterial = null   # GLB chars swing their legs in the shader
var leg_gain: float = 1.0   # leg-swing amplitude scale (long legs need less)

# t is elapsed milliseconds, speed is current planar speed (units/s)
func animate(t: float, speed: float) -> void:
	var sp: float = clampf(speed / 13.0, 0.0, 1.0)
	var ph: float = t * 0.021
	# Swing amplitude is proportional to speed, so when standing still (sp == 0)
	# the legs/arms settle straight ("standing") instead of marching in place.
	if leg_shader:
		leg_shader.set_shader_parameter("u_phase", ph)
		leg_shader.set_shader_parameter("u_amp", (1.0 * sp) * leg_gain)
	for i in legs.size():
		var p: float = ph + i * PI
		legs[i].hip.rotation.x = sin(p) * (1.15 * sp)
		legs[i].knee.rotation.x = -maxf(0.0, sin(p + 1.15)) * (1.25 * sp)
	for i in arms.size():
		arms[i].rotation.x = -sin(ph + i * PI) * (0.98 * sp)
	if body:
		body.position.y = absf(sin(ph)) * 0.14 * sp
		body.rotation.x = 0.1 * sp
	if extra.is_valid():
		extra.call(t)
