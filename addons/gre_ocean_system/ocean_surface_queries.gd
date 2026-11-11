class_name GREOceanSurfaceQueries
extends GREWaterSurface
## The ocean's GREWaterSurface: batches every owner's query points into one compute
## dispatch per frame and reads the results back asynchronously, and keeps the hulls
## reported for the interactive waves (GREOceanInteraction reads them). Owned by
## GREOceanSystem, which registers it for its world.
##
## Results leave the interactive waves out unless their owner set a wave response
## (set_query_wave_response(): the simulated waves, its own hull's footprint filled from
## around it) or is the interaction owner (GREOceanSystem's camera, which gets the drawn
## height to tell above from below).
##
## A ring of SLOT_COUNT buffer sets lets new dispatches start while earlier
## readbacks are still in flight; each slot is reused only after its readback
## has been delivered.

const SHADER_PATH := 'res://addons/gre_ocean_system/shaders/compute/surface_query.glsl'
const SLOT_COUNT := 3
const WORKGROUP_SIZE := 64
## Points are uploaded as xyz plus their owner's record index (a vec4).
const FLOATS_PER_POINT := 4
const BYTES_PER_POINT := FLOATS_PER_POINT * 4
## Floats of one owner record (QueryOwner in surface_query.glsl): its hull's pose and
## shape, and its wave response.
const FLOATS_PER_OWNER := 8
## Floats of one cascade record (OceanCascade in ocean_sampling.glslinc).
const FLOATS_PER_CASCADE := 12
const BYTES_PER_CASCADE := FLOATS_PER_CASCADE * 4
const BYTES_PER_SAMPLE := 48
const FLOATS_PER_SAMPLE := 12
const NORMAL_SAMPLE_DISTANCE := 0.25
## Edge of the window (share of its half size) where the interactive waves start to fade
## out, as interaction_fade() in water.gdshaderinc.
const INTERACTION_FADE_START := 0.8
## The rim that stands in for the waves inside an owner's own hull: its footprint grown
## by this share of its size, and at least WAVE_RESPONSE_RIM_CELLS cells of the
## simulation, past the water it displaces (which the cells blur) but close enough for
## its bow wave.
const WAVE_RESPONSE_RIM := 1.3
const WAVE_RESPONSE_RIM_CELLS := 3.0
## A moving hull leaves a hollow behind it that the water takes about half the period of
## a wave as long as the hull to fill: the rim stretches back along the hull's motion
## through the water over this share of that period, so the stern does not sink into it.
const WAVE_RESPONSE_TRAIL := 0.5

class QuerySlot:
	var capacity := 0
	var point_buffer := RID()
	var owner_buffer := RID()
	var cascade_buffer := RID()
	var sample_buffer := RID()
	## "displacement_a_rid:displacement_b_rid:interaction_map_rid:interaction_state_rid"
	## -> uniform set RID.
	var uniform_sets := {}
	var in_flight := false
	var points := PackedVector3Array()
	## [{owner_id, offset, count}] in dispatch order.
	var requests : Array[Dictionary] = []
	var dispatch_time := 0.0

## Frames whose queued queries could not be dispatched because every slot was
## still waiting on a readback. The queries stay queued for the next frame.
var skipped_dispatch_count := 0

var _device : RenderingDevice
## The ocean clock (s), advanced once per frame (advance_clock()), and the physics
## frame, interpolation fraction and physics step at that moment.
var _clock := 0.0
var _clock_physics_frame := 0
var _clock_physics_fraction := 0.0
var _physics_step := 0.0
## The surface drift (m/s), set every frame by GREOceanSystem.
var _surface_drift := Vector3.ZERO
var _shader : RID
var _pipeline : RID
var _slots : Array[QuerySlot] = []
var _queued := {}   # owner_id -> PackedVector3Array
var _owners := {}   # owner_id -> true, for owners that have not been released
var _results := {}  # owner_id -> GREWaterSurfaceQueryResult
var _disturbances := {}  # owner_id -> GREWaterDisturbance (copies)
## Owner id -> [position (x, z), physics frame, velocity through the water (x, z)] of its
## hull at its last report.
var _hull_motions := {}
## Owner id -> how much of the interactive waves its results include (set_query_wave_response()).
var _wave_responses := {}
## The owner whose points get the interactive waves' drawn height (0: none).
var _interaction_owner_id := 0
var _retired := false
var _displacement_sampler : RID
## 1x1 zero maps and a small zero buffer bound in place of the wave displacement maps
## (a flat ocean: no cascades or no generator) and of the interactive waves' map and
## state while there are none.
var _flat_displacement_maps : RID
var _flat_interaction_map : RID
var _flat_interaction_state : RID


