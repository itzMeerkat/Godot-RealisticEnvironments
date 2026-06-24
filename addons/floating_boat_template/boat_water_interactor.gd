class_name BoatWaterInteractor
extends Node3D
## Adds immediate bow-side foam sources in world space for a floating boat.

@export var enabled := true
@export_range(0.0, 100.0, 0.01, "or_greater") var min_speed := 0.35
@export_range(0.01, 100.0, 0.01, "or_greater") var max_speed := 8.0
@export var bow_offset := Vector3(0.0, 0.0, -1.15)
@export_range(0.0, 20.0, 0.01, "or_greater") var side_offset := 0.38
@export_range(0.05, 20.0, 0.01, "or_greater") var bow_radius := 0.18
@export_range(0.05, 20.0, 0.01, "or_greater") var bow_streak_length := 1.15
@export_range(0.0, 2.0, 0.01) var outward_splay := 0.42
@export_range(0.0, 1.0, 0.001) var bow_foam_amount := 0.38
@export var use_bow_contact_probes := true
@export var bow_probe_tag := "bow"
@export_range(0, 16, 1) var max_bow_probe_foam_sources := 4
@export_range(-1.0, 1.0, 0.001) var min_bow_probe_depth := -0.05

var rigid_body : RigidBody3D
var buoyant_body : BuoyantBody


func _enter_tree() -> void:
	add_to_group(&"boat_water_interactor")
	add_to_group(&"manual_water_foam_source")


func _exit_tree() -> void:
	remove_from_group(&"boat_water_interactor")
	remove_from_group(&"manual_water_foam_source")


func _ready() -> void:
	rigid_body = get_parent() as RigidBody3D
	buoyant_body = _find_buoyant_body()


func get_manual_foam_sources() -> Array[Dictionary]:
	var sources : Array[Dictionary] = []
	if not enabled or not is_visible_in_tree():
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
	if use_bow_contact_probes and _add_probe_bow_streaks(sources, -forward, right, strength) > 0:
		return sources
	var bow_center := global_transform * bow_offset
	var amount := bow_foam_amount * strength
	_add_bow_streak(sources, bow_center, -forward, right, 1.0, amount)
	_add_bow_streak(sources, bow_center, -forward, right, -1.0, amount)
	return sources


func _add_probe_bow_streaks(sources: Array[Dictionary], backward: Vector3, right: Vector3, strength: float) -> int:
	if buoyant_body == null:
		buoyant_body = _find_buoyant_body()
	if buoyant_body == null:
		return 0
	var states := buoyant_body.get_probe_states(bow_probe_tag)
	var added := 0
	for state in states:
		if added >= max_bow_probe_foam_sources:
			break
		var depth := float(state.get("depth", 0.0))
		if not bool(state.get("is_wet", false)) and depth < min_bow_probe_depth:
			continue
		var start : Vector3 = state.get("water_position", state.get("world_position", global_position))
		var side_sign := 1.0 if right.dot(start - rigid_body.global_position) >= 0.0 else -1.0
		var depth_strength := clampf((depth - min_bow_probe_depth) / maxf(0.35 - min_bow_probe_depth, 0.001), 0.0, 1.0)
		var amount := bow_foam_amount * strength * maxf(depth_strength, 0.25)
		_add_probe_bow_streak(sources, start, backward, right, side_sign, amount)
		added += 1
	return added


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


func _add_probe_bow_streak(sources: Array[Dictionary], start: Vector3, backward: Vector3, right: Vector3, side_sign: float, amount: float) -> void:
	var direction := (backward + right * side_sign * outward_splay).normalized()
	var center := start + direction * bow_streak_length * 0.45
	sources.push_back({
		"position": center,
		"radius": bow_radius,
		"amount": amount,
		"direction": direction,
		"length": bow_streak_length,
	})


func _find_buoyant_body() -> BuoyantBody:
	var parent_node := get_parent()
	if parent_node == null:
		return null
	for child in parent_node.get_children():
		var candidate := child as BuoyantBody
		if candidate != null:
			return candidate
	return null
