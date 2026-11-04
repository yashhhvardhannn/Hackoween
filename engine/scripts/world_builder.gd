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
const LOOK_SIZE := Vector2i(640, 480)
const PANEL_SIZE := Vector2i(400, 260)

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
var overview_vp: SubViewport
var pickup_vp: SubViewport
var pov_vp: SubViewport        # 1280x720 copy of the robot camera, for clip frames
var pov_cam: Camera3D
var capturing := false
var capture_dir := ""
var capture_frame := 0
var look_cam: Camera3D
var overview_cam: Camera3D
var pickup_cam: Camera3D

var trail_points: Array[Vector3] = []
var start_transforms := {}     # pickable body -> starting transform, for /reset
var trail_node: MeshInstance3D
var trail_color := Color(0.1, 0.55, 1.0)

var server := TCPServer.new()
var peer: StreamPeerTCP
var handling_request := false
var state_label: Label

func _ready() -> void:
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

func _process(_delta: float) -> void:
	_update_cameras()
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

# ---------------- world ----------------

func _mat(color: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = 0.85
	return m

func _box_mesh(size: Vector3, color: Color) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = size
	mi.mesh = mesh
	mi.material_override = _mat(color)
	return mi

func _static_box(n: String, size: Vector3, pos: Vector3, color: Color) -> void:
	var body := StaticBody3D.new()
	body.name = n
	body.position = pos
	var cs := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	cs.shape = shape
	body.add_child(cs)
	body.add_child(_box_mesh(size, color))
	add_child(body)

func _build_world() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.75, 0.85, 0.95)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color.WHITE
	env.ambient_light_energy = 0.7
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-55, 35, 0)
	sun.shadow_enabled = true
	add_child(sun)

	_static_box("Floor", Vector3(8, 0.1, 8), Vector3(0, -0.05, 0), Color(0.84, 0.84, 0.81))
	var wall := Color(0.42, 0.42, 0.46)
	_static_box("NorthWall", Vector3(8.3, 1, 0.2), Vector3(0, 0.5, -4.1), wall)
	_static_box("SouthWall", Vector3(8.3, 1, 0.2), Vector3(0, 0.5, 4.1), wall)
	_static_box("WestWall", Vector3(0.2, 1, 8.3), Vector3(-4.1, 0.5, 0), wall)
	_static_box("EastWall", Vector3(0.2, 1, 8.3), Vector3(4.1, 0.5, 0), wall)

	_make_object("CubeA", "cube", Color(0.9, 0.08, 0.08), Vector3(1.5, 0.16, -1.2))
	_make_object("SphereB", "sphere", Color(0.9, 0.08, 0.08), Vector3(0.5, 0.16, 1.8))
	_make_object("CubeC", "cube", Color(0.08, 0.18, 0.9), Vector3(2.5, 0.16, 1.0))
	_make_object("CylinderD", "cylinder", Color(0.08, 0.72, 0.2), Vector3(0, 0.3, -2.5))
	_make_object("ConeE", "cone", Color(0.98, 0.82, 0.05), Vector3(-0.5, 0.16, 0.2))
	_make_drop_zone()

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
	var cs := CollisionShape3D.new()
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
			mesh.mesh = sphere_mesh
			var sphere_shape := SphereShape3D.new()
			sphere_shape.radius = 0.15
			cs.shape = sphere_shape
		"cylinder":
			var cylinder_mesh := CylinderMesh.new()
			cylinder_mesh.top_radius = 0.15
			cylinder_mesh.bottom_radius = 0.15
			cylinder_mesh.height = 0.6
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
			mesh.mesh = cone_mesh
			var cone_shape := CylinderShape3D.new()
			cone_shape.radius = 0.15
			cone_shape.height = 0.3
			cs.shape = cone_shape
	mesh.material_override = _mat(color)
	body.add_child(mesh)
	body.add_child(cs)
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
	area.add_child(_box_mesh(Vector3(1, 0.015, 1), Color(1, 0, 0.85)))
	add_child(area)

