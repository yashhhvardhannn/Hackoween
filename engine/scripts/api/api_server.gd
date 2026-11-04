extends Node
## The engine's HTTP "receptionist" (autoload name: ApiServer).
##
## Listens on port 8080 and answers exactly the contract in plan.md §2.
## For each request it calls the robot (any node in group "robot", see plan.md §3a),
## updates StateMachine, and replies.
##
## LEAK RULE: every reply is built here from an explicit list of allowed keys.
## Whatever extra data the robot returns is dropped, so no object information can escape.

const PORT := 8080
const MAX_REQUEST_BYTES := 65536
const REASONS := {200: "OK", 400: "Bad Request", 404: "Not Found", 409: "Conflict", 413: "Payload Too Large", 503: "Service Unavailable"}


class Client:
	var peer: StreamPeerTCP
	var buf := PackedByteArray()
	var busy := false  # a request is being handled (moves can take several frames)
	var done := false


var _server := TCPServer.new()
var _clients: Array[Client] = []
var _motion_busy := false  # only one move/turn at a time


func _ready() -> void:
	var err := _server.listen(PORT, "*")
	if err != OK:
		push_error("ApiServer: cannot listen on port %d (error %d). Is the mock engine still running?" % [PORT, err])
		return
	print("ApiServer listening on http://localhost:%d" % PORT)


func _process(_delta: float) -> void:
	while _server.is_connection_available():
		var c := Client.new()
		c.peer = _server.take_connection()
		_clients.append(c)
	for c in _clients:
		_poll(c)
	var alive: Array[Client] = []
	for c in _clients:
		if not c.done:
			alive.append(c)
	_clients = alive


# ---------------------------------------------------------------------------
# Reading requests
# ---------------------------------------------------------------------------
func _poll(c: Client) -> void:
	if c.busy:
		return
	c.peer.poll()
	if c.peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		c.done = true
		return
	var n := c.peer.get_available_bytes()
	if n > 0:
		var res: Array = c.peer.get_data(n)
		if res[0] == OK:
			var b := c.buf
			b.append_array(res[1])
			c.buf = b
	if c.buf.size() > MAX_REQUEST_BYTES:
		_send(c, _json(413, {"error": "request too large"}))
		return
	var req := _parse(c.buf)
	if req.is_empty():
		return  # not fully arrived yet
	c.busy = true
	_handle(c, req)  # runs as a coroutine; replies when finished


## Returns {} until the whole request (headers + body) has arrived.
func _parse(buf: PackedByteArray) -> Dictionary:
	var text := buf.get_string_from_ascii()
	var head_end := text.find("\r\n\r\n")
	if head_end == -1:
		return {}
	var lines := text.substr(0, head_end).split("\r\n")
	var first := lines[0].split(" ")
	if first.size() < 2:
		return {"method": "BAD", "path": "", "body": ""}
	var length := 0
	for i in range(1, lines.size()):
		var line: String = lines[i]
		var colon := line.find(":")
		if colon > 0 and line.substr(0, colon).strip_edges().to_lower() == "content-length":
			length = line.substr(colon + 1).strip_edges().to_int()
	var body_start := head_end + 4
	if buf.size() < body_start + length:
		return {}
	return {
		"method": first[0],
		"path": first[1].split("?")[0],
		"body": buf.slice(body_start, body_start + length).get_string_from_utf8(),
	}


func _handle(c: Client, req: Dictionary) -> void:
	var reply: Array = await _route(req["method"], req["path"], req["body"])
	_send(c, reply)


