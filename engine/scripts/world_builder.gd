extends Node3D
# Self-contained Membrane Robot simulator for Godot 4.x.
# Agent sees only /look pixels, /depth scalar, robot-only /state and collision flag.

const PORT := 8080
const SPEED := 1.0
const TURN_SPEED := 90.0
const PICKUP_REACH := 0.5
const PICKUP_HALF_ANGLE := 30.0
const MAX_DEPTH := 10.0
const LOOK_SIZE := Vector2i(640, 480)
const PANEL_SIZE := Vector2i(400, 260)

var robot: CharacterBody3D
var pickup_area: Area3D
var pickup_point: Marker3D
var held: RigidBody3D
var heading := 0.0
var state_name := "Idle"
var retries := 0
var collided := false
var busy := false

var look_vp: SubViewport
var overview_vp: SubViewport
var pickup_vp: SubViewport
var look_cam: Camera3D
var overview_cam: Camera3D
var pickup_cam: Camera3D

var trail_points: Array[Vector3] = []
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
	var err := server.listen(PORT, "127.0.0.1")
	if err == OK:
		print("Robot HTTP API: http://127.0.0.1:%d" % PORT)
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
	pickup_point.position = Vector3(0.48, 0.55, 0)
	robot.add_child(pickup_point)

	pickup_area = Area3D.new()
	pickup_area.name = "PickupArea"
	pickup_area.position = Vector3(0.25, 0.2, 0)
	pickup_area.collision_layer = 0
	pickup_area.collision_mask = 2
	var ps := SphereShape3D.new()
	ps.radius = PICKUP_REACH
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
	look_cam.global_position = robot.global_position + Vector3.UP * 0.5
	look_cam.look_at(look_cam.global_position + fwd + Vector3.DOWN * 0.18, Vector3.UP)
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
	state_name = "Carry" if held != null else "Go to object"
	trail_color = Color(0.1, 0.85, 0.3) if held != null else Color(0.1, 0.55, 1.0)
	_rebuild_trail()
	var dir := _forward() * signf(distance)
	var remaining := absf(distance)
	var moved := 0.0
	while remaining > 0.001:
		await get_tree().physics_frame
		var step := minf(SPEED * get_physics_process_delta_time(), remaining)
		var hit := robot.move_and_collide(dir * step)
		if hit != null:
			collided = true
			state_name = "Blocked"
			retries += 1
			trail_color = Color(1.0, 0.5, 0.05)
			_rebuild_trail()
			break
		remaining -= step
		moved += step
		_add_trail()
	busy = false
	return {"moved": snappedf(moved, 0.001), "collided": collided}

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
	busy = false
	return {"heading": snappedf(heading, 0.1)}

func _pickup() -> Dictionary:
	if held != null:
		return {"ok": false}
	var best: RigidBody3D = null
	var best_d := INF
	var fwd := _forward()
	for body in pickup_area.get_overlapping_bodies():
		if not body is RigidBody3D or not body.is_in_group("pickable"):
			continue
		var offset: Vector3 = body.global_position - robot.global_position
		var flat := Vector3(offset.x, 0, offset.z)
		var d := flat.length()
		if d > PICKUP_REACH:
			continue
		if d > 0.001 and rad_to_deg(acos(clampf(fwd.dot(flat.normalized()), -1.0, 1.0))) > PICKUP_HALF_ANGLE:
			continue
		if d < best_d:
			best = body
			best_d = d
	if best == null:
		return {"ok": false}
	held = best
	held.freeze = true
	held.linear_velocity = Vector3.ZERO
	held.angular_velocity = Vector3.ZERO
	held.reparent(robot, true)
	held.global_position = pickup_point.global_position
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
	var delta := obj.global_position - Vector3(-2.5, 0, 2.5)
	var inside := absf(delta.x) <= 0.5 and absf(delta.z) <= 0.5
	state_name = "Done" if inside else "Drop"
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
	if held != null:
		_drop()
	robot.position = Vector3(-3, 0, 0)
	robot.velocity = Vector3.ZERO
	heading = 0.0
	_sync_heading()
	retries = 0
	collided = false
	state_name = "Idle"
	trail_points.clear()
	trail_color = Color(0.1, 0.55, 1.0)
	_rebuild_trail()
	_add_trail()

func _save_look() -> void:
	await RenderingServer.frame_post_draw
	var image := look_vp.get_texture().get_image()
	image.save_jpg("user://look.jpg", 0.9)
	print("Saved camera image to: ", ProjectSettings.globalize_path("user://look.jpg"))

# ---------------- HTTP server ----------------

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
	match path:
		"/state":
			_send_json(200, _state())
		"/look":
			await _send_look()
		"/depth":
			_send_json(200, {"distance": _depth()})
		"/collision":
			_send_json(200, {"collided": collided})
		"/move":
			if method == "POST":
				_send_json(200, await _move(float(body.get("distance", 0.0))))
			else:
				_send_json(405, {"error": "method_not_allowed"})
		"/turn":
			if method == "POST":
				_send_json(200, await _turn(float(body.get("degrees", 0.0))))
			else:
				_send_json(405, {"error": "method_not_allowed"})
		"/pickup":
			_send_json(200, _pickup() if method == "POST" else {"error": "method_not_allowed"})
		"/drop":
			if method == "POST":
				_send_json(200, await _drop())
			else:
				_send_json(405, {"error": "method_not_allowed"})
		"/throw":
			_send_json(200, _throw(float(body.get("impulse", 3.0))) if method == "POST" else {"error": "method_not_allowed"})
		_:
			_send_json(404, {"error": "not_found"})
	_close_peer()

func _read_http_request() -> Dictionary:
	var data := PackedByteArray()
	var header_end := -1
	var length := 0
	var deadline := Time.get_ticks_msec() + 3000
	while Time.get_ticks_msec() < deadline:
		if peer == null or peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
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
	var reason := "OK" if status == 200 else ("Not Found" if status == 404 else "Method Not Allowed")
	var header := "HTTP/1.1 %d %s\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n" % [status, reason, bytes.size()]
	peer.put_data(header.to_utf8_buffer())
	peer.put_data(bytes)

func _send_look() -> void:
	await RenderingServer.frame_post_draw
	var bytes := look_vp.get_texture().get_image().save_jpg_to_buffer(0.88)
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
		"name": state_name,
		"x": snappedf(robot.global_position.x, 0.01),
		"y": snappedf(robot.global_position.z, 0.01),
		"heading": snappedf(heading, 0.1),
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
