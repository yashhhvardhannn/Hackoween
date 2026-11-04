extends Node3D
# Self-contained Membrane Robot simulator for Godot 4.x.
# Agent sees only /look pixels, /depth scalar, robot-only /state and collision flag.

const PORT := 8080
const SPEED := 1.0
const TURN_SPEED := 90.0
const PICKUP_REACH := 0.5      # brief: reach 0.5 m, measured from the robot's FRONT
const ROBOT_RADIUS := 0.28     # matches the body capsule; the front is this far from the centre
const CAMERA_FORWARD := 0.28   # brief: camera at the robot front, 0.5 m above the floor
const PICKUP_HALF_ANGLE := 30.0
const MAX_DEPTH := 10.0
const BACK_OFF := 0.1          # brief: on collision, back off 0.1 m
const STUCK_SECONDS := 2.0     # brief: no movement for 2 s counts as blocked
const MAX_RETRIES := 3         # brief: fail after 3 retries
const POV_SIZE := Vector2i(1280, 720)  # Phase 2 clips: 720p
const DROP_ZONE_CENTER := Vector3(-2.5, 0, 2.5)
const THROW_MIN := 0.5         # /throw distance range in metres
const THROW_MAX := 4.0
const THROW_SETTLE_MAX := 4.0  # seconds to wait for a thrown object to stop
const LOOK_SIZE := Vector2i(640, 480)
const RAMP_TIME := 0.25       # seconds to reach full speed / to stop (smooth starts and stops)
const MIN_RAMP := 0.15
const CLIP_FPS := 30.0

var robot: CharacterBody3D
var pickup_area: Area3D
var pickup_point: Marker3D
var held: RigidBody3D
var heading := 0.0
# State names follow plan.md section 2 exactly:
# Idle | Locate | GoToObject | PickUp | Carry | Drop | Done | Blocked
var state_name := "Idle"
var outcome := ""              # pass | fail_collision | fail_not_reached | fail_wrong_object
var retries := 0
var collided := false
var busy := false

var look_vp: SubViewport
var pov_vp: SubViewport        # 1280x720 copy of the robot camera, for clip frames
var pov_cam: Camera3D
var capturing := false
var capture_dir := ""
var capture_frame := 0
var look_cam: Camera3D
var capture_accum := 0.0

var trail_points: Array[Vector3] = []
var start_transforms := {}     # pickable body -> starting transform, for /reset
var trail_node: MeshInstance3D
var trail_color := Color(0.1, 0.55, 1.0)

var server := TCPServer.new()
var peer: StreamPeerTCP
var handling_request := false
var state_label: Label
var title_label: Label

func _ready() -> void:
	# Run physics at the screen's refresh rate (60-144 Hz) so motion is smooth on any display.
	# Speeds use the frame time, and clip frames are taken by time (CLIP_FPS), so nothing else changes.
	var hz := roundi(DisplayServer.screen_get_refresh_rate())
	Engine.physics_ticks_per_second = clampi(hz, 60, 144) if hz > 0 else 60
	# Optional start view: godot --path engine -- --view=front   (behind | front | overview)
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--view="):
			view_mode = maxi(0, ["behind", "front", "overview"].find(arg.get_slice("=", 1)))
	_build_world()
	_build_robot()
	_build_cameras()
	_build_trail()
	_build_ui()
	var err := server.listen(PORT, "*")  # "*" so other laptops on the Wi-Fi can connect
	if err == OK:
		print("Robot HTTP API: http://localhost:%d" % PORT)
	else:
		push_error("Could not listen on port %d. Error %d" % [PORT, err])
	print("Keys: W/S move, A/D turn, E pickup, Q drop, T throw, R reset, P save /look")

func _process(delta: float) -> void:
	_update_cameras()
	_animate_robot(delta)
	_update_chase(delta)
	_update_ui()
	_poll_server()

func _unhandled_key_input(event: InputEvent) -> void:
	if not event is InputEventKey or not event.pressed or event.echo:
		return
	match event.keycode:
		KEY_W: _move(0.5)
		KEY_S: _move(-0.5)
		KEY_A: _turn(-30.0)
		KEY_D: _turn(30.0)
		KEY_E: _pickup()
		KEY_Q: _drop()
		KEY_T: _throw(3.0)
		KEY_R: _reset()
		KEY_P: _save_look()
		KEY_V: view_mode = (view_mode + 1) % 3

# ---------------- world ----------------

const WALL_HEIGHT := 2.0
const AGENT_EXPOSURE := 0.78   # keeps the floor in Claude's view mid-bright, not clipped white
const FLOOR_SHADER := """
shader_type spatial;
uniform vec3 tint : source_color = vec3(0.72, 0.72, 0.72);
uniform float tile = 1.0;
varying vec3 wp;
float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), f.x),
			   mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), f.x), f.y);
}
float fbm(vec2 p) {
	float v = 0.0;
	float a = 0.5;
	for (int k = 0; k < 4; k++) { v += a * noise(p); p *= 2.03; a *= 0.5; }
	return v;
}
void vertex() { wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz; }
void fragment() {
	// Polished concrete tiles: soft mottling, slight per-tile shade, thin grout lines.
	vec2 p = wp.xz / tile;
	vec2 g = abs(fract(p) - 0.5);
	float grout = smoothstep(0.488, 0.497, max(g.x, g.y));
	float fine = fbm(wp.xz * 4.0);
	float broad = fbm(wp.xz * 0.5 + 11.0);
	float per_tile = hash(floor(p) + 3.0) * 0.05;
	vec3 col = tint * (0.9 + 0.1 * fine + 0.08 * broad - per_tile);
	col = mix(col, tint * 0.6, grout * 0.7);
	ALBEDO = col;
	ROUGHNESS = mix(0.42 + 0.3 * fine, 0.9, grout);
	SPECULAR = 0.45;
}
"""

var main_env: Environment
var agent_env: Environment     # neutral version for Claude's camera: same light, faithful colours
var detail_normal: NoiseTexture2D

func _mat(color: Color, rough := 0.85) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = rough
	return m

