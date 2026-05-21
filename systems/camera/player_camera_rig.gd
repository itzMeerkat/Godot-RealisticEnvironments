class_name PlayerCameraRig
extends Node3D

enum CameraMode {
	FIRST_PERSON,
	THIRD_PERSON,
	FREE_LOOK,
}

@export var active_mode: CameraMode = CameraMode.THIRD_PERSON
@export var current_on_ready := true

@export_group("Targets")
@export var follow_target_path: NodePath
@export var first_person_anchor_path: NodePath
@export var third_person_focus_path: NodePath

@export_group("Input")
@export var enable_camera_movement := true
@export var cycle_mode_action: StringName = &"toggle_camera_follow"
@export var move_forward_action: StringName = &"camera_move_forward"
@export var move_back_action: StringName = &"camera_move_back"
@export var move_left_action: StringName = &"camera_move_left"
@export var move_right_action: StringName = &"camera_move_right"
@export var move_up_action: StringName = &"camera_move_up"
@export var move_down_action: StringName = &"camera_move_down"
@export var boost_action: StringName = &"camera_boost"
@export_range(0.001, 0.02, 0.0001) var mouse_sensitivity := 0.003
@export var invert_mouse_y := false
@export_range(-89.0, 0.0, 0.1) var min_pitch_degrees := -75.0
@export_range(0.0, 89.0, 0.1) var max_pitch_degrees := 55.0

@export_group("Third Person")
@export var third_person_distance := 12.0
@export var third_person_side_offset := 0.0
@export_range(-60.0, 10.0, 0.1) var third_person_default_pitch_degrees := -18.0
@export_range(0.0, 30.0, 0.01) var position_smoothing := 8.0
@export_range(0.0, 30.0, 0.01) var rotation_smoothing := 12.0
@export_range(0.0, 10.0, 0.01) var recenter_delay := 1.2
@export_range(0.0, 20.0, 0.01) var recenter_smoothing := 3.0

@export_group("First Person")
@export_range(-45.0, 45.0, 0.1) var first_person_default_pitch_degrees := -4.0
@export var first_person_lock_to_anchor_transform := true
@export_range(0.0, 30.0, 0.01) var first_person_anchor_rotation_smoothing := 14.0

@export_group("Free Look")
@export var free_look_velocity := 5.0
@export var free_look_boost_multiplier := 3.0
@export var free_look_speed_scale := 1.17
@export var free_look_min_velocity := 0.2
@export var free_look_max_velocity := 1000.0

@export_group("Lens")
@export var base_fov := 70.0
@export var speed_fov_boost := 5.0
@export var speed_fov_reference := 18.0
@export_range(0.0, 30.0, 0.01) var fov_smoothing := 6.0

@onready var _yaw_pivot := $YawPivot as Node3D
@onready var _pitch_pivot := $YawPivot/PitchPivot as Node3D
@onready var _spring_arm := $YawPivot/PitchPivot/SpringArm3D as SpringArm3D
@onready var _camera := $YawPivot/PitchPivot/SpringArm3D/Camera3D as Camera3D

var _follow_target: Node3D
var _first_person_anchor: Node3D
var _third_person_focus: Node3D
var _look_yaw_offset := 0.0
var _pitch := 0.0
var _free_look_speed := 5.0
var _last_look_input_time := -1000.0
var _mode_initialized := false

func _ready() -> void:
	_free_look_speed = free_look_velocity
	_resolve_targets()
	if current_on_ready:
		_camera.make_current()
	else:
		_camera.current = false
	_camera.fov = base_fov
	_initialize_mode(active_mode, true)

func _input(event: InputEvent) -> void:
	if not _camera.current:
		return

	if event.is_action_pressed(cycle_mode_action):
		cycle_mode()
		return

	if event.is_action_pressed(&"ui_cancel"):
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
		return

	if not enable_camera_movement:
		return

	if event is InputEventMouseButton:
		_handle_mouse_button(event)
	elif event is InputEventMouseMotion and Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
		_handle_mouse_motion(event)

func _process(delta: float) -> void:
	if not _camera.current:
		return

	_resolve_targets()

	match active_mode:
		CameraMode.FIRST_PERSON:
			_update_first_person(delta)
		CameraMode.THIRD_PERSON:
			_update_third_person(delta)
		CameraMode.FREE_LOOK:
			_update_free_look(delta)

	_update_fov(delta)

