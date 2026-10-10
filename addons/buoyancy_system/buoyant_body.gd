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
# Water resistance follows Morison's equation for bodies small next to the
# waves: quadratic drag ½·ρ·C_d·area·|v|·v along each of the body's up, forward
# and right axes, against the velocity across that face relative to the water
# (which moves with the waves), plus wave-making damping and added mass.

## Drag coefficient along the body's up axis, against the column's
## cross-section (volume / buoyancy_height): about 1 for a blunt body, 2 for a
## flat plate.
@export_range(0.0, 10.0, 0.01, "or_greater") var vertical_drag_coefficient := 1.0
## Drag coefficient along the body's forward axis, against the column's wetted
## side (width × submerged height). Side by side, the columns' sides add up to
## more than a hull's frontal area, so a streamlined hull is around 0.05.
@export_range(0.0, 10.0, 0.001, "or_greater") var longitudinal_drag_coefficient := 1.0
## Drag coefficient along the body's right axis, against the column's wetted
## side: about 1 for a hull's side or keel.
@export_range(0.0, 10.0, 0.001, "or_greater") var lateral_drag_coefficient := 1.0
## Linear damping of each probe's bobbing as a fraction of critical damping
## (from its waterplane stiffness and its share of the mass), against its
## vertical velocity relative to the water: the energy a floating body radiates
## as waves. Damps heave, pitch and roll where the quadratic drag is too weak
## (small, slow motion). Ships are around 0.1-0.3.
@export_range(0.0, 2.0, 0.01, "or_greater") var heave_damping_ratio := 0.2
## Added mass in heave, as a multiple of the submerged volume's water mass: the
## water that has to move with the body. It adds inertia but no weight, so it
## slows the bobbing without changing the draft. About 1 for a hull. Heave only:
## pitch and roll get no added inertia.
@export_range(0.0, 5.0, 0.01, "or_greater") var added_mass_coefficient := 1.0
## Safety cap for the acceleration any single probe's buoyancy, and separately
## its drag, can contribute. 0 disables it.
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
## Physics time (s) this node has run: the clock of probe states and events.
var _physics_time := 0.0

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
## sqrt(volume / height): the side of a square column, for tilted columns.
var _column_widths := PackedFloat32Array()
var _longitudinal_drag := PackedFloat32Array()
var _lateral_drag := PackedFloat32Array()
## Water vertical velocity and acceleration at each physical probe, from the
## last two results (for the added mass), and the clock of the last one.
var _water_velocity_y := PackedFloat32Array()
var _water_acceleration_y := PackedFloat32Array()
var _water_sample_time := -INF
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


