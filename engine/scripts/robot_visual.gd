extends Node3D
## The robot's look and animation. Purely visual: the robot's physics body, speed,
## reach and camera are untouched (world_builder.gd). Every mesh here is on render
## layer 2, which the agent camera (/look) and the POV clip camera cull, so none of
## this can reach Claude.
##
## Robot-local axes: +x forward, +z right, +y up.

const LAYER := 2
const TRACK_HALF := 0.22        # track centre distance from the middle
const ROLLER_RADIUS := 0.07

# Palette (original design): warm white shell, graphite metal, rubber tracks,
# teal lenses and an orange accent stripe.
const SHELL := Color(0.90, 0.89, 0.86)
const GRAPHITE := Color(0.3, 0.31, 0.33)
const RUBBER := Color(0.07, 0.07, 0.08)
const ACCENT := Color(0.95, 0.47, 0.13)
const LENS_GLOW := Color(0.25, 0.95, 0.9)

const TREAD_SHADER := """
shader_type spatial;
uniform float scroll = 0.0;
uniform vec4 base : source_color = vec4(0.07, 0.07, 0.08, 1.0);
varying vec3 lp;
void vertex() { lp = VERTEX; }
void fragment() {
	// Ridges along the track's length (local y of the rotated capsule).
	float s = fract((lp.y + scroll) * 16.0);
	float ridge = smoothstep(0.05, 0.15, s) * (1.0 - smoothstep(0.5, 0.62, s));
	ALBEDO = base.rgb * (0.65 + 0.7 * ridge);
	ROUGHNESS = 0.9 - 0.25 * ridge;
	SPECULAR = 0.3;
}
"""

var body_pivot: Node3D          # everything above the tracks; leans on the "suspension"
var head_yaw: Node3D
var head_pitch: Node3D
var lids: Array[Node3D] = []
var arms: Array[Dictionary] = []
var rollers: Array[Dictionary] = []
var tread_mats: Array[ShaderMaterial] = []
var led_mat: StandardMaterial3D

# animation state
var t := 0.0
var speed := 0.0                # smoothed forward speed, m/s
var yaw_rate := 0.0             # smoothed turn rate, deg/s (positive = right)
var last_speed := 0.0
var tread_scroll := [0.0, 0.0]  # left, right
var pitch := 0.0
var pitch_vel := 0.0
var roll := 0.0
var roll_vel := 0.0
var head_y := 0.0
var head_p := 0.0
var blink_in := 2.5
var blink_t := -1.0
var fling_t := 0.0


func _ready() -> void:
	_build()


# ---------------- model ----------------

