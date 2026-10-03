class_name HitboxHealthManager
extends Node3D
## Hitbox container and damage router: ProjectileHitbox descendants report
## projectile impacts here, which become per-group health, signals and hit
## effects. Optionally shows a health-bar debug panel.

const DEBUG_SCREEN_POSITION := Vector2(24.0, 88.0)
const DEBUG_PANEL_WIDTH := 260.0

signal hitbox_hit(hitbox_group: StringName, hitbox: Node, projectile: Node, hit_data: Dictionary)
signal group_health_changed(hitbox_group: StringName, health: float, max_health: float, hit_data: Dictionary)
signal group_destroyed(hitbox_group: StringName, hit_data: Dictionary)

## Enables damage routing, health changes, hit effects, and projectile cleanup.
@export var enabled := true
## Optional owner rigid body used for own-projectile filtering. Leave empty to find an ancestor.
@export var owner_rigid_body_path: NodePath

@export_group("Projectile Filtering")
## Ignores projectiles whose source metadata points back to owner_rigid_body_path.
@export var ignore_own_projectiles := true

@export_group("Damage")
## Converts projectile momentum magnitude into damage when hit data has no explicit damage.
@export_range(0.0, 1000.0, 0.001, "or_greater") var damage_per_momentum := 0.03
## Minimum damage applied by momentum-based hits.
@export_range(0.0, 1000.0, 0.001, "or_greater") var minimum_hit_damage := 1.0
## Max health used for hitbox groups not listed in group_max_health.
@export_range(0.0, 1000000.0, 0.1, "or_greater") var default_group_max_health := 100.0
## Per-hitbox-group max health map, for example {"hull": 300.0, "mast": 60.0}.
@export var group_max_health := {
	"default": 100.0,
}
## Per-hitbox-group damage multiplier map applied before hitbox damage_multiplier.
@export var group_damage_multipliers := {}
## Frees the projectile after a registered hit.
@export var destroy_projectile_on_hit := true

@export_group("Hit Effect")
## Optional effect scene spawned at the impact position.
@export var hit_effect_scene: PackedScene
## Optional parent for spawned hit effects. Leave empty to use the current scene root.
@export var hit_effect_parent_path: NodePath
## Fallback seconds before spawned hit effects are freed if they do not self-delete.
@export_range(0.0, 10.0, 0.01, "or_greater") var hit_effect_fallback_lifetime := 1.6

@export_group("Debug")
## Shows a panel with a health bar per group in group_max_health.
@export var debug_ui_enabled := false :
	set(value):
		debug_ui_enabled = value
		if _debug_layer != null:
			_debug_layer.visible = debug_ui_enabled

var _hitboxes: Array[Node] = []
var _group_health := {}
var _destroyed_groups := {}
var _owner_rigid_body: RigidBody3D
var _debug_layer: CanvasLayer
var _debug_bars := {}
var _debug_labels := {}


func _enter_tree() -> void:
	add_to_group(&"hitbox_health_manager")


func _exit_tree() -> void:
	remove_from_group(&"hitbox_health_manager")


func _ready() -> void:
	_initialize_group_health()
	refresh_hitboxes()
	_build_debug_ui()
	group_health_changed.connect(_on_debug_health_changed)


## Re-registers every ProjectileHitbox below this node.
func refresh_hitboxes() -> void:
	_hitboxes.clear()
	_collect_hitboxes(self)


func handle_projectile_hit(hitbox: Node, projectile: Node, hit_data: Dictionary = {}) -> void:
	if not enabled:
		return
	if should_ignore_projectile(projectile, hitbox):
		return
	var hitbox_group := _get_hitbox_group(hitbox, hit_data)
	var damage := _calculate_damage(hitbox_group, hitbox, hit_data)
	hit_data = hit_data.duplicate()
	hit_data["damage"] = damage
	hit_data["remaining_health"] = get_group_health(hitbox_group)
	hitbox_hit.emit(hitbox_group, hitbox, projectile, hit_data)

	if damage > 0.0 and not bool(_destroyed_groups.get(hitbox_group, false)):
		_apply_damage(hitbox_group, damage, hit_data)

	_spawn_hit_effect(hit_data)

	if destroy_projectile_on_hit and projectile != null and is_instance_valid(projectile):
		projectile.queue_free()


