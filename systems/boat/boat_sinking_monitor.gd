class_name BoatSinkingMonitor
extends Node
## Watches a floating rigid body and starts sinking when roll or draft limits are exceeded.

signal sinking_started(reason: StringName, data: Dictionary)
signal sinking_delete_timeout()

@export var enabled := true
@export var rigid_body_path: NodePath
@export var buoyant_body_path: NodePath
@export var delete_root_path: NodePath

@export_group("Roll Limit")
@export_range(0.0, 180.0, 0.1, "degrees") var max_roll_degrees := 70.0

@export_group("Draft Limit")
@export var sinking_probe_paths: Array[NodePath] = []
@export_range(-10.0, 10.0, 0.01) var sink_probe_depth_threshold := 0.5

@export_group("Sink Behavior")
@export_range(0.0, 1.0, 0.01) var sink_buoyancy_multiplier := 0.3
@export_range(0.0, 60.0, 0.01, "or_greater") var delete_delay := 5.0

var rigid_body: RigidBody3D
var buoyant_body: BuoyantBody
var _initial_buoyancy_strength := 1.0
var _is_sinking := false


func _ready() -> void:
	_resolve_nodes()
	if buoyant_body != null:
		_initial_buoyancy_strength = buoyant_body.buoyancy_strength


func _physics_process(_delta: float) -> void:
	if not enabled or _is_sinking:
		return
	if rigid_body == null or buoyant_body == null:
		_resolve_nodes()
	if rigid_body == null or buoyant_body == null:
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
	if buoyant_body == null:
		_resolve_nodes()
	if buoyant_body != null:
		buoyant_body.buoyancy_strength = _initial_buoyancy_strength * clampf(sink_buoyancy_multiplier, 0.0, 1.0)
	sinking_started.emit(reason, data)

	if delete_delay <= 0.0 or not is_inside_tree():
		_delete_sink_root()
		return
	get_tree().create_timer(delete_delay).timeout.connect(_on_delete_timeout)


func is_sinking() -> bool:
	return _is_sinking


func _resolve_nodes() -> void:
	if not rigid_body_path.is_empty():
		rigid_body = get_node_or_null(rigid_body_path) as RigidBody3D
	if rigid_body == null:
		rigid_body = get_parent() as RigidBody3D
	if rigid_body == null:
		rigid_body = _find_parent_rigid_body()

	if not buoyant_body_path.is_empty():
		buoyant_body = get_node_or_null(buoyant_body_path) as BuoyantBody
	if buoyant_body == null and rigid_body != null:
		buoyant_body = rigid_body.get_node_or_null("BuoyantBody") as BuoyantBody
	if buoyant_body == null and rigid_body != null:
		buoyant_body = _find_descendant_buoyant_body(rigid_body)
	if buoyant_body == null:
		buoyant_body = _find_descendant_buoyant_body(self)


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
	if sinking_probe_paths.is_empty():
		return {"should_sink": false, "probe_count": 0}
	var selected_probes := _get_sinking_probe_nodes()
	if selected_probes.is_empty():
		return {"should_sink": false, "probe_count": 0, "missing_probe_paths": sinking_probe_paths.size()}

	var states := buoyant_body.get_probe_states()
	var submerged_count := 0
	var deepest_depth := -INF
	for probe in selected_probes:
		var state := _find_probe_state(states, probe)
		if state.is_empty():
			return {"should_sink": false, "probe_count": selected_probes.size(), "missing_state_for": probe.get_path()}
		var depth := float(state.get("depth", -INF))
		deepest_depth = maxf(deepest_depth, depth)
		if depth >= sink_probe_depth_threshold:
			submerged_count += 1

	return {
		"should_sink": submerged_count == selected_probes.size(),
		"probe_count": selected_probes.size(),
		"submerged_count": submerged_count,
		"depth_threshold": sink_probe_depth_threshold,
		"deepest_depth": deepest_depth,
	}


func _get_sinking_probe_nodes() -> Array[Node]:
	var probes: Array[Node] = []
	for path in sinking_probe_paths:
		var probe := get_node_or_null(path)
		if probe != null and not probes.has(probe):
			probes.push_back(probe)
	return probes


func _find_probe_state(states: Array[Dictionary], probe: Node) -> Dictionary:
	for state in states:
		if state.get("probe") == probe:
			return state
	return {}


func _on_delete_timeout() -> void:
	sinking_delete_timeout.emit()
	_delete_sink_root()


func _delete_sink_root() -> void:
	var root := _get_delete_root()
	if root != null and is_instance_valid(root):
		root.queue_free()


func _get_delete_root() -> Node:
	if not delete_root_path.is_empty():
		var configured_root := get_node_or_null(delete_root_path)
		if configured_root != null:
			return configured_root
	if rigid_body != null:
		return rigid_body
	return get_parent()
