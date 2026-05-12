class_name BuoyantBody
extends Node
## Applies buoyancy forces to a parent RigidBody3D using child BuoyancyProbe
## sample points and an OceanSystem surface query.

@export var rigid_body_path : NodePath
@export var ocean_path : NodePath
@export var auto_collect_child_probes := true
@export var probe_paths : Array[NodePath] = []
@export_range(0.0, 10.0, 0.01, "or_greater") var buoyancy_strength := 1.0
@export_range(0.0, 10.0, 0.01, "or_greater") var surface_velocity_influence := 1.0
@export_range(0.0, 10.0, 0.01, "or_greater") var current_influence := 1.0
@export var apply_forces := true

var rigid_body : RigidBody3D
var ocean : OceanSystem
var probes : Array[BuoyancyProbe] = []


func _ready() -> void:
	_resolve_nodes()
	_collect_probes()


func _physics_process(_delta : float) -> void:
	if not apply_forces:
		return
	if rigid_body == null or ocean == null:
		_resolve_nodes()
	if rigid_body == null or ocean == null:
		return
	if probes.is_empty():
		_collect_probes()
	if probes.is_empty():
		return

	var points := PackedVector3Array()
	var active_probes : Array[BuoyancyProbe] = []
	for probe in probes:
		if probe == null or not probe.enabled or not probe.is_inside_tree():
			continue
		points.push_back(probe.global_position)
		active_probes.push_back(probe)
	if points.is_empty():
		return

	var samples := ocean.sample_water_surface_batch(points)
	var total_weight := _get_total_probe_weight(active_probes)
	var gravity := float(ProjectSettings.get_setting("physics/3d/default_gravity", 9.8))
	for i in active_probes.size():
		_apply_probe_forces(active_probes[i], samples[i], total_weight, gravity)


func refresh_probes() -> void:
	_collect_probes()


func _resolve_nodes() -> void:
	if not rigid_body_path.is_empty():
		rigid_body = get_node_or_null(rigid_body_path) as RigidBody3D
	if rigid_body == null:
		rigid_body = get_parent() as RigidBody3D
	if not ocean_path.is_empty():
		ocean = get_node_or_null(ocean_path) as OceanSystem
	if ocean == null:
		ocean = get_tree().get_first_node_in_group(&"ocean_system") as OceanSystem


func _collect_probes() -> void:
	probes.clear()
	for path in probe_paths:
		var probe := get_node_or_null(path) as BuoyancyProbe
		if probe != null:
			probes.push_back(probe)
	if auto_collect_child_probes:
		var root : Node = rigid_body if rigid_body != null else self
		_collect_probe_descendants(root)


func _collect_probe_descendants(node : Node) -> void:
	for child in node.get_children():
		if child is BuoyancyProbe and not probes.has(child):
			probes.push_back(child)
		_collect_probe_descendants(child)


func _get_total_probe_weight(active_probes : Array[BuoyancyProbe]) -> float:
	var total := 0.0
	for probe in active_probes:
		total += maxf(probe.buoyancy_weight, 0.0)
	return maxf(total, 0.0001)


func _apply_probe_forces(probe : BuoyancyProbe, sample : WaterSurfaceSample, total_weight : float, gravity : float) -> void:
	var probe_position := probe.global_position
	var depth := sample.height - probe_position.y
	var submersion := clampf(depth / maxf(probe.submersion_depth, 0.001), 0.0, 1.0)

	var offset := probe_position - rigid_body.global_position
	var point_velocity := rigid_body.linear_velocity + rigid_body.angular_velocity.cross(offset)
	var weight_ratio := maxf(probe.buoyancy_weight, 0.0) / total_weight
	var water_velocity := sample.surface_velocity * surface_velocity_influence + sample.current_velocity * current_influence

	var buoyancy_direction := sample.normal
	if not sample.valid or buoyancy_direction.length_squared() <= 0.0001:
		buoyancy_direction = Vector3.UP
	else:
		buoyancy_direction = buoyancy_direction.normalized()
	var buoyancy_force := buoyancy_direction * rigid_body.mass * gravity * buoyancy_strength * weight_ratio * submersion
	var vertical_speed := point_velocity.dot(Vector3.UP) - water_velocity.dot(Vector3.UP)
	var vertical_damping_force := -Vector3.UP * vertical_speed * probe.vertical_damping * rigid_body.mass * weight_ratio * submersion

	var horizontal_point_velocity := Vector3(point_velocity.x, 0.0, point_velocity.z)
	var horizontal_surface_velocity := Vector3(sample.surface_velocity.x, 0.0, sample.surface_velocity.z) * surface_velocity_influence
	var horizontal_current_velocity := Vector3(sample.current_velocity.x, 0.0, sample.current_velocity.z) * current_influence
	var water_drag_force := (horizontal_surface_velocity - horizontal_point_velocity) * probe.water_drag * rigid_body.mass * weight_ratio * submersion
	var current_drag_force := (horizontal_current_velocity - horizontal_point_velocity) * probe.current_drag * rigid_body.mass * weight_ratio * submersion

	var total_force := buoyancy_force + vertical_damping_force + water_drag_force + current_drag_force
	probe.set_debug_state(Vector3(probe_position.x, sample.height, probe_position.z), total_force, sample.valid)
	if submersion <= 0.0:
		return
	rigid_body.apply_force(total_force, offset)