func should_ignore_projectile(projectile: Node, _hitbox: Node = null) -> bool:
	if not ignore_own_projectiles or projectile == null:
		return false
	var owner_body := _get_owner_rigid_body()
	if owner_body == null:
		return false
	if not projectile.has_meta(&"source_rigid_body_instance_id"):
		return false
	return int(projectile.get_meta(&"source_rigid_body_instance_id")) == owner_body.get_instance_id()


func get_group_health(hitbox_group: StringName) -> float:
	_ensure_group_health(hitbox_group)
	return float(_group_health.get(hitbox_group, 0.0))


func get_group_max_health(hitbox_group: StringName) -> float:
	return _get_group_float(group_max_health, hitbox_group, default_group_max_health)


func set_group_health(hitbox_group: StringName, health: float) -> void:
	_group_health[hitbox_group] = clampf(health, 0.0, get_group_max_health(hitbox_group))
	_refresh_debug_ui()


func reset_health() -> void:
	_group_health.clear()
	_destroyed_groups.clear()
	_initialize_group_health()
	_refresh_debug_ui()


func is_group_destroyed(hitbox_group: StringName) -> bool:
	return bool(_destroyed_groups.get(hitbox_group, false))


func _initialize_group_health() -> void:
	for key in group_max_health.keys():
		var group := StringName(str(key))
		_group_health[group] = maxf(float(group_max_health[key]), 0.0)


func _ensure_group_health(hitbox_group: StringName) -> void:
	if _group_health.has(hitbox_group):
		return
	_group_health[hitbox_group] = get_group_max_health(hitbox_group)


func _apply_damage(hitbox_group: StringName, damage: float, hit_data: Dictionary) -> void:
	_ensure_group_health(hitbox_group)
	var max_health := get_group_max_health(hitbox_group)
	var health := maxf(float(_group_health.get(hitbox_group, max_health)) - damage, 0.0)
	_group_health[hitbox_group] = health
	hit_data["remaining_health"] = health
	group_health_changed.emit(hitbox_group, health, max_health, hit_data)
	if health <= 0.0:
		_destroyed_groups[hitbox_group] = true
		group_destroyed.emit(hitbox_group, hit_data)


func _calculate_damage(hitbox_group: StringName, hitbox: Node, hit_data: Dictionary) -> float:
	var explicit_damage = hit_data.get("damage", null)
	if explicit_damage != null:
		return maxf(float(explicit_damage), 0.0)
	var momentum := float(hit_data.get("momentum_magnitude", 0.0))
	var group_multiplier := _get_group_float(group_damage_multipliers, hitbox_group, 1.0)
	var hitbox_multiplier := float(hit_data.get("damage_multiplier", 1.0))
	if hitbox != null:
		var configured_multiplier = hitbox.get(&"damage_multiplier")
		if configured_multiplier != null:
			hitbox_multiplier = float(configured_multiplier)
	var damage := momentum * damage_per_momentum * group_multiplier * hitbox_multiplier
	return maxf(damage, minimum_hit_damage)


func _get_hitbox_group(hitbox: Node, hit_data: Dictionary) -> StringName:
	if hitbox != null:
		var configured_group = hitbox.get(&"hitbox_group")
		if configured_group != null:
			return StringName(str(configured_group))
	var group_value = hit_data.get("hitbox_group", &"default")
	return StringName(str(group_value))


func _get_group_float(values: Dictionary, hitbox_group: StringName, default_value: float) -> float:
	if values.has(hitbox_group):
		return float(values[hitbox_group])
	var string_key := String(hitbox_group)
	if values.has(string_key):
		return float(values[string_key])
	return default_value