func _box_mesh(size: Vector3, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = size
	mi.mesh = mesh
	mi.material_override = mat
	return mi

func _static_box(n: String, size: Vector3, pos: Vector3, mat: Material) -> void:
	var body := StaticBody3D.new()
	body.name = n
	body.position = pos
	var cs := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	cs.shape = shape
	body.add_child(cs)
	body.add_child(_box_mesh(size, mat))
	add_child(body)

func _visual_box(size: Vector3, pos: Vector3, mat: Material) -> void:
	var mi := _box_mesh(size, mat)
	mi.position = pos
	add_child(mi)

func _floor_mat(tint: Color, tile: float) -> ShaderMaterial:
	var sh := Shader.new()
	sh.code = FLOOR_SHADER
	var m := ShaderMaterial.new()
	m.shader = sh
	m.set_shader_parameter("tint", Vector3(tint.r, tint.g, tint.b))
	m.set_shader_parameter("tile", tile)
	return m

func _make_detail_normal() -> NoiseTexture2D:
	# One small tileable bump texture, reused for walls and objects (fine surface grain).
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.frequency = 0.06
	noise.fractal_octaves = 4
	var tex := NoiseTexture2D.new()
	tex.width = 256
	tex.height = 256
	tex.seamless = true
	tex.as_normal_map = true
	tex.bump_strength = 2.0
	tex.noise = noise
	return tex

func _build_world() -> void:
	detail_normal = _make_detail_normal()

	# Sky, soft sky light, filmic tone mapping and a little glow for the robot's lights.
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.36, 0.55, 0.84)
	sky_mat.sky_horizon_color = Color(0.76, 0.83, 0.9)
	sky_mat.ground_horizon_color = Color(0.66, 0.64, 0.6)
	sky_mat.ground_bottom_color = Color(0.32, 0.3, 0.28)
	sky_mat.sun_angle_max = 25.0
	var sky := Sky.new()
	sky.sky_material = sky_mat
	main_env = Environment.new()
	main_env.background_mode = Environment.BG_SKY
	main_env.sky = sky
	main_env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	main_env.ambient_light_energy = 0.5
	# Mostly neutral room light with a little sky blue, so the floor reads as grey, not blue.
	main_env.ambient_light_color = Color(0.86, 0.84, 0.8)
	main_env.ambient_light_sky_contribution = 0.35
	main_env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	main_env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	main_env.tonemap_exposure = 1.15
	main_env.tonemap_white = 6.0
	main_env.glow_enabled = true
	main_env.glow_intensity = 0.35
	main_env.glow_bloom = 0.03
	main_env.glow_hdr_threshold = 1.1
	main_env.adjustment_enabled = true
	main_env.adjustment_saturation = 1.08
	main_env.adjustment_contrast = 1.04
	# The agent camera gets the same light but no tone curve, glow or colour grading,
	# so the colours Claude sees stay faithful.
	agent_env = main_env.duplicate()
	agent_env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	agent_env.tonemap_exposure = AGENT_EXPOSURE
	agent_env.glow_enabled = false
	agent_env.adjustment_enabled = false
	if RenderingServer.get_current_rendering_method() == "forward_plus":
		# Extra polish only available on the Forward+ renderer (main view and clips only).
		main_env.ssao_enabled = true
		main_env.ssao_intensity = 1.6
		main_env.ssr_enabled = true
	var we := WorldEnvironment.new()
	we.environment = main_env
	add_child(we)

	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	sun.rotation_degrees = Vector3(-58, 38, 0)
	sun.light_color = Color(1.0, 0.95, 0.87)
	sun.light_energy = 1.0
	sun.shadow_enabled = true
	sun.shadow_blur = 1.5
	sun.directional_shadow_max_distance = 24.0
	add_child(sun)
	var fill := DirectionalLight3D.new()
	fill.name = "Fill"
	fill.rotation_degrees = Vector3(-30, -140, 0)
	fill.light_color = Color(0.75, 0.84, 1.0)
	fill.light_energy = 0.25
	fill.light_specular = 0.0
	add_child(fill)

	# Room: tiled concrete floor, plaster walls with a dark skirting board and a cap.
	_static_box("Floor", Vector3(8, 0.1, 8), Vector3(0, -0.05, 0), _floor_mat(Color(0.62, 0.61, 0.59), 1.0))
	var plaster := _mat(Color(0.8, 0.79, 0.76), 0.92)
	plaster.normal_enabled = true
	plaster.normal_texture = detail_normal
	plaster.normal_scale = 0.35
	plaster.uv1_triplanar = true
	plaster.uv1_scale = Vector3(0.6, 0.6, 0.6)
	var h := WALL_HEIGHT
	_static_box("NorthWall", Vector3(8.4, h, 0.2), Vector3(0, h / 2, -4.1), plaster)
	_static_box("SouthWall", Vector3(8.4, h, 0.2), Vector3(0, h / 2, 4.1), plaster)
	_static_box("WestWall", Vector3(0.2, h, 8.4), Vector3(-4.1, h / 2, 0), plaster)
	_static_box("EastWall", Vector3(0.2, h, 8.4), Vector3(4.1, h / 2, 0), plaster)
	var skirting := _mat(Color(0.2, 0.21, 0.23), 0.6)
	_visual_box(Vector3(8.0, 0.12, 0.02), Vector3(0, 0.06, -3.99), skirting)
	_visual_box(Vector3(8.0, 0.12, 0.02), Vector3(0, 0.06, 3.99), skirting)
	_visual_box(Vector3(0.02, 0.12, 8.0), Vector3(-3.99, 0.06, 0), skirting)
	_visual_box(Vector3(0.02, 0.12, 8.0), Vector3(3.99, 0.06, 0), skirting)
	var cap := _mat(Color(0.62, 0.62, 0.63), 0.5)
	_visual_box(Vector3(8.5, 0.05, 0.28), Vector3(0, h + 0.025, -4.1), cap)
	_visual_box(Vector3(8.5, 0.05, 0.28), Vector3(0, h + 0.025, 4.1), cap)
	_visual_box(Vector3(0.28, 0.05, 8.5), Vector3(-4.1, h + 0.025, 0), cap)
	_visual_box(Vector3(0.28, 0.05, 8.5), Vector3(4.1, h + 0.025, 0), cap)
	# Paved yard outside the room (only the third-person view ever sees it).
	var yard := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(80, 80)
	yard.mesh = plane
	yard.material_override = _floor_mat(Color(0.47, 0.45, 0.42), 2.0)
	yard.position = Vector3(0, -0.01, 0)
	yard.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(yard)

	_make_object("CubeA", "cube", Color(0.86, 0.09, 0.08), Vector3(1.5, 0.16, -1.2))
	_make_object("SphereB", "sphere", Color(0.86, 0.09, 0.08), Vector3(0.5, 0.16, 1.8))
	_make_object("CubeC", "cube", Color(0.08, 0.2, 0.86), Vector3(2.5, 0.16, 1.0))
	_make_object("CylinderD", "cylinder", Color(0.1, 0.62, 0.22), Vector3(0, 0.3, -2.5))
	_make_object("ConeE", "cone", Color(0.97, 0.78, 0.06), Vector3(-0.5, 0.16, 0.2))
	_make_drop_zone()

