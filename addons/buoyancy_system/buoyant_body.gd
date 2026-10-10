@tool
class_name BuoyantBody
extends Node
## Applies probe-based buoyancy forces to a parent RigidBody3D using the water
## surface of its world (WaterSurface.find(), e.g. an OceanSystem). FX probes
## are queried in the same batch but never apply forces. With sinking enabled it
## also sinks the body when it rolls over, floods (all sinking probes deep under
## water) or loses a hitbox group.
##
## Probe data is cached when volumes are collected and whenever a volume reports
## probes_changed. Probes must stay rigid relative to the body: each tick only
## transforms their cached body-space positions.

## Emitted when a probe becomes wet (its state's entered is true).
signal probe_entered_water(state: BuoyancyProbeState)
## Emitted when a probe becomes dry (its state's exited is true).
signal probe_exited_water(state: BuoyancyProbeState)
## Emitted once when the body starts sinking. reason is &"roll", &"draft",
## &"hitbox_group_destroyed" or the one passed to start_sinking(); data holds its details.
signal sinking_started(reason: StringName, data: Dictionary)

## Optional rigid body target. Leave empty to use the parent or nearest ancestor RigidBody3D.
@export var rigid_body_path : NodePath :
	set(value):
		rigid_body_path = value
		update_configuration_warnings()
## Automatically includes child BuoyancyProbeVolume nodes in addition to explicit paths.
@export var auto_collect_child_volumes := true
## Explicit probe volumes used by this buoyant body.
@export var probe_volume_paths : Array[NodePath] = []
## Global multiplier for all buoyancy force output.
@export_range(0.0, 10.0, 0.01, "or_greater") var buoyancy_strength := 1.0
## Fluid density in kg/m^3. Seawater is usually around 1025.
@export_range(1.0, 2000.0, 1.0, "or_greater") var water_density := 1025.0
## Vertical water drag applied at each physical probe, in 1/s, against the probe's
## vertical velocity relative to the water there. Damps heave, pitch and roll
## relative to the surface, so the body still rides the waves.
@export_range(0.0, 100.0, 0.01, "or_greater") var vertical_water_drag := 2.0
## Body-forward/back water drag applied at each physical probe, against the
## probe's velocity relative to the water (which moves with the waves).
@export_range(0.0, 100.0, 0.01, "or_greater") var longitudinal_water_drag := 0.45
## Body-sideways water drag applied at each physical probe, against the probe's
## velocity relative to the water.
@export_range(0.0, 100.0, 0.01, "or_greater") var lateral_water_drag := 0.45
## Safety cap for acceleration contributed by any single probe.
@export_range(0.0, 100.0, 0.1, "or_greater") var max_probe_acceleration := 35.0
## Enables applying forces. Disable to keep query/contact state without affecting physics.
@export var apply_forces := true

@export_group("Sinking")
## Enables roll, draft and damage-triggered sinking. start_sinking() works either way.
@export var sinking_enabled := false
## Starts sinking when absolute roll reaches this angle. Set 0 to disable roll sinking.
@export_range(0.0, 180.0, 0.1, "degrees") var max_roll_degrees := 70.0
## Probes that must all be deeper than sink_probe_depth_threshold to start
## sinking. Each must be an enabled probe of this body. Empty disables it.
@export var sinking_probe_paths : Array[NodePath] = []
## Water depth above each sinking probe that counts as flooded.
@export_range(-10.0, 10.0, 0.01) var sink_probe_depth_threshold := 0.5
## Hitbox groups whose destruction starts sinking, reported through
## _on_hitbox_group_destroyed (connect a damage system's signal to it).
@export var sink_on_destroyed_groups : Array[StringName] = [&"hull"]
## buoyancy_strength is multiplied by this once sinking starts.
@export_range(0.0, 1.0, 0.01) var sink_buoyancy_multiplier := 0.3
## Seconds after sinking starts before delete_root_path is freed. 0 frees immediately.
@export_range(0.0, 60.0, 0.01, "or_greater") var delete_delay := 5.0
## Node freed after delete_delay. Empty frees the rigid body.
@export var delete_root_path : NodePath

## The body the forces act on (resolved in _ready).
var rigid_body : RigidBody3D
## The water surface of this body's world (resolved in _ready); null disables buoyancy.
var water : WaterSurface
## The probe volumes in use (see refresh_volumes()).
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
## Water clock (WaterSurface.get_clock()) when the probe set last changed. Results dispatched before
## then answer the old point set.
var _probe_set_time := -INF
var _sinking_probes : Array[Node] = []
var _is_sinking := false


