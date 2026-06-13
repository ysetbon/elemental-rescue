class_name MeshLib
extends Object
# Procedural mesh & material factory. Recreates the storybook characters and
# props from the original Three.js "Elemental Tag" prototype in Godot.
# Everything is built in code (no imported assets) so it stays self-contained.

# ---------------------------------------------------------------- color helpers
static func rgb(h: int) -> Color:
	return Color8((h >> 16) & 0xff, (h >> 8) & 0xff, h & 0xff, 255)

# stops: Array of [t:float, Color] ascending in t. Returns interpolated color.
static func sample_gradient(stops: Array, t: float) -> Color:
	if t <= stops[0][0]:
		return stops[0][1]
	for i in range(stops.size() - 1):
		if t <= stops[i + 1][0]:
			var t0: float = stops[i][0]
			var t1: float = stops[i + 1][0]
			var k: float = clampf((t - t0) / maxf(1e-5, t1 - t0), 0.0, 1.0)
			return Color(stops[i][1]).lerp(stops[i + 1][1], k)
	return stops[stops.size() - 1][1]

# ----------------------------------------------------------------- materials
static var _vcol_mat: StandardMaterial3D
static var _mat_cache: Dictionary = {}

# unshaded material that reads per-vertex colors (storybook flat look)
static func vcol_mat() -> StandardMaterial3D:
	if _vcol_mat == null:
		var m := StandardMaterial3D.new()
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.vertex_color_use_as_albedo = true
		m.cull_mode = BaseMaterial3D.CULL_DISABLED
		_vcol_mat = m
	return _vcol_mat

# flat unshaded solid color (eyes, ink limbs, glows)
static func unlit_mat(c: Color, alpha: float = 1.0) -> StandardMaterial3D:
	var key := "u_%s_%.2f" % [c.to_html(), alpha]
	if _mat_cache.has(key):
		return _mat_cache[key]
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = Color(c.r, c.g, c.b, alpha)
	if alpha < 1.0:
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_mat_cache[key] = m
	return m

# matte lit material (houses, ground, gas molecules) — Lambert-ish
static func lit_mat(c: Color) -> StandardMaterial3D:
	var key := "l_" + c.to_html()
	if _mat_cache.has(key):
		return _mat_cache[key]
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = 1.0
	m.metallic = 0.0
	m.metallic_specular = 0.0
	_mat_cache[key] = m
	return m

static func ink() -> StandardMaterial3D:
	return unlit_mat(rgb(0x17151f))

# Half stone, half glass: a tinted, lightly translucent, slightly glossy stone so
# you can see a captive/character inside or beneath it from above.
static func glass_stone_mat(c: Color, alpha: float = 0.5) -> StandardMaterial3D:
	var key := "gs_%s_%.2f" % [c.to_html(), alpha]
	if _mat_cache.has(key):
		return _mat_cache[key]
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(c.r, c.g, c.b, alpha)
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.roughness = 0.45
	m.metallic = 0.1
	m.metallic_specular = 0.6
	m.cull_mode = BaseMaterial3D.CULL_DISABLED   # see both faces of the dome from inside or above
	_mat_cache[key] = m
	return m

# ----------------------------------------------------------- primitive helpers
static func mi(mesh: Mesh, mat: Material) -> MeshInstance3D:
	var n := MeshInstance3D.new()
	n.mesh = mesh
	n.material_override = mat
	return n

static func cyl(top: float, bottom: float, h: float, mat: Material, seg: int = 8) -> MeshInstance3D:
	var c := CylinderMesh.new()
	c.top_radius = top
	c.bottom_radius = bottom
	c.height = h
	c.radial_segments = seg
	c.rings = 1
	return mi(c, mat)

static func box(w: float, h: float, d: float, mat: Material) -> MeshInstance3D:
	var b := BoxMesh.new()
	b.size = Vector3(w, h, d)
	return mi(b, mat)

static func sphere(r: float, mat: Material, seg: int = 16, rings: int = 10) -> MeshInstance3D:
	var s := SphereMesh.new()
	s.radius = r
	s.height = r * 2.0
	s.radial_segments = seg
	s.rings = rings
	return mi(s, mat)

