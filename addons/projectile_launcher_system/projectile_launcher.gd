class_name ProjectileLauncher
extends Node3D
## Spawns physical projectiles, muzzle flashes, and notifies recoil receivers.

signal fired(projectile: Node, fire_direction: Vector3, shot_data: Dictionary)

const DEFAULT_PROJECTILE_SCENE := preload("res://addons/projectile_launcher_system/default_projectile.tscn")
const DEFAULT_MUZZLE_FLASH_SCENE := preload("res://addons/projectile_launcher_system/default_muzzle_flash.tscn")

@export_group("Launch")
@export var muzzle_path: NodePath
@export var projectile_parent_path: NodePath
@export var projectile_scene: PackedScene
@export_range(0.001, 10000.0, 0.001, "or_greater") var projectile_mass := 1.0
@export_range(0.0, 10000.0, 0.1, "or_greater") var initial_speed := 60.0
@export_range(0.0, 100.0, 0.001, "or_greater") var drag_coefficient := 0.0
@export_range(0.0, 120.0, 0.01, "or_greater") var projectile_lifetime := 10.0

@export_group("Collision")
@export var configure_projectile_collision := true
@export_flags_3d_physics var projectile_collision_layer: int = 2
@export_flags_3d_physics var projectile_collision_mask: int = 4

@export_group("Spread")
@export var spread_enabled := false
@export_range(0.0, 45.0, 0.01, "degrees") var spread_degrees := 0.0

@export_group("Muzzle Flash")
@export var muzzle_flash_scene: PackedScene
@export var muzzle_flash_parent_path: NodePath
@export_range(0.01, 10.0, 0.01, "or_greater") var muzzle_flash_lifetime := 0.25

@export_group("Recoil")
@export_range(0.0, 10000.0, 0.001, "or_greater") var recoil_strength := 1.0
@export var recoil_receiver_paths: Array[NodePath] = []


func fire(direction := Vector3.ZERO) -> Node:
	var muzzle_transform := _get_muzzle_transform()
	var base_direction := direction.normalized()
	if base_direction.length_squared() <= 0.0001:
		base_direction = (-muzzle_transform.basis.z).normalized()
	if base_direction.length_squared() <= 0.0001:
		base_direction = Vector3.FORWARD

	var fire_direction := _apply_spread(base_direction)
	var projectile := _spawn_projectile(muzzle_transform, fire_direction)
	_spawn_muzzle_flash(muzzle_transform, fire_direction)

	var shot_data := {
		"launcher": self,
		"projectile": projectile,
		"recoil_strength": recoil_strength,
		"projectile_mass": projectile_mass,
		"initial_speed": initial_speed,
		"drag_coefficient": drag_coefficient,
		"projectile_collision_layer": projectile_collision_layer,
		"projectile_collision_mask": projectile_collision_mask,
		"muzzle_transform": muzzle_transform,
	}
	_notify_recoil_receivers(fire_direction, shot_data)
	fired.emit(projectile, fire_direction, shot_data)
	return projectile


func _get_muzzle_transform() -> Transform3D:
	if not muzzle_path.is_empty():
		var muzzle := get_node_or_null(muzzle_path) as Node3D
		if muzzle != null:
			return muzzle.global_transform if muzzle.is_inside_tree() else muzzle.transform
	return global_transform if is_inside_tree() else transform


func _spawn_projectile(muzzle_transform: Transform3D, fire_direction: Vector3) -> Node:
	var scene := projectile_scene if projectile_scene != null else DEFAULT_PROJECTILE_SCENE
	var projectile := scene.instantiate()
	var parent := _resolve_parent(projectile_parent_path)
	parent.add_child(projectile)
	_configure_projectile_collision(projectile)

	var projectile_3d := projectile as Node3D
	if projectile_3d != null:
		var projectile_transform := Transform3D(_basis_for_direction(fire_direction), muzzle_transform.origin)
		if projectile_3d.is_inside_tree():
			projectile_3d.global_transform = projectile_transform
		else:
			projectile_3d.transform = projectile_transform

	if projectile.has_method(&"launch"):
		projectile.call(&"launch", fire_direction, initial_speed, projectile_mass, drag_coefficient, projectile_lifetime)
	elif projectile is RigidBody3D:
		var body := projectile as RigidBody3D
		body.mass = maxf(projectile_mass, 0.001)
		body.linear_velocity = fire_direction.normalized() * maxf(initial_speed, 0.0)
		_set_property_if_present(body, &"drag_coefficient", drag_coefficient)
		_set_property_if_present(body, &"lifetime", projectile_lifetime)

	return projectile