func _physics_process(delta : float) -> void:
	_physics_time += delta
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
	_update_water_acceleration(result)
	# Drag acts along the body's own axes, so it stays well defined however the
	# body lies. The areas come from each column's geometry, so the coefficients
	# mean the same in every orientation.
	var body_basis := body_transform.basis.orthonormalized()
	var body_up := body_basis.y
	var forward := -body_basis.z
	var right := body_basis.x
	var mass := rigid_body.mass
	var linear_velocity := rigid_body.linear_velocity
	var angular_velocity := rigid_body.angular_velocity
	var body_state := PhysicsServer3D.body_get_direct_state(rigid_body.get_rid())
	# Probe forces are summed into one force and one torque about the center of mass
	# (what apply_force() at each probe adds up to), sent with two calls per tick.
	var center_of_mass := body_state.center_of_mass
	# Columns hang from their probes along the body's down axis and turn with it:
	# a capsized body displaces what it does upright, instead of floating a column
	# height higher (columns hanging below the inverted hull).
	var column_tilt := sqrt(maxf(1.0 - body_up.y * body_up.y, 0.0))

	var total_external_force := Vector3.ZERO
	var total_torque := Vector3.ZERO
	var added_mass := 0.0
	var added_mass_water_force := 0.0
	for i in _force_states.size():
		var sample := result.samples[i]
		var water_height := sample.extrapolated_height(elapsed)
		var position := _points[i]
		var column_height := _column_heights[i]
		var column_width := _column_widths[i]
		var column := body_up * column_height
		var column_center := position - column * 0.5
		# A tilted column is a prism of its own width, so the submerged share stays
		# smooth all the way to a horizontal column.
		var vertical_extent := column_height * absf(body_up.y) + column_width * column_tilt
		var submersion := clampf((water_height - column_center.y) / vertical_extent + 0.5, 0.0, 1.0)
		var applied_force := Vector3.ZERO
		if submersion > 0.0:
			var probe_mass := mass * _volume_shares[i]
			# Forces act at the submerged part's centre: from the column's lower end
			# (fully dry) to its centre (fully wet), along the column's vertical span.
			var force_point := column_center + column * (body_up.y * (submersion - 1.0) * 0.5)
			# linear_velocity is the center of mass's, so the lever arm is from there.
			var arm := force_point - body_transform.origin - center_of_mass
			var relative_velocity := linear_velocity + angular_velocity.cross(arm) - sample.surface_velocity
			var max_force := probe_mass * max_probe_acceleration if max_probe_acceleration > 0.0 else INF
			# Buoyancy and drag are capped separately. Capping their sum let a deeply
			# submerged probe's buoyancy swallow its drag (the sum stayed at the cap
			# whichever way the probe moved), so a body that dived bounced undamped and
			# the waves pumped it higher with every bounce.
			var buoyancy := water_density * _gravity * buoyancy_strength * _max_volumes[i] * submersion
			var buoyancy_force := Vector3.UP * minf(buoyancy, max_force)

			# Quadratic drag per body axis, each from the velocity across that face
			# alone (the cross-flow principle: moving forward does not stiffen the
			# sides), as a rate on the probe's share of the mass (see
			# _stable_drag_rate()). The end face meets the water fully once it is a
			# column width deep; the sides are wet over the submerged height.
			var drag_per_area := 0.5 * water_density / probe_mass
			var end_area := column_width * column_width * minf(submersion * vertical_extent / column_width, 1.0)
			var side_area := column_width * column_height * submersion
			var up_speed := relative_velocity.dot(body_up)
			var forward_speed := relative_velocity.dot(forward)
			var right_speed := relative_velocity.dot(right)
			var drag_acceleration := -body_up * up_speed * _stable_drag_rate(drag_per_area * vertical_drag_coefficient * end_area * absf(up_speed), delta)
			drag_acceleration -= forward * forward_speed * _stable_drag_rate(drag_per_area * longitudinal_drag_coefficient * _longitudinal_drag[i] * side_area * absf(forward_speed), delta)
			drag_acceleration -= right * right_speed * _stable_drag_rate(drag_per_area * lateral_drag_coefficient * _lateral_drag[i] * side_area * absf(right_speed), delta)
			# Wave-making damping while the column crosses the surface (where its
			# waterplane gives it a stiffness k): c = 2·ζ·√(k·m).
			if submersion < 1.0 and heave_damping_ratio > 0.0:
				var stiffness := water_density * _gravity * buoyancy_strength * _max_volumes[i] / vertical_extent
				drag_acceleration.y -= relative_velocity.y * _stable_drag_rate(2.0 * heave_damping_ratio * sqrt(stiffness / probe_mass), delta)
			var drag_force := drag_acceleration * probe_mass
			if drag_force.length_squared() > max_force * max_force:
				drag_force = drag_force.normalized() * max_force
			applied_force = buoyancy_force + drag_force
			total_external_force += applied_force
			total_torque += arm.cross(applied_force)
			var probe_added_mass := water_density * added_mass_coefficient * _max_volumes[i] * submersion
			added_mass += probe_added_mass
			added_mass_water_force += probe_added_mass * _water_acceleration_y[i]
		_update_state(_force_states[i], position, sample, water_height, applied_force, submersion, _physics_time)

	# Added mass in heave: (m + M_a)·a = F + m·g + M_a·a_water. The engine only
	# knows m, so add the force that gives that acceleration. It comes from this
	# tick's forces, not from measured accelerations, so it cannot feed back and
	# go unstable however large M_a gets.
	if added_mass > 0.0:
		var net_vertical_force := total_external_force.y + mass * body_state.total_gravity.y
		total_external_force.y += (mass * added_mass_water_force - added_mass * net_vertical_force) / (mass + added_mass)

	if total_external_force != Vector3.ZERO:
		rigid_body.apply_central_force(total_external_force)
		rigid_body.apply_torque(total_torque)

	var force_count := _force_states.size()
	for j in _contact_states.size():
		var sample := result.samples[force_count + j]
		_update_state(_contact_states[j], _points[force_count + j], sample, sample.extrapolated_height(elapsed), Vector3.ZERO, 0.0, _physics_time)

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


## Estimates the water's vertical acceleration at each physical probe from the
## surface velocity of the last two results (once per new result).
func _update_water_acceleration(result : WaterSurfaceQueryResult) -> void:
	if result.dispatch_time == _water_sample_time:
		return
	var interval := result.dispatch_time - _water_sample_time
	for i in _force_states.size():
		var velocity_y := result.samples[i].surface_velocity.y
		# The first result (also after the probe set changed) has no predecessor;
		# the cap keeps a stalled readback from spiking it.
		var acceleration := (velocity_y - _water_velocity_y[i]) / interval if is_finite(_water_sample_time) and interval > 0.0 else 0.0
		_water_acceleration_y[i] = clampf(acceleration, -2.0 * _gravity, 2.0 * _gravity)
		_water_velocity_y[i] = velocity_y
	_water_sample_time = result.dispatch_time


## Drag rate (1/s) that removes over one tick of delta what rate would remove
## continuously: never more than the relative velocity, so even strong drag
## cannot overshoot and oscillate.
static func _stable_drag_rate(rate : float, delta : float) -> float:
	return (1.0 - exp(-rate * delta)) / delta if delta > 0.0 else rate


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
	_column_widths.resize(force_count)
	_longitudinal_drag.resize(force_count)
	_lateral_drag.resize(force_count)
	_water_velocity_y.resize(force_count)
	_water_acceleration_y.resize(force_count)
	_water_acceleration_y.fill(0.0)
	_water_sample_time = -INF
	_states_by_probe.clear()
	var total_volume := 0.0
	for i in force_count:
		var probe := _force_states[i].probe as BuoyancyProbeNode
		_body_offsets[i] = to_body * probe.global_position
		_max_volumes[i] = probe.max_submerged_volume_cubic_meters
		_column_heights[i] = probe.buoyancy_height
		_column_widths[i] = sqrt(probe.max_submerged_volume_cubic_meters / probe.buoyancy_height)
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
