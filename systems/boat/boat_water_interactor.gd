class_name BoatWaterInteractor
extends Node3D
## Adds immediate bow-side foam sources in world space.

@export var enabled := true
@export_range(0.0, 100.0, 0.01, "or_greater") var min_speed := 0.35
@export_range(0.01, 100.0, 0.01, "or_greater") var max_speed := 8.0
@export var bow_offset := Vector3(0.0, 0.0, -1.15)
@export_range(0.0, 20.0, 0.01, "or_greater") var side_offset := 0.38
@export_range(0.05, 20.0, 0.01, "or_greater") var bow_radius := 0.18
@export_range(0.05, 20.0, 0.01, "or_greater") var bow_streak_length := 1.15
@export_range(0.0, 2.0, 0.01) var outward_splay := 0.42
@export_range(0.0, 1.0, 0.001) var bow_foam_amount := 0.38

var rigid_body : RigidBody3D


func _enter_tree() -> void:
	add_to_group(&"boat_water_interactor")
	add_to_group(&"manual_water_foam_source")


func _exit_tree() -> void:
	remove_from_group(&"boat_water_interactor")
	remove_from_group(&"manual_water_foam_source")


func _ready() -> void:
	rigid_body = get_parent() as RigidBody3D


func get_manual_foam_sources() -> Array[Dictionary]:
	var sources : Array[Dictionary] = []
	if not enabled:
		return sources
	if rigid_body == null:
		rigid_body = get_parent() as RigidBody3D
	if rigid_body == null:
		return sources
	var horizontal_velocity := Vector3(rigid_body.linear_velocity.x, 0.0, rigid_body.linear_velocity.z)
	var speed := horizontal_velocity.length()
	if speed < min_speed:
		return sources
	var forward := -rigid_body.global_transform.basis.z
	forward.y = 0.0
	forward = forward.normalized() if forward.length_squared() > 0.0001 else Vector3.FORWARD
	var forward_speed := horizontal_velocity.dot(forward)
	var strength := clampf(maxf(forward_speed, 0.0) / maxf(max_speed, 0.001), 0.0, 1.0)
	if strength <= 0.001:
		return sources
	var right := rigid_body.global_transform.basis.x
	right.y = 0.0
	right = right.normalized() if right.length_squared() > 0.0001 else Vector3.RIGHT
	var bow_center := global_transform * bow_offset
	var amount := bow_foam_amount * strength
	_add_bow_streak(sources, bow_center, -forward, right, 1.0, amount)
	_add_bow_streak(sources, bow_center, -forward, right, -1.0, amount)
	return sources


func _add_bow_streak(sources: Array[Dictionary], bow_center: Vector3, backward: Vector3, right: Vector3, side_sign: float, amount: float) -> void:
	var direction := (backward + right * side_sign * outward_splay).normalized()
	var start := bow_center + right * side_offset * side_sign
	var center := start + direction * bow_streak_length * 0.45
	sources.push_back({
		"position": center,
		"radius": bow_radius,
		"amount": amount,
		"direction": direction,
		"length": bow_streak_length,
	})