func _configure_projectile_collision(node: Node) -> void:
	if not configure_projectile_collision:
		return
	if node is CollisionObject3D:
		var collision_object := node as CollisionObject3D
		collision_object.collision_layer = projectile_collision_layer
		collision_object.collision_mask = projectile_collision_mask
	for child in node.get_children():
		var child_node := child as Node
		if child_node != null:
			_configure_projectile_collision(child_node)


func _spawn_muzzle_flash(muzzle_transform: Transform3D, fire_direction: Vector3) -> void:
	var scene := muzzle_flash_scene if muzzle_flash_scene != null else DEFAULT_MUZZLE_FLASH_SCENE
	if scene == null:
		return
	var effect := scene.instantiate()
	var parent := _resolve_parent(muzzle_flash_parent_path)
	parent.add_child(effect)

	var effect_3d := effect as Node3D
	if effect_3d != null:
		var effect_transform := Transform3D(_basis_for_direction(fire_direction), muzzle_transform.origin)
		if effect_3d.is_inside_tree():
			effect_3d.global_transform = effect_transform
		else:
			effect_3d.transform = effect_transform
	if effect.has_method(&"play"):
		effect.call(&"play")
	elif _object_has_property(effect, &"emitting"):
		effect.set(&"emitting", true)

	if muzzle_flash_lifetime > 0.0 and is_inside_tree():
		get_tree().create_timer(muzzle_flash_lifetime).timeout.connect(effect.queue_free)


func _notify_recoil_receivers(fire_direction: Vector3, shot_data: Dictionary) -> void:
	for path in recoil_receiver_paths:
		var receiver := get_node_or_null(path)
		if receiver != null and receiver.has_method(&"apply_recoil"):
			receiver.call(&"apply_recoil", fire_direction, shot_data)


func _resolve_parent(path: NodePath) -> Node:
	if not path.is_empty():
		var configured_parent := get_node_or_null(path)
		if configured_parent != null:
			return configured_parent
	var current_scene := get_tree().current_scene if is_inside_tree() else null
	if current_scene != null:
		return current_scene
	return get_parent() if get_parent() != null else self


func _apply_spread(direction: Vector3) -> Vector3:
	var normalized_direction := direction.normalized()
	if not spread_enabled or spread_degrees <= 0.0:
		return normalized_direction

	var cone_angle := deg_to_rad(spread_degrees)
	var cos_theta := lerpf(cos(cone_angle), 1.0, randf())
	var sin_theta := sqrt(maxf(1.0 - cos_theta * cos_theta, 0.0))
	var phi := randf() * TAU
	var local_direction := Vector3(cos(phi) * sin_theta, sin(phi) * sin_theta, -cos_theta)
	return (_basis_for_direction(normalized_direction) * local_direction).normalized()


func _basis_for_direction(direction: Vector3) -> Basis:
	var normalized_direction := direction.normalized()
	var up := Vector3.UP
	if absf(normalized_direction.dot(up)) > 0.98:
		up = Vector3.RIGHT
	return Basis.looking_at(normalized_direction, up)


func _set_property_if_present(object: Object, property_name: StringName, value: Variant) -> void:
	if _object_has_property(object, property_name):
		object.set(property_name, value)


func _object_has_property(object: Object, property_name: StringName) -> bool:
	for property in object.get_property_list():
		if property is Dictionary and property.get("name", "") == String(property_name):
			return true
	return false
