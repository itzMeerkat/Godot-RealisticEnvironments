class_name ProjectileHitbox
extends Area3D
## Area3D hitbox that reports projectile impacts to a compatible hitbox manager.

signal projectile_hit(projectile: Node, hit_data: Dictionary)

## Enables projectile detection for this hitbox.
@export var enabled := true
## Health group affected by hits on this hitbox.
@export var hitbox_group: StringName = &"default"
## Per-hitbox multiplier applied to calculated or explicit hit damage.
@export_range(0.0, 100.0, 0.01, "or_greater") var damage_multiplier := 1.0
## Optional HitboxHealthManager path. Leave empty to find the nearest compatible manager.
@export var manager_path: NodePath
## Applies hitbox_collision_layer and projectile_collision_mask in _ready().
@export var configure_collision_layers := true
## Physics layer assigned to this Area3D when configure_collision_layers is enabled.
@export_flags_3d_physics var hitbox_collision_layer: int = 4
## Physics mask used to detect projectile bodies when configure_collision_layers is enabled.
@export_flags_3d_physics var projectile_collision_mask: int = 2
## Minimum seconds before the same projectile can register another hit on this hitbox.
@export_range(0.0, 5.0, 0.001, "or_greater") var same_projectile_hit_interval := 0.08

var _manager: Node
var _last_hit_time_by_projectile := {}


func _ready() -> void:
	if configure_collision_layers:
		collision_layer = hitbox_collision_layer
		collision_mask = projectile_collision_mask
	monitoring = true
	monitorable = true
	if not body_entered.is_connected(_on_body_entered):
		body_entered.connect(_on_body_entered)


func set_manager(manager: Node) -> void:
	_manager = manager


func _on_body_entered(body: Node3D) -> void:
	if not enabled or body == null:
		return
	if not _is_projectile(body):
		return
	var manager := _resolve_manager()
	if manager != null and manager.has_method(&"should_ignore_projectile") and bool(manager.call(&"should_ignore_projectile", body, self)):
		return
	if not _can_register_hit(body):
		return

	var hit_data := _build_hit_data(body)
	projectile_hit.emit(body, hit_data)
	if manager != null and manager.has_method(&"handle_projectile_hit"):
		manager.call(&"handle_projectile_hit", self, body, hit_data)


func _is_projectile(body: Node) -> bool:
	return body.is_in_group(&"projectile") or body.has_method(&"launch")


func _can_register_hit(projectile: Node) -> bool:
	if same_projectile_hit_interval <= 0.0:
		return true
	var now := float(Time.get_ticks_msec()) * 0.001
	var key := projectile.get_instance_id()
	var last_time := float(_last_hit_time_by_projectile.get(key, -1.0e20))
	if now - last_time < same_projectile_hit_interval:
		return false
	_last_hit_time_by_projectile[key] = now
	return true


func _build_hit_data(projectile: Node) -> Dictionary:
	var projectile_body := projectile as RigidBody3D
	var velocity := Vector3.ZERO
	var projectile_mass := 0.0
	if projectile_body != null:
		velocity = projectile_body.linear_velocity
		projectile_mass = projectile_body.mass
	var momentum := velocity * projectile_mass
	var impact_position := global_position
	var projectile_3d := projectile as Node3D
	if projectile_3d != null:
		impact_position = projectile_3d.global_position
	return {
		"hitbox": self,
		"hitbox_group": hitbox_group,
		"damage_multiplier": damage_multiplier,
		"projectile": projectile,
		"position": impact_position,
		"velocity": velocity,
		"speed": velocity.length(),
		"mass": projectile_mass,
		"momentum": momentum,
		"momentum_magnitude": momentum.length(),
	}


func _resolve_manager() -> Node:
	if _manager != null and is_instance_valid(_manager):
		return _manager
	if not manager_path.is_empty():
		_manager = get_node_or_null(manager_path)
		if _manager != null:
			return _manager
	_manager = _find_nearest_manager()
	return _manager


func _find_nearest_manager() -> Node:
	var ancestor := get_parent()
	while ancestor != null:
		var manager := _find_manager_descendant(ancestor)
		if manager != null:
			return manager
		ancestor = ancestor.get_parent()
	return null


func _find_manager_descendant(root: Node) -> Node:
	if root != self and root.has_method(&"handle_projectile_hit"):
		return root
	for child in root.get_children():
		var child_node := child as Node
		if child_node == null or child_node == self:
			continue
		var manager := _find_manager_descendant(child_node)
		if manager != null:
			return manager
	return null