# flat disc lying on the ground (cave glows etc.)
static func disc(r: float, mat: Material, seg: int = 24) -> MeshInstance3D:
	var c := CylinderMesh.new()
	c.top_radius = r
	c.bottom_radius = r
	c.height = 0.02
	c.radial_segments = seg
	c.rings = 1
	return mi(c, mat)

# ---------------------------------------------------- lathe / teardrop bodies
static func teardrop_profile(R: float, H: float, exp_: float, rings: int) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in rings + 1:
		var t: float = float(i) / rings
		pts.append(Vector2(R * sin(PI * pow(t, exp_)), H * t))
	pts[0].x = 0.0
	pts[rings].x = 0.0
	return pts

# revolve a profile around the Y axis. color_fn: func(pos:Vector3, y:float)->Color
static func revolve(profile: PackedVector2Array, radial: int, color_fn: Callable) -> ArrayMesh:
	var rings := profile.size() - 1
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var verts: Array = []
	var cols: Array = []
	for i in rings + 1:
		var rv: Array = []
		var rc: Array = []
		for j in radial + 1:
			var th: float = TAU * float(j) / radial
			var p := Vector3(profile[i].x * cos(th), profile[i].y, profile[i].x * sin(th))
			rv.append(p)
			rc.append(color_fn.call(p, profile[i].y))
		verts.append(rv)
		cols.append(rc)
	for i in rings:
		for j in radial:
			_tri(st, verts[i][j], cols[i][j], verts[i + 1][j], cols[i + 1][j], verts[i + 1][j + 1], cols[i + 1][j + 1])
			_tri(st, verts[i][j], cols[i][j], verts[i + 1][j + 1], cols[i + 1][j + 1], verts[i][j + 1], cols[i][j + 1])
	return st.commit()

static func _tri(st: SurfaceTool, p0: Vector3, c0: Color, p1: Vector3, c1: Color, p2: Vector3, c2: Color) -> void:
	st.set_color(c0); st.add_vertex(p0)
	st.set_color(c1); st.add_vertex(p1)
	st.set_color(c2); st.add_vertex(p2)

static func make_teardrop(R: float, H: float, exp_: float, radial: int, rings: int, stops: Array) -> ArrayMesh:
	var profile := teardrop_profile(R, H, exp_, rings)
	var f := func(_p: Vector3, y: float) -> Color: return sample_gradient(stops, y / H)
	return revolve(profile, radial, f)

static func make_leaf_blade(R: float, H: float, exp_: float, radial: int, rings: int, cl: Color, cr: Color, cv: Color) -> ArrayMesh:
	var profile := teardrop_profile(R, H, exp_, rings)
	var f := func(p: Vector3, _y: float) -> Color:
		if absf(p.x) < 0.02:
			return cv
		return cl if p.x < 0.0 else cr
	return revolve(profile, radial, f)

# partial torus tube (the little smile), single ink color
static func torus_arc(R: float, r: float, arc: float, useg: int, vseg: int) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var grid: Array = []
	for i in useg + 1:
		var u: float = arc * float(i) / useg
		var row: Array = []
		for j in vseg + 1:
			var v: float = TAU * float(j) / vseg
			row.append(Vector3((R + r * cos(v)) * cos(u), (R + r * cos(v)) * sin(u), r * sin(v)))
		grid.append(row)
	var c := Color.WHITE
	for i in useg:
		for j in vseg:
			_tri(st, grid[i][j], c, grid[i + 1][j], c, grid[i + 1][j + 1], c)
			_tri(st, grid[i][j], c, grid[i + 1][j + 1], c, grid[i][j + 1], c)
	return st.commit()

# ----------------------------------------------------------------- the face
static func add_face(parent: Node3D, y: float, z_off: float, opts: Dictionary) -> void:
	var s: float = opts.get("scale", 1.0)
	var gap: float = opts.get("gap", 0.33) * s
	var pupil_col: Color = opts.get("pupil", rgb(0x17151f))
	for sx in [-gap, gap]:
		var sc := sphere(0.32 * s, unlit_mat(Color.WHITE), 18, 12)
		sc.scale = Vector3(opts.get("eyeW", 0.8), opts.get("eyeH", 1.15), 0.3)
		sc.position = Vector3(sx, y, z_off)
		parent.add_child(sc)
		var pu := sphere(0.185 * s, unlit_mat(pupil_col), 14, 10)
		pu.scale = Vector3(0.88, 1.12, 0.5)
		pu.position = Vector3(sx, y - 0.015 * s, z_off + 0.08 * s)
		parent.add_child(pu)
	if opts.get("smile", false):
		var arc := PI * 0.8
		var sm := mi(torus_arc(0.17 * s, 0.04 * s, arc, 20, 8), unlit_mat(rgb(0x17151f)))
		sm.rotation.z = -PI / 2.0 - arc / 2.0
		sm.position = Vector3(0, y - 0.46 * s, z_off + 0.12 * s)
		parent.add_child(sm)