func _object_mat(color: Color, kind: String) -> StandardMaterial3D:
	# Same colours as before (Claude identifies by colour); real-world surfaces on top.
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.normal_enabled = true
	m.normal_texture = detail_normal
	m.uv1_triplanar = true
	m.uv1_scale = Vector3(3, 3, 3)
	match kind:
		"cube":      # painted wood block
			m.roughness = 0.55
			m.normal_scale = 0.25
		"sphere":    # glossy rubber ball
			m.roughness = 0.22
			m.normal_scale = 0.05
			m.rim_enabled = true
			m.rim = 0.2
		"cylinder":  # painted metal tin
			m.roughness = 0.32
			m.metallic = 0.2
			m.normal_scale = 0.08
		"cone":      # matte moulded plastic
			m.roughness = 0.6
			m.normal_scale = 0.15
	return m

func _make_object(n: String, kind: String, color: Color, pos: Vector3) -> void:
	var body := RigidBody3D.new()
	body.name = n # Internal only; never returned through API.
	body.position = pos
	body.mass = 0.25
	body.linear_damp = 1.5
	body.angular_damp = 2.0
	body.collision_layer = 2
	body.collision_mask = 1 | 2
	body.add_to_group("pickable")
	start_transforms[body] = Transform3D(Basis(), pos)
	var mesh := MeshInstance3D.new()
	mesh.name = "Mesh"
	var cs := CollisionShape3D.new()
	var mat := _object_mat(color, kind)
	match kind:
		"cube":
			var cube_mesh := BoxMesh.new()
			cube_mesh.size = Vector3(0.3, 0.3, 0.3)
			mesh.mesh = cube_mesh
			var cube_shape := BoxShape3D.new()
			cube_shape.size = Vector3(0.3, 0.3, 0.3)
			cs.shape = cube_shape
		"sphere":
			var sphere_mesh := SphereMesh.new()
			sphere_mesh.radius = 0.15
			sphere_mesh.height = 0.3
			sphere_mesh.radial_segments = 48
			sphere_mesh.rings = 24
			mesh.mesh = sphere_mesh
			var sphere_shape := SphereShape3D.new()
			sphere_shape.radius = 0.15
			cs.shape = sphere_shape
		"cylinder":
			var cylinder_mesh := CylinderMesh.new()
			cylinder_mesh.top_radius = 0.15
			cylinder_mesh.bottom_radius = 0.15
			cylinder_mesh.height = 0.6
			cylinder_mesh.radial_segments = 48
			mesh.mesh = cylinder_mesh
			var cylinder_shape := CylinderShape3D.new()
			cylinder_shape.radius = 0.15
			cylinder_shape.height = 0.6
			cs.shape = cylinder_shape
		"cone":
			var cone_mesh := CylinderMesh.new()
			cone_mesh.top_radius = 0.0
			cone_mesh.bottom_radius = 0.15
			cone_mesh.height = 0.3
			cone_mesh.radial_segments = 48
			mesh.mesh = cone_mesh
			var cone_shape := CylinderShape3D.new()
			cone_shape.radius = 0.15
			cone_shape.height = 0.3
			cs.shape = cone_shape
	mesh.material_override = mat
	body.add_child(mesh)
	body.add_child(cs)
	if kind == "cylinder":
		# Rolled rims top and bottom, like a real tin.
		var rim_mat := _object_mat(color.darkened(0.3), kind)
		for y: float in [-0.27, 0.27]:
			var rim := MeshInstance3D.new()
			var rim_mesh := CylinderMesh.new()
			rim_mesh.top_radius = 0.156
			rim_mesh.bottom_radius = 0.156
			rim_mesh.height = 0.025
			rim_mesh.radial_segments = 48
			rim.mesh = rim_mesh
			rim.material_override = rim_mat
			rim.position.y = y
			body.add_child(rim)
	add_child(body)

func _make_drop_zone() -> void:
	var area := Area3D.new()
	area.name = "DropZone"
	area.position = Vector3(-2.5, 0.02, 2.5)
	area.collision_layer = 4
	area.collision_mask = 2
	area.add_to_group("drop_zone")
	var cs := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(1.0, 0.2, 1.0)
	cs.shape = shape
	area.add_child(cs)
	# Rubber mat in the same colour as before, with a faint glow and a dark frame.
	var mat := _mat(Color(1, 0, 0.85), 0.7)
	mat.emission_enabled = true
	mat.emission = Color(1, 0, 0.85)
	mat.emission_energy_multiplier = 0.12
	area.add_child(_box_mesh(Vector3(1, 0.015, 1), mat))
	var frame := _mat(Color(0.16, 0.16, 0.18), 0.5)
	for s: float in [-1.0, 1.0]:
		var a := _box_mesh(Vector3(1.08, 0.02, 0.04), frame)
		a.position = Vector3(0, 0, s * 0.52)
		area.add_child(a)
		var b := _box_mesh(Vector3(0.04, 0.02, 1.08), frame)
		b.position = Vector3(s * 0.52, 0, 0)
		area.add_child(b)
	add_child(area)

