@tool
class_name ProjectileLauncher
extends Node3D
## Spawns physical projectiles, muzzle flashes, and notifies recoil receivers.

signal fired(projectile: Node, fire_direction: Vector3, shot_data: Dictionary)

const DEFAULT_PROJECTILE_SCENE := preload("res://addons/projectile_launcher_system/default_projectile.tscn")
const DEFAULT_MUZZLE_FLASH_SCENE := preload("res://addons/projectile_launcher_system/default_muzzle_flash.tscn")
const DEBUG_ARROW_NODE_NAME := &"DebugFireDirectionArrow"

@export_group("Launch")
@export var muzzle_path: NodePath
@export var projectile_parent_path: NodePath
@export var projectile_scene: PackedScene
@export_range(0.001, 10000.0, 0.001, "or_greater") var projectile_mass := 1.0
@export_range(0.0, 10000.0, 0.1, "or_greater") var initial_speed := 60.0
@export_range(0.0, 100.0, 0.001, "or_greater") var drag_coefficient := 0.0
@export_range(0.0, 120.0, 0.01, "or_greater") var projectile_lifetime := 10.0
@export var inherit_launcher_velocity := true

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

@export_group("Debug")
@export var debug_draw_fire_direction := false:
	set(value):
		debug_draw_fire_direction = value
		_update_debug_arrow()
@export_range(0.1, 100.0, 0.01, "or_greater") var debug_arrow_length := 3.0:
	set(value):
		debug_arrow_length = maxf(value, 0.1)
		_update_debug_arrow()
@export_range(0.01, 10.0, 0.01, "or_greater") var debug_arrow_head_length := 0.45:
	set(value):
		debug_arrow_head_length = maxf(value, 0.01)
		_update_debug_arrow()
@export_range(1.0, 89.0, 0.1, "degrees") var debug_arrow_head_angle_degrees := 25.0:
	set(value):
		debug_arrow_head_angle_degrees = clampf(value, 1.0, 89.0)
		_update_debug_arrow()
@export var debug_arrow_color := Color(1.0, 0.35, 0.05, 1.0):
	set(value):
		debug_arrow_color = value
		_update_debug_material()
@export var debug_arrow_on_top := true:
	set(value):
		debug_arrow_on_top = value
		_update_debug_material()

var _debug_arrow_instance: MeshInstance3D
var _debug_arrow_mesh := ImmediateMesh.new()
var _debug_arrow_material: StandardMaterial3D
var _previous_global_position := Vector3.ZERO
var _estimated_velocity := Vector3.ZERO
var _has_previous_global_position := false


func _ready() -> void:
	_previous_global_position = global_position if is_inside_tree() else position
	_has_previous_global_position = true
	_update_debug_arrow()


func _process(_delta: float) -> void:
	if debug_draw_fire_direction:
		_update_debug_arrow()


func _physics_process(delta: float) -> void:
	_update_estimated_velocity(delta)


func fire(direction := Vector3.ZERO) -> Node:
	var muzzle_transform := _get_muzzle_transform()
	var base_direction := direction.normalized()
	if base_direction.length_squared() <= 0.0001:
		base_direction = (-muzzle_transform.basis.z).normalized()
	if base_direction.length_squared() <= 0.0001:
		base_direction = Vector3.FORWARD

	var fire_direction := _apply_spread(base_direction)
	var inherited_velocity := get_inherited_velocity_at(muzzle_transform.origin)
	var projectile := _spawn_projectile(muzzle_transform, fire_direction, inherited_velocity)
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
		"inherited_velocity": inherited_velocity,
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


func get_muzzle_transform() -> Transform3D:
	return _get_muzzle_transform()


func get_inherited_velocity() -> Vector3:
	return get_inherited_velocity_at(global_position if is_inside_tree() else position)


func get_inherited_velocity_at(world_position: Vector3) -> Vector3:
	if not inherit_launcher_velocity:
		return Vector3.ZERO
	var rigid_body := _find_parent_rigid_body()
	if rigid_body != null:
		return rigid_body.linear_velocity + rigid_body.angular_velocity.cross(world_position - rigid_body.global_position)
	return _estimated_velocity


