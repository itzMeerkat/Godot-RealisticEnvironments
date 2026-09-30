class_name BuoyantBody
extends Node
## Applies probe-based buoyancy forces to a parent RigidBody3D using OceanSystem's
## batched GPU water-surface query. FX probes are queried in the same batch but
## never apply forces.
##
## Probe data is cached when volumes are collected and whenever a volume reports
## probes_changed. Probes must stay rigid relative to the body: each tick only
## transforms their cached body-space positions.

signal probe_entered_water(state: BuoyancyProbeState)
signal probe_exited_water(state: BuoyancyProbeState)

## Optional rigid body target. Leave empty to use the parent or nearest ancestor RigidBody3D.
@export var rigid_body_path : NodePath
## Optional OceanSystem target. Leave empty to use the first node in the ocean_system group.
@export var ocean_path : NodePath
## Automatically includes child BuoyancyProbeVolume nodes in addition to explicit paths.
@export var auto_collect_child_volumes := true
## Explicit probe volumes used by this buoyant body.
@export var probe_volume_paths : Array[NodePath] = []
## Global multiplier for all buoyancy force output.
@export_range(0.0, 10.0, 0.01, "or_greater") var buoyancy_strength := 1.0
## Fluid density in kg/m^3. Seawater is usually around 1025.
@export_range(1.0, 2000.0, 1.0, "or_greater") var water_density := 1025.0
## Central vertical damping that suppresses bobbing without adding probe torque.
@export_range(0.0, 20.0, 0.01, "or_greater") var heave_damping := 2.0
## Body-forward/back water drag applied at each physical probe.
@export_range(0.0, 100.0, 0.01, "or_greater") var longitudinal_water_drag := 0.45
## Body-sideways water drag applied at each physical probe.
@export_range(0.0, 100.0, 0.01, "or_greater") var lateral_water_drag := 0.45
## Safety cap for acceleration contributed by any single probe.
@export_range(0.0, 100.0, 0.1, "or_greater") var max_probe_acceleration := 35.0
## Enables applying forces. Disable to keep query/contact state without affecting physics.
@export var apply_forces := true

var rigid_body : RigidBody3D
var ocean : OceanSystem
var probe_volumes : Array[BuoyancyProbeVolume] = []
## True while the body is held frozen waiting for its first water sample.
var _awaiting_first_sample := false
var _gravity := 9.8

# Probe cache. Force (physical) probes come first in every per-point array,
# contact probes after them.
var _probe_cache_dirty := true
var _force_states : Array[BuoyancyProbeState] = []
var _contact_states : Array[BuoyancyProbeState] = []
var _states_by_probe := {}
var _body_offsets := PackedVector3Array()
var _points := PackedVector3Array()
var _max_volumes := PackedFloat32Array()
var _volume_shares := PackedFloat32Array()
var _column_heights := PackedFloat32Array()
var _longitudinal_drag := PackedFloat32Array()
var _lateral_drag := PackedFloat32Array()
## OceanSystem.time when the probe set last changed. Results dispatched before
## then answer the old point set.
var _probe_set_time := -INF


func _ready() -> void:
	rigid_body = _resolve_rigid_body()
	ocean = _resolve_ocean()
	_gravity = float(ProjectSettings.get_setting("physics/3d/default_gravity"))
	_collect_volumes()
	if probe_volumes.is_empty():
		push_error("BuoyantBody found no probe volumes: %s" % get_path())
	# The first surface query result arrives several frames after the first submit,
	# and much later in physics time when startup frames hitch. Hold the body still
	# until then instead of letting it free-fall through the water.
	if apply_forces and not rigid_body.freeze:
		_awaiting_first_sample = true
		rigid_body.freeze = true


func _exit_tree() -> void:
	# On scene teardown the ocean may already be freed; its queries go with it.
	if is_instance_valid(ocean):
		ocean.release_surface_query(self)


