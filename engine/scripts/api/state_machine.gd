extends Node
## The robot's "what phase am I in" tracker (autoload name: StateMachine).
##
## States (brief): Idle -> Locate -> GoToObject -> PickUp -> Carry -> Drop -> Done, plus Blocked.
## The API server tells it what just happened; it decides the new state.
## It never knows anything about objects or the target: it only sees success/collision flags.
##
## Note for the robot (Yash): "no movement for 2 seconds" during a move should be reported
## by do_move() as collided = true. That is treated exactly like a collision here.

signal state_changed(new_state: String)

const MAX_RETRIES := 3  # brief: back off / turn / retry, fail after 3 retries

var state := "Idle"
var retries := 0
var outcome := ""  # pass | fail_wrong_object | fail_not_reached | fail_collision


func _set_state(s: String) -> void:
	if s != state:
		state = s
		state_changed.emit(s)


func is_done() -> bool:
	return state == "Done"


func reset() -> void:
	retries = 0
	outcome = ""
	_set_state("Idle")


func start_run() -> void:
	retries = 0
	outcome = ""
	_set_state("Locate")


func end_run(result: String) -> void:
	outcome = result
	_set_state("Done")


func on_turn(holding: bool) -> void:
	# Turning after a block is the recovery; turning otherwise means searching or aiming.
	_set_state("Carry" if holding else "Locate")


func on_move(collided: bool, holding: bool) -> void:
	if collided:
		retries += 1
		if retries > MAX_RETRIES:
			end_run("fail_collision")
		else:
			_set_state("Blocked")
	else:
		_set_state("Carry" if holding else "GoToObject")


func on_pickup_attempt() -> void:
	_set_state("PickUp")


func on_pickup(success: bool) -> void:
	_set_state("Carry" if success else "GoToObject")


func on_drop(in_zone: bool) -> void:
	_set_state("Drop")
	if in_zone:
		end_run("pass")


## The only fields /state may expose from here.
func snapshot() -> Dictionary:
	return {"state": state, "retries": retries}
