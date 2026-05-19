class_name BoatWakeTrail
extends Node3D
## World-space stern foam trail that is blended by the ocean shader.

@export var enabled := true
@export var stern_offset := Vector3(0.0, 0.0, 1.15)
@export_range(0.0, 100.0, 0.01, "or_greater") var min_speed := 0.45
@export_range(0.01, 100.0, 0.01, "or_greater") var max_speed := 5.0
@export_range(0.05, 20.0, 0.01, "or_greater") var min_radius := 0.18
@export_range(0.05, 20.0, 0.01, "or_greater") var max_radius := 0.58
@export_range(0.05, 20.0, 0.01, "or_greater") var point_spacing := 0.28
@export_range(0.1, 60.0, 0.01, "or_greater") var lifetime := 5.0
@export_range(0.0, 1.0, 0.001) var max_foam_amount := 0.58
@export_range(2, 96, 1) var max_points := 72

var rigid_body : RigidBody3D
var _positions := PackedVector3Array()
var _ages := PackedFloat32Array()
var _radii := PackedFloat32Array()
var _amounts := PackedFloat32Array()


func _enter_tree() -> void:
	add_to_group(&"boat_wake_trail")
	add_to_group(&"manual_water_foam_source")


func _exit_tree() -> void:
	remove_from_group(&"boat_wake_trail")
	remove_from_group(&"manual_water_foam_source")


func _ready() -> void:
	rigid_body = get_parent() as RigidBody3D


func _process(delta: float) -> void:
	if not enabled:
		_clear_trail()
		return
	if rigid_body == null:
		rigid_body = get_parent() as RigidBody3D
	if rigid_body == null:
		return
	_age_points(delta)
	_try_add_point()


func get_manual_foam_sources() -> Array[Dictionary]:
	var sources : Array[Dictionary] = []
	for reverse_i in _positions.size():
		var i := _positions.size() - 1 - reverse_i
		var age_t := clampf(_ages[i] / maxf(lifetime, 0.001), 0.0, 1.0)
		var amount := _amounts[i] * (1.0 - age_t) * (1.0 - age_t)
		var radius := _radii[i] * lerpf(1.0, 1.9, age_t)
		if amount <= 0.001:
			continue
		sources.push_back({"position": _positions[i], "radius": radius, "amount": amount})
	return sources


func _age_points(delta: float) -> void:
	for i in _ages.size():
		_ages[i] += delta
	while not _ages.is_empty() and _ages[0] > lifetime:
		_positions.remove_at(0)
		_ages.remove_at(0)
		_radii.remove_at(0)
		_amounts.remove_at(0)


func _try_add_point() -> void:
	var horizontal_velocity := Vector3(rigid_body.linear_velocity.x, 0.0, rigid_body.linear_velocity.z)
	var speed := horizontal_velocity.length()
	if speed < min_speed:
		return
	var forward := -rigid_body.global_transform.basis.z
	forward.y = 0.0
	forward = forward.normalized() if forward.length_squared() > 0.0001 else Vector3.FORWARD
	var forward_speed := horizontal_velocity.dot(forward)
	if forward_speed <= min_speed * 0.35:
		return
	var position := global_transform * stern_offset
	if not _positions.is_empty() and _positions[_positions.size() - 1].distance_to(position) < point_spacing:
		return
	var strength := clampf((speed - min_speed) / maxf(max_speed - min_speed, 0.001), 0.0, 1.0)
	_positions.push_back(position)
	_ages.push_back(0.0)
	_radii.push_back(lerpf(min_radius, max_radius, strength))
	_amounts.push_back(max_foam_amount * strength)
	while _positions.size() > max_points:
		_positions.remove_at(0)
		_ages.remove_at(0)
		_radii.remove_at(0)
		_amounts.remove_at(0)


func _clear_trail() -> void:
	_positions.clear()
	_ages.clear()
	_radii.clear()
	_amounts.clear()