## Sampler for the wave displacement maps in compute shaders (ocean_sampling.glslinc):
## repeat wrapping and bilinear filtering, as the water material samples them.
static func create_displacement_sampler_state() -> RDSamplerState:
	return GRERenderingContext.linear_sampler_state(RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT)


func _init(device : RenderingDevice) -> void:
	_device = device
	var shader_file : RDShaderFile = load(SHADER_PATH)
	var spirv := shader_file.get_spirv()
	if spirv.compile_error_compute.is_empty():
		_shader = _device.shader_create_from_spirv(spirv)
		_pipeline = _device.compute_pipeline_create(_shader)
	else:
		# Queries stay queued and never answer.
		push_error("%s failed to compile; water surface queries are off: %s" % [SHADER_PATH, spirv.compile_error_compute])
	for i in SLOT_COUNT:
		_slots.push_back(QuerySlot.new())
	_displacement_sampler = _device.sampler_create(create_displacement_sampler_state())
	var flat_format := RDTextureFormat.new()
	flat_format.format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
	flat_format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	var zero := PackedByteArray()
	zero.resize(8)
	_flat_interaction_map = _device.texture_create(flat_format, RDTextureView.new(), [zero])
	flat_format.texture_type = RenderingDevice.TEXTURE_TYPE_2D_ARRAY
	_flat_displacement_maps = _device.texture_create(flat_format, RDTextureView.new(), [zero])
	_flat_interaction_state = _device.storage_buffer_create(zero.size(), zero)


func submit_query(query_owner : Object, points : PackedVector3Array) -> void:
	if _retired:
		push_error("Surface query submitted after the ocean was freed.")
		return
	if points.is_empty():
		push_error("Surface queries need at least one point; release the owner instead.")
		return
	var owner_id := query_owner.get_instance_id()
	_owners[owner_id] = true
	_queued[owner_id] = points


## Latest completed result for query_owner, or null before its first one arrives.
func get_query_result(query_owner : Object) -> GREWaterSurfaceQueryResult:
	return _results.get(query_owner.get_instance_id())


## Ocean seconds from result's dispatch to now (the current physics tick, or the frame).
## Pass it to GREWaterSurfaceSample.extrapolated_height().
func get_query_age(result : GREWaterSurfaceQueryResult) -> float:
	if not Engine.is_in_physics_frame():
		return _clock - result.dispatch_time
	# Several ticks may fall between two frames, each at its own moment: a frame's
	# clock lies _clock_physics_fraction of a tick past its last tick.
	var ticks_since_frame := Engine.get_physics_frames() - _clock_physics_frame
	var tick_time := _clock + (float(ticks_since_frame - 1) - _clock_physics_fraction) * _physics_step
	return tick_time - result.dispatch_time


## Forgets query_owner's points and results. Call from the owner's _exit_tree.
func release_query(query_owner : Object) -> void:
	var owner_id := query_owner.get_instance_id()
	_owners.erase(owner_id)
	_queued.erase(owner_id)
	_results.erase(owner_id)
	_wave_responses.erase(owner_id)


func set_query_wave_response(query_owner : Object, response : float) -> void:
	var owner_id := query_owner.get_instance_id()
	if response > 0.0:
		_wave_responses[owner_id] = response
	else:
		_wave_responses.erase(owner_id)


func submit_disturbance(disturbance_owner : Object, disturbance : GREWaterDisturbance) -> void:
	if _retired:
		return
	var owner_id := disturbance_owner.get_instance_id()
	var copy : GREWaterDisturbance = _disturbances.get(owner_id)
	if copy == null:
		copy = GREWaterDisturbance.new()
		_disturbances[owner_id] = copy
	copy.position = disturbance.position
	copy.forward = disturbance.forward
	copy.half_extents = disturbance.half_extents
	copy.shape_exponent = disturbance.shape_exponent
	copy.depth = disturbance.depth
	copy.water_velocity = disturbance.water_velocity
	copy.wave_strength = disturbance.wave_strength
	# Its velocity through the water, from its last report one tick before (none after a
	# gap or a jump).
	var position := Vector2(disturbance.position.x, disturbance.position.z)
	var frame := Engine.get_physics_frames()
	var velocity := Vector2.ZERO
	var motion : Array = _hull_motions.get(owner_id, [])
	if not motion.is_empty() and frame - int(motion[1]) == 1:
		var step := 1.0 / Engine.physics_ticks_per_second
		var moved : Vector2 = position - motion[0]
		if moved.length() < disturbance.half_extents.x:
			velocity = moved / step - Vector2(disturbance.water_velocity.x, disturbance.water_velocity.z)
	_hull_motions[owner_id] = [position, frame, velocity]