func _spawn_projectile(muzzle_transform: Transform3D, fire_direction: Vector3, inherited_velocity: Vector3) -> Node:
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
	if projectile is RigidBody3D:
		var body := projectile as RigidBody3D
		if not projectile.has_method(&"launch"):
			body.mass = maxf(projectile_mass, 0.001)
			body.linear_velocity = fire_direction.normalized() * maxf(initial_speed, 0.0)
			_set_property_if_present(body, &"drag_coefficient", drag_coefficient)
			_set_property_if_present(body, &"lifetime", projectile_lifetime)
		body.linear_velocity += inherited_velocity

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


func _update_estimated_velocity(delta: float) -> void:
	if Engine.is_editor_hint() or delta <= 0.0 or not is_inside_tree():
		return
	var current_position := global_position
	if _has_previous_global_position:
		_estimated_velocity = (current_position - _previous_global_position) / delta
	_previous_global_position = current_position
	_has_previous_global_position = true


func _find_parent_rigid_body() -> RigidBody3D:
	var node := get_parent()
	while node != null:
		if node is RigidBody3D:
			return node
		node = node.get_parent()
	return null


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


func _update_debug_arrow() -> void:
	if not is_inside_tree():
		return
	if not debug_draw_fire_direction:
		if _debug_arrow_instance != null:
			_debug_arrow_instance.visible = false
		return

	_ensure_debug_arrow_node()
	if _debug_arrow_instance == null:
		return

	var muzzle_transform := _get_muzzle_transform()
	var direction := (-muzzle_transform.basis.z).normalized()
	if direction.length_squared() <= 0.0001:
		direction = Vector3.FORWARD

	_debug_arrow_instance.visible = true
	_debug_arrow_instance.top_level = true
	_debug_arrow_instance.global_transform = Transform3D.IDENTITY
	_debug_arrow_mesh.clear_surfaces()
	_debug_arrow_mesh.surface_begin(Mesh.PRIMITIVE_LINES)

	var origin := muzzle_transform.origin
	var end := origin + direction * debug_arrow_length
	_debug_arrow_mesh.surface_add_vertex(origin)
	_debug_arrow_mesh.surface_add_vertex(end)

	var basis := _basis_for_direction(direction)
	var head_length := minf(debug_arrow_head_length, debug_arrow_length * 0.5)
	var head_side_offset := tan(deg_to_rad(debug_arrow_head_angle_degrees)) * head_length
	var back := basis.z * head_length
	var right := basis.x * head_side_offset
	var up := basis.y * head_side_offset
	_add_debug_arrow_head_line(end, back + right)
	_add_debug_arrow_head_line(end, back - right)
	_add_debug_arrow_head_line(end, back + up)
	_add_debug_arrow_head_line(end, back - up)

	_debug_arrow_mesh.surface_end()
	_update_debug_material()


func _add_debug_arrow_head_line(end: Vector3, offset: Vector3) -> void:
	_debug_arrow_mesh.surface_add_vertex(end)
	_debug_arrow_mesh.surface_add_vertex(end + offset)


func _ensure_debug_arrow_node() -> void:
	if _debug_arrow_instance != null and is_instance_valid(_debug_arrow_instance):
		return
	_debug_arrow_instance = get_node_or_null(NodePath(String(DEBUG_ARROW_NODE_NAME))) as MeshInstance3D
	if _debug_arrow_instance == null:
		_debug_arrow_instance = MeshInstance3D.new()
		_debug_arrow_instance.name = String(DEBUG_ARROW_NODE_NAME)
		add_child(_debug_arrow_instance, false, INTERNAL_MODE_BACK)
	_debug_arrow_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_debug_arrow_instance.extra_cull_margin = 10000.0
	_debug_arrow_instance.mesh = _debug_arrow_mesh
	_update_debug_material()


func _update_debug_material() -> void:
	if _debug_arrow_material == null:
		_debug_arrow_material = StandardMaterial3D.new()
		_debug_arrow_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_debug_arrow_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_debug_arrow_material.albedo_color = debug_arrow_color
	_debug_arrow_material.no_depth_test = debug_arrow_on_top
	if _debug_arrow_instance != null:
		_debug_arrow_instance.material_override = _debug_arrow_material
