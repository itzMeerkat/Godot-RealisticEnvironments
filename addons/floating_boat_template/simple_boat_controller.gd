class_name SimpleBoatController
extends Node
## Lightweight player input for a floating boat. It applies forces to the parent RigidBody3D.

@export var enabled := true
@export var move_forward_action: StringName = &"camera_move_forward"
@export var move_back_action: StringName = &"camera_move_back"
@export var turn_left_action: StringName = &"camera_move_left"
@export var turn_right_action: StringName = &"camera_move_right"
@export_range(0.0, 20.0, 0.01, "or_greater") var max_forward_speed := 5.0
@export_range(0.0, 20.0, 0.01, "or_greater") var max_reverse_speed := 1.8
@export_range(0.0, 20.0, 0.01, "or_greater") var forward_acceleration := 2.4
@export_range(0.0, 20.0, 0.01, "or_greater") var reverse_acceleration := 1.2
@export_range(0.0, 40.0, 0.01, "or_greater") var turn_torque_per_kg := 12.0
@export_range(0.0, 1.0, 0.01) var low_speed_turn_factor := 0.55
@export_range(0.0, 20.0, 0.01, "or_greater") var extra_lateral_damping := 0.9

var rigid_body : RigidBody3D


func _enter_tree() -> void:
	add_to_group(&"boat_controller")


func _exit_tree() -> void:
	remove_from_group(&"boat_controller")


func _ready() -> void:
	rigid_body = get_parent() as RigidBody3D


func _physics_process(_delta: float) -> void:
	if not enabled:
		return
	if rigid_body == null:
		rigid_body = get_parent() as RigidBody3D
	if rigid_body == null:
		return

	var throttle := Input.get_action_strength(move_forward_action) - Input.get_action_strength(move_back_action)
	var turn_input := Input.get_action_strength(turn_left_action) - Input.get_action_strength(turn_right_action)
	var forward := -rigid_body.global_transform.basis.z
	forward.y = 0.0
	forward = forward.normalized() if forward.length_squared() > 0.0001 else Vector3.FORWARD
	var right := rigid_body.global_transform.basis.x
	right.y = 0.0
	right = right.normalized() if right.length_squared() > 0.0001 else Vector3.RIGHT

	var horizontal_velocity := Vector3(rigid_body.linear_velocity.x, 0.0, rigid_body.linear_velocity.z)
	var forward_speed := horizontal_velocity.dot(forward)
	var side_speed := horizontal_velocity.dot(right)
	_apply_throttle(throttle, forward, forward_speed)
	_apply_turn(turn_input, absf(forward_speed))
	_apply_lateral_damping(right, side_speed)


func _apply_throttle(throttle: float, forward: Vector3, forward_speed: float) -> void:
	if absf(throttle) <= 0.001:
		return
	var acceleration := forward_acceleration if throttle > 0.0 else reverse_acceleration
	var speed_limit := max_forward_speed if throttle > 0.0 else max_reverse_speed
	var speed_in_input_direction := forward_speed * signf(throttle)
	if speed_in_input_direction >= speed_limit:
		return
	rigid_body.apply_central_force(forward * throttle * acceleration * rigid_body.mass)


func _apply_turn(turn_input: float, forward_speed_abs: float) -> void:
	if absf(turn_input) <= 0.001:
		return
	var speed_factor := lerpf(low_speed_turn_factor, 1.0, clampf(forward_speed_abs / maxf(max_forward_speed, 0.001), 0.0, 1.0))
	rigid_body.apply_torque(Vector3.UP * turn_input * turn_torque_per_kg * rigid_body.mass * speed_factor)


func _apply_lateral_damping(right: Vector3, side_speed: float) -> void:
	if extra_lateral_damping <= 0.0 or absf(side_speed) <= 0.001:
		return
	rigid_body.apply_central_force(-right * side_speed * extra_lateral_damping * rigid_body.mass)
