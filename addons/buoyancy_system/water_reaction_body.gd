class_name WaterReactionBody
extends Node
## Applies hydrodynamic reaction forces to a parent RigidBody3D using child
## WaterReactionProbe nodes and an OceanSystem surface query.

@export var rigid_body_path : NodePath
@export var ocean_path : NodePath
@export var auto_collect_child_probes := true
@export var probe_paths : Array[NodePath] = []
@export_range(1.0, 2000.0, 1.0, "or_greater") var water_density := 1025.0
@export_range(0.0, 10.0, 0.01, "or_greater") var surface_velocity_influence := 1.0
@export_range(0.0, 10.0, 0.01, "or_greater") var current_influence := 1.0
@export var apply_forces := true

var rigid_body : RigidBody3D
var ocean : OceanSystem
var probes : Array[WaterReactionProbe] = []
var _has_collected_probes := false
var _previous_probe_positions := {}


func _ready() -> void:
	_resolve_nodes()
	_collect_probes()


func _physics_process(delta : float) -> void:
	if not apply_forces:
		_update_previous_probe_positions()
		return
	if delta <= 0.0:
		return
	if rigid_body == null or ocean == null:
		_resolve_nodes()
	if rigid_body == null or ocean == null:
		return
	if not _has_collected_probes or probes.is_empty():
		_collect_probes()

	var active_probes := _get_active_probes()
	if active_probes.is_empty():
		_update_previous_probe_positions()
		return

	var points := PackedVector3Array()
	for probe in active_probes:
		points.push_back(probe.global_position)
	if points.is_empty():
		return

	var samples := ocean.sample_water_surface_batch(points)
	var sample_count := mini(active_probes.size(), samples.size())
	for i in sample_count:
		_apply_probe_force(active_probes[i], samples[i], delta)
	_update_previous_probe_positions()


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
		var probe := get_node_or_null(path) as WaterReactionProbe
		if probe != null:
			probes.push_back(probe)
	if auto_collect_child_probes:
		var root : Node = rigid_body if rigid_body != null else self
		_collect_probe_descendants(root)
	_has_collected_probes = true


func _collect_probe_descendants(node : Node) -> void:
	for child in node.get_children():
		if child is WaterReactionProbe and not probes.has(child):
			probes.push_back(child)
		_collect_probe_descendants(child)


func _get_active_probes() -> Array[WaterReactionProbe]:
	var active_probes : Array[WaterReactionProbe] = []
	for probe in probes:
		if probe == null or not probe.enabled or not probe.is_inside_tree():
			continue
		active_probes.push_back(probe)
	return active_probes


func _apply_probe_force(probe : WaterReactionProbe, sample : WaterSurfaceSample, delta : float) -> void:
	var probe_position := probe.global_position
	var depth := sample.height - probe_position.y
	var submersion := clampf(depth / maxf(probe.submersion_depth, 0.001), 0.0, 1.0)
	var force := Vector3.ZERO

	if submersion > 0.0:
		var probe_velocity := _get_probe_velocity(probe, delta)
		var water_velocity := sample.surface_velocity * surface_velocity_influence + sample.current_velocity * current_influence
		var relative_velocity := probe_velocity - water_velocity
		var blade_normal := probe.get_blade_normal()
		var normal_speed := relative_velocity.dot(blade_normal)
		var normal_force := -blade_normal * normal_speed * absf(normal_speed) * 0.5 * water_density * probe.blade_area * probe.normal_drag

		var tangent_velocity := relative_velocity - blade_normal * normal_speed
		var tangent_force := Vector3.ZERO
		var tangent_speed := tangent_velocity.length()
		if tangent_speed > 0.0001:
			tangent_force = -tangent_velocity.normalized() * tangent_speed * tangent_speed * 0.5 * water_density * probe.blade_area * probe.tangent_drag

		force = (normal_force + tangent_force) * probe.force_multiplier * submersion
		if probe.max_force > 0.0 and force.length_squared() > probe.max_force * probe.max_force:
			force = force.normalized() * probe.max_force

	probe.set_debug_state(Vector3(probe_position.x, sample.height, probe_position.z), force, sample.valid)
	if force.length_squared() <= 0.0001:
		return

	var offset := probe_position - rigid_body.global_position
	rigid_body.apply_force(force, offset)


func _get_probe_velocity(probe : WaterReactionProbe, delta : float) -> Vector3:
	if _previous_probe_positions.has(probe):
		return (probe.global_position - _previous_probe_positions[probe]) / delta
	var offset := probe.global_position - rigid_body.global_position
	return rigid_body.linear_velocity + rigid_body.angular_velocity.cross(offset)


func _update_previous_probe_positions() -> void:
	for probe in probes:
		if probe == null or not probe.is_inside_tree():
			continue
		_previous_probe_positions[probe] = probe.global_position