func set_mode(mode: CameraMode) -> void:
	active_mode = mode
	_initialize_mode(mode, false)

func cycle_mode() -> void:
	match active_mode:
		CameraMode.THIRD_PERSON:
			set_mode(CameraMode.FIRST_PERSON)
		CameraMode.FIRST_PERSON:
			set_mode(CameraMode.FREE_LOOK)
		_:
			set_mode(CameraMode.THIRD_PERSON)

func get_camera() -> Camera3D:
	return _camera

func set_target_paths(follow_path: NodePath, first_person_path: NodePath, third_person_path: NodePath) -> void:
	follow_target_path = follow_path
	first_person_anchor_path = first_person_path
	third_person_focus_path = third_person_path
	_follow_target = null
	_first_person_anchor = null
	_third_person_focus = null
	_resolve_targets()
	_initialize_mode(active_mode, true)

func _handle_mouse_button(event: InputEventMouseButton) -> void:
	match event.button_index:
		MOUSE_BUTTON_RIGHT:
			Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED if event.pressed else Input.MOUSE_MODE_VISIBLE)
		MOUSE_BUTTON_WHEEL_UP:
			_free_look_speed = clampf(_free_look_speed * free_look_speed_scale, free_look_min_velocity, free_look_max_velocity)
		MOUSE_BUTTON_WHEEL_DOWN:
			_free_look_speed = clampf(_free_look_speed / free_look_speed_scale, free_look_min_velocity, free_look_max_velocity)

func _handle_mouse_motion(event: InputEventMouseMotion) -> void:
	_look_yaw_offset -= event.relative.x * mouse_sensitivity
	var y_sign := -1.0 if invert_mouse_y else 1.0
	_pitch -= event.relative.y * mouse_sensitivity * y_sign
	_pitch = clampf(_pitch, deg_to_rad(min_pitch_degrees), deg_to_rad(max_pitch_degrees))
	_last_look_input_time = Time.get_ticks_msec() / 1000.0

func _update_first_person(delta: float) -> void:
	var anchor := _first_person_anchor if _first_person_anchor != null else _follow_target
	if anchor == null:
		return

	_spring_arm.spring_length = 0.0
	if first_person_lock_to_anchor_transform:
		global_transform = _smooth_anchor_transform(
			global_transform,
			_get_anchor_transform(anchor),
			first_person_anchor_rotation_smoothing,
			delta
		)
		_apply_view_rotation(_look_yaw_offset, _pitch, delta)
	else:
		var target_position := anchor.global_position
		global_position = _smooth_vector(global_position, target_position, position_smoothing, delta)
		_apply_view_rotation(_get_target_yaw() + _look_yaw_offset, _pitch, delta)

func _update_third_person(delta: float) -> void:
	var focus := _third_person_focus if _third_person_focus != null else _follow_target
	if focus == null:
		return

	_spring_arm.spring_length = third_person_distance
	var target_position := focus.global_position
	var target_yaw := _get_target_yaw()
	var right := Basis(Vector3.UP, target_yaw + _look_yaw_offset) * Vector3.RIGHT
	target_position += right * third_person_side_offset
	global_position = _smooth_vector(global_position, target_position, position_smoothing, delta)
	global_transform = Transform3D(Basis.IDENTITY, global_position)
	_recenter_look(delta)
	_apply_view_rotation(target_yaw + _look_yaw_offset, _pitch, delta)

func _update_free_look(delta: float) -> void:
	_spring_arm.spring_length = 0.0
	if not enable_camera_movement:
		_apply_view_rotation(_look_yaw_offset, _pitch, delta)
		return

	var direction := _get_free_look_direction()
	var speed := _free_look_speed * (free_look_boost_multiplier if _is_boost_pressed() else 1.0)
	global_position += _camera.global_transform.basis * direction * speed * delta
	_apply_view_rotation(_look_yaw_offset, _pitch, delta)

func _apply_view_rotation(target_yaw: float, target_pitch: float, delta: float) -> void:
	var weight := _smoothing_weight(rotation_smoothing, delta)
	_yaw_pivot.rotation.y = lerp_angle(_yaw_pivot.rotation.y, target_yaw, weight)
	_pitch_pivot.rotation.x = lerp_angle(_pitch_pivot.rotation.x, target_pitch, weight)

