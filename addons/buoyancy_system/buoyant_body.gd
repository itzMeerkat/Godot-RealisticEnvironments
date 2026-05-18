class_name BuoyantBody
extends Node
## Applies buoyancy forces to a parent RigidBody3D using child
## BuoyancyCellVolume nodes and an OceanSystem surface query.

@export var rigid_body_path : NodePath
@export var ocean_path : NodePath
@export var auto_collect_child_volumes := true
@export var cell_volume_paths : Array[NodePath] = []
@export_range(0.0, 10.0, 0.01, "or_greater") var buoyancy_strength := 1.0
@export_range(1.0, 2000.0, 1.0, "or_greater") var water_density := 1025.0
@export_range(0.0, 100.0, 0.01, "or_greater") var vertical_damping := 1.4
@export_range(0.0, 100.0, 0.01, "or_greater") var longitudinal_water_drag := 0.45
@export_range(0.0, 100.0, 0.01, "or_greater") var lateral_water_drag := 0.45
@export_range(0.0, 100.0, 0.1, "or_greater") var max_cell_acceleration := 35.0
@export var submit_water_interactions := true
@export var apply_forces := true

var rigid_body : RigidBody3D
var ocean : OceanSystem
var cell_volumes : Array[Node] = []
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
	if not _has_collected_volumes or cell_volumes.is_empty():
		_collect_volumes()

	var sample_points := _get_active_sample_points()
	if sample_points.is_empty():
		return

	var points := PackedVector3Array()
	for sample_point in sample_points:
		var sample_position : Vector3 = sample_point["world_position"]
		points.push_back(sample_position)
	if points.is_empty():
		return

	var samples := ocean.sample_water_surface_batch(points, self)
	if samples.size() != sample_points.size():
		return
	var total_volume := _get_total_effective_sample_volume(sample_points)
	var gravity := float(ProjectSettings.get_setting("physics/3d/default_gravity", 9.8))
	var total_external_force := Vector3.ZERO
	for i in sample_points.size():
		total_external_force += _apply_sample_forces(sample_points[i], samples[i], total_volume, gravity)
	_update_body_debug(total_external_force, gravity)
	if submit_water_interactions:
		_submit_water_interactions(sample_points, samples)


func refresh_volumes() -> void:
	_collect_volumes()


func _resolve_nodes() -> void:
	if not rigid_body_path.is_empty():
		rigid_body = get_node_or_null(rigid_body_path) as RigidBody3D
	if rigid_body == null:
		rigid_body = get_parent() as RigidBody3D
	if not ocean_path.is_empty():
		ocean = get_node_or_null(ocean_path) as OceanSystem
	if ocean == null:
		ocean = get_tree().get_first_node_in_group(&"ocean_system") as OceanSystem


func _collect_volumes() -> void:
	cell_volumes.clear()
	for path in cell_volume_paths:
		var volume := get_node_or_null(path)
		if volume != null:
			cell_volumes.push_back(volume)
	if auto_collect_child_volumes:
		var root : Node = rigid_body if rigid_body != null else self
		_collect_cell_volume_descendants(root)
	_has_collected_volumes = true


func _collect_cell_volume_descendants(node : Node) -> void:
	for child in node.get_children():
		if child is Node and child.has_method(&"get_buoyancy_sample_points") and not cell_volumes.has(child):
			cell_volumes.push_back(child)
		_collect_cell_volume_descendants(child)


func _get_active_sample_points() -> Array[Dictionary]:
	var sample_points : Array[Dictionary] = []
	for cell_volume in cell_volumes:
		if cell_volume == null or not bool(cell_volume.get(&"enabled")) or not cell_volume.is_inside_tree():
			continue
		sample_points.append_array(cell_volume.get_buoyancy_sample_points())
	return sample_points


func _get_total_effective_sample_volume(sample_points : Array[Dictionary]) -> float:
	var total_volume := 0.0
	for sample_point in sample_points:
		total_volume += _get_effective_sample_volume(sample_point)
	return maxf(total_volume, 0.0001)