# --------------------------------------------------------- legs + arms (rig)
static func add_limbs(g: CharVisual, o: Dictionary) -> void:
	var hip_y: float = o.get("hipY", 0.85)
	var hip_z: float = o.get("hipZ", 0.0)   # +z = forward (toward the face)
	var gap: float = o.get("gap", 0.3)
	var thigh: float = o.get("thigh", 0.42)
	var shin: float = o.get("shin", 0.42)
	for s in [-1, 1]:
		var hip := Node3D.new()
		hip.position = Vector3(s * gap, hip_y, hip_z)
		var tm := cyl(0.055, 0.05, thigh, ink())
		tm.position.y = -thigh / 2.0
		var knee := Node3D.new()
		knee.position.y = -thigh
		var sm := cyl(0.05, 0.045, shin, ink())
		sm.position.y = -shin / 2.0
		var foot := box(0.16, 0.07, 0.26, ink())
		foot.position = Vector3(0, -shin + 0.03, 0.09)
		knee.add_child(sm)
		knee.add_child(foot)
		hip.add_child(tm)
		hip.add_child(knee)
		g.add_child(hip)
		g.legs.append({ "hip": hip, "knee": knee })
	if o.has("armY"):
		var arm_len: float = o.get("armLen", 0.55)
		for s in [-1, 1]:
			var sh := Node3D.new()
			sh.position = Vector3(s * o.get("armX", 0.8), o["armY"], 0)
			sh.rotation.z = s * o.get("armSplay", 0.55)
			var a := cyl(0.045, 0.04, arm_len, ink())
			a.position.y = -arm_len / 2.0
			var h := sphere(0.075, ink(), 10, 8)
			h.position.y = -arm_len
			sh.add_child(a)
			sh.add_child(h)
			g.add_child(sh)
			g.arms.append(sh)

# ---------------------------------------------------- imported GLB characters
# The fire / water / leaf elementals are shipped as .glb files: bare, position-
# only meshes (no materials/normals/vertex colors) with a body, a sculpted face
# (eyes + smile) and two legs all fused into one mesh. A single shader does
# everything on the original geometry — no mesh surgery:
#   * vertical gradient body colour,
#   * region-tint the eyes (white + dark pupil), smile and legs,
#   * compute a per-pixel normal from derivatives so the sculpt is lit, and
#   * swing the leg vertices about the hip line for a walk cycle (u_phase/u_amp,
#     driven each frame by CharVisual.animate via g.leg_shader).
# All feature positions are in the model's own units (see the cfg blocks below).
static var _glb_cache: Dictionary = {}
static var _feat_shader: Shader
static var _tex_shader: Shader
static var _body_shader: Shader

# For models that already ship their own colours in a texture (e.g. Leaf2): keep
# the texture for shading, and swing ONLY the leg vertices. Legs are detected as
# near-black texels below the face (so the black legs swing, but never the green
# body or the black pupils), then rotated about the hip line (hip_y, hip_z).
const TEX_LEG_SHADER_CODE := """
shader_type spatial;
render_mode cull_disabled;
uniform sampler2D tex_albedo : source_color;
uniform sampler2D tex_emis : source_color, hint_default_black;
uniform float emis_energy;
uniform float leg_top;
uniform float hip_y;
uniform float hip_z;
uniform float u_phase;
uniform float u_amp;
void vertex() {
	vec3 lc = textureLod(tex_albedo, UV, 0.0).rgb;
	if (lc.r + lc.g + lc.b < 0.45 && VERTEX.y < leg_top) {   // a dark, low (leg) vertex
		float ang = u_amp * sin(u_phase) * (VERTEX.x < 0.0 ? 1.0 : -1.0);
		float dy = VERTEX.y - hip_y;
		float dz = VERTEX.z - hip_z;
		float ca = cos(ang);
		float sa = sin(ang);
		VERTEX.y = hip_y + dy * ca - dz * sa;
		VERTEX.z = hip_z + dz * ca + dy * sa;
		float ny = NORMAL.y;
		float nz = NORMAL.z;
		NORMAL.y = ny * ca - nz * sa;
		NORMAL.z = nz * ca + ny * sa;
	}
}
void fragment() {
	ALBEDO = texture(tex_albedo, UV).rgb;
	EMISSION = texture(tex_emis, UV).rgb * emis_energy;
	METALLIC = 0.0;
	ROUGHNESS = 1.0;
}
"""

