@tool
class_name GREProjectileHitbox
extends Area3D
## An Area3D that detects projectiles and reports their hits to its hitbox manager (a
## GREHitboxHealthManager it sits under, or manager_path). Give it collision shapes and
## a collision_mask that includes the projectiles' layer (the demo: layer 3
## "Hitbox", mask 2 "Projectile"). A projectile is a body in group "projectile" or
## with a launch() method.

## Emitted for every projectile hit on this hitbox, before the manager handles it.
signal projectile_hit(projectile: Node, hit_data: Dictionary)

## Enables projectile detection for this hitbox.
@export var enabled := true
## Health group affected by hits on this hitbox.
@export var hitbox_group: StringName = &"default"
## Per-hitbox multiplier applied to calculated or explicit hit damage.
@export_range(0.0, 100.0, 0.01, "or_greater") var damage_multiplier := 1.0
## The manager hits are reported to: any node with handle_projectile_hit() (a
## GREHitboxHealthManager). Empty: the nearest such ancestor.
@export var manager_path: NodePath :
	set(value):
		manager_path = value
		update_configuration_warnings()
## Minimum seconds before the same projectile can register another hit on this hitbox.
@export_range(0.0, 5.0, 0.001, "or_greater", "suffix:s") var same_projectile_hit_interval := 0.08

var _manager: Node
var _last_hit_time_by_projectile := {}


func _ready() -> void:
	if Engine.is_editor_hint():
		return
	_manager = _find_manager()
	if _manager == null:
		push_error("GREProjectileHitbox %s: no hitbox manager (manager_path, or a GREHitboxHealthManager ancestor); hits only emit projectile_hit." % get_path())
	body_entered.connect(_on_body_entered)


func _get_configuration_warnings() -> PackedStringArray:
	if _find_manager() == null:
		return PackedStringArray(["No hitbox manager: put this hitbox under a GREHitboxHealthManager or set manager_path. Hits then only emit projectile_hit."])
	return PackedStringArray()


func _on_body_entered(body: Node3D) -> void:
	if not enabled or not _is_projectile(body):
		return
	if _manager != null and _manager.has_method(&"should_ignore_projectile") and bool(_manager.call(&"should_ignore_projectile", body)):
		return
	if not _can_register_hit(body):
		return

	var hit_data := _build_hit_data(body)
	projectile_hit.emit(body, hit_data)
	if _manager != null:
		_manager.call(&"handle_projectile_hit", self, body, hit_data)


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


func _build_hit_data(projectile: Node3D) -> Dictionary:
	var projectile_body := projectile as RigidBody3D
	var velocity := Vector3.ZERO
	var projectile_mass := 0.0
	if projectile_body != null:
		velocity = projectile_body.linear_velocity
		projectile_mass = projectile_body.mass
	var momentum := velocity * projectile_mass
	return {
		"hitbox": self,
		"hitbox_group": hitbox_group,
		"damage_multiplier": damage_multiplier,
		"projectile": projectile,
		"position": projectile.global_position,
		"velocity": velocity,
		"speed": velocity.length(),
		"mass": projectile_mass,
		"momentum": momentum,
		"momentum_magnitude": momentum.length(),
	}


## The node at manager_path, else the nearest ancestor manager.
func _find_manager() -> Node:
	if not manager_path.is_empty():
		var configured := get_node_or_null(manager_path)
		return configured if _is_manager(configured) else null
	var ancestor := get_parent()
	while ancestor != null and not _is_manager(ancestor):
		ancestor = ancestor.get_parent()
	return ancestor


## A GREHitboxHealthManager (checked by type in the editor, where its script does not
## run), or any node with handle_projectile_hit().
static func _is_manager(node : Node) -> bool:
	return node is GREHitboxHealthManager or (node != null and node.has_method(&"handle_projectile_hit"))