# ---------------- robot ----------------

const RobotVisualScript := preload("res://scripts/robot_visual.gd")
var visual: Node3D
var last_robot_pos := Vector3.ZERO
var last_heading := 0.0
var robot_moving := false

func _build_robot() -> void:
	robot = CharacterBody3D.new()
	robot.name = "Robot"
	robot.position = Vector3(-3, 0, 0)
	robot.collision_layer = 1
	robot.collision_mask = 1 | 2
	add_child(robot)

	var body_shape := CapsuleShape3D.new()
	body_shape.radius = 0.28
	body_shape.height = 0.75
	var body_cs := CollisionShape3D.new()
	body_cs.shape = body_shape
	body_cs.position.y = 0.38
	robot.add_child(body_cs)

	# Model and animation live in robot_visual.gd (render layer 2: hidden from Claude's camera).
	visual = RobotVisualScript.new()
	visual.name = "RobotVisual"
	robot.add_child(visual)
	last_robot_pos = robot.global_position

	pickup_point = Marker3D.new()
	pickup_point.name = "PickupPoint"
	# Carried objects rest just above the floor, ahead of the camera (forklift style), so even
	# the tall cylinder blocks as little of the robot's view as possible.
	pickup_point.position = Vector3(0.9, 0.01, 0)
	robot.add_child(pickup_point)

	pickup_area = Area3D.new()
	pickup_area.name = "PickupArea"
	pickup_area.position = Vector3(0.25, 0.2, 0)
	pickup_area.collision_layer = 0
	pickup_area.collision_mask = 2
	var ps := SphereShape3D.new()
	ps.radius = PICKUP_REACH + 0.1  # covers everything up to ~0.85 m ahead of the centre
	var pcs := CollisionShape3D.new()
	pcs.shape = ps
	pickup_area.add_child(pcs)
	robot.add_child(pickup_area)

func _animate_robot(delta: float) -> void:
	if delta <= 0.0 or visual == null:
		return
	var lin := (robot.global_position - last_robot_pos).dot(_forward()) / delta
	var turn := wrapf(heading - last_heading, -180.0, 180.0) / delta
	last_robot_pos = robot.global_position
	last_heading = heading
	if absf(lin) > 5.0 or absf(turn) > 720.0:   # teleport (reset), not motion
		lin = 0.0
		turn = 0.0
	robot_moving = absf(lin) > 0.02 or absf(turn) > 2.0
	var hold: Variant = null
	if held != null and is_instance_valid(held):
		hold = robot.to_local(held.global_position)
	visual.animate(delta, lin, turn, state_name, hold)

func _half_height(body: Node3D) -> float:
	var mesh := body.get_node_or_null("Mesh") as MeshInstance3D
	if mesh == null:
		return 0.15
	return mesh.get_aabb().size.y / 2.0

func _forward() -> Vector3:
	var a := deg_to_rad(heading)
	return Vector3(cos(a), 0, sin(a))

func _sync_heading() -> void:
	robot.rotation.y = -deg_to_rad(heading)

# ---------------- cameras and on-screen display ----------------

var chase_cam: Camera3D
var cam_yaw := 0.0
var cam_focus := Vector3.ZERO
var cam_dist := 2.8
var cam_pitch := 0.4            # radians above the horizon
var orbit_yaw := 0.0
var orbit_pitch := 0.0
var dragging := false
var cam_snap := true
var view_mode := 0              # V key: 0 behind the robot, 1 in front (face), 2 high overview

func _new_viewport(view_name: String, size: Vector2i, camera_name: String) -> Array:
	var vp := SubViewport.new()
	vp.name = view_name
	vp.size = size
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	vp.msaa_3d = Viewport.MSAA_4X
	add_child(vp)
	var cam := Camera3D.new()
	cam.name = camera_name
	cam.fov = 90
	cam.keep_aspect = Camera3D.KEEP_WIDTH
	cam.cull_mask = 1
	vp.add_child(cam)
	return [vp, cam]

func _build_cameras() -> void:
	var b := _new_viewport("AgentLookViewport", LOOK_SIZE, "AgentCamera")
	look_vp = b[0]
	look_cam = b[1]
	look_cam.environment = agent_env
	var d := _new_viewport("PovViewport", POV_SIZE, "PovCamera")
	pov_vp = d[0]
	pov_cam = d[1]
	# Same 90-degree horizontal view as the agent camera (KEEP_WIDTH), at 720p for the clips,
	# with the main (tone-mapped) look. Rendered only while a run is being recorded.
	pov_vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	look_cam.position = Vector3(0, 0.5, 0)
	# Main window: a third-person chase camera, like in third-person games.
	get_viewport().msaa_3d = Viewport.MSAA_4X
	chase_cam = Camera3D.new()
	chase_cam.name = "ChaseCamera"
	chase_cam.fov = 62.0
	chase_cam.near = 0.05
	add_child(chase_cam)
	chase_cam.current = true
	_update_cameras()

func _update_cameras() -> void:
	if robot == null:
		return
	var fwd := _forward()
	look_cam.global_position = robot.global_position + fwd * CAMERA_FORWARD + Vector3.UP * 0.5
	look_cam.look_at(look_cam.global_position + fwd + Vector3.DOWN * 0.18, Vector3.UP)
	pov_cam.global_transform = look_cam.global_transform