func _recenter_look(delta: float) -> void:
	if recenter_smoothing <= 0.0:
		return
	var now := Time.get_ticks_msec() / 1000.0
	if now - _last_look_input_time < recenter_delay:
		return
	var weight := _smoothing_weight(recenter_smoothing, delta)
	_look_yaw_offset = lerp_angle(_look_yaw_offset, 0.0, weight)
	_pitch = lerp_angle(_pitch, deg_to_rad(third_person_default_pitch_degrees), weight)

func _update_fov(delta: float) -> void:
	var target_fov := base_fov
	if active_mode == CameraMode.THIRD_PERSON and _follow_target is RigidBody3D and speed_fov_reference > 0.0:
		var speed_ratio := clampf((_follow_target as RigidBody3D).linear_velocity.length() / speed_fov_reference, 0.0, 1.0)
		target_fov += speed_fov_boost * speed_ratio
	var weight := _smoothing_weight(fov_smoothing, delta)
	_camera.fov = lerpf(_camera.fov, target_fov, weight)

func _initialize_mode(mode: CameraMode, snap: bool) -> void:
	if not is_node_ready():
		return

	_pitch = deg_to_rad(first_person_default_pitch_degrees if mode == CameraMode.FIRST_PERSON else third_person_default_pitch_degrees)
	_look_yaw_offset = 0.0
	_last_look_input_time = -1000.0
	_spring_arm.spring_length = 0.0 if mode != CameraMode.THIRD_PERSON else third_person_distance
	var first_person_anchor_locked := mode == CameraMode.FIRST_PERSON and first_person_lock_to_anchor_transform

	if mode == CameraMode.FREE_LOOK:
		var camera_transform := _camera.global_transform
		global_transform = Transform3D(Basis.IDENTITY, camera_transform.origin)
		var camera_rotation := camera_transform.basis.get_euler()
		_yaw_pivot.rotation = Vector3.ZERO
		_pitch_pivot.rotation = Vector3.ZERO
		_look_yaw_offset = camera_rotation.y
		_pitch = camera_rotation.x
		_yaw_pivot.rotation.y = _look_yaw_offset
		_pitch_pivot.rotation.x = _pitch
	elif snap or not _mode_initialized:
		var anchor := _first_person_anchor if mode == CameraMode.FIRST_PERSON else _third_person_focus
		if anchor == null:
			anchor = _follow_target
		if anchor != null:
			if first_person_anchor_locked:
				global_transform = _get_anchor_transform(anchor)
			else:
				global_transform = Transform3D(Basis.IDENTITY, anchor.global_position)
		_yaw_pivot.rotation.y = 0.0 if first_person_anchor_locked else _get_target_yaw()
		_pitch_pivot.rotation.x = _pitch

	_mode_initialized = true

func _resolve_targets() -> void:
	if _follow_target == null and not follow_target_path.is_empty():
		_follow_target = get_node_or_null(follow_target_path) as Node3D
	if _first_person_anchor == null and not first_person_anchor_path.is_empty():
		_first_person_anchor = get_node_or_null(first_person_anchor_path) as Node3D
	if _third_person_focus == null and not third_person_focus_path.is_empty():
		_third_person_focus = get_node_or_null(third_person_focus_path) as Node3D

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

func _get_target_yaw() -> float:
	if _follow_target == null:
		return _yaw_pivot.rotation.y
	var back := _follow_target.global_transform.basis.z
	back.y = 0.0
	if back.length_squared() < 0.0001:
		return _yaw_pivot.rotation.y
	back = back.normalized()
	return atan2(back.x, back.z)

func _get_anchor_transform(anchor: Node3D) -> Transform3D:
	return Transform3D(anchor.global_transform.basis.orthonormalized(), anchor.global_position)

func _smooth_anchor_transform(from: Transform3D, to: Transform3D, rotation_smoothing_value: float, delta: float) -> Transform3D:
	var weight := _smoothing_weight(rotation_smoothing_value, delta)
	var basis := from.basis.slerp(to.basis, weight).orthonormalized()
	return Transform3D(basis, to.origin)

func _smooth_vector(from: Vector3, to: Vector3, smoothing: float, delta: float) -> Vector3:
	return from.lerp(to, _smoothing_weight(smoothing, delta))

func _smoothing_weight(smoothing: float, delta: float) -> float:
	return 1.0 if smoothing <= 0.0 else 1.0 - exp(-smoothing * delta)