# For a textured GLB that ships its colours but NO legs (Fire3/Water3/Leaf3):
# just paint the body with its own albedo + emission, forced matte and double-
# sided like the storybook look. The legs are separate procedural ink limbs
# (add_limbs), so nothing is swung in the shader here.
const BODY_TEX_SHADER_CODE := """
shader_type spatial;
render_mode cull_disabled;
uniform sampler2D tex_albedo : source_color;
uniform sampler2D tex_emis : source_color, hint_default_black;
uniform float emis_energy;
void fragment() {
	ALBEDO = texture(tex_albedo, UV).rgb;
	EMISSION = texture(tex_emis, UV).rgb * emis_energy;
	METALLIC = 0.0;
	ROUGHNESS = 1.0;
}
"""

const FEATURE_SHADER_CODE := """
shader_type spatial;
render_mode cull_disabled;
uniform vec3 c_bot : source_color;
uniform vec3 c_mid : source_color;
uniform vec3 c_top : source_color;
uniform vec3 c_dark : source_color;
uniform vec3 c_eye : source_color;
uniform float y_min;
uniform float y_span;
uniform float hip_y;
uniform float face_z;
uniform float eye_cx;
uniform float eye_cy;
uniform float eye_rx;
uniform float eye_ry;
uniform float pupil_frac;
uniform float sm_y;
uniform float sm_curve;
uniform float sm_hw;
uniform float sm_thick;
uniform float u_phase;
uniform float u_amp;
varying vec3 vorig;
void vertex() {
	vorig = VERTEX;
	if (VERTEX.y < hip_y) {                       // rigidly swing each leg at the hip
		float ang = u_amp * sin(u_phase) * (VERTEX.x < 0.0 ? 1.0 : -1.0);
		float dy = VERTEX.y - hip_y;
		float dz = VERTEX.z;
		float ca = cos(ang);
		float sa = sin(ang);
		VERTEX.y = hip_y + dy * ca - dz * sa;
		VERTEX.z = dz * ca + dy * sa;
	}
}
void fragment() {
	float t = clamp((vorig.y - y_min) / y_span, 0.0, 1.0);
	vec3 col = t < 0.5 ? mix(c_bot, c_mid, t * 2.0) : mix(c_mid, c_top, (t - 0.5) * 2.0);
	if (vorig.y < hip_y) {
		col = c_dark;                             // legs
	} else if (vorig.z > face_z) {               // front-facing features only
		float my = sm_y + sm_curve * vorig.x * vorig.x;
		if (abs(vorig.x) < sm_hw && abs(vorig.y - my) < sm_thick) {
			col = c_dark;                        // smile
		} else {
			float ex = abs(vorig.x) - eye_cx;
			float ey = vorig.y - eye_cy;
			float d = (ex * ex) / (eye_rx * eye_rx) + (ey * ey) / (eye_ry * eye_ry);
			if (d < 1.0) {
				col = d < pupil_frac ? c_dark : c_eye;   // pupil : white of eye
			}
		}
	}
	ALBEDO = col;
	ROUGHNESS = 1.0;
	vec3 nn = normalize(cross(dFdx(VERTEX), dFdy(VERTEX)));
	NORMAL = nn.z < 0.0 ? -nn : nn;              // face the camera (view space)
}
"""

static func _load_glb(path: String) -> PackedScene:
	if not _glb_cache.has(path):
		_glb_cache[path] = load(path)
	return _glb_cache[path]