func _update_chase(delta: float) -> void:
	if chase_cam == null or robot == null:
		return
	var fwd := _forward()
	var target_yaw := atan2(fwd.z, fwd.x) + orbit_yaw + (PI if view_mode == 1 else 0.0)
	var focus := robot.global_position + Vector3.UP * 0.5
	if cam_snap:
		cam_yaw = target_yaw
		cam_focus = focus
	# Smoothly swing in behind the robot and follow it, with a little lag.
	cam_yaw = lerp_angle(cam_yaw, target_yaw, 1.0 - exp(-delta * 2.6))
	cam_focus = cam_focus.lerp(focus, 1.0 - exp(-delta * 7.0))
	var dir := Vector3(cos(cam_yaw), 0, sin(cam_yaw))
	var base_p := clampf(cam_pitch + orbit_pitch + (0.75 if view_mode == 2 else 0.0), 0.08, 1.3)
	var dist := cam_dist * (2.2 if view_mode == 2 else 1.0)
	# Stay inside the room: if a wall is in the way, come closer and look down more steeply
	# (like a third-person game camera in a tight corridor).
	var want := _chase_point(dir, base_p, dist)
	var free := _chase_free_distance(want)
	if free < dist:
		var squeeze := 1.0 - free / dist
		var p2 := minf(base_p + squeeze * 0.8, 1.3)
		want = _chase_point(dir, p2, dist)
		free = _chase_free_distance(want)
		if free < dist:
			want = _chase_point(dir, p2, maxf(free - 0.2, 0.6))
	if cam_snap:
		chase_cam.global_position = want
		cam_snap = false
	else:
		chase_cam.global_position = chase_cam.global_position.lerp(want, 1.0 - exp(-delta * 9.0))
	chase_cam.look_at(cam_focus + dir * 0.7 + Vector3.DOWN * 0.1, Vector3.UP)
	# Like most third-person games, the camera drifts back behind the robot once it moves.
	if not dragging and robot_moving:
		var back := 1.0 - exp(-delta * 1.2)
		orbit_yaw = lerpf(orbit_yaw, 0.0, back)
		orbit_pitch = lerpf(orbit_pitch, 0.0, back)

func _chase_point(dir: Vector3, pitch: float, dist: float) -> Vector3:
	return cam_focus - dir * dist * cos(pitch) + Vector3.UP * dist * sin(pitch)

func _chase_free_distance(want: Vector3) -> float:
	# How far the camera can go from the focus point toward `want` before hitting a wall.
	var q := PhysicsRayQueryParameters3D.create(cam_focus, want)
	q.collision_mask = 1
	q.exclude = [robot.get_rid()]
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	if hit.is_empty():
		return 100.0
	var hit_pos: Vector3 = hit.position
	return cam_focus.distance_to(hit_pos)

func _unhandled_input(event: InputEvent) -> void:
	# Mouse: drag to orbit the camera, wheel to zoom. (Hands off during judged runs.)
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT or mb.button_index == MOUSE_BUTTON_RIGHT:
			dragging = mb.pressed
		elif mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			cam_dist = maxf(1.3, cam_dist * 0.9)
		elif mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			cam_dist = minf(7.0, cam_dist * 1.1)
	elif event is InputEventMouseMotion and dragging:
		var mm := event as InputEventMouseMotion
		orbit_yaw = wrapf(orbit_yaw + mm.relative.x * 0.006, -PI, PI)
		orbit_pitch = clampf(orbit_pitch + mm.relative.y * 0.004, -0.3, 0.85)

func _hud_box() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.04, 0.05, 0.07, 0.62)
	sb.set_corner_radius_all(10)
	sb.content_margin_left = 14
	sb.content_margin_right = 14
	sb.content_margin_top = 8
	sb.content_margin_bottom = 10
	return sb

func _build_ui() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	# Status (top left)
	var chip := PanelContainer.new()
	chip.add_theme_stylebox_override("panel", _hud_box())
	layer.add_child(chip)
	var col := VBoxContainer.new()
	chip.add_child(col)
	title_label = Label.new()
	title_label.add_theme_font_size_override("font_size", 12)
	title_label.modulate = Color(1, 1, 1, 0.6)
	col.add_child(title_label)
	state_label = Label.new()
	state_label.add_theme_font_size_override("font_size", 18)
	col.add_child(state_label)
	chip.position = Vector2(16, 14)
	# What the robot's own camera (and Claude) sees (top right)
	var pip := PanelContainer.new()
	pip.add_theme_stylebox_override("panel", _hud_box())
	layer.add_child(pip)
	var pcol := VBoxContainer.new()
	pip.add_child(pcol)
	var plabel := Label.new()
	plabel.text = "ROBOT CAMERA"
	plabel.add_theme_font_size_override("font_size", 12)
	plabel.modulate = Color(1, 1, 1, 0.6)
	pcol.add_child(plabel)
	var rect := TextureRect.new()
	rect.custom_minimum_size = Vector2(320, 240)
	rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT
	rect.texture = look_vp.get_texture()
	pcol.add_child(rect)
	pip.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT, Control.PRESET_MODE_MINSIZE, 16)
	# Controls hint (bottom left)
	var help := Label.new()
	help.text = "Mouse drag: orbit  ·  Wheel: zoom  ·  V: camera view  ·  W/S move  ·  A/D turn  ·  E pickup  ·  Q drop  ·  T throw  ·  R reset  ·  P save camera"
	help.add_theme_font_size_override("font_size", 12)
	help.modulate = Color(1, 1, 1, 0.55)
	layer.add_child(help)
	help.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT, Control.PRESET_MODE_MINSIZE, 16)

func _update_ui() -> void:
	if title_label:
		title_label.text = "ROBOT SIMULATOR  ·  API localhost:%d  ·  %d FPS" % [PORT, Engine.get_frames_per_second()]
	if state_label:
		state_label.text = "%s     Holding: %s     Collisions: %d" % [
			state_name, "yes" if held != null else "no", retries
		]
		var c := Color(0.75, 0.9, 1.0)
		match state_name:
			"Carry", "PickUp": c = Color(0.6, 1.0, 0.7)
			"Blocked": c = Color(1.0, 0.7, 0.4)
			"Done": c = Color(1.0, 1.0, 1.0)
		state_label.modulate = c

# ---------------- trail ----------------

func _build_trail() -> void:
	trail_node = MeshInstance3D.new()
	trail_node.name = "MovementTrail"
	trail_node.top_level = true
	trail_node.layers = 4   # third-person view only; Claude's camera and the clips cull it
	add_child(trail_node)
	_add_trail()