func release_disturbance(disturbance_owner : Object) -> void:
	_disturbances.erase(disturbance_owner.get_instance_id())
	_hull_motions.erase(disturbance_owner.get_instance_id())


## The latest hull reported per owner (owner instance id -> GREWaterDisturbance).
func get_disturbances() -> Dictionary:
	return _disturbances


## Makes query_owner's points also get the interactive waves' height (GREOceanSystem's
## camera; everyone else's results leave those waves out).
func set_interaction_owner(query_owner : Object) -> void:
	_interaction_owner_id = query_owner.get_instance_id()


## The ocean clock (GREOceanSystem.time): the clock of dispatch_time.
func get_clock() -> float:
	return _clock


## Sets the ocean clock for this frame; physics_step is the physics tick length.
func advance_clock(clock : float, physics_step : float) -> void:
	_clock = clock
	_clock_physics_frame = Engine.get_physics_frames()
	_clock_physics_fraction = Engine.get_physics_interpolation_fraction()
	_physics_step = physics_step


func get_surface_drift() -> Vector3:
	return _surface_drift


## Sets the drift get_surface_drift() reports (GREOceanSystem, every frame).
func set_surface_drift(drift : Vector3) -> void:
	_surface_drift = drift


## Displacement textures are recreated when the wave generator is rebuilt. Uniform
## sets that referenced the old textures are freed by the RenderingDevice together
## with those textures, so only the cache entries need to go.
func clear_uniform_set_cache() -> void:
	for slot in _slots:
		slot.uniform_sets.clear()


## Dispatches every queued query, with the interactive waves of interaction (null without).
## Empty displacement RIDs (cascade_count 0) sample a flat ocean.
func dispatch(displacement_a : RID, displacement_b : RID, cascade_data : PackedByteArray, cascade_count : int, water_level : float, interaction : GREOceanInteraction) -> void:
	if _queued.is_empty() or not _pipeline.is_valid():
		return
	var slot := _get_idle_slot()
	if slot == null:
		skipped_dispatch_count += 1
		return

	var points := PackedVector3Array()
	var requests : Array[Dictionary] = []
	# The interaction owner's points go first: the shader adds the interactive waves to
	# the first interaction_point_count points.
	var interaction_point_count := 0
	if interaction != null and _queued.has(_interaction_owner_id):
		var interaction_points : PackedVector3Array = _queued[_interaction_owner_id]
		requests.push_back({"owner_id": _interaction_owner_id, "offset": 0, "count": interaction_points.size()})
		points.append_array(interaction_points)
		interaction_point_count = interaction_points.size()
		_queued.erase(_interaction_owner_id)
	for owner_id in _queued:
		var owner_points : PackedVector3Array = _queued[owner_id]
		requests.push_back({"owner_id": owner_id, "offset": points.size(), "count": owner_points.size()})
		points.append_array(owner_points)
	_queued.clear()

	# Each point carries its request's owner record: the hull it reports (the footprint
	# its own waves are filled in over) and its wave response.
	var point_values := PackedFloat32Array()
	point_values.resize(points.size() * FLOATS_PER_POINT)
	var owner_values := PackedFloat32Array()
	owner_values.resize(requests.size() * FLOATS_PER_OWNER)
	for r in requests.size():
		var request := requests[r]
		var offset : int = request["offset"]
		for i in range(offset, offset + int(request["count"])):
			point_values[i * FLOATS_PER_POINT] = points[i].x
			point_values[i * FLOATS_PER_POINT + 1] = points[i].y
			point_values[i * FLOATS_PER_POINT + 2] = points[i].z
			point_values[i * FLOATS_PER_POINT + 3] = r
		_write_owner_record(owner_values, r, request["owner_id"], interaction.cell_size if interaction != null else 0.0)

	_ensure_slot_capacity(slot, points.size(), cascade_data.size())
	var point_data := point_values.to_byte_array()
	_device.buffer_update(slot.point_buffer, 0, point_data.size(), point_data)
	var owner_data := owner_values.to_byte_array()
	_device.buffer_update(slot.owner_buffer, 0, owner_data.size(), owner_data)
	_device.buffer_update(slot.cascade_buffer, 0, cascade_data.size(), cascade_data)

	var window := interaction.get_window() if interaction != null else Vector4.ZERO
	var origin := interaction.get_origin() if interaction != null else Vector2i.ZERO
	var push_constant := GRERenderingContext.create_push_constant([
		points.size(),
		cascade_count,
		water_level,
		NORMAL_SAMPLE_DISTANCE,
		interaction_point_count,
		window.x,
		window.y,
		window.z,
		window.w,
		INTERACTION_FADE_START,
		origin.x,
		origin.y,
		interaction.map_size if interaction != null else 0,
		interaction.cell_size if interaction != null else 1.0,
		GREOceanInteraction.MAX_HEIGHT,
	])
	var map := interaction.map.rid if interaction != null else _flat_interaction_map
	var state := interaction.state_buffer.rid if interaction != null else _flat_interaction_state
	if not displacement_a.is_valid() or not displacement_b.is_valid():
		displacement_a = _flat_displacement_maps
		displacement_b = _flat_displacement_maps
	var compute_list := _device.compute_list_begin()
	_device.compute_list_bind_compute_pipeline(compute_list, _pipeline)
	_device.compute_list_bind_uniform_set(compute_list, _get_uniform_set(slot, displacement_a, displacement_b, map, state), 0)
	_device.compute_list_set_push_constant(compute_list, push_constant, push_constant.size())
	_device.compute_list_dispatch(compute_list, ceili(float(points.size()) / float(WORKGROUP_SIZE)), 1, 1)
	_device.compute_list_end()

	slot.in_flight = true
	slot.points = points
	slot.requests = requests
	slot.dispatch_time = _clock
	# The callback may run outside the main thread's frame logic; hand the data
	# over deferred. The lambda also keeps this object alive until it runs.
	var on_read := func(data : PackedByteArray) -> void:
		_on_samples_read.call_deferred(slot, data)
	var error := _device.buffer_get_data_async(slot.sample_buffer, on_read, 0, points.size() * BYTES_PER_SAMPLE)
	if error != OK:
		slot.in_flight = false
		push_error("Surface query readback failed: %s" % error_string(error))