static func _feature_shader() -> Shader:
	if _feat_shader == null:
		_feat_shader = Shader.new()
		_feat_shader.code = FEATURE_SHADER_CODE
	return _feat_shader

static func _tex_leg_shader() -> Shader:
	if _tex_shader == null:
		_tex_shader = Shader.new()
		_tex_shader.code = TEX_LEG_SHADER_CODE
	return _tex_shader

static func _body_tex_shader() -> Shader:
	if _body_shader == null:
		_body_shader = Shader.new()
		_body_shader.code = BODY_TEX_SHADER_CODE
	return _body_shader

# For an already-textured GLB: reuse its own colours, swing only the legs.
# cfg: scale, lift, foot, yaw, idle, leg_top (dark-below cutoff for "is a leg"),
#      hip_y / hip_z (swing pivot).
static func build_glb_textured(path: String, cfg: Dictionary) -> CharVisual:
	var g := CharVisual.new()
	var body := Node3D.new()
	g.add_child(body)
	var inst: Node3D = _load_glb(path).instantiate()
	var s: float = cfg.get("scale", 1.43)
	inst.scale = Vector3.ONE * s
	inst.position.y = cfg.get("foot", 0.97) * s + cfg.get("lift", 0.0)
	inst.rotation.y = cfg.get("yaw", 0.0)
	var albedo_tex: Texture2D = null
	var emis_tex: Texture2D = null
	var emis_energy: float = 0.0
	var target: MeshInstance3D = null
	for child in inst.find_children("*", "MeshInstance3D", true, false):
		target = child as MeshInstance3D
		var src: Material = target.mesh.surface_get_material(0) if target.mesh else null
		if src == null:
			src = target.get_active_material(0)
		if src is BaseMaterial3D:
			var bm := src as BaseMaterial3D
			albedo_tex = bm.albedo_texture
			if bm.emission_enabled:
				emis_tex = bm.emission_texture
				emis_energy = bm.emission_energy_multiplier
	var mat := ShaderMaterial.new()
	mat.shader = _tex_leg_shader()
	mat.set_shader_parameter("tex_albedo", albedo_tex)
	if emis_tex:
		mat.set_shader_parameter("tex_emis", emis_tex)
	mat.set_shader_parameter("emis_energy", emis_energy)
	mat.set_shader_parameter("leg_top", cfg.get("leg_top", -0.5))
	mat.set_shader_parameter("hip_y", cfg.get("hip_y", -0.55))
	mat.set_shader_parameter("hip_z", cfg.get("hip_z", -0.2))
	mat.set_shader_parameter("u_phase", 0.0)
	mat.set_shader_parameter("u_amp", 0.0)
	if target:
		target.material_override = mat
	body.add_child(inst)
	g.body = body
	g.leg_shader = mat
	g.leg_gain = cfg.get("leg_gain", 0.25)
	if cfg.get("idle", "") == "sway":
		g.extra = func(t: float) -> void:
			inst.rotation.z = sin(t * 0.0018) * 0.05
	return g

