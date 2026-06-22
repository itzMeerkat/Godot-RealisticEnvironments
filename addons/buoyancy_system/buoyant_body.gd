class_name BuoyantBody
extends Node
## Applies probe-based buoyancy forces to a parent RigidBody3D using OceanSystem's
## batched GPU water-surface query. FX probes are queried in the same batch but
## never apply forces.

signal probe_entered_water(probe: Node, state: Dictionary)
signal probe_exited_water(probe: Node, state: Dictionary)

@export var rigid_body_path : NodePath
@export var ocean_path : NodePath
@export var auto_collect_child_volumes := true
@export var probe_volume_paths : Array[NodePath] = []
@export_range(0.0, 10.0, 0.01, "or_greater") var buoyancy_strength := 1.0
@export_range(1.0, 2000.0, 1.0, "or_greater") var water_density := 1025.0
@export_range(0.0, 100.0, 0.01, "or_greater") var vertical_damping := 1.4
@export_range(0.0, 100.0, 0.01, "or_greater") var longitudinal_water_drag := 0.45
@export_range(0.0, 100.0, 0.01, "or_greater") var lateral_water_drag := 0.45
@export_range(0.0, 100.0, 0.1, "or_greater") var max_probe_acceleration := 35.0
@export var apply_forces := true

var rigid_body : RigidBody3D
var ocean : OceanSystem
var probe_volumes : Array[Node] = []
var _has_collected_volumes := false


func _ready() -> void:
	_resolve_nodes()
	_collect_volumes()


func _physics_process(_delta : float) -> void:
	if not apply_forces:
		return
	if rigid_body == null or ocean == null:
		_resolve_nodes()
	if rigid_body == null or ocean == null:
		return
	if not _has_collected_volumes or probe_volumes.is_empty():
		_collect_volumes()

	var force_sample_points := _get_active_sample_points()
	var contact_sample_points := _get_contact_sample_points()
	if force_sample_points.is_empty() and contact_sample_points.is_empty():
		return

	var query_entries : Array[Dictionary] = []
	var points := PackedVector3Array()
	for sample_point in force_sample_points:
		var sample_position : Vector3 = sample_point["world_position"]
		points.push_back(sample_position)
		query_entries.push_back({"type": "force", "sample_point": sample_point})
	for sample_point in contact_sample_points:
		var sample_position : Vector3 = sample_point["world_position"]
		points.push_back(sample_position)
		query_entries.push_back({"type": "contact", "sample_point": sample_point})
	if points.is_empty():
		return

	var samples := ocean.sample_water_surface_batch(points, self)
	if samples.size() != query_entries.size():
		return

	var total_volume := _get_total_max_submerged_volume(force_sample_points)
	var gravity := float(ProjectSettings.get_setting("physics/3d/default_gravity", 9.8))
	var total_external_force := Vector3.ZERO
	for i in query_entries.size():
		var entry := query_entries[i]
		var sample_point : Dictionary = entry["sample_point"]
		var water_sample : WaterSurfaceSample = samples[i]
		if str(entry["type"]) == "force":
			var force_result := _apply_sample_forces(sample_point, water_sample, total_volume, gravity)
			total_external_force += Vector3(force_result.get("applied_force", Vector3.ZERO))
			_update_sample_source_state(sample_point, water_sample, force_result, false)
		else:
			var contact_result := {
				"force": Vector3.ZERO,
				"applied_force": Vector3.ZERO,
				"submersion": 0.0,
			}
			_update_sample_source_state(sample_point, water_sample, contact_result, true)
	_update_body_debug(total_external_force, gravity)


func refresh_volumes() -> void:
	_collect_volumes()


func get_probe_states(tag_filter := "") -> Array[Dictionary]:
	var states : Array[Dictionary] = []
	for volume in probe_volumes:
		if volume == null or not volume.has_method(&"get_probe_states"):
			continue
		var volume_states : Array = volume.call(&"get_probe_states", tag_filter)
		for state in volume_states:
			if state is Dictionary:
				states.push_back(state)
	return states


func get_wet_probe_states(tag_filter := "") -> Array[Dictionary]:
	var states : Array[Dictionary] = []
	for volume in probe_volumes:
		if volume == null or not volume.has_method(&"get_wet_probe_states"):
			continue
		var volume_states : Array = volume.call(&"get_wet_probe_states", tag_filter)
		for state in volume_states:
			if state is Dictionary:
				states.push_back(state)
	return states


