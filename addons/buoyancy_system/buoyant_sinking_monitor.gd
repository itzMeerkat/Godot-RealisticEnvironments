class_name BuoyantSinkingMonitor
extends Node
## Watches a floating rigid body and starts sinking when roll or draft limits are exceeded.

signal sinking_started(reason: StringName, data: Dictionary)
signal sinking_delete_timeout()

## Enables roll, draft, and damage-triggered sinking checks.
@export var enabled := true
## Optional rigid body target. Leave empty to use the parent or nearest ancestor.
@export var rigid_body_path: NodePath
## Optional buoyant body target. Leave empty to find one near the rigid body.
@export var buoyant_body_path: NodePath
## Optional node deleted after delete_delay once sinking starts. Leave empty to delete the rigid body or parent.
@export var delete_root_path: NodePath

@export_group("Roll Limit")
## Starts sinking when absolute roll reaches this angle. Set 0 to disable roll sinking.
@export_range(0.0, 180.0, 0.1, "degrees") var max_roll_degrees := 70.0

@export_group("Draft Limit")
## Probe nodes that must all exceed sink_probe_depth_threshold before draft sinking starts.
@export var sinking_probe_paths: Array[NodePath] = []
## Water depth threshold required for each selected sinking probe.
@export_range(-10.0, 10.0, 0.01) var sink_probe_depth_threshold := 0.5

@export_group("Damage Integration")
## Hitbox groups that trigger sinking when an external health system reports destruction.
@export var sink_on_destroyed_groups: Array[StringName] = [&"hull"]

@export_group("Sink Behavior")
## Multiplier applied to the initial BuoyantBody.buoyancy_strength once sinking starts.
@export_range(0.0, 1.0, 0.01) var sink_buoyancy_multiplier := 0.3
## Seconds after sinking starts before delete_root_path is freed. Set 0 for immediate delete.
@export_range(0.0, 60.0, 0.01, "or_greater") var delete_delay := 5.0

var rigid_body: RigidBody3D
var buoyant_body: BuoyantBody
var _sinking_probes: Array[Node] = []
var _initial_buoyancy_strength := 1.0
var _is_sinking := false


func _enter_tree() -> void:
	add_to_group(&"buoyant_sinking_monitor")


func _exit_tree() -> void:
	remove_from_group(&"buoyant_sinking_monitor")


func _ready() -> void:
	rigid_body = _resolve_rigid_body()
	buoyant_body = _resolve_buoyant_body()
	for path in sinking_probe_paths:
		var probe := get_node(path)
		if not _sinking_probes.has(probe):
			_sinking_probes.push_back(probe)
	_initial_buoyancy_strength = buoyant_body.buoyancy_strength


func _physics_process(_delta: float) -> void:
	if not enabled or _is_sinking:
		return

	var roll_degrees := _get_abs_roll_degrees()
	if max_roll_degrees > 0.0 and roll_degrees >= max_roll_degrees:
		start_sinking(&"roll", {"roll_degrees": roll_degrees})
		return

	var draft_result := _get_draft_sink_result()
	if bool(draft_result.get("should_sink", false)):
		start_sinking(&"draft", draft_result)


func start_sinking(reason: StringName = &"manual", data: Dictionary = {}) -> void:
	if _is_sinking:
		return
	_is_sinking = true
	buoyant_body.buoyancy_strength = _initial_buoyancy_strength * clampf(sink_buoyancy_multiplier, 0.0, 1.0)
	sinking_started.emit(reason, data)

	if delete_delay <= 0.0 or not is_inside_tree():
		_delete_sink_root()
		return
	get_tree().create_timer(delete_delay).timeout.connect(_on_delete_timeout)


func is_sinking() -> bool:
	return _is_sinking


func _on_hitbox_group_destroyed(hitbox_group: StringName, hit_data: Dictionary) -> void:
	if _should_sink_on_group_destroyed(hitbox_group):
		start_sinking(&"hitbox_group_destroyed", {"hitbox_group": hitbox_group, "hit_data": hit_data})