# ---------------------------------------------------------------------------
# Endpoints (plan.md §2)
# ---------------------------------------------------------------------------
func _route(method: String, path: String, body_text: String) -> Array:
	var robot = get_tree().get_first_node_in_group("robot")  # untyped: robot methods are defined in its own script
	if robot == null:
		return _json(503, {"error": "robot not ready"})

	var body := {}
	if method == "POST" and body_text.strip_edges() != "":
		var parsed: Variant = JSON.parse_string(body_text)
		if typeof(parsed) != TYPE_DICTIONARY:
			return _json(400, {"error": "body must be a JSON object"})
		body = parsed

	match method + " " + path:
		"GET /state":
			var pose: Dictionary = robot.get_pose()
			return _json(200, {
				"state": StateMachine.state,
				"x": snappedf(float(pose.get("x", 0.0)), 0.001),
				"y": snappedf(float(pose.get("y", 0.0)), 0.001),
				"heading": snappedf(float(pose.get("heading", 0.0)), 0.01),
				"holding": bool(pose.get("holding", false)),
				"retries": int(StateMachine.retries),
			})

		"GET /look":
			return [200, "image/jpeg", robot.get_look_jpeg()]

		"GET /depth":
			var d: Variant = robot.get_depth()
			return _json(200, {"distance": null if d == null else snappedf(float(d), 0.001)})

		"POST /move":
			if not body.has("distance"):
				return _json(400, {"error": "missing distance"})
			if StateMachine.is_done():
				return _json(200, {"moved": 0.0, "collided": false, "state": StateMachine.state})
			if _motion_busy:
				return _json(409, {"error": "robot is busy"})
			_motion_busy = true
			var r: Dictionary = await robot.do_move(float(body["distance"]))
			_motion_busy = false
			var collided := bool(r.get("collided", false))
			StateMachine.on_move(collided, _holding(robot))
			return _json(200, {
				"moved": snappedf(float(r.get("moved", 0.0)), 0.001),
				"collided": collided,
				"state": StateMachine.state,
			})

		"POST /turn":
			if not body.has("degrees"):
				return _json(400, {"error": "missing degrees"})
			if StateMachine.is_done():
				return _json(200, {"turned": 0.0, "state": StateMachine.state})
			if _motion_busy:
				return _json(409, {"error": "robot is busy"})
			_motion_busy = true
			var r: Dictionary = await robot.do_turn(float(body["degrees"]))
			_motion_busy = false
			StateMachine.on_turn(_holding(robot))
			return _json(200, {
				"turned": snappedf(float(r.get("turned", 0.0)), 0.01),
				"state": StateMachine.state,
			})

		"POST /pickup":
			if StateMachine.is_done():
				return _json(200, {"success": false})
			StateMachine.on_pickup_attempt()
			var ok := bool(robot.do_pickup())
			StateMachine.on_pickup(ok)
			return _json(200, {"success": ok})

		"POST /drop":
			if StateMachine.is_done():
				return _json(200, {"success": false, "in_zone": false})
			var r: Dictionary = robot.do_drop()
			var success := bool(r.get("success", false))
			var in_zone := success and bool(r.get("in_zone", false))
			if success:
				StateMachine.on_drop(in_zone)
			return _json(200, {"success": success, "in_zone": in_zone})

		"POST /run/start":
			StateMachine.start_run()
			# The command is passed on only for the clip overlay. It is never sent back.
			robot.start_capture(str(body.get("run_id", "run")), str(body.get("command", "")))
			return _json(200, {"ok": true})

		"POST /run/end":
			robot.stop_capture()
			if not StateMachine.is_done():
				StateMachine.end_run(str(body.get("outcome", "fail_not_reached")))
			return _json(200, {"ok": true})

		"POST /reset":
			if robot.has_method("reset_layout"):
				robot.reset_layout(str(body.get("layout", "default")))
			StateMachine.reset()
			return _json(200, {"ok": true})

	return _json(404, {"error": "unknown endpoint"})


func _holding(robot) -> bool:
	return bool(robot.get_pose().get("holding", false))


# ---------------------------------------------------------------------------
# Writing replies
# ---------------------------------------------------------------------------
func _json(code: int, data: Dictionary) -> Array:
	return [code, "application/json", JSON.stringify(data).to_utf8_buffer()]


func _send(c: Client, reply: Array) -> void:
	var code: int = reply[0]
	var body: PackedByteArray = reply[2]
	c.peer.poll()
	if c.peer.get_status() == StreamPeerTCP.STATUS_CONNECTED:
		var head := "HTTP/1.1 %d %s\r\nContent-Type: %s\r\nContent-Length: %d\r\nConnection: close\r\n\r\n" % [
			code, REASONS.get(code, "OK"), reply[1], body.size()]
		c.peer.put_data(head.to_utf8_buffer())
		c.peer.put_data(body)
		c.peer.disconnect_from_host()
	c.done = true