## Frees GPU resources when the owning ocean goes away. Readbacks already in
## flight are ignored when they arrive.
func retire() -> void:
	_retired = true
	for slot in _slots:
		_free_slot_buffers(slot)
	_device.free_rid(_displacement_sampler)
	_device.free_rid(_flat_displacement_maps)
	_device.free_rid(_flat_interaction_map)
	_device.free_rid(_flat_interaction_state)
	_wave_responses.clear()
	_disturbances.clear()
	_hull_motions.clear()
	if _shader.is_valid():
		_device.free_rid(_shader)
	_owners.clear()
	_queued.clear()
	_results.clear()


func _on_samples_read(slot : QuerySlot, data : PackedByteArray) -> void:
	slot.in_flight = false
	if _retired:
		return
	if data.size() != slot.points.size() * BYTES_PER_SAMPLE:
		push_error("Surface query readback has %d bytes, expected %d; dropped." % [data.size(), slot.points.size() * BYTES_PER_SAMPLE])
		return
	var samples := _unpack_samples(slot.points, data)
	for request in slot.requests:
		var owner_id : int = request["owner_id"]
		# The owner may have been released while its query was in flight.
		if not _owners.has(owner_id):
			continue
		var offset : int = request["offset"]
		var count : int = request["count"]
		var result := GREWaterSurfaceQueryResult.new()
		result.points = slot.points.slice(offset, offset + count)
		result.samples.assign(samples.slice(offset, offset + count))
		result.dispatch_time = slot.dispatch_time
		_results[owner_id] = result