func _add_trail() -> void:
	var p := robot.global_position + Vector3(0, 0.025, 0)
	if trail_points.size() > 0 and trail_points[-1].distance_to(p) < 0.04:
		return
	trail_points.append(p)
	_rebuild_trail()

func _rebuild_trail() -> void:
	var im := ImmediateMesh.new()
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = trail_color
	mat.emission_enabled = true
	mat.emission = trail_color
	if trail_points.size() >= 2:
		im.surface_begin(Mesh.PRIMITIVE_LINE_STRIP, mat)
		for point in trail_points:
			im.surface_add_vertex(point)
		im.surface_end()
	trail_node.mesh = im

# ---------------- robot actions ----------------

func _move(distance: float) -> Dictionary:
	if busy:
		return {"error": "busy", "moved": 0.0, "collided": false}
	busy = true
	collided = false
	state_name = "Carry" if held != null else "GoToObject"
	trail_color = Color(0.1, 0.85, 0.3) if held != null else Color(0.1, 0.55, 1.0)
	_rebuild_trail()
	var dir := _forward() * signf(distance)
	var remaining := absf(distance)
	var moved := 0.0
	var still_for := 0.0
	var elapsed := 0.0
	while remaining > 0.000001:
		await get_tree().physics_frame
		var dt := get_physics_process_delta_time()
		elapsed += dt
		# Cruise at SPEED (1 m/s) with short eased starts and stops; the distance is exact.
		var ramp := clampf(minf(elapsed / RAMP_TIME, sqrt(2.0 * remaining / (SPEED * RAMP_TIME))), MIN_RAMP, 1.0)
		var step := minf(SPEED * ramp * dt, remaining)
		var before := robot.global_position
		var hit := robot.move_and_collide(dir * step)
		var progress := (robot.global_position - before).length()
		still_for = still_for + dt if progress < 0.0005 else 0.0
		if hit != null or still_for >= STUCK_SECONDS:
			collided = true
			break
		remaining -= step
		moved += step
		_add_trail()
		_capture_frame()
	if collided:
		# Brief: stop, back off 0.1 m, report the collision, enter Blocked; fail after 3 retries.
		visual.bump()
		var back := BACK_OFF
		while back > 0.0005:
			await get_tree().physics_frame
			var s := minf(0.8 * get_physics_process_delta_time(), back)
			robot.move_and_collide(-dir * s)
			back -= s
			_capture_frame()
		moved = maxf(moved - BACK_OFF, 0.0)
		retries += 1
		trail_color = Color(1.0, 0.5, 0.05)
		_rebuild_trail()
		if retries > MAX_RETRIES:
			_end_run("fail_collision")
		else:
			state_name = "Blocked"
	busy = false
	return {"moved": snappedf(moved * signf(distance), 0.001), "collided": collided}

func _turn(degrees: float) -> Dictionary:
	if busy:
		return {"error": "busy", "heading": heading}
	busy = true
	var remaining := absf(degrees)
	var sign_turn := signf(degrees)
	var elapsed := 0.0
	while remaining > 0.000001:
		await get_tree().physics_frame
		var dt := get_physics_process_delta_time()
		elapsed += dt
		# Cruise at TURN_SPEED (90 deg/s) with eased starts and stops; the angle is exact.
		var ramp := clampf(minf(elapsed / RAMP_TIME, sqrt(2.0 * remaining / (TURN_SPEED * RAMP_TIME))), MIN_RAMP, 1.0)
		var step := minf(TURN_SPEED * ramp * dt, remaining)
		heading = fposmod(heading + sign_turn * step, 360.0)
		remaining -= step
		_sync_heading()
		_capture_frame()
	if state_name != "Done":
		state_name = "Carry" if held != null else "Locate"
	busy = false
	return {"turned": snappedf(degrees, 0.01)}

func _pickup() -> Dictionary:
	if held != null or busy:
		return {"ok": false}
	state_name = "PickUp"
	var best: RigidBody3D = null
	var best_d := INF
	var fwd := _forward()
	for body in pickup_area.get_overlapping_bodies():
		if not body is RigidBody3D or not body.is_in_group("pickable"):
			continue
		var offset: Vector3 = body.global_position - robot.global_position
		var flat := Vector3(offset.x, 0, offset.z)
		var d := flat.length()
		if d - ROBOT_RADIUS > PICKUP_REACH:  # gap from robot front to object centre
			continue
		if d > 0.001 and rad_to_deg(acos(clampf(fwd.dot(flat.normalized()), -1.0, 1.0))) > PICKUP_HALF_ANGLE:
			continue
		if d < best_d:
			best = body
			best_d = d
	if best == null:
		state_name = "GoToObject"
		return {"ok": false}
	busy = true
	held = best
	held.freeze = true
	held.linear_velocity = Vector3.ZERO
	held.angular_velocity = Vector3.ZERO
	held.collision_layer = 0
	held.collision_mask = 0
	# 1) the arms reach out to the object, 2) it is lifted on a short arc to the carry point.
	await _wait_physics(0.22)
	held.reparent(robot, true)
	var start := held.position
	var start_rot := held.quaternion
	var end := pickup_point.position + Vector3.UP * _half_height(held)
	var t := 0.0
	while t < 0.4:
		await get_tree().physics_frame
		t += get_physics_process_delta_time()
		var k := smoothstep(0.0, 1.0, minf(t / 0.4, 1.0))
		held.position = start.lerp(end, k) + Vector3.UP * sin(k * PI) * 0.12
		held.quaternion = start_rot.slerp(Quaternion.IDENTITY, k)
		_capture_frame()
	held.position = end
	held.quaternion = Quaternion.IDENTITY
	busy = false
	state_name = "Carry"
	trail_color = Color(0.1, 0.85, 0.3)
	_rebuild_trail()
	return {"ok": true}