# ---------------- robot ----------------

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

	var visual := Node3D.new()
	visual.name = "RobotVisual"
	robot.add_child(visual)
	_robot_box(visual, Vector3(0.62, 0.16, 0.56), Color(0.13, 0.13, 0.15), Vector3(0, 0.1, 0))
	_robot_box(visual, Vector3(0.42, 0.3, 0.42), Color(0.93, 0.91, 0.86), Vector3(0, 0.34, 0))
	_robot_box(visual, Vector3(0.34, 0.26, 0.4), Color(0.93, 0.91, 0.86), Vector3(0, 0.64, 0))
	_robot_box(visual, Vector3(0.025, 0.18, 0.3), Color(0.95, 0.62, 0.22), Vector3(0.175, 0.64, 0))
	for side in [-1.0, 1.0]:
		_robot_box(visual, Vector3(0.3, 0.06, 0.06), Color(0.93, 0.91, 0.86), Vector3(0.2, 0.31, side * 0.25))

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

func _robot_box(parent: Node3D, size: Vector3, color: Color, pos: Vector3) -> void:
	var mi := _box_mesh(size, color)
	mi.position = pos
	mi.layers = 2 # Agent cameras cull layer 2 to avoid seeing the robot itself.
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mi)

func _forward() -> Vector3:
	var a := deg_to_rad(heading)
	return Vector3(cos(a), 0, sin(a))

func _sync_heading() -> void:
	robot.rotation.y = -deg_to_rad(heading)

# ---------------- cameras and operator interface ----------------

func _new_viewport(view_name: String, size: Vector2i, camera_name: String) -> Array:
	var vp := SubViewport.new()
	vp.name = view_name
	vp.size = size
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(vp)
	var cam := Camera3D.new()
	cam.name = camera_name
	cam.fov = 90
	cam.keep_aspect = Camera3D.KEEP_WIDTH
	cam.cull_mask = 1
	vp.add_child(cam)
	return [vp, cam]

func _build_cameras() -> void:
	var a := _new_viewport("OverviewViewport", PANEL_SIZE, "OverviewCamera")
	overview_vp = a[0]
	overview_cam = a[1]
	var b := _new_viewport("AgentLookViewport", LOOK_SIZE, "AgentCamera")
	look_vp = b[0]
	look_cam = b[1]
	var c := _new_viewport("PickupViewport", PANEL_SIZE, "PickupCamera")
	pickup_vp = c[0]
	pickup_cam = c[1]
	var d := _new_viewport("PovViewport", POV_SIZE, "PovCamera")
	pov_vp = d[0]
	pov_cam = d[1]
	# Same 90-degree horizontal view as the agent camera (KEEP_WIDTH), at 720p for the clips.
	# The subviewports share the main scene World3D. Update their cameras from robot pose.
	overview_cam.position = Vector3(-7, 6, 7)
	overview_cam.look_at(Vector3.ZERO)
	look_cam.position = Vector3(0, 0.5, 0)
	pickup_cam.position = Vector3(0.18, 1.05, 0)
	pickup_cam.fov = 72.0
	_update_cameras()

func _update_cameras() -> void:
	if robot == null:
		return
	var fwd := _forward()
	look_cam.global_position = robot.global_position + fwd * CAMERA_FORWARD + Vector3.UP * 0.5
	look_cam.look_at(look_cam.global_position + fwd + Vector3.DOWN * 0.18, Vector3.UP)
	pov_cam.global_transform = look_cam.global_transform
	# Close, downward-angled view of the pickup point. Keep the camera just
	# behind the robot's front so the target stays in frame as the robot approaches.
	pickup_cam.global_position = robot.global_position + fwd * 0.18 + Vector3.UP * 1.05
	pickup_cam.look_at(robot.global_position + fwd * 0.85 + Vector3.UP * 0.12, Vector3.UP)
	pickup_cam.fov = 72.0
	pickup_cam.cull_mask = 1 # Show arena and pickable objects; hide robot body meshes.
	var target := robot.global_position
	var overview_pos := target + Vector3(-6.5, 5.0, 6.5)
	overview_cam.global_position = overview_cam.global_position.lerp(overview_pos, 0.08)
	overview_cam.look_at(target, Vector3.UP)