func _resolve_nodes() -> void:
	if not rigid_body_path.is_empty():
		rigid_body = get_node_or_null(rigid_body_path) as RigidBody3D
	if rigid_body == null:
		rigid_body = get_parent() as RigidBody3D
	if rigid_body == null:
		rigid_body = _find_parent_rigid_body()
	if not ocean_path.is_empty():
		ocean = get_node_or_null(ocean_path) as OceanSystem
	if ocean == null:
		ocean = get_tree().get_first_node_in_group(&"ocean_system") as OceanSystem


func _find_parent_rigid_body() -> RigidBody3D:
	var node := get_parent()
	while node != null:
		if node is RigidBody3D:
			return node
		node = node.get_parent()
	return null


func _collect_volumes() -> void:
	probe_volumes.clear()
	for path in probe_volume_paths:
		var volume := get_node_or_null(path)
		if volume != null and not probe_volumes.has(volume):
			probe_volumes.push_back(volume)
	if auto_collect_child_volumes:
		var root : Node = rigid_body if rigid_body != null else self
		_collect_probe_volume_descendants(root)
	for volume in probe_volumes:
		_connect_volume_signals(volume)
	_has_collected_volumes = true


func _collect_probe_volume_descendants(node : Node) -> void:
	for child in node.get_children():
		if child is Node and (child.has_method(&"get_buoyancy_sample_points") or child.has_method(&"get_contact_sample_points")) and not probe_volumes.has(child):
			probe_volumes.push_back(child)
		_collect_probe_volume_descendants(child)


func _connect_volume_signals(volume: Node) -> void:
	if volume == null:
		return
	var entered_callable := Callable(self, "_on_volume_probe_entered_water")
	var exited_callable := Callable(self, "_on_volume_probe_exited_water")
	if volume.has_signal(&"probe_entered_water") and not volume.is_connected(&"probe_entered_water", entered_callable):
		volume.connect(&"probe_entered_water", entered_callable)
	if volume.has_signal(&"probe_exited_water") and not volume.is_connected(&"probe_exited_water", exited_callable):
		volume.connect(&"probe_exited_water", exited_callable)


func _get_active_sample_points() -> Array[Dictionary]:
	var sample_points : Array[Dictionary] = []
	for volume in probe_volumes:
		if not _is_volume_enabled(volume) or not volume.has_method(&"get_buoyancy_sample_points"):
			continue
		sample_points.append_array(volume.call(&"get_buoyancy_sample_points"))
	return sample_points


func _get_contact_sample_points() -> Array[Dictionary]:
	var sample_points : Array[Dictionary] = []
	for volume in probe_volumes:
		if not _is_volume_enabled(volume) or not volume.has_method(&"get_contact_sample_points"):
			continue
		sample_points.append_array(volume.call(&"get_contact_sample_points"))
	return sample_points


func _is_volume_enabled(volume: Node) -> bool:
	if volume == null or not volume.is_inside_tree():
		return false
	var value = volume.get(&"enabled")
	return true if value == null else bool(value)


func _get_total_max_submerged_volume(sample_points : Array[Dictionary]) -> float:
	var total_volume := 0.0
	for sample_point in sample_points:
		total_volume += _get_probe_max_submerged_volume(sample_point)
	return maxf(total_volume, 0.0001)


func _get_probe_max_submerged_volume(sample_point : Dictionary) -> float:
	return maxf(float(sample_point.get("max_submerged_volume_cubic_meters", 0.0)), 0.0)