func _ready() -> void:
	if Engine.is_editor_hint():
		set_physics_process(false)
		return
	rigid_body = _resolve_rigid_body()
	water = WaterSurface.find(self)
	if rigid_body == null or water == null:
		if water == null:
			push_error("BuoyantBody %s: no WaterSurface in this world (add an OceanSystem). Buoyancy is disabled." % get_path())
		set_physics_process(false)
		return
	_gravity = float(ProjectSettings.get_setting("physics/3d/default_gravity"))
	_collect_volumes()
	if probe_volumes.is_empty():
		push_error("BuoyantBody found no probe volumes: %s" % get_path())
	for path in sinking_probe_paths:
		var probe := get_node_or_null(path)
		if probe == null:
			push_error("BuoyantBody %s: sinking probe %s not found; ignored." % [get_path(), path])
			continue
		_sinking_probes.push_back(probe)
	# The first surface query result arrives several frames after the first submit,
	# and much later in physics time when startup frames hitch. Hold the body still
	# until then instead of letting it free-fall through the water.
	if apply_forces and not rigid_body.freeze:
		_awaiting_first_sample = true
		rigid_body.freeze = true


func _exit_tree() -> void:
	if water != null:
		water.release_query(self)


func _physics_process(_delta : float) -> void:
	if not apply_forces:
		_end_first_sample_hold()
		return
	if _probe_cache_dirty:
		_rebuild_probe_cache()
	# Every volume and probe is disabled: nothing to float, and no sample to wait for.
	if _points.is_empty():
		_end_first_sample_hold()
		return

	var body_transform := rigid_body.global_transform
	_submit_points(body_transform)
	var result := water.get_query_result(self)
	# The first readback arrives a few frames after the first submit.
	if result == null or result.dispatch_time <= _probe_set_time:
		return
	if result.samples.size() != _points.size():
		push_error("BuoyantBody %s: query result has %d samples for %d probes; tick skipped." % [get_path(), result.samples.size(), _points.size()])
		return
	_end_first_sample_hold()
	var elapsed := water.get_query_age(result)
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
	# Probe forces are summed into one force and one torque about the center of mass
	# (what apply_force() at each probe adds up to), sent with two calls per tick.
	var center_of_mass := PhysicsServer3D.body_get_direct_state(rigid_body.get_rid()).center_of_mass

	var total_external_force := Vector3.ZERO
	var total_torque := Vector3.ZERO
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
			var relative_velocity := linear_velocity + angular_velocity.cross(offset) - sample.surface_velocity
			var buoyancy_force := Vector3.UP * water_density * _gravity * buoyancy_strength * _max_volumes[i] * submersion
			var drag_scale := mass * share * submersion
			var longitudinal_drag_force := -forward * relative_velocity.dot(forward) * longitudinal_water_drag * _longitudinal_drag[i] * drag_scale
			var lateral_drag_force := -right * relative_velocity.dot(right) * lateral_water_drag * _lateral_drag[i] * drag_scale
			var vertical_drag_force := Vector3.DOWN * relative_velocity.y * vertical_water_drag * drag_scale
			applied_force = buoyancy_force + longitudinal_drag_force + lateral_drag_force + vertical_drag_force
			var max_force := mass * share * max_probe_acceleration
			if max_probe_acceleration > 0.0 and applied_force.length_squared() > max_force * max_force:
				applied_force = applied_force.normalized() * max_force
			total_external_force += applied_force
			total_torque += (offset - center_of_mass).cross(applied_force)
		_update_state(_force_states[i], position, sample, water_height, applied_force, submersion, now)

	if total_external_force != Vector3.ZERO:
		rigid_body.apply_central_force(total_external_force)
		rigid_body.apply_torque(total_torque)

	var force_count := _force_states.size()
	for j in _contact_states.size():
		var sample := result.samples[force_count + j]
		_update_state(_contact_states[j], _points[force_count + j], sample, sample.extrapolated_height(elapsed), Vector3.ZERO, 0.0, now)

	_update_volume_debug(total_external_force)
	if sinking_enabled and not _is_sinking:
		_check_sinking()


## Lowers buoyancy, emits sinking_started and frees delete_root_path after
## delete_delay. Only the first call has an effect.
func start_sinking(reason : StringName = &"manual", data : Dictionary = {}) -> void:
	if _is_sinking:
		return
	_is_sinking = true
	buoyancy_strength *= sink_buoyancy_multiplier
	sinking_started.emit(reason, data)
	var delete_root : Node = rigid_body
	if not delete_root_path.is_empty():
		delete_root = get_node_or_null(delete_root_path)
		if delete_root == null:
			push_error("BuoyantBody %s: delete_root_path %s not found; freeing the rigid body instead." % [get_path(), delete_root_path])
			delete_root = rigid_body
	if delete_delay <= 0.0:
		delete_root.queue_free()
	else:
		get_tree().create_timer(delete_delay).timeout.connect(delete_root.queue_free)