func _resolve_rigid_body() -> RigidBody3D:
	if not rigid_body_path.is_empty():
		var target := get_node(rigid_body_path)
		assert(target is RigidBody3D, "BuoyantSinkingMonitor %s: rigid_body_path points to %s (%s), not a RigidBody3D." % [get_path(), target.get_path(), target.get_class()])
		return target as RigidBody3D
	var ancestor := _find_parent_rigid_body()
	assert(ancestor != null, "BuoyantSinkingMonitor %s: rigid_body_path is empty and no ancestor is a RigidBody3D." % get_path())
	return ancestor


func _resolve_buoyant_body() -> BuoyantBody:
	if not buoyant_body_path.is_empty():
		var target := get_node(buoyant_body_path)
		assert(target is BuoyantBody, "BuoyantSinkingMonitor %s: buoyant_body_path points to %s (%s), not a BuoyantBody." % [get_path(), target.get_path(), target.get_class()])
		return target as BuoyantBody
	var found := _find_descendant_buoyant_body(rigid_body)
	assert(found != null, "BuoyantSinkingMonitor %s: buoyant_body_path is empty and %s has no BuoyantBody descendant." % [get_path(), rigid_body.get_path()])
	return found


func _find_parent_rigid_body() -> RigidBody3D:
	var node := get_parent()
	while node != null:
		if node is RigidBody3D:
			return node
		node = node.get_parent()
	return null


func _find_descendant_buoyant_body(root: Node) -> BuoyantBody:
	for child in root.get_children():
		if child is BuoyantBody:
			return child
		var found := _find_descendant_buoyant_body(child)
		if found != null:
			return found
	return null


func _get_abs_roll_degrees() -> float:
	var basis := rigid_body.global_transform.basis.orthonormalized()
	var roll_axis := basis.z.normalized()
	var body_up := basis.y.normalized()
	if roll_axis.length_squared() <= 0.0001 or body_up.length_squared() <= 0.0001:
		return 0.0
	var target_up := Vector3.UP - roll_axis * Vector3.UP.dot(roll_axis)
	if target_up.length_squared() <= 0.0001:
		return 0.0
	target_up = target_up.normalized()
	return absf(rad_to_deg(body_up.signed_angle_to(target_up, roll_axis)))


func _get_draft_sink_result() -> Dictionary:
	if _sinking_probes.is_empty():
		return {"should_sink": false, "probe_count": 0}
	var submerged_count := 0
	var deepest_depth := -INF
	for probe in _sinking_probes:
		var state := buoyant_body.get_probe_state(probe)
		assert(state != null, "BuoyantSinkingMonitor %s: sinking probe %s is not an enabled probe of %s." % [get_path(), probe.get_path(), buoyant_body.get_path()])
		# No water sample yet (the first query result is still in flight).
		if not state.has_sample:
			return {"should_sink": false, "probe_count": _sinking_probes.size(), "missing_state_for": probe.get_path()}
		deepest_depth = maxf(deepest_depth, state.depth)
		if state.depth >= sink_probe_depth_threshold:
			submerged_count += 1

	return {
		"should_sink": submerged_count == _sinking_probes.size(),
		"probe_count": _sinking_probes.size(),
		"submerged_count": submerged_count,
		"depth_threshold": sink_probe_depth_threshold,
		"deepest_depth": deepest_depth,
	}


func _should_sink_on_group_destroyed(hitbox_group: StringName) -> bool:
	for group in sink_on_destroyed_groups:
		if group == hitbox_group:
			return true
	return false


func _on_delete_timeout() -> void:
	sinking_delete_timeout.emit()
	_delete_sink_root()


func _delete_sink_root() -> void:
	_get_delete_root().queue_free()


func _get_delete_root() -> Node:
	return get_node(delete_root_path) if not delete_root_path.is_empty() else rigid_body