func _wait_physics(seconds: float) -> void:
	var waited := 0.0
	while waited < seconds:
		await get_tree().physics_frame
		waited += get_physics_process_delta_time()
		_capture_frame()

func _drop() -> Dictionary:
	if held == null or not is_instance_valid(held):
		return {"ok": false, "in_zone": false}
	var obj := held
	var transform_before := obj.global_transform
	obj.reparent(self, true)
	obj.global_transform = transform_before
	obj.freeze = false
	obj.sleeping = false
	obj.collision_layer = 2
	obj.collision_mask = 1 | 2
	held = null
	await get_tree().physics_frame
	var delta := obj.global_position - DROP_ZONE_CENTER
	var inside := absf(delta.x) <= 0.5 and absf(delta.z) <= 0.5
	state_name = "Drop"
	if inside:
		_end_run("pass")
	return {"ok": true, "in_zone": inside}

func _throw(distance: float) -> Dictionary:
	# Lob the held object forward so it lands about `distance` metres ahead of where it is held.
	# 45-degree launch: range = v^2 / g, so v = sqrt(distance * g). It may bounce or roll a little.
	if busy or held == null or not is_instance_valid(held):
		return {"ok": false, "in_zone": false}
	busy = true
	visual.fling()
	distance = clampf(distance, THROW_MIN, THROW_MAX)
	var obj := held
	var transform_before := obj.global_transform
	obj.reparent(self, true)
	obj.global_transform = transform_before
	obj.freeze = false
	obj.sleeping = false
	obj.collision_layer = 2
	obj.collision_mask = 1 | 2
	held = null
	# `distance` is measured from the robot's front (like the camera guide ticks); the object
	# is held further ahead than that, so subtract the part it already covers.
	var target := robot.global_position + _forward() * (ROBOT_RADIUS + distance)
	var flight := maxf((target - obj.global_position).dot(_forward()), 0.2)
	var g := float(ProjectSettings.get_setting("physics/3d/default_gravity", 9.8))
	var v := sqrt(flight * g)
	obj.linear_velocity = _forward() * v * cos(PI / 4.0) + Vector3.UP * v * sin(PI / 4.0)
	obj.angular_velocity = Vector3.ZERO
	# No air drag in flight (objects have linear_damp, which made throws land short);
	# drag goes back on at landing so the object stops rolling soon.
	var damp_before := obj.linear_damp
	obj.linear_damp = 0.0
	var flight_time := 2.0 * v * sin(PI / 4.0) / g
	# Wait (in engine time) until it has landed and stopped, so the clip shows the flight.
	var waited := 0.0
	while waited < THROW_SETTLE_MAX:
		await get_tree().physics_frame
		waited += get_physics_process_delta_time()
		_capture_frame()
		if waited >= flight_time:
			obj.linear_damp = damp_before
		if waited > flight_time and obj.linear_velocity.length() < 0.05:
			break
	obj.linear_damp = damp_before
	var delta := obj.global_position - DROP_ZONE_CENTER
	var inside := absf(delta.x) <= 0.5 and absf(delta.z) <= 0.5
	state_name = "Drop"
	busy = false
	if inside:
		_end_run("pass")
	return {"ok": true, "in_zone": inside}

func _reset() -> void:
	# Put everything back where it started, without reloading the scene
	# (reloading would briefly stop the HTTP server and drop requests).
	if held != null and is_instance_valid(held):
		held.reparent(self, true)
		held.collision_layer = 2
		held.collision_mask = 1 | 2
		held.freeze = false
		held = null
	for body in start_transforms:
		body.global_transform = start_transforms[body]
		body.linear_velocity = Vector3.ZERO
		body.angular_velocity = Vector3.ZERO
	robot.position = Vector3(-3, 0, 0)
	robot.velocity = Vector3.ZERO
	heading = 0.0
	_sync_heading()
	last_robot_pos = robot.global_position
	last_heading = heading
	cam_snap = true
	retries = 0
	collided = false
	state_name = "Idle"
	outcome = ""
	capturing = false
	trail_points.clear()
	trail_color = Color(0.1, 0.55, 1.0)
	_rebuild_trail()
	_add_trail()

func _save_look() -> void:
	await RenderingServer.frame_post_draw
	var image := look_vp.get_texture().get_image()
	image.save_jpg("user://look.jpg", 0.9)
	print("Saved camera image to: ", ProjectSettings.globalize_path("user://look.jpg"))

# ---------------- run lifecycle and clip frames ----------------

func _start_run(run_id: String) -> void:
	retries = 0
	collided = false
	outcome = ""
	state_name = "Locate"
	# Frames are saved only while the robot moves/turns (engine time), so a
	# 1-2 minute run with Claude thinking becomes a 10-20 s clip.
	capture_dir = ProjectSettings.globalize_path("res://").path_join("../runs/%s/pov" % run_id).simplify_path()
	capture_frame = 0
	capturing = DisplayServer.get_name() != "headless"
	capture_accum = 1.0 / CLIP_FPS   # take a frame at the very first motion step
	if capturing:
		DirAccess.make_dir_recursive_absolute(capture_dir)
		pov_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS

func _end_run(result: String) -> void:
	if state_name != "Done":
		outcome = result
	state_name = "Done"
	capturing = false
	pov_vp.render_target_update_mode = SubViewport.UPDATE_DISABLED

func _capture_frame() -> void:
	# Called every physics step while something moves; keep one frame per 1/CLIP_FPS s.
	if not capturing:
		return
	capture_accum += get_physics_process_delta_time()
	if capture_accum < 1.0 / CLIP_FPS:
		return
	capture_accum -= 1.0 / CLIP_FPS
	var img := pov_vp.get_texture().get_image()
	if img != null:
		img.save_png(capture_dir.path_join("%05d.png" % capture_frame))
		capture_frame += 1

# ---------------- HTTP server (plan.md section 2) ----------------
# Every reply below is built from an explicit list of keys, so internal data
# (object names, colours, positions) can never reach the agent.

func _poll_server() -> void:
	if not server.is_listening() or handling_request:
		return
	if server.is_connection_available():
		peer = server.take_connection()
		handling_request = true
		_serve_peer()