func _physics_process(_delta : float) -> void:
	if not apply_forces:
		return
	if _probe_cache_dirty:
		_rebuild_probe_cache()
	# Every volume and probe is disabled: nothing to float.
	if _points.is_empty():
		return

	var body_transform := rigid_body.global_transform
	_submit_points(body_transform)
	var result := ocean.get_surface_query_result(self)
	# The first readback arrives a few frames after the first submit.
	if result == null or result.dispatch_time <= _probe_set_time:
		return
	assert(result.samples.size() == _points.size(), "BuoyantBody %s: query result has %d samples for %d probes." % [get_path(), result.samples.size(), _points.size()])
	if _awaiting_first_sample:
		_awaiting_first_sample = false
		rigid_body.freeze = false
	var elapsed := ocean.time - result.dispatch_time
	var now := float(Time.get_ticks_msec()) * 0.001

	var forward := -body_transform.basis.z
	forward.y = 0.0
	forward = forward.normalized() if forward.length_squared() > 0.0001 else Vector3.FORWARD
	var right := body_transform.basis.x
	right.y = 0.0
	right = right.normalized() if right.length_squared() > 0.0001 else Vector3.RIGHT
	var mass := rigid_body.mass
	var linear_velocity := rigid_body.linear_velocity
	var angular_velocity := rigid_body.angular_velocity

	var total_external_force := Vector3.ZERO
	var heave_submersion := 0.0
	for i in _force_states.size():
		var sample := result.samples[i]
		var water_height := sample.extrapolated_height(elapsed)
		var position := _points[i]
		var column_height := _column_heights[i]
		var submersion := clampf(water_height - (position.y - column_height), 0.0, column_height) / column_height
		var applied_force := Vector3.ZERO
		if submersion > 0.0:
			var share := _volume_shares[i]
			var offset := position - body_transform.origin
			var point_velocity := linear_velocity + angular_velocity.cross(offset)
			var buoyancy_force := Vector3.UP * water_density * _gravity * buoyancy_strength * _max_volumes[i] * submersion
			var drag_scale := mass * share * submersion
			var longitudinal_drag_force := -forward * point_velocity.dot(forward) * longitudinal_water_drag * _longitudinal_drag[i] * drag_scale
			var lateral_drag_force := -right * point_velocity.dot(right) * lateral_water_drag * _lateral_drag[i] * drag_scale
			applied_force = buoyancy_force + longitudinal_drag_force + lateral_drag_force
			var max_force := mass * share * max_probe_acceleration
			if max_probe_acceleration > 0.0 and applied_force.length_squared() > max_force * max_force:
				applied_force = applied_force.normalized() * max_force
			rigid_body.apply_force(applied_force, offset)
			total_external_force += applied_force
			heave_submersion += share * submersion
		_update_state(_force_states[i], position, sample, water_height, applied_force, submersion, now)

	var force_count := _force_states.size()
	for j in _contact_states.size():
		var sample := result.samples[force_count + j]
		_update_state(_contact_states[j], _points[force_count + j], sample, sample.extrapolated_height(elapsed), Vector3.ZERO, 0.0, now)

	total_external_force += _apply_heave_damping(clampf(heave_submersion, 0.0, 1.0))
	_update_volume_debug(total_external_force)


## Re-collects probe volumes (after adding or removing volumes at runtime).
func refresh_volumes() -> void:
	_collect_volumes()


## Every enabled probe's state, or only those with the given tag. States that
## have not been sampled yet have has_sample == false.
func get_probe_states(tag_filter := "") -> Array[BuoyancyProbeState]:
	if _probe_cache_dirty:
		_rebuild_probe_cache()
	var states : Array[BuoyancyProbeState] = []
	for state in _force_states + _contact_states:
		if tag_filter == "" or state.tag == tag_filter:
			states.push_back(state)
	return states


func get_wet_probe_states(tag_filter := "") -> Array[BuoyancyProbeState]:
	var states : Array[BuoyancyProbeState] = []
	for state in get_probe_states(tag_filter):
		if state.is_wet:
			states.push_back(state)
	return states


## State of one probe node, or null if it is not an enabled probe of this body.
func get_probe_state(probe : Node) -> BuoyancyProbeState:
	if _probe_cache_dirty:
		_rebuild_probe_cache()
	return _states_by_probe.get(probe.get_instance_id())


func _resolve_rigid_body() -> RigidBody3D:
	if not rigid_body_path.is_empty():
		var target := get_node(rigid_body_path)
		assert(target is RigidBody3D, "BuoyantBody %s: rigid_body_path points to %s (%s), not a RigidBody3D." % [get_path(), target.get_path(), target.get_class()])
		return target as RigidBody3D
	var ancestor := _find_parent_rigid_body()
	assert(ancestor != null, "BuoyantBody %s: rigid_body_path is empty and no ancestor is a RigidBody3D." % get_path())
	return ancestor


func _resolve_ocean() -> OceanSystem:
	if not ocean_path.is_empty():
		var target := get_node(ocean_path)
		assert(target is OceanSystem, "BuoyantBody %s: ocean_path points to %s (%s), not an OceanSystem." % [get_path(), target.get_path(), target.get_class()])
		return target as OceanSystem
	var found := get_tree().get_first_node_in_group(&"ocean_system") as OceanSystem
	assert(found != null, "BuoyantBody %s: ocean_path is empty and no OceanSystem is in group 'ocean_system'." % get_path())
	return found


