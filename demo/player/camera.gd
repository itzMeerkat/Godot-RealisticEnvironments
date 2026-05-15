#Copyright © 2022 Marc Nahr: https://github.com/MarcPhi/godot-free-look-camera
extends Camera3D

@export_range(0, 10, 0.01) var sensitivity : float = 3
@export_range(0, 1000, 0.1) var default_velocity : float = 5
@export_range(0, 10, 0.01) var speed_scale : float = 1.17
@export_range(1, 100, 0.1) var boost_speed_multiplier : float = 3.0
@export var max_speed : float = 1000
@export var min_speed : float = 0.2
@export var move_forward_action: StringName = &"camera_move_forward"
@export var move_back_action: StringName = &"camera_move_back"
@export var move_left_action: StringName = &"camera_move_left"
@export var move_right_action: StringName = &"camera_move_right"
@export var move_up_action: StringName = &"camera_move_up"
@export var move_down_action: StringName = &"camera_move_down"
@export var boost_action: StringName = &"camera_boost"
@export_group("Third Person Follow")
@export var follow_target_path : NodePath
@export var enable_follow_target := false
@export var follow_distance := 9.0
@export var follow_height := 4.0
@export var follow_side_offset := 0.0
@export_range(0.0, 30.0, 0.01) var follow_position_smoothing := 8.0
@export_range(0.0, 30.0, 0.01) var follow_rotation_smoothing := 10.0
@export var look_at_height := 0.5

@onready var _velocity = default_velocity

var enable_camera_movement := true
var _follow_target : Node3D

func _ready() -> void:
	DemoInputActions.ensure_defaults()

func _input(event):
	if not current:
		return

	if event.is_action_pressed(&'toggle_camera_follow'):
		enable_follow_target = not enable_follow_target
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
		return

	if not enable_camera_movement:
		return

	if Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
		if event is InputEventMouseMotion:
			rotation.y -= event.relative.x / 1000 * sensitivity
			rotation.x -= event.relative.y / 1000 * sensitivity
			rotation.x = clamp(rotation.x, PI/-2, PI/2)

	if event is InputEventMouseButton:
		match event.button_index:
			MOUSE_BUTTON_RIGHT:
				Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED if event.pressed else Input.MOUSE_MODE_VISIBLE)
			MOUSE_BUTTON_WHEEL_UP: # increase fly velocity
				_velocity = clamp(_velocity * speed_scale, min_speed, max_speed)
			MOUSE_BUTTON_WHEEL_DOWN: # decrease fly velocity
				_velocity = clamp(_velocity / speed_scale, min_speed, max_speed)

func _process(delta):
	if not current:
		return
	if enable_follow_target:
		_update_follow_target(delta)
		return

	var direction = _get_free_look_direction()

	if _is_boost_pressed(): # boost
		translate(direction * _velocity * delta * boost_speed_multiplier)
	else:
		translate(direction * _velocity * delta)

func _update_follow_target(delta: float) -> void:
	if _follow_target == null:
		_follow_target = get_node_or_null(follow_target_path) as Node3D
	if _follow_target == null:
		return

	var basis := _follow_target.global_transform.basis.orthonormalized()
	var target_position := (
		_follow_target.global_position
		+ basis.z * follow_distance
		+ basis.y * follow_height
		+ basis.x * follow_side_offset
	)
	var position_weight := 1.0 if follow_position_smoothing <= 0.0 else 1.0 - exp(-follow_position_smoothing * delta)
	global_position = global_position.lerp(target_position, position_weight)

	var look_position := _follow_target.global_position + basis.y * look_at_height
	var target_transform := global_transform.looking_at(look_position, Vector3.UP)
	var rotation_weight := 1.0 if follow_rotation_smoothing <= 0.0 else 1.0 - exp(-follow_rotation_smoothing * delta)
	var smoothed_basis := global_transform.basis.slerp(target_transform.basis, rotation_weight).orthonormalized()
	global_transform = Transform3D(smoothed_basis, global_position)

func _get_free_look_direction() -> Vector3:
	var horizontal := Input.get_vector(move_left_action, move_right_action, move_forward_action, move_back_action)
	var direction := Vector3(
		horizontal.x,
		_get_vertical_axis(),
		horizontal.y
	)
	return direction.normalized()

func _get_vertical_axis() -> float:
	var value := 0.0
	if InputMap.has_action(move_up_action):
		value += Input.get_action_strength(move_up_action)
	if InputMap.has_action(move_down_action):
		value -= Input.get_action_strength(move_down_action)
	return value

func _is_boost_pressed() -> bool:
	return InputMap.has_action(boost_action) and Input.is_action_pressed(boost_action)
