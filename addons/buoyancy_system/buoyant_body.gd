class_name BuoyantBody
extends Node
## Applies buoyancy forces to a parent RigidBody3D using child BuoyancyProbe
## sample points, generated HullVolume samples, and an OceanSystem surface query.

@export var rigid_body_path : NodePath
@export var ocean_path : NodePath
@export var auto_collect_child_probes := true
@export var probe_paths : Array[NodePath] = []
@export_range(0.0, 10.0, 0.01, "or_greater") var buoyancy_strength := 1.0
@export_range(1.0, 2000.0, 1.0, "or_greater") var water_density := 1025.0
@export var use_surface_normal_for_buoyancy := false
@export_range(0.0, 10.0, 0.01, "or_greater") var surface_velocity_influence := 1.0
@export_range(0.0, 10.0, 0.01, "or_greater") var current_influence := 1.0
@export_range(0.0, 100.0, 0.1, "or_greater") var max_probe_acceleration := 35.0
@export var apply_forces := true

var rigid_body : RigidBody3D
var ocean : OceanSystem
var probes : Array[BuoyancyProbe] = []
var hull_volumes : Array[HullVolume] = []
var _has_collected_floaters := false


func _ready() -> void:
	_resolve_nodes()
	_collect_floaters()


func _physics_process(_delta : float) -> void:
	if not apply_forces:
		return
	if rigid_body == null or ocean == null:
		_resolve_nodes()
	if rigid_body == null or ocean == null:
		return
	if not _has_collected_floaters or (probes.is_empty() and hull_volumes.is_empty()):
		_collect_floaters()

	var sample_points := _get_active_sample_points()
	if sample_points.is_empty():
		return

	var points := PackedVector3Array()
	for sample_point in sample_points:
		var sample_position : Vector3 = sample_point["world_position"]
		points.push_back(sample_position)
	if points.is_empty():
		return

	var samples := ocean.sample_water_surface_batch(points)
	var total_volume := _get_total_effective_sample_volume(sample_points)
	var gravity := float(ProjectSettings.get_setting("physics/3d/default_gravity", 9.8))
	for i in sample_points.size():
		_apply_sample_forces(sample_points[i], samples[i], total_volume, gravity)


func refresh_probes() -> void:
	_collect_floaters()


func _resolve_nodes() -> void:
	if not rigid_body_path.is_empty():
		rigid_body = get_node_or_null(rigid_body_path) as RigidBody3D
	if rigid_body == null:
		rigid_body = get_parent() as RigidBody3D
	if not ocean_path.is_empty():
		ocean = get_node_or_null(ocean_path) as OceanSystem
	if ocean == null:
		ocean = get_tree().get_first_node_in_group(&"ocean_system") as OceanSystem


func _collect_floaters() -> void:
	probes.clear()
	hull_volumes.clear()
	for path in probe_paths:
		var probe := get_node_or_null(path) as BuoyancyProbe
		if probe != null:
			probes.push_back(probe)
	if auto_collect_child_probes:
		var root : Node = rigid_body if rigid_body != null else self
		_collect_probe_descendants(root)
		_collect_hull_volume_descendants(root)
	_has_collected_floaters = true


func _collect_probe_descendants(node : Node) -> void:
	for child in node.get_children():
		if child is BuoyancyProbe and not probes.has(child):
			probes.push_back(child)
		_collect_probe_descendants(child)


func _collect_hull_volume_descendants(node : Node) -> void:
	for child in node.get_children():
		if child is HullVolume and not hull_volumes.has(child):
			hull_volumes.push_back(child)
		_collect_hull_volume_descendants(child)


func _get_active_sample_points() -> Array[Dictionary]:
	var sample_points : Array[Dictionary] = []
	for probe in probes:
		if probe == null or not probe.enabled or not probe.is_inside_tree():
			continue
		sample_points.push_back({
			"world_position": probe.global_position,
			"volume_cubic_meters": probe.volume_cubic_meters,
			"buoyancy_efficiency": probe.buoyancy_efficiency * probe.buoyancy_weight,
			"flooding_fraction": probe.flooding_fraction,
			"submersion_depth": probe.submersion_depth,
			"vertical_damping": probe.vertical_damping,
			"water_drag": probe.water_drag,
			"current_drag": probe.current_drag,
			"source": probe,
		})
	for hull_volume in hull_volumes:
		if hull_volume == null or not hull_volume.enabled or not hull_volume.is_inside_tree():
			continue
		sample_points.append_array(hull_volume.get_buoyancy_sample_points())
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


func _apply_sample_forces(sample_point : Dictionary, sample : WaterSurfaceSample, total_volume : float, gravity : float) -> void:
	var sample_position : Vector3 = sample_point["world_position"]
	var depth := sample.height - sample_position.y
	var submersion_depth := float(sample_point.get("submersion_depth", 1.0))
	var submersion := clampf(depth / maxf(submersion_depth, 0.001), 0.0, 1.0)

	var offset := sample_position - rigid_body.global_position
	var point_velocity := rigid_body.linear_velocity + rigid_body.angular_velocity.cross(offset)
	var effective_volume := _get_effective_sample_volume(sample_point)
	var volume_ratio := effective_volume / total_volume
	var water_velocity := sample.surface_velocity * surface_velocity_influence + sample.current_velocity * current_influence

	var buoyancy_direction := Vector3.UP
	if use_surface_normal_for_buoyancy and sample.valid and sample.normal.length_squared() > 0.0001:
		buoyancy_direction = sample.normal
		buoyancy_direction = buoyancy_direction.normalized()
	var displaced_volume := effective_volume * submersion
	var buoyancy_force := buoyancy_direction * water_density * gravity * buoyancy_strength * displaced_volume
	var vertical_speed := point_velocity.dot(Vector3.UP) - water_velocity.dot(Vector3.UP)
	var vertical_damping := float(sample_point.get("vertical_damping", 2.0))
	var vertical_damping_force := -Vector3.UP * vertical_speed * vertical_damping * rigid_body.mass * volume_ratio * submersion

	var horizontal_point_velocity := Vector3(point_velocity.x, 0.0, point_velocity.z)
	var horizontal_surface_velocity := Vector3(sample.surface_velocity.x, 0.0, sample.surface_velocity.z) * surface_velocity_influence
	var horizontal_current_velocity := Vector3(sample.current_velocity.x, 0.0, sample.current_velocity.z) * current_influence
	var water_drag := float(sample_point.get("water_drag", 1.0))
	var current_drag := float(sample_point.get("current_drag", 1.0))
	var water_drag_force := (horizontal_surface_velocity - horizontal_point_velocity) * water_drag * rigid_body.mass * volume_ratio * submersion
	var current_drag_force := (horizontal_current_velocity - horizontal_point_velocity) * current_drag * rigid_body.mass * volume_ratio * submersion

	var total_force := buoyancy_force + vertical_damping_force + water_drag_force + current_drag_force
	if max_probe_acceleration > 0.0:
		var max_force := rigid_body.mass * volume_ratio * max_probe_acceleration
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
			sample.valid
		)
	elif source != null and source.has_method(&"set_debug_state"):
		source.call(&"set_debug_state", Vector3(sample_position.x, sample.height, sample_position.z), total_force, sample.valid)
	if submersion <= 0.0:
		return
	rigid_body.apply_force(total_force, offset)