## Writes owner_id's record r: the rim around the hull it reports, stretched back along
## its motion through the water, and its wave response (none: zero).
func _write_owner_record(values : PackedFloat32Array, r : int, owner_id : int, cell_size : float) -> void:
	var response : float = _wave_responses.get(owner_id, 0.0)
	if response <= 0.0:
		return
	var o := r * FLOATS_PER_OWNER
	values[o + 7] = response
	var disturbance : GREWaterDisturbance = _disturbances.get(owner_id)
	if disturbance == null:
		return
	var forward := Vector2(disturbance.forward.x, disturbance.forward.z)
	forward = forward.normalized() if forward.length_squared() > 1e-8 else Vector2(0.0, -1.0)
	var half_extents := disturbance.half_extents.max(Vector2(0.01, 0.01))
	var rim := (half_extents * WAVE_RESPONSE_RIM).max(half_extents + Vector2.ONE * (WAVE_RESPONSE_RIM_CELLS * cell_size))
	var gravity : float = ProjectSettings.get_setting("physics/3d/default_gravity", 9.8)
	var fill_time := WAVE_RESPONSE_TRAIL * sqrt(TAU * 2.0 * half_extents.x / gravity)
	var motion : Array = _hull_motions.get(owner_id, [])
	var trail : Vector2 = motion[2] * fill_time if not motion.is_empty() else Vector2.ZERO
	var beam_axis := Vector2(-forward.y, forward.x)
	rim += Vector2(absf(trail.dot(forward)), absf(trail.dot(beam_axis))) * 0.5
	values[o] = disturbance.position.x - trail.x * 0.5
	values[o + 1] = disturbance.position.z - trail.y * 0.5
	values[o + 2] = forward.x
	values[o + 3] = forward.y
	values[o + 4] = rim.x
	values[o + 5] = rim.y
	values[o + 6] = clampf(disturbance.shape_exponent, 1.0, 16.0)


func _get_idle_slot() -> QuerySlot:
	for slot in _slots:
		if not slot.in_flight:
			return slot
	return null


func _ensure_slot_capacity(slot : QuerySlot, point_count : int, cascade_bytes : int) -> void:
	if point_count <= slot.capacity:
		return
	_free_slot_buffers(slot)
	var capacity := WORKGROUP_SIZE
	while capacity < point_count:
		capacity *= 2
	slot.capacity = capacity
	slot.point_buffer = _device.storage_buffer_create(capacity * BYTES_PER_POINT)
	# At most one owner per point.
	slot.owner_buffer = _device.storage_buffer_create(capacity * FLOATS_PER_OWNER * 4)
	slot.cascade_buffer = _device.storage_buffer_create(cascade_bytes)
	slot.sample_buffer = _device.storage_buffer_create(capacity * BYTES_PER_SAMPLE)


func _free_slot_buffers(slot : QuerySlot) -> void:
	if slot.capacity == 0:
		return
	# Uniform sets depend on these buffers and are freed with them.
	_device.free_rid(slot.point_buffer)
	_device.free_rid(slot.owner_buffer)
	_device.free_rid(slot.cascade_buffer)
	_device.free_rid(slot.sample_buffer)
	slot.uniform_sets.clear()
	slot.capacity = 0


func _get_uniform_set(slot : QuerySlot, displacement_a : RID, displacement_b : RID, interaction_map : RID, interaction_state : RID) -> RID:
	var key := "%d:%d:%d:%d" % [displacement_a.get_id(), displacement_b.get_id(), interaction_map.get_id(), interaction_state.get_id()]
	if slot.uniform_sets.has(key):
		return slot.uniform_sets[key]
	var uniforms : Array[RDUniform] = [
		GRERenderingContext.buffer_uniform(0, slot.point_buffer),
		GRERenderingContext.buffer_uniform(1, slot.cascade_buffer),
		GRERenderingContext.buffer_uniform(2, slot.sample_buffer),
		GRERenderingContext.sampled_uniform(3, _displacement_sampler, displacement_a),
		GRERenderingContext.sampled_uniform(4, _displacement_sampler, displacement_b),
		GRERenderingContext.sampled_uniform(5, _displacement_sampler, interaction_map),
		GRERenderingContext.buffer_uniform(6, slot.owner_buffer),
		GRERenderingContext.buffer_uniform(7, interaction_state),
	]
	var uniform_set := _device.uniform_set_create(uniforms, _shader, 0)
	slot.uniform_sets[key] = uniform_set
	return uniform_set


func _unpack_samples(points : PackedVector3Array, data : PackedByteArray) -> Array[GREWaterSurfaceSample]:
	var values := data.to_float32_array()
	var samples : Array[GREWaterSurfaceSample] = []
	samples.resize(points.size())
	for i in points.size():
		var o := i * FLOATS_PER_SAMPLE
		var sample := GREWaterSurfaceSample.new()
		sample.position = points[i]
		sample.displacement = Vector3(values[o], values[o + 1], values[o + 2])
		sample.height = values[o + 3]
		sample.normal = Vector3(values[o + 4], values[o + 5], values[o + 6])
		sample.surface_velocity = Vector3(values[o + 8], values[o + 9], values[o + 10])
		samples[i] = sample
	return samples