func _mat(color: Color, rough: float, metal := 0.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = rough
	m.metallic = metal
	return m

func _glow(color: Color, energy: float) -> StandardMaterial3D:
	var m := _mat(color, 0.3)
	m.emission_enabled = true
	m.emission = color
	m.emission_energy_multiplier = energy
	return m

func _part(parent: Node3D, mesh: Mesh, mat: Material, pos: Vector3, rot_deg := Vector3.ZERO, scl := Vector3.ONE) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = pos
	mi.rotation_degrees = rot_deg
	mi.scale = scl
	mi.layers = LAYER
	parent.add_child(mi)
	return mi

func _box(size: Vector3) -> BoxMesh:
	var b := BoxMesh.new()
	b.size = size
	return b

func _cyl(radius: float, height: float, sides := 24) -> CylinderMesh:
	var c := CylinderMesh.new()
	c.top_radius = radius
	c.bottom_radius = radius
	c.height = height
	c.radial_segments = sides
	return c

func _node(parent: Node3D, pos: Vector3) -> Node3D:
	var n := Node3D.new()
	n.position = pos
	parent.add_child(n)
	return n

func _build() -> void:
	var shell := _mat(SHELL, 0.42)
	var graphite := _mat(GRAPHITE, 0.45, 0.35)
	var dark := _mat(Color(0.1, 0.1, 0.11), 0.6)
	var accent := _mat(ACCENT, 0.45)
	var glass := _mat(Color(0.02, 0.03, 0.04), 0.05, 0.4)
	var lens_ring := _glow(LENS_GLOW, 2.2)
	led_mat = _glow(Color(0.2, 0.6, 1.0), 3.0)

	# --- tracks: a stadium-shaped belt per side with three visible rollers
	for side: float in [-1.0, 1.0]:
		var sm := ShaderMaterial.new()
		var sh := Shader.new()
		sh.code = TREAD_SHADER
		sm.shader = sh
		tread_mats.append(sm)
		var belt := CapsuleMesh.new()
		belt.radius = 0.105
		belt.height = 0.62
		belt.radial_segments = 24
		_part(self, belt, sm, Vector3(0, 0.105, side * TRACK_HALF), Vector3(0, 0, 90), Vector3(1, 1, 0.62))
		# mudguard over the belt
		_part(self, _box(Vector3(0.56, 0.018, 0.15)), shell, Vector3(0, 0.222, side * TRACK_HALF))
		for x: float in [-0.2, 0.0, 0.2]:
			var hub := _node(self, Vector3(x, 0.105, side * (TRACK_HALF + 0.068)))
			_part(hub, _cyl(ROLLER_RADIUS, 0.016), graphite, Vector3.ZERO, Vector3(90, 0, 0))
			# two spokes so the spin is visible
			_part(hub, _box(Vector3(0.12, 0.016, 0.02)), dark, Vector3(0, 0, side * 0.006))
			_part(hub, _box(Vector3(0.016, 0.12, 0.02)), dark, Vector3(0, 0, side * 0.006))
			_part(hub, _cyl(0.018, 0.03), accent, Vector3(0, 0, side * 0.01), Vector3(90, 0, 0))
			rollers.append({"node": hub, "side": 0 if side < 0 else 1})

	# --- body (leans on its suspension)
	body_pivot = _node(self, Vector3(0, 0.2, 0))
	var bp := body_pivot
	_part(bp, _box(Vector3(0.44, 0.36, 0.34)), shell, Vector3(0, 0.16, 0))                  # main shell
	_part(bp, _box(Vector3(0.46, 0.03, 0.36)), accent, Vector3(0, 0.355, 0))                # lid
	_part(bp, _box(Vector3(0.46, 0.04, 0.36)), graphite, Vector3(0, -0.01, 0))              # belly plate
	_part(bp, _box(Vector3(0.012, 0.22, 0.26)), dark, Vector3(0.221, 0.15, 0))              # front face plate
	for i in 4:                                                                           # front grille
		_part(bp, _box(Vector3(0.006, 0.012, 0.16)), graphite, Vector3(0.228, 0.08 + i * 0.03, -0.03))
	_part(bp, _cyl(0.038, 0.02), lens_ring, Vector3(0.226, 0.27, 0.07), Vector3(0, 0, 90))   # front sensor ring
	_part(bp, _cyl(0.026, 0.024), glass, Vector3(0.228, 0.27, 0.07), Vector3(0, 0, 90))      # front sensor lens
	for side: float in [-1.0, 1.0]:
		_part(bp, _box(Vector3(0.3, 0.035, 0.006)), accent, Vector3(-0.02, 0.24, side * 0.173))  # side stripe
		_part(bp, _box(Vector3(0.12, 0.08, 0.006)), dark, Vector3(-0.1, 0.12, side * 0.173))     # side panel
	_part(bp, _box(Vector3(0.012, 0.16, 0.2)), graphite, Vector3(-0.221, 0.18, 0))          # back hatch
	var led := _part(bp, _box(Vector3(0.04, 0.012, 0.04)), led_mat, Vector3(-0.17, 0.375, 0.12))
	led.name = "StatusLight"
	_part(bp, _cyl(0.006, 0.16, 8), graphite, Vector3(-0.17, 0.45, -0.12))                  # antenna
	_part(bp, _cyl(0.014, 0.02), accent, Vector3(-0.17, 0.535, -0.12))

	# --- neck and twin-lens camera head
	_part(bp, _cyl(0.05, 0.04), graphite, Vector3(0.02, 0.39, 0))
	_part(bp, _cyl(0.022, 0.2, 12), graphite, Vector3(0.02, 0.5, 0))
	head_yaw = _node(bp, Vector3(0.02, 0.6, 0))
	head_pitch = _node(head_yaw, Vector3.ZERO)
	var hp := head_pitch
	_part(hp, _box(Vector3(0.07, 0.05, 0.08)), graphite, Vector3(0, 0, 0))                 # bridge
	for side: float in [-1.0, 1.0]:
		var z := side * 0.078
		_part(hp, _cyl(0.068, 0.12), shell, Vector3(0.035, 0.0, z), Vector3(0, 0, 90))      # eye pod
		_part(hp, _cyl(0.06, 0.012), accent, Vector3(-0.027, 0.0, z), Vector3(0, 0, 90))    # back cap
		var ring := TorusMesh.new()
		ring.inner_radius = 0.042
		ring.outer_radius = 0.058
		_part(hp, ring, lens_ring, Vector3(0.096, 0.0, z), Vector3(0, 0, 90))               # glowing ring
		_part(hp, _cyl(0.046, 0.012), glass, Vector3(0.097, 0.0, z), Vector3(0, 0, 90))     # lens
		_part(hp, SphereMesh.new(), _glow(Color(0.85, 1.0, 1.0), 1.5), Vector3(0.104, 0.018, z - 0.016), Vector3.ZERO, Vector3.ONE * 0.016)  # glint
		# eyelid: hinges at the top of the pod and scales down over the lens when blinking
		var lid := _node(hp, Vector3(0.098, 0.07, z))
		_part(lid, _box(Vector3(0.02, 0.14, 0.15)), shell, Vector3(0, -0.07, 0))
		lid.scale = Vector3(1, 0.001, 1)
		lids.append(lid)

	# --- telescopic arms with two-finger grippers
	for side: float in [-1.0, 1.0]:
		var shoulder := _node(bp, Vector3(0.02, 0.22, side * 0.2))
		_part(shoulder, SphereMesh.new(), graphite, Vector3.ZERO, Vector3.ZERO, Vector3.ONE * 0.085)
		var boom := _part(shoulder, _box(Vector3(1.0, 0.045, 0.045)), shell, Vector3(0.1, 0, 0), Vector3.ZERO, Vector3(0.2, 1, 1))
		var sleeve := _part(shoulder, _box(Vector3(1.0, 0.03, 0.03)), graphite, Vector3(0.1, 0, 0), Vector3.ZERO, Vector3(0.2, 1, 1))
		var hand := _node(shoulder, Vector3(0.2, 0, 0))
		_part(hand, _box(Vector3(0.05, 0.075, 0.07)), graphite, Vector3.ZERO)
		var fingers: Array[Node3D] = []
		for f: float in [-1.0, 1.0]:
			var finger := _node(hand, Vector3(0.02, f * 0.03, 0))
			_part(finger, _box(Vector3(0.07, 0.016, 0.02)), accent, Vector3(0.035, 0, -side * 0.02))
			fingers.append(finger)
		arms.append({
			"side": side, "shoulder": shoulder, "boom": boom, "sleeve": sleeve, "hand": hand,
			"fingers": fingers, "angle": -1.15, "length": 0.17, "grip": 0.0,
		})


# ---------------- animation ----------------

## Called every rendered frame by world_builder.gd.
## lin_speed: forward speed in m/s; turn_rate: deg/s (positive = right);
## hold_target: robot-local point between the hands (object centre), or null.
func animate(delta: float, lin_speed: float, turn_rate: float, state: String, hold_target: Variant) -> void:
	t += delta
	var k := 1.0 - exp(-delta * 14.0)
	speed = lerpf(speed, lin_speed, k)
	yaw_rate = lerpf(yaw_rate, turn_rate, k)
	var accel := (speed - last_speed) / maxf(delta, 0.001)
	last_speed = speed
	var moving := absf(speed) > 0.02 or absf(yaw_rate) > 2.0

	# Tracks: on a right turn the left belt runs forward and the right one backward.
	var w := deg_to_rad(yaw_rate)
	var belt_speed := [speed + w * TRACK_HALF, speed - w * TRACK_HALF]
	for i in 2:
		tread_scroll[i] += belt_speed[i] * delta
		tread_mats[i].set_shader_parameter("scroll", tread_scroll[i])
	for r in rollers:
		var hub: Node3D = r.node
		var bs: float = belt_speed[r.side]
		hub.rotation.z -= bs * delta / ROLLER_RADIUS

	# Body: springy lean back when speeding up, forward when braking, slight sway in turns,
	# and a little track rumble while moving.
	var pitch_target := clampf(accel * 0.02, -0.08, 0.08)
	var roll_target := clampf(-w * 0.025, -0.04, 0.04)
	pitch_vel += ((pitch_target - pitch) * 140.0 - pitch_vel * 14.0) * delta
	pitch += pitch_vel * delta
	roll_vel += ((roll_target - roll) * 120.0 - roll_vel * 13.0) * delta
	roll += roll_vel * delta
	var rumble := 0.0
	if moving:
		rumble = sin(t * 38.0) * 0.0025 + sin(t * 23.0) * 0.0015
	body_pivot.rotation = Vector3(roll, 0, pitch)
	body_pivot.position.y = 0.2 + rumble

	# Head: looks around when idle, looks into turns, looks down at what it holds or reaches for.
	var yaw_t := 0.0
	var pitch_t := 0.0
	if hold_target != null:
		pitch_t = -0.38
	elif moving:
		yaw_t = clampf(w * 0.35, -0.6, 0.6)
		pitch_t = -0.08
	elif state == "Done":
		pitch_t = 0.12 + sin(t * 2.0) * 0.05
	else:
		yaw_t = sin(t * 0.45) * 0.45 + sin(t * 1.3) * 0.12
		pitch_t = sin(t * 0.7) * 0.1 - 0.04
	var hk := 1.0 - exp(-delta * 5.0)
	head_y = lerpf(head_y, yaw_t, hk)
	head_p = lerpf(head_p, pitch_t, hk)
	head_yaw.rotation.y = -head_y
	head_pitch.rotation.z = head_p

	# Blink every few seconds.
	blink_in -= delta
	if blink_in <= 0.0 and blink_t < 0.0:
		blink_t = 0.0
		blink_in = randf_range(2.5, 5.5)
	var lid_scale := 0.001
	if blink_t >= 0.0:
		blink_t += delta
		lid_scale = maxf(0.001, sin(clampf(blink_t / 0.16, 0.0, 1.0) * PI))
		if blink_t > 0.16:
			blink_t = -1.0
	for lid in lids:
		lid.scale.y = lid_scale

	# Arms: reach for / hold the object, tuck in otherwise; swing a little while driving.
	fling_t = maxf(0.0, fling_t - delta)
	var ak := 1.0 - exp(-delta * 9.0)
	for arm in arms:
		var shoulder: Node3D = arm.shoulder
		var arm_side: float = arm.side
		var angle_t: float = -1.15 + sin(t * 9.0 + arm_side) * 0.05 * minf(absf(speed), 1.0)
		var length_t: float = 0.17
		var grip_t: float = 0.0
		if hold_target != null:
			var sp := body_pivot.position + shoulder.position
			var to: Vector3 = (hold_target as Vector3) - sp
			angle_t = atan2(to.y, to.x)
			length_t = clampf(Vector2(to.x, to.y).length() - 0.02, 0.17, 0.95)
			grip_t = 1.0
		if fling_t > 0.0:
			angle_t = 0.35
			length_t = 0.55
		var angle: float = lerpf(arm.angle, angle_t, ak)
		var length: float = lerpf(arm.length, length_t, ak)
		var grip: float = lerpf(arm.grip, grip_t, ak)
		arm.angle = angle
		arm.length = length
		arm.grip = grip
		shoulder.rotation.z = angle
		var boom: MeshInstance3D = arm.boom
		var sleeve: MeshInstance3D = arm.sleeve
		var outer := minf(length, 0.3)
		boom.scale.x = outer
		boom.position.x = outer * 0.5
		sleeve.scale.x = length
		sleeve.position.x = length * 0.5
		var hand: Node3D = arm.hand
		hand.position.x = length
		hand.rotation.z = -angle * 0.8         # keep the gripper roughly level
		var f_open := lerpf(0.5, 0.05, grip)
		for fg in arm.fingers:
			var finger: Node3D = fg
			finger.rotation.y = -arm_side * f_open   # open outward, close onto the object

	# Status light colour follows the state machine.
	var c := Color(0.2, 0.6, 1.0)
	match state:
		"Idle": c = Color(0.3, 0.8, 1.0) * (0.6 + 0.4 * sin(t * 2.0))
		"Carry", "PickUp": c = Color(0.25, 1.0, 0.45)
		"Blocked": c = Color(1.0, 0.45, 0.1)
		"Done": c = Color(1.0, 1.0, 1.0)
		"Drop": c = Color(1.0, 0.3, 0.85)
	led_mat.emission = c
	led_mat.albedo_color = c


## A quick forward-up arm swing for throws.
func fling() -> void:
	fling_t = 0.3


## A jolt for collisions.
func bump() -> void:
	pitch_vel -= 3.5