func _spawn_hit_effect(hit_data: Dictionary) -> void:
	if hit_effect_scene == null:
		return
	var effect := hit_effect_scene.instantiate()
	var parent := _get_hit_effect_parent()
	parent.add_child(effect)

	var effect_3d := effect as Node3D
	if effect_3d != null:
		var hit_position := Vector3.ZERO
		var hit_position_value = hit_data.get("position", Vector3.ZERO)
		if hit_position_value is Vector3:
			hit_position = hit_position_value
		effect_3d.global_position = hit_position
	var velocity := Vector3(hit_data.get("velocity", Vector3.ZERO))
	if effect_3d != null and velocity.length_squared() > 0.0001:
		effect_3d.look_at(effect_3d.global_position - velocity.normalized(), Vector3.UP)

	if effect.has_method(&"play"):
		effect.call(&"play")
	elif effect is GPUParticles3D:
		(effect as GPUParticles3D).emitting = true
		_queue_effect_free(effect)
	else:
		_queue_effect_free(effect)


func _get_hit_effect_parent() -> Node:
	if not hit_effect_parent_path.is_empty():
		var configured_parent := get_node_or_null(hit_effect_parent_path)
		if configured_parent != null:
			return configured_parent
	var current_scene := get_tree().current_scene if is_inside_tree() else null
	if current_scene != null:
		return current_scene
	return get_parent() if get_parent() != null else self


func _queue_effect_free(effect: Node) -> void:
	if hit_effect_fallback_lifetime > 0.0 and is_inside_tree():
		get_tree().create_timer(hit_effect_fallback_lifetime).timeout.connect(effect.queue_free)


func _get_owner_rigid_body() -> RigidBody3D:
	if _owner_rigid_body != null and is_instance_valid(_owner_rigid_body):
		return _owner_rigid_body
	if not owner_rigid_body_path.is_empty():
		_owner_rigid_body = get_node_or_null(owner_rigid_body_path) as RigidBody3D
		if _owner_rigid_body != null:
			return _owner_rigid_body
	var node := get_parent()
	while node != null:
		if node is RigidBody3D:
			_owner_rigid_body = node as RigidBody3D
			return _owner_rigid_body
		node = node.get_parent()
	return null


func _collect_hitboxes(root: Node) -> void:
	if root is ProjectileHitbox:
		if not _hitboxes.has(root):
			_hitboxes.push_back(root)
			root.call(&"set_manager", self)
	for child in root.get_children():
		var child_node := child as Node
		if child_node != null:
			_collect_hitboxes(child_node)


func _build_debug_ui() -> void:
	_debug_layer = CanvasLayer.new()
	_debug_layer.name = "HealthDebugUI"
	_debug_layer.visible = debug_ui_enabled
	add_child(_debug_layer, false, INTERNAL_MODE_BACK)

	var panel := PanelContainer.new()
	panel.position = DEBUG_SCREEN_POSITION
	panel.custom_minimum_size = Vector2(DEBUG_PANEL_WIDTH, 0.0)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_debug_layer.add_child(panel)
	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 6)
	panel.add_child(content)
	var title := Label.new()
	title.text = "Hitbox Health"
	content.add_child(title)

	for key in group_max_health.keys():
		var group := StringName(str(key))
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		content.add_child(row)
		var name_label := Label.new()
		name_label.custom_minimum_size = Vector2(56.0, 0.0)
		name_label.text = String(group)
		row.add_child(name_label)
		var bar := ProgressBar.new()
		bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		bar.show_percentage = false
		row.add_child(bar)
		var value_label := Label.new()
		value_label.custom_minimum_size = Vector2(78.0, 0.0)
		value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		row.add_child(value_label)
		_debug_bars[group] = bar
		_debug_labels[group] = value_label
	_refresh_debug_ui()


func _refresh_debug_ui() -> void:
	for group in _debug_bars.keys():
		var max_health := get_group_max_health(group)
		var health := get_group_health(group)
		var bar := _debug_bars[group] as ProgressBar
		bar.max_value = maxf(max_health, 0.001)
		bar.value = health
		(_debug_labels[group] as Label).text = "%d / %d" % [roundi(health), roundi(max_health)]


func _on_debug_health_changed(_group: StringName, _health: float, _max_health: float, _hit_data: Dictionary) -> void:
	_refresh_debug_ui()