func _apply_sample_forces(sample_point : Dictionary, sample : WaterSurfaceSample, total_volume : float, gravity : float) -> Dictionary:
	var sample_position : Vector3 = sample_point["world_position"]
	var buoyancy_height := maxf(float(sample_point.get("buoyancy_height", 1.0)), 0.001)
	var probe_bottom_y := sample_position.y - buoyancy_height
	var immersion_depth := clampf(sample.height - probe_bottom_y, 0.0, buoyancy_height)
	var submersion := immersion_depth / buoyancy_height
	var empty_result := {
		"force": Vector3.ZERO,
		"applied_force": Vector3.ZERO,
		"buoyancy_force": Vector3.ZERO,
		"submersion": submersion,
	}
	if sample.normal.length_squared() <= 0.0001:
		return empty_result

	var offset := sample_position - rigid_body.global_position
	var point_velocity := rigid_body.linear_velocity + rigid_body.angular_velocity.cross(offset)
	var max_submerged_volume := _get_probe_max_submerged_volume(sample_point)
	var volume_ratio := max_submerged_volume / total_volume
	var water_velocity := sample.surface_velocity
	var buoyancy_direction := sample.normal.normalized()
	var displaced_volume := max_submerged_volume * submersion
	var buoyancy_force := buoyancy_direction * water_density * gravity * buoyancy_strength * displaced_volume
	var vertical_speed := point_velocity.dot(Vector3.UP) - water_velocity.dot(Vector3.UP)
	var vertical_damping_multiplier := float(sample_point.get("vertical_damping_multiplier", 1.0))
	var vertical_damping_force := -Vector3.UP * vertical_speed * vertical_damping * vertical_damping_multiplier * rigid_body.mass * volume_ratio * submersion

	var horizontal_point_velocity := Vector3(point_velocity.x, 0.0, point_velocity.z)
	var horizontal_surface_velocity := Vector3(sample.surface_velocity.x, 0.0, sample.surface_velocity.z)
	var relative_horizontal_velocity := horizontal_surface_velocity - horizontal_point_velocity
	var forward := -rigid_body.global_transform.basis.z
	forward.y = 0.0
	forward = forward.normalized() if forward.length_squared() > 0.0001 else Vector3.FORWARD
	var right := rigid_body.global_transform.basis.x
	right.y = 0.0
	right = right.normalized() if right.length_squared() > 0.0001 else Vector3.RIGHT
	var longitudinal_multiplier := float(sample_point.get("longitudinal_water_drag_multiplier", 1.0))
	var lateral_multiplier := float(sample_point.get("lateral_water_drag_multiplier", 1.0))
	var longitudinal_drag_force := forward * relative_horizontal_velocity.dot(forward) * longitudinal_water_drag * longitudinal_multiplier * rigid_body.mass * volume_ratio * submersion
	var lateral_drag_force := right * relative_horizontal_velocity.dot(right) * lateral_water_drag * lateral_multiplier * rigid_body.mass * volume_ratio * submersion

	var total_force := buoyancy_force + vertical_damping_force + longitudinal_drag_force + lateral_drag_force
	if max_probe_acceleration > 0.0:
		var max_force := rigid_body.mass * volume_ratio * max_probe_acceleration
		if max_force > 0.0 and total_force.length_squared() > max_force * max_force:
			total_force = total_force.normalized() * max_force
	var applied_force := Vector3.ZERO
	if submersion > 0.0:
		rigid_body.apply_force(total_force, offset)
		applied_force = total_force
	return {
		"force": total_force,
		"applied_force": applied_force,
		"buoyancy_force": buoyancy_force,
		"submersion": submersion,
	}


func _update_sample_source_state(sample_point: Dictionary, sample: WaterSurfaceSample, force_result: Dictionary, is_fx_probe: bool) -> void:
	var source : Object = sample_point.get("source")
	if source == null or not source.has_method(&"update_probe_state"):
		return
	var source_probe : Node = sample_point.get("source_probe")
	var sample_position : Vector3 = sample_point["world_position"]
	source.call(
		&"update_probe_state",
		source_probe,
		sample_position,
		sample,
		Vector3(force_result.get("force", Vector3.ZERO)),
		float(force_result.get("submersion", 0.0)),
		is_fx_probe
	)


func _update_body_debug(total_external_force: Vector3, gravity: float) -> void:
	if rigid_body == null:
		return
	var center_of_mass_world := rigid_body.global_transform * rigid_body.center_of_mass
	var gravity_force := Vector3.DOWN * rigid_body.mass * gravity
	for volume in probe_volumes:
		if volume == null or not volume.has_method(&"set_debug_body_state"):
			continue
		volume.call(&"set_debug_body_state", center_of_mass_world, gravity_force, total_external_force, true)


func _on_volume_probe_entered_water(probe: Node, state: Dictionary) -> void:
	probe_entered_water.emit(probe, state)


func _on_volume_probe_exited_water(probe: Node, state: Dictionary) -> void:
	probe_exited_water.emit(probe, state)
