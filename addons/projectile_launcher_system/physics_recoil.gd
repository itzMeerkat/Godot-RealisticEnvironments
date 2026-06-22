class_name PhysicsRecoil
extends Node
## Applies an opposite impulse to a RigidBody3D whenever a launcher fires.

@export var rigid_body_path: NodePath
@export var impulse_point_path: NodePath
@export var use_shot_muzzle_as_impulse_point := true
@export var use_projectile_momentum := true
@export_range(0.0, 10000.0, 0.001, "or_greater") var impulse_multiplier := 1.0
@export_range(0.0, 1000000.0, 0.001, "or_greater") var fallback_impulse := 100.0

var rigid_body: RigidBody3D
var impulse_point: Node3D


func _ready() -> void:
	_resolve_nodes()


func apply_recoil(fire_direction: Vector3, shot_data := {}) -> void:
	if rigid_body == null:
		_resolve_nodes()
	if rigid_body == null:
		return

	var direction := fire_direction.normalized()
	if direction.length_squared() <= 0.0001:
		return

	var impulse_magnitude := fallback_impulse
	var strength := 1.0
	if shot_data is Dictionary:
		strength = float(shot_data.get("recoil_strength", 1.0))
		if use_projectile_momentum:
			var projectile_mass := maxf(float(shot_data.get("projectile_mass", 0.0)), 0.0)
			var initial_speed := maxf(float(shot_data.get("initial_speed", 0.0)), 0.0)
			impulse_magnitude = projectile_mass * initial_speed

	var impulse := -direction * impulse_magnitude * impulse_multiplier * maxf(strength, 0.0)
	var point_offset := _get_impulse_point_offset(shot_data)
	if point_offset != null:
		rigid_body.apply_impulse(impulse, point_offset)
	else:
		rigid_body.apply_central_impulse(impulse)


func _resolve_nodes() -> void:
	if not rigid_body_path.is_empty():
		rigid_body = get_node_or_null(rigid_body_path) as RigidBody3D
	if rigid_body == null:
		rigid_body = _find_parent_rigid_body()
	_resolve_impulse_point()


func _resolve_impulse_point() -> void:
	if not impulse_point_path.is_empty():
		impulse_point = get_node_or_null(impulse_point_path) as Node3D
	else:
		impulse_point = null


func _get_impulse_point_offset(shot_data: Variant) -> Variant:
	if use_shot_muzzle_as_impulse_point and shot_data is Dictionary and shot_data.has("muzzle_transform"):
		var muzzle_transform: Transform3D = shot_data["muzzle_transform"]
		return muzzle_transform.origin - rigid_body.global_position

	_resolve_impulse_point()
	if impulse_point != null:
		return impulse_point.global_position - rigid_body.global_position
	return null


func _find_parent_rigid_body() -> RigidBody3D:
	var node := get_parent()
	while node != null:
		if node is RigidBody3D:
			return node
		node = node.get_parent()
	return null