# For a textured GLB body that has NO legs of its own (Fire3/Water3/Leaf3):
# render the body with its own texture and bolt on procedural ink legs like the
# O2/CO2 molecules. The legs live on the root (g.legs) and are swung by
# CharVisual.animate — there is no shader leg-swing here, so leg_shader stays null.
# cfg keys:
#   scale, yaw, idle ("flicker"|"sway"|""),
#   embed — how deep the hips sink into the body underside (default 0.2),
#   legs — dict forwarded to add_limbs (hipY, gap, thigh, shin).
static func build_glb_legged(path: String, cfg: Dictionary) -> CharVisual:
	var g := CharVisual.new()
	var body := Node3D.new()
	g.add_child(body)
	var inst: Node3D = _load_glb(path).instantiate()
	var s: float = cfg.get("scale", 1.43)
	inst.scale = Vector3.ONE * s
	inst.rotation.y = cfg.get("yaw", 0.0)
	var albedo_tex: Texture2D = null
	var emis_tex: Texture2D = null
	var emis_energy: float = 0.0
	var target: MeshInstance3D = null
	var aabb := AABB()
	for child in inst.find_children("*", "MeshInstance3D", true, false):
		target = child as MeshInstance3D
		if target.mesh:
			aabb = target.mesh.get_aabb()
		var src: Material = target.mesh.surface_get_material(0) if target.mesh else null
		if src == null:
			src = target.get_active_material(0)
		if src is BaseMaterial3D:
			var bm := src as BaseMaterial3D
			albedo_tex = bm.albedo_texture
			if bm.emission_enabled:
				emis_tex = bm.emission_texture
				emis_energy = bm.emission_energy_multiplier
	# Seat the body on the legs: measure the mesh's underside directly above the
	# leg columns (x = ±gap, z ≈ 0) and lower the body so the hips sink `embed`
	# into it. This auto-adapts to each body (rounded vs pointed bottom) so the
	# legs always meet the mesh instead of dangling below a narrow tip.
	var legs_cfg: Dictionary = cfg.get("legs", {})
	var hip_y: float = legs_cfg.get("hipY", 0.68)
	var hip_x: float = legs_cfg.get("gap", 0.34)
	var hip_z: float = legs_cfg.get("hipZ", 0.0)
	var embed: float = cfg.get("embed", 0.2)
	var local_under: float = aabb.position.y   # fallback: overall mesh bottom
	if target and target.mesh and target.mesh.get_surface_count() > 0:
		var vtx: PackedVector3Array = target.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
		var col: float = hip_x / s              # leg column in model-space x
		var z_center: float = hip_z / s         # follow the legs' forward offset
		var x_band: float = 0.05 / s            # window around the column
		var z_win: float = 0.16 / s             # band around the leg's z line
		var found: float = INF
		for v in vtx:
			if absf(absf(v.x) - col) < x_band and absf(v.z - z_center) < z_win:
				found = minf(found, v.y)
		if found < INF:
			local_under = found
	inst.position.y = (hip_y - embed) - local_under * s
	var mat := ShaderMaterial.new()
	mat.shader = _body_tex_shader()
	mat.set_shader_parameter("tex_albedo", albedo_tex)
	if emis_tex:
		mat.set_shader_parameter("tex_emis", emis_tex)
	mat.set_shader_parameter("emis_energy", emis_energy)
	if target:
		target.material_override = mat
	body.add_child(inst)
	g.body = body
	add_limbs(g, cfg.get("legs", {}))   # dark stick legs, like the gas molecules
	var idle: String = cfg.get("idle", "")
	if idle == "flicker":
		g.extra = func(t: float) -> void:
			inst.scale = Vector3(s, s * (1.0 + sin(t * 0.013) * 0.05), s)
	elif idle == "sway":
		g.extra = func(t: float) -> void:
			inst.rotation.z = sin(t * 0.0018) * 0.05
	return g

# cfg keys (all positions in model-space units, read off the grid renders):
#   scale, idle ("flicker"|"sway"|""), grad [bot,mid,top] hex,
#   hip_y (legs/​swing pivot, below = leg), face_z (front cutoff for the face),
#   eye [cx, cy, rx, ry, pupil_frac]  — eyes at (±cx, cy), ellipse radii rx/ry,
#   smile [y, curve, halfwidth, thick].
static func build_glb_char(path: String, cfg: Dictionary) -> CharVisual:
	var g := CharVisual.new()
	var body := Node3D.new()
	g.add_child(body)
	var inst: Node3D = _load_glb(path).instantiate()
	var s: float = cfg.get("scale", 1.5)
	inst.scale = Vector3.ONE * s
	# model bottom sits at y ≈ -0.95 in its own space; raise it to ground level
	inst.position.y = 0.95 * s + cfg.get("lift", 0.0)
	inst.rotation.y = cfg.get("yaw", 0.0)
	var mat := ShaderMaterial.new()
	mat.shader = _feature_shader()
	var grd: Array = cfg["grad"]
	mat.set_shader_parameter("c_bot", rgb(grd[0]))
	mat.set_shader_parameter("c_mid", rgb(grd[1]))
	mat.set_shader_parameter("c_top", rgb(grd[2]))
	mat.set_shader_parameter("c_dark", rgb(0x17151f))
	mat.set_shader_parameter("c_eye", rgb(0xfbfbf6))
	var aabb := AABB()
	for child in inst.find_children("*", "MeshInstance3D", true, false):
		var m := child as MeshInstance3D
		if m.mesh:
			aabb = m.mesh.get_aabb()
		m.material_override = mat
	mat.set_shader_parameter("y_min", aabb.position.y)
	mat.set_shader_parameter("y_span", maxf(0.0001, aabb.size.y))
	mat.set_shader_parameter("hip_y", cfg["hip_y"])
	mat.set_shader_parameter("face_z", cfg.get("face_z", 0.06))
	var eye: Array = cfg["eye"]
	mat.set_shader_parameter("eye_cx", eye[0])
	mat.set_shader_parameter("eye_cy", eye[1])
	mat.set_shader_parameter("eye_rx", eye[2])
	mat.set_shader_parameter("eye_ry", eye[3])
	mat.set_shader_parameter("pupil_frac", eye[4])
	var sm: Array = cfg.get("smile", [-0.4, 1.5, 0.0, 0.02])
	mat.set_shader_parameter("sm_y", sm[0])
	mat.set_shader_parameter("sm_curve", sm[1])
	mat.set_shader_parameter("sm_hw", sm[2])
	mat.set_shader_parameter("sm_thick", sm[3])
	mat.set_shader_parameter("u_phase", 0.0)
	mat.set_shader_parameter("u_amp", 0.0)
	body.add_child(inst)
	g.body = body
	g.leg_shader = mat
	var idle: String = cfg.get("idle", "")
	if idle == "flicker":
		g.extra = func(t: float) -> void:
			inst.scale = Vector3(s, s * (1.0 + sin(t * 0.013) * 0.05), s)
	elif idle == "sway":
		g.extra = func(t: float) -> void:
			inst.rotation.z = sin(t * 0.0018) * 0.05
	return g