func _build_ui() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	var panel := PanelContainer.new()
	panel.position = Vector2(16, 12)
	panel.size = Vector2(1260, 430)
	layer.add_child(panel)
	var column := VBoxContainer.new()
	panel.add_child(column)
	var header := HBoxContainer.new()
	column.add_child(header)
	var title := Label.new()
	title.text = "MEMBRANE ROBOT  |  SIMULATION CONSOLE"
	title.add_theme_font_size_override("font_size", 20)
	header.add_child(title)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(spacer)
	var online := Label.new()
	online.text = "ENGINE ONLINE  |  HTTP :8080"
	header.add_child(online)
	var row := HBoxContainer.new()
	column.add_child(row)
	_add_view(row, "ROBOT POV (AGENT)", look_vp)
	_add_view(row, "THIRD PERSON", overview_vp)
	_add_view(row, "PICKUP POV", pickup_vp)
	state_label = Label.new()
	column.add_child(state_label)
	var help := Label.new()
	help.text = "W/S move 0.5m  |  A/D turn 30°  |  E pickup  |  Q drop  |  T throw  |  R reset  |  P save robot camera"
	column.add_child(help)

func _add_view(parent: HBoxContainer, label_text: String, vp: SubViewport) -> void:
	var col := VBoxContainer.new()
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(col)
	var label := Label.new()
	label.text = label_text
	col.add_child(label)
	var rect := TextureRect.new()
	rect.custom_minimum_size = PANEL_SIZE
	rect.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT
	rect.texture = vp.get_texture()
	col.add_child(rect)

func _update_ui() -> void:
	if state_label:
		state_label.text = "State: %s   Holding: %s   Retries: %d   Collision: %s" % [
			state_name, str(held != null), retries, str(collided)
		]

# ---------------- trail ----------------

func _build_trail() -> void:
	trail_node = MeshInstance3D.new()
	trail_node.name = "MovementTrail"
	trail_node.top_level = true
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
	while remaining > 0.001:
		await get_tree().physics_frame
		var dt := get_physics_process_delta_time()
		var step := minf(SPEED * dt, remaining)
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
		robot.move_and_collide(-dir * BACK_OFF)
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
	while remaining > 0.01:
		await get_tree().physics_frame
		var step := minf(TURN_SPEED * get_physics_process_delta_time(), remaining)
		heading = fposmod(heading + sign_turn * step, 360.0)
		remaining -= step
		_sync_heading()
		_capture_frame()
	if state_name != "Done":
		state_name = "Carry" if held != null else "Locate"
	busy = false
	return {"turned": snappedf(degrees, 0.01)}

func _pickup() -> Dictionary:
	if held != null:
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
	held = best
	held.freeze = true
	held.linear_velocity = Vector3.ZERO
	held.angular_velocity = Vector3.ZERO
	held.reparent(robot, true)
	var half_height := 0.15
	for child in held.get_children():
		if child is MeshInstance3D:
			half_height = child.get_aabb().size.y / 2.0
	held.global_position = pickup_point.global_position + Vector3.UP * half_height
	held.global_rotation = robot.global_rotation
	held.collision_layer = 0
	held.collision_mask = 0
	state_name = "Carry"
	trail_color = Color(0.1, 0.85, 0.3)
	_rebuild_trail()
	return {"ok": true}

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

func _throw(power: float) -> Dictionary:
	if held == null or not is_instance_valid(held):
		return {"ok": false}
	var obj := held
	var transform_before := obj.global_transform
	obj.reparent(self, true)
	obj.global_transform = transform_before
	obj.freeze = false
	obj.sleeping = false
	obj.collision_layer = 2
	obj.collision_mask = 1 | 2
	obj.apply_central_impulse(_forward() * power + Vector3.UP * power * 0.25)
	held = null
	state_name = "Done"
	return {"ok": true}

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
	if capturing:
		DirAccess.make_dir_recursive_absolute(capture_dir)

func _end_run(result: String) -> void:
	if state_name != "Done":
		outcome = result
	state_name = "Done"
	capturing = false

func _capture_frame() -> void:
	# Physics runs at 60 Hz; keep every other frame for a 30 FPS clip.
	if not capturing or Engine.get_physics_frames() % 2 != 0:
		return
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
				_send_json(200, {"success": bool(_pickup()["ok"])})
		"POST /drop":
			if state_name == "Done":
				_send_json(200, {"success": false, "in_zone": false})
			else:
				var r := await _drop()
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
