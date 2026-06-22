class_name CannonSlideRecoil
extends Node
## Visual spring-damper recoil for a cannon barrel or carriage sliding on a local axis.

@export var target_path: NodePath
@export var recoil_axis := Vector3.BACK
@export_range(0.0, 100.0, 0.001, "or_greater") var kick_velocity_per_strength := 1.0
@export_range(0.0, 100.0, 0.001, "or_greater") var max_recoil_distance := 0.8
@export_range(0.0, 1000.0, 0.01, "or_greater") var spring_strength := 80.0
@export_range(0.0, 1000.0, 0.01, "or_greater") var damping := 14.0

var target: Node3D
var rest_position := Vector3.ZERO
var _recoil_offset := 0.0
var _recoil_velocity := 0.0


func _ready() -> void:
	_resolve_target()
	if target != null:
		rest_position = target.position


func _process(delta: float) -> void:
	if target == null:
		_resolve_target()
		if target == null:
			return
	_update_recoil(delta)


func apply_recoil(_fire_direction: Vector3, shot_data := {}) -> void:
	var strength := 1.0
	if shot_data is Dictionary:
		strength = float(shot_data.get("recoil_strength", 1.0))
	_recoil_velocity += maxf(strength, 0.0) * kick_velocity_per_strength


func reset_recoil() -> void:
	_recoil_offset = 0.0
	_recoil_velocity = 0.0
	if target != null:
		target.position = rest_position


func reset_rest_position() -> void:
	_resolve_target()
	if target != null:
		rest_position = target.position
		_recoil_offset = 0.0
		_recoil_velocity = 0.0


func _update_recoil(delta: float) -> void:
	var acceleration := -_recoil_offset * spring_strength - _recoil_velocity * damping
	_recoil_velocity += acceleration * delta
	_recoil_offset += _recoil_velocity * delta

	if _recoil_offset < 0.0:
		_recoil_offset = 0.0
		if _recoil_velocity < 0.0:
			_recoil_velocity = 0.0
	elif _recoil_offset > max_recoil_distance:
		_recoil_offset = max_recoil_distance
		if _recoil_velocity > 0.0:
			_recoil_velocity = 0.0

	var axis := _get_axis_in_target_parent_space()
	target.position = rest_position + axis * _recoil_offset


func _resolve_target() -> void:
	if not target_path.is_empty():
		target = get_node_or_null(target_path) as Node3D
	if target == null:
		target = get_parent() as Node3D


func _get_axis_in_target_parent_space() -> Vector3:
	var local_axis := recoil_axis.normalized()
	if local_axis.length_squared() <= 0.0001:
		local_axis = Vector3.BACK
	return (target.transform.basis.orthonormalized() * local_axis).normalized()