# --------------------------------------------------------------- characters
# The *3 meshes (Fire3/Water3/Leaf3) ship their own textured bodies but have no
# legs, so we give them procedural ink legs like the gas molecules. The black
# molecule (CO2) uses 0.42 thigh + 0.42 shin; these run 20% shorter (0.336 each).
const LEG_THIGH := 0.336    # 0.42 * 0.8
const LEG_SHIN := 0.336     # 0.42 * 0.8

static func build_droplet() -> CharVisual:
	return build_glb_legged("res://Water3.glb", {
		"scale": 1.43, "idle": "sway",
		"legs": { "hipY": 0.68, "gap": 0.36, "thigh": LEG_THIGH, "shin": LEG_SHIN },
	})

static func build_flame() -> CharVisual:
	return build_glb_legged("res://Fire3.glb", {
		"scale": 1.43, "idle": "flicker",
		"legs": { "hipY": 0.68, "gap": 0.30, "thigh": LEG_THIGH, "shin": LEG_SHIN },
	})

static func build_leaf() -> CharVisual:
	# legs nudged forward (toward the face) so they emerge from the higher front
	# of the leaf and read as sitting a bit higher when seen head-on.
	return build_glb_legged("res://Leaf3.glb", {
		"scale": 1.43, "idle": "sway",
		"legs": { "hipY": 0.68, "hipZ": 0.18, "gap": 0.30, "thigh": LEG_THIGH, "shin": LEG_SHIN },
	})

# A little key (bow ring + shaft + two teeth) in silvery metal tinted by `base`.
static func key_node(base: Color) -> Node3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = base.lerp(Color(0.9, 0.9, 0.93), 0.22)
	mat.metallic = 0.9
	mat.metallic_specular = 0.95
	mat.roughness = 0.22
	mat.emission_enabled = true
	mat.emission = base
	mat.emission_energy_multiplier = 0.3
	var n := Node3D.new()
	var ring := TorusMesh.new()
	ring.inner_radius = 0.22; ring.outer_radius = 0.42
	var bow := mi(ring, mat)
	bow.rotation.x = PI / 2.0; bow.position.y = 0.5
	n.add_child(bow)
	var shaft := cyl(0.07, 0.07, 1.1, mat, 8)
	shaft.position.y = -0.2
	n.add_child(shaft)
	for zt in [-0.62, -0.82]:
		var tooth := box(0.34, 0.1, 0.1, mat)
		tooth.position = Vector3(0.16, zt, 0)
		n.add_child(tooth)
	return n

