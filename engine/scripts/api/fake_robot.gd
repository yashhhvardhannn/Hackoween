extends Node
## Stand-in robot so the API can be built and tested before Yash's real robot exists.
##
## It implements the same functions the real robot must provide (plan.md §3a).
## Only loaded in the practice project (api_sandbox). The real game never registers it.
##
## World: empty 8x8 m room, robot starts in the middle facing +x.
## Heading 0 = +x, positive = clockwise from above (y-down map).

const ROOM := 8.0
const RADIUS := 0.25
const STEP := 0.05

var x := 4.0
var y := 4.0
var heading := 0.0
var holding := false


func _ready() -> void:
	add_to_group("robot")


## Drive forward (negative = backwards). Stops at walls, backs off 0.1 m.
func do_move(distance: float) -> Dictionary:
	await get_tree().process_frame  # behave like the real robot: takes at least a frame
	var dir := Vector2.from_angle(deg_to_rad(heading)) * signf(distance)
	var moved := 0.0
	var collided := false
	while moved < absf(distance) - 0.0001:
		var step := minf(STEP, absf(distance) - moved)
		var nx := x + dir.x * step
		var ny := y + dir.y * step
		if nx < RADIUS or nx > ROOM - RADIUS or ny < RADIUS or ny > ROOM - RADIUS:
			collided = true
			break
		x = nx
		y = ny
		moved += step
	if collided:
		x -= dir.x * 0.1
		y -= dir.y * 0.1
		moved = maxf(moved - 0.1, 0.0)
	return {"moved": moved * signf(distance), "collided": collided}


func do_turn(degrees: float) -> Dictionary:
	await get_tree().process_frame
	heading = fposmod(heading + degrees, 360.0)
	return {"turned": degrees}


func do_pickup() -> bool:
	if holding:
		return false
	holding = true  # the stand-in always "finds" something, so the full flow can be tested
	return true


func do_drop() -> Dictionary:
	if not holding:
		return {"success": false, "in_zone": false}
	holding = false
	return {"success": true, "in_zone": x > 6.0 and y > 6.0}  # pretend zone: top-right corner


func get_pose() -> Dictionary:
	return {"x": x, "y": y, "heading": heading, "holding": holding}


## A plain test picture: grey floor, blue "wall" band that slides as the robot turns.
func get_look_jpeg() -> PackedByteArray:
	var img := Image.create_empty(640, 480, false, Image.FORMAT_RGB8)
	img.fill(Color(0.78, 0.78, 0.8))
	img.fill_rect(Rect2i(0, 0, 640, 180), Color(0.55, 0.62, 0.7))
	var band_x := int(fposmod(heading * 4.0, 640.0))
	img.fill_rect(Rect2i(band_x, 120, 60, 120), Color(0.3, 0.3, 0.35))
	return img.save_jpg_to_buffer(0.85)


func get_depth() -> Variant:
	var dir := Vector2.from_angle(deg_to_rad(heading))
	var best := INF
	if dir.x > 0.0001: best = minf(best, (ROOM - x) / dir.x)
	if dir.x < -0.0001: best = minf(best, -x / dir.x)
	if dir.y > 0.0001: best = minf(best, (ROOM - y) / dir.y)
	if dir.y < -0.0001: best = minf(best, -y / dir.y)
	return null if best > 10.0 else best


func start_capture(_run_id: String, _command: String) -> void:
	pass  # the real robot starts saving POV frames here


func stop_capture() -> void:
	pass


func reset_layout(_layout: String) -> void:
	x = 4.0
	y = 4.0
	heading = 0.0
	holding = false
