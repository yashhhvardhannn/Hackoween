extends CharacterBody3D
## TEMPLATE for Yash: copy this file to engine/scripts/robot/robot.gd and fill it in.
## (This copy lives in the API folder only as a reference. Don't attach it directly.)
##
## It already has every function ApiServer calls (plan.md §3a), with simple working
## versions where possible. Node layout it expects (rename paths below if yours differ):
##
##   Robot (CharacterBody3D, this script, in group "robot")
##   ├── CollisionShape3D          capsule, radius ~0.25
##   ├── LookViewport (SubViewport 640x480, update mode: Always)
##   │   └── LookCamera (Camera3D)        fov 73.74 (vertical) = 90° horizontal at 4:3
##   ├── PovViewport  (SubViewport 1280x720, update mode: Always)  for clips
##   │   └── PovCamera (Camera3D)
##   ├── DepthRay (RayCast3D)             at camera position, target (0, 0, -10)
##   └── HoldPoint (Marker3D)             low in front of the camera, where carried objects sit
##
## Pickable objects: put them in group "pickable". The drop zone: an Area3D in group "drop_zone".
## Units: metres, degrees. Heading 0 = +x, positive = clockwise from above.

const MOVE_SPEED := 1.0     # m/s (brief)
const TURN_SPEED := 90.0    # deg/s (brief)
const REACH := 0.5          # pickup reach, metres from robot front
const REACH_ANGLE := 30.0   # degrees either side of heading
const BACK_OFF := 0.1
const STUCK_TIME := 2.0     # no movement for 2 s counts as a collision

@onready var look_viewport: SubViewport = $LookViewport
@onready var pov_viewport: SubViewport = $PovViewport
@onready var depth_ray: RayCast3D = $DepthRay
@onready var hold_point: Marker3D = $HoldPoint

var held: Node3D = null
var _capturing := false
var _capture_dir := ""
var _capture_frame := 0


func _ready() -> void:
	add_to_group("robot")


# --- movement ----------------------------------------------------------------
# Godot's forward is -Z. With a +y-up world, heading clockwise from above means
# heading = -rotation_degrees.y (+ 90 if your robot's forward is -Z and +x is heading 0).
func _heading() -> float:
	return fposmod(-rotation_degrees.y - 90.0, 360.0)


func do_move(distance: float) -> Dictionary:
	var dir := -global_transform.basis.z * signf(distance)
	dir.y = 0
	dir = dir.normalized()
	var moved := 0.0
	var collided := false
	var still_for := 0.0
	while moved < absf(distance) - 0.001:
		var delta := get_physics_process_delta_time()
		await get_tree().physics_frame
		var step := minf(MOVE_SPEED * delta, absf(distance) - moved)
		var before := global_position
		var hit := move_and_collide(dir * step)
		var progress := (global_position - before).length()
		moved += progress
		if hit:
			collided = true
			break
		still_for = still_for + delta if progress < 0.0005 else 0.0
		if still_for >= STUCK_TIME:
			collided = true
			break
		_capture()
	if collided:
		move_and_collide(-dir * BACK_OFF)
		moved = maxf(moved - BACK_OFF, 0.0)
	return {"moved": moved * signf(distance), "collided": collided}


func do_turn(degrees: float) -> Dictionary:
	var turned := 0.0
	while absf(turned) < absf(degrees) - 0.01:
		var delta := get_physics_process_delta_time()
		await get_tree().physics_frame
		var step := minf(TURN_SPEED * delta, absf(degrees) - absf(turned)) * signf(degrees)
		rotate_y(deg_to_rad(-step))  # positive degrees = turn right (clockwise from above)
		turned += step
		_capture()
	return {"turned": turned}


# --- pickup / drop -----------------------------------------------------------
func do_pickup() -> bool:
	if held:
		return false
	var best: Node3D = null
	var best_d := INF
	var fwd := -global_transform.basis.z
	for obj in get_tree().get_nodes_in_group("pickable"):
		var to: Vector3 = obj.global_position - global_position
		to.y = 0
		var d := to.length() - 0.25  # minus robot radius, roughly "from the front"
		var ang := rad_to_deg(Vector3(fwd.x, 0, fwd.z).angle_to(to))
		if d <= REACH and ang <= REACH_ANGLE and d < best_d:
			best = obj
			best_d = d
	if best == null:
		return false
	if best is RigidBody3D:
		best.freeze = true
	if best is PhysicsBody3D:
		add_collision_exception_with(best)  # don't "collide" with what we're carrying
	best.reparent(hold_point, false)
	best.position = Vector3.ZERO
	held = best
	return true


func do_drop() -> Dictionary:
	if held == null:
		return {"success": false, "in_zone": false}
	var obj := held
	held = null
	var drop_pos := global_position - global_transform.basis.z * 0.45
	obj.reparent(get_tree().current_scene)
	obj.global_position = Vector3(drop_pos.x, obj.global_position.y, drop_pos.z)
	if obj is RigidBody3D:
		obj.freeze = false
	if obj is PhysicsBody3D:
		remove_collision_exception_with(obj)
	# Drop zone = Area3D in group "drop_zone" with a CollisionShape3D child using a BoxShape3D.
	var in_zone := false
	for zone in get_tree().get_nodes_in_group("drop_zone"):
		for child in zone.get_children():
			if child is CollisionShape3D and child.shape is BoxShape3D:
				var size: Vector3 = child.shape.size
				var local: Vector3 = child.global_transform.affine_inverse() * obj.global_position
				if absf(local.x) <= size.x / 2 and absf(local.z) <= size.z / 2:
					in_zone = true
	return {"success": true, "in_zone": in_zone}


# --- sensors -----------------------------------------------------------------
func get_pose() -> Dictionary:
	return {"x": global_position.x, "y": global_position.z, "heading": _heading(), "holding": held != null}


func get_look_jpeg() -> PackedByteArray:
	if _headless():  # nothing is drawn with --headless: send a blank frame
		return Image.create_empty(640, 480, false, Image.FORMAT_RGB8).save_jpg_to_buffer(0.85)
	return look_viewport.get_texture().get_image().save_jpg_to_buffer(0.85)


func _headless() -> bool:
	return DisplayServer.get_name() == "headless"


func get_depth() -> Variant:
	depth_ray.force_raycast_update()
	if not depth_ray.is_colliding():
		return null
	return depth_ray.global_position.distance_to(depth_ray.get_collision_point())


# --- POV clip capture (engine-time frames only: saved during move/turn) -------
func start_capture(run_id: String, _command: String) -> void:
	# The command overlay is added later by tools/make_clip.py, so it isn't drawn here.
	_capture_dir = ProjectSettings.globalize_path("res://").path_join("../runs/%s/pov" % run_id).simplify_path()
	DirAccess.make_dir_recursive_absolute(_capture_dir)
	_capture_frame = 0
	_capturing = true


func stop_capture() -> void:
	_capturing = false


func _capture() -> void:
	if not _capturing or _headless():
		return
	var img := pov_viewport.get_texture().get_image()
	img.save_png(_capture_dir.path_join("%05d.png" % _capture_frame))
	_capture_frame += 1


func reset_layout(_layout: String) -> void:
	# Optional: reload the scene or move objects to a named layout.
	get_tree().reload_current_scene()