func _serve_peer() -> void:
	var req := await _read_http_request()
	if req.is_empty():
		_close_peer()
		return
	var method: String = req["method"]
	var path: String = req["path"]
	var body: Dictionary = req["body"]
	match method + " " + path:
		"GET /state":
			_send_json(200, _state())
		"GET /look":
			await _send_look()
		"GET /depth":
			_send_json(200, {"distance": _depth()})
		"POST /move":
			if not body.has("distance"):
				_send_json(400, {"error": "missing distance"})
			elif state_name == "Done":
				_send_json(200, {"moved": 0.0, "collided": false, "state": state_name})
			else:
				var r := await _move(float(body["distance"]))
				if r.has("error"):
					_send_json(409, {"error": "busy"})
				else:
					_send_json(200, {"moved": r["moved"], "collided": r["collided"], "state": state_name})
		"POST /turn":
			if not body.has("degrees"):
				_send_json(400, {"error": "missing degrees"})
			elif state_name == "Done":
				_send_json(200, {"turned": 0.0, "state": state_name})
			else:
				var r := await _turn(float(body["degrees"]))
				if r.has("error"):
					_send_json(409, {"error": "busy"})
				else:
					_send_json(200, {"turned": r["turned"], "state": state_name})
		"POST /pickup":
			if state_name == "Done":
				_send_json(200, {"success": false})
			else:
				var r := await _pickup()
				_send_json(200, {"success": bool(r["ok"])})
		"POST /drop":
			if state_name == "Done":
				_send_json(200, {"success": false, "in_zone": false})
			else:
				var r := await _drop()
				_send_json(200, {"success": bool(r["ok"]), "in_zone": bool(r["in_zone"])})
		"POST /throw":
			if not body.has("distance"):
				_send_json(400, {"error": "missing distance"})
			elif state_name == "Done":
				_send_json(200, {"success": false, "in_zone": false})
			elif busy:
				_send_json(409, {"error": "busy"})
			else:
				var r := await _throw(float(body["distance"]))
				_send_json(200, {"success": bool(r["ok"]), "in_zone": bool(r["in_zone"])})
		"POST /run/start":
			# The command is only for the clip overlay (added later by tools/make_clip.py); never echoed.
			_start_run(str(body.get("run_id", "run")))
			_send_json(200, {"ok": true})
		"POST /run/end":
			_end_run(str(body.get("outcome", "fail_not_reached")))
			_send_json(200, {"ok": true})
		"POST /reset":
			_reset()
			_send_json(200, {"ok": true})
		_:
			_send_json(404, {"error": "not_found"})
	_close_peer()

func _read_http_request() -> Dictionary:
	var data := PackedByteArray()
	var header_end := -1
	var length := 0
	var deadline := Time.get_ticks_msec() + 3000
	while Time.get_ticks_msec() < deadline:
		if peer == null:
			return {}
		peer.poll()
		if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			return {}
		var count := peer.get_available_bytes()
		if count > 0:
			var result := peer.get_data(count)
			if result[0] == OK:
				data.append_array(result[1])
				header_end = data.get_string_from_utf8().find("\r\n\r\n")
				if header_end >= 0:
					var h := data.slice(0, header_end).get_string_from_utf8()
					for line in h.split("\r\n"):
						if line.to_lower().begins_with("content-length:"):
							length = int(line.get_slice(":", 1).strip_edges())
					if data.size() >= header_end + 4 + length:
						break
		await get_tree().process_frame
	if header_end < 0:
		return {}
	var header := data.slice(0, header_end).get_string_from_utf8()
	var first := header.split("\r\n")[0].split(" ")
	if first.size() < 2:
		return {}
	var body_bytes := data.slice(header_end + 4, header_end + 4 + length)
	var body: Dictionary = {}
	if length > 0:
		var parsed = JSON.parse_string(body_bytes.get_string_from_utf8())
		if parsed is Dictionary:
			body = parsed
	return {"method": first[0], "path": first[1].split("?")[0], "body": body}

func _send_json(status: int, payload: Dictionary) -> void:
	var bytes := JSON.stringify(payload).to_utf8_buffer()
	var reason: String = {200: "OK", 400: "Bad Request", 404: "Not Found", 409: "Conflict"}.get(status, "Error")
	var header := "HTTP/1.1 %d %s\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n" % [status, reason, bytes.size()]
	peer.put_data(header.to_utf8_buffer())
	peer.put_data(bytes)

func _send_look() -> void:
	var bytes: PackedByteArray
	if DisplayServer.get_name() == "headless":  # nothing is drawn headless: send a blank frame
		bytes = Image.create_empty(LOOK_SIZE.x, LOOK_SIZE.y, false, Image.FORMAT_RGB8).save_jpg_to_buffer(0.88)
	else:
		await RenderingServer.frame_post_draw
		bytes = look_vp.get_texture().get_image().save_jpg_to_buffer(0.88)
	var header := "HTTP/1.1 200 OK\r\nContent-Type: image/jpeg\r\nContent-Length: %d\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n" % bytes.size()
	peer.put_data(header.to_utf8_buffer())
	peer.put_data(bytes)

func _close_peer() -> void:
	if peer != null:
		peer.disconnect_from_host()
	peer = null
	handling_request = false

func _state() -> Dictionary:
	# Intentionally no object names, ids, colour, shape, coordinates, count or target distance.
	return {
		"state": state_name,
		"x": snappedf(robot.global_position.x, 0.01),
		"y": snappedf(robot.global_position.z, 0.01),
		"heading": fposmod(snappedf(heading, 0.1), 360.0),
		"holding": held != null,
		"retries": retries
	}

func _depth() -> Variant:
	var origin := look_cam.global_position
	var direction := -look_cam.global_basis.z
	var query := PhysicsRayQueryParameters3D.create(origin, origin + direction * MAX_DEPTH)
	query.exclude = [robot.get_rid()]
	query.collision_mask = 1 | 2
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return null
	return snappedf(origin.distance_to(hit.position), 0.01)