static func build_o2() -> CharVisual:
	# a single oxygen atom (one white sphere) — grab one and a CO becomes CO₂
	var g := CharVisual.new()
	var body := Node3D.new()
	g.add_child(body)
	var mat := lit_mat(rgb(0xf7f8fc))
	var s := sphere(0.82, mat, 24, 16); s.position.y = 1.5
	body.add_child(s)
	add_face(body, 1.62, 0.78, { "scale": 0.92, "gap": 0.32 })
	g.body = body
	add_limbs(g, { "hipY": 0.9, "gap": 0.3, "armY": 1.0, "armX": 0.66, "armLen": 0.48 })
	return g

static func build_co2() -> CharVisual:
	var g := CharVisual.new()
	var body := Node3D.new()
	g.add_child(body)
	var c_mat := lit_mat(rgb(0x3f3b4b))            # carbon — black centre (eyes + legs live here)
	var o_mat := lit_mat(rgb(0xf2f4fa))            # oxygen — white, to read as O=C=O
	var c := sphere(0.78, c_mat, 22, 14); c.position.y = 1.5
	var o1 := sphere(0.55, o_mat, 22, 14); o1.position = Vector3(1.12, 1.5, 0)
	var o2 := sphere(0.55, o_mat, 22, 14); o2.position = Vector3(-1.12, 1.5, 0)
	var bond_mat := lit_mat(rgb(0xb9b7c6))
	var b1 := cyl(0.14, 0.14, 1.15, bond_mat, 14); b1.rotation.z = PI / 2.0; b1.position = Vector3(0.58, 1.5, 0)
	var b2 := cyl(0.14, 0.14, 1.15, bond_mat, 14); b2.rotation.z = PI / 2.0; b2.position = Vector3(-0.58, 1.5, 0)
	body.add_child(c); body.add_child(o1); body.add_child(o2); body.add_child(b1); body.add_child(b2)
	add_face(body, 1.64, 0.72, { "scale": 0.95, "gap": 0.33, "pupil": rgb(0xff5a5a) })
	g.body = body
	add_limbs(g, { "hipY": 0.85, "gap": 0.34, "armY": 1.0, "armX": 0.7, "armLen": 0.5 })
	# expose one oxygen + its bond so the game can drop it (CO₂ → CO) and re-add it
	g.set_meta("spare_o", o2)
	g.set_meta("spare_bond", b2)
	return g

# ------------------------------------------------------- generated textures
static var _blob_tex: ImageTexture

static func blob_tex() -> ImageTexture:
	if _blob_tex != null:
		return _blob_tex
	var size := 128
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	var base := Color8(58, 54, 92, 255)
	for y in size:
		for x in size:
			var d: float = Vector2(x - 64, y - 64).length() / 62.0
			var a := 0.0
			if d < 0.65:
				a = lerpf(0.32, 0.16, d / 0.65)
			elif d < 1.0:
				a = lerpf(0.16, 0.0, (d - 0.65) / 0.35)
			img.set_pixel(x, y, Color(base.r, base.g, base.b, a))
	_blob_tex = ImageTexture.create_from_image(img)
	return _blob_tex

static func add_blob_shadow(g: Node3D, r: float = 1.4) -> void:
	var p := PlaneMesh.new()
	p.size = Vector2(r * 2.0, r * 2.0)
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.albedo_texture = blob_tex()
	m.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	var n := mi(p, m)
	n.position.y = 0.05
	g.add_child(n)

static var _moon_tex: ImageTexture

static func moon_tex() -> ImageTexture:
	if _moon_tex != null:
		return _moon_tex
	var size := 128
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	for y in size:
		for x in size:
			var d: float = Vector2(x - 64, y - 64).length() / 64.0
			var col := Color(1.0, 0.992, 0.965)
			var a := 0.0
			if d < 0.4:
				a = lerpf(1.0, 0.96, d / 0.4)
			elif d < 0.62:
				a = lerpf(0.96, 0.55, (d - 0.4) / 0.22)
			elif d < 0.82:
				a = lerpf(0.55, 0.18, (d - 0.62) / 0.2)
				col = Color(0.973, 0.941, 0.878)
			elif d < 1.0:
				a = lerpf(0.18, 0.0, (d - 0.82) / 0.18)
				col = Color(0.973, 0.941, 0.878)
			img.set_pixel(x, y, Color(col.r, col.g, col.b, a))
	_moon_tex = ImageTexture.create_from_image(img)
	return _moon_tex