func _find_parent_rigid_body() -> RigidBody3D:
	var node := get_parent()
	while node != null:
		if node is RigidBody3D:
			return node
		node = node.get_parent()
	return null


func _collect_volumes() -> void:
	for volume in probe_volumes:
		if volume.probes_changed.is_connected(_on_probes_changed):
			volume.probes_changed.disconnect(_on_probes_changed)
	probe_volumes.clear()
	for path in probe_volume_paths:
		var node := get_node(path)
		assert(node is BuoyancyProbeVolume, "BuoyantBody %s: probe_volume_paths entry %s is not a BuoyancyProbeVolume." % [get_path(), node.get_path()])
		if not probe_volumes.has(node):
			probe_volumes.push_back(node)
	if auto_collect_child_volumes:
		_collect_probe_volume_descendants(rigid_body)
	for volume in probe_volumes:
		volume.probes_changed.connect(_on_probes_changed)
	_probe_cache_dirty = true


func _collect_probe_volume_descendants(node : Node) -> void:
	for child in node.get_children():
		if child is BuoyancyProbeVolume and not probe_volumes.has(child):
			probe_volumes.push_back(child)
		_collect_probe_volume_descendants(child)


func _on_probes_changed() -> void:
	_probe_cache_dirty = true


func _rebuild_probe_cache() -> void:
	_probe_cache_dirty = false
	_force_states.clear()
	_contact_states.clear()
	for volume in probe_volumes:
		_force_states.append_array(volume.get_physical_probe_states())
		_contact_states.append_array(volume.get_contact_probe_states())

	var force_count := _force_states.size()
	var point_count := force_count + _contact_states.size()
	var to_body := rigid_body.global_transform.affine_inverse()
	_body_offsets.resize(point_count)
	_points.resize(point_count)
	_max_volumes.resize(force_count)
	_volume_shares.resize(force_count)
	_column_heights.resize(force_count)
	_longitudinal_drag.resize(force_count)
	_lateral_drag.resize(force_count)
	_states_by_probe.clear()
	var total_volume := 0.0
	for i in force_count:
		var probe := _force_states[i].probe as BuoyancyProbeNode
		_body_offsets[i] = to_body * probe.global_position
		_max_volumes[i] = probe.max_submerged_volume_cubic_meters
		_column_heights[i] = probe.buoyancy_height
		_longitudinal_drag[i] = probe.longitudinal_water_drag_multiplier
		_lateral_drag[i] = probe.lateral_water_drag_multiplier
		_states_by_probe[probe.get_instance_id()] = _force_states[i]
		total_volume += _max_volumes[i]
	for i in force_count:
		_volume_shares[i] = _max_volumes[i] / total_volume
	for j in _contact_states.size():
		var probe := _contact_states[j].probe
		_body_offsets[force_count + j] = to_body * probe.global_position
		_states_by_probe[probe.get_instance_id()] = _contact_states[j]
	# Replace any queued submission of the old probe set, so every dispatch after
	# this moment answers the new one.
	_probe_set_time = ocean.time
	if point_count == 0:
		ocean.release_surface_query(self)
	else:
		_submit_points(rigid_body.global_transform)


func _submit_points(body_transform : Transform3D) -> void:
	for i in _points.size():
		_points[i] = body_transform * _body_offsets[i]
	ocean.submit_surface_query(self, _points)


func _update_state(state : BuoyancyProbeState, position : Vector3, sample : WaterSurfaceSample, water_height : float, applied_force : Vector3, submersion : float, now : float) -> void:
	state.update(position, sample, water_height, applied_force, submersion, now)
	if state.entered:
		probe_entered_water.emit(state)
	elif state.exited:
		probe_exited_water.emit(state)


func _apply_heave_damping(submersion: float) -> Vector3:
	if submersion <= 0.0 or heave_damping <= 0.0:
		return Vector3.ZERO
	var heave_force := Vector3.UP * (-rigid_body.linear_velocity.y * heave_damping * rigid_body.mass * submersion)
	rigid_body.apply_central_force(heave_force)
	return heave_force


func _update_volume_debug(total_external_force : Vector3) -> void:
	var center_of_mass_world := rigid_body.global_transform * rigid_body.center_of_mass
	var gravity_force := Vector3.DOWN * rigid_body.mass * _gravity
	for volume in probe_volumes:
		if volume.debug_enabled:
			volume.set_debug_body_state(center_of_mass_world, gravity_force, total_external_force, true)