## Whether start_sinking() has run.
func is_sinking() -> bool:
	return _is_sinking


func _on_hitbox_group_destroyed(hitbox_group : StringName, hit_data : Dictionary) -> void:
	if sinking_enabled and sink_on_destroyed_groups.has(hitbox_group):
		start_sinking(&"hitbox_group_destroyed", {"hitbox_group": hitbox_group, "hit_data": hit_data})


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


## States of the probes that are under water, optionally only those with tag_filter.
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


## Releases the body held frozen until the first water sample (see _ready()).
func _end_first_sample_hold() -> void:
	if _awaiting_first_sample:
		_awaiting_first_sample = false
		rigid_body.freeze = false


func _get_configuration_warnings() -> PackedStringArray:
	var warnings := PackedStringArray()
	var body : Node = get_node_or_null(rigid_body_path) if not rigid_body_path.is_empty() else _find_parent_rigid_body()
	if not body is RigidBody3D:
		warnings.push_back("Needs a RigidBody3D to float: make it a descendant of one, or set rigid_body_path.")
	elif probe_volume_paths.is_empty() and not (auto_collect_child_volumes and not body.find_children("*", "BuoyancyProbeVolume", true, false).is_empty()):
		warnings.push_back("No BuoyancyProbeVolume under the body (or in probe_volume_paths): nothing makes it float.")
	return warnings


## Null (reported) when the configured body is missing or not a RigidBody3D.
func _resolve_rigid_body() -> RigidBody3D:
	if not rigid_body_path.is_empty():
		var target := get_node_or_null(rigid_body_path)
		if not target is RigidBody3D:
			push_error("BuoyantBody %s: rigid_body_path %s is not a RigidBody3D. Buoyancy is disabled." % [get_path(), rigid_body_path])
			return null
		return target as RigidBody3D
	var ancestor := _find_parent_rigid_body()
	if ancestor == null:
		push_error("BuoyantBody %s: rigid_body_path is empty and no ancestor is a RigidBody3D. Buoyancy is disabled." % get_path())
	return ancestor


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
		var node := get_node_or_null(path)
		if not node is BuoyancyProbeVolume:
			push_error("BuoyantBody %s: probe_volume_paths entry %s is not a BuoyancyProbeVolume; ignored." % [get_path(), path])
			continue
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
	_probe_set_time = water.get_clock()
	if point_count == 0:
		water.release_query(self)
	else:
		_submit_points(rigid_body.global_transform)


func _submit_points(body_transform : Transform3D) -> void:
	for i in _points.size():
		_points[i] = body_transform * _body_offsets[i]
	water.submit_query(self, _points, rigid_body)


func _update_state(state : BuoyancyProbeState, position : Vector3, sample : WaterSurfaceSample, water_height : float, applied_force : Vector3, submersion : float, now : float) -> void:
	state.update(position, sample, water_height, applied_force, submersion, now)
	if state.entered:
		probe_entered_water.emit(state)
	elif state.exited:
		probe_exited_water.emit(state)


func _check_sinking() -> void:
	var roll_degrees := _get_abs_roll_degrees()
	if max_roll_degrees > 0.0 and roll_degrees >= max_roll_degrees:
		start_sinking(&"roll", {"roll_degrees": roll_degrees})
		return
	if _sinking_probes.is_empty():
		return
	var deepest_depth := -INF
	for probe in _sinking_probes:
		var state := get_probe_state(probe)
		# A disabled probe has no state and cannot be flooded.
		if state == null:
			return
		if state.depth < sink_probe_depth_threshold:
			return
		deepest_depth = maxf(deepest_depth, state.depth)
	start_sinking(&"draft", {"probe_count": _sinking_probes.size(), "deepest_depth": deepest_depth})


func _get_abs_roll_degrees() -> float:
	var basis := rigid_body.global_transform.basis.orthonormalized()
	var roll_axis := basis.z
	var target_up := Vector3.UP - roll_axis * Vector3.UP.dot(roll_axis)
	# Bow pointing straight up or down: roll is undefined.
	if target_up.length_squared() <= 0.0001:
		return 0.0
	return absf(rad_to_deg(basis.y.signed_angle_to(target_up.normalized(), roll_axis)))


func _update_volume_debug(total_external_force : Vector3) -> void:
	var center_of_mass_world := rigid_body.global_transform * rigid_body.center_of_mass
	var gravity_force := Vector3.DOWN * rigid_body.mass * _gravity
	for volume in probe_volumes:
		if volume.debug_enabled:
			volume.set_debug_body_state(center_of_mass_world, gravity_force, total_external_force, true)