func _get_effective_sample_volume(sample_point : Dictionary) -> float:
	var dry_volume := maxf(float(sample_point.get("volume_cubic_meters", 0.0)), 0.0)
	dry_volume *= clampf(float(sample_point.get("buoyancy_efficiency", 1.0)), 0.0, 100.0)
	return dry_volume * (1.0 - clampf(float(sample_point.get("flooding_fraction", 0.0)), 0.0, 1.0))


func _apply_sample_forces(sample_point : Dictionary, sample : WaterSurfaceSample, total_volume : float, gravity : float) -> Vector3:
	var sample_position : Vector3 = sample_point["world_position"]
	var submersion_depth := maxf(float(sample_point.get("submersion_depth", 1.0)), 0.001)
	var cell_half_height := maxf(float(sample_point.get("cell_vertical_half_extent", submersion_depth * 0.5)), 0.0005)
	var cell_bottom_y := sample_position.y - cell_half_height
	var submersion := clampf((sample.height - cell_bottom_y) / submersion_depth, 0.0, 1.0)

	var offset := sample_position - rigid_body.global_position
	var point_velocity := rigid_body.linear_velocity + rigid_body.angular_velocity.cross(offset)
	var effective_volume := _get_effective_sample_volume(sample_point)
	var volume_ratio := effective_volume / total_volume
	var water_velocity := sample.surface_velocity

	if sample.normal.length_squared() <= 0.0001:
		return Vector3.ZERO
	var buoyancy_direction := sample.normal.normalized()
	var displaced_volume := effective_volume * submersion
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
	if max_cell_acceleration > 0.0:
		var max_force := rigid_body.mass * volume_ratio * max_cell_acceleration
		if max_force > 0.0 and total_force.length_squared() > max_force * max_force:
			total_force = total_force.normalized() * max_force
	var source : Object = sample_point.get("source")
	if source != null and source.has_method(&"set_debug_sample_state"):
		source.call(
			&"set_debug_sample_state",
			int(sample_point.get("source_sample_index", -1)),
			sample_position,
			Vector3(sample_position.x, sample.height, sample_position.z),
			total_force,
			true,
			buoyancy_force,
			submersion
		)
	if submersion <= 0.0:
		return Vector3.ZERO
	rigid_body.apply_force(total_force, offset)
	return total_force


func _update_body_debug(total_external_force: Vector3, gravity: float) -> void:
	if rigid_body == null:
		return
	var center_of_mass_world := rigid_body.global_transform * rigid_body.center_of_mass
	var gravity_force := Vector3.DOWN * rigid_body.mass * gravity
	for cell_volume in cell_volumes:
		if cell_volume == null or not cell_volume.has_method(&"set_debug_body_state"):
			continue
		cell_volume.call(&"set_debug_body_state", center_of_mass_world, gravity_force, total_external_force, true)


func _submit_water_interactions(sample_points: Array[Dictionary], samples: Array[WaterSurfaceSample]) -> void:
	if ocean == null or not ocean.has_method(&"queue_water_interaction_source"):
		return
	var grouped_points := {}
	var grouped_samples := {}
	var sample_count := mini(sample_points.size(), samples.size())
	for i in sample_count:
		var source : Object = sample_points[i].get("source")
		if source == null or not source.has_method(&"get_water_interaction_sources"):
			continue
		if not grouped_points.has(source):
			grouped_points[source] = []
			grouped_samples[source] = []
		grouped_points[source].push_back(sample_points[i])
		grouped_samples[source].push_back(samples[i])
	for source in grouped_points.keys():
		var sources : Array = source.call(&"get_water_interaction_sources", grouped_points[source], grouped_samples[source], rigid_body)
		for interaction_source in sources:
			ocean.call(&"queue_water_interaction_source", interaction_source)
