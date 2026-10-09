class_name OceanSurfaceQueries
extends WaterSurface
## The ocean's WaterSurface: batches every owner's query points into one compute
## dispatch per frame and reads the results back asynchronously, and routes
## impulses to the interaction simulation. Owned by OceanSystem, which registers
## it for its world.
##
## A ring of SLOT_COUNT buffer sets lets new dispatches start while earlier
## readbacks are still in flight; each slot is reused only after its readback
## has been delivered.

const SHADER_PATH := 'res://addons/ocean_system/shaders/compute/surface_query.glsl'
const SLOT_COUNT := 3
const WORKGROUP_SIZE := 64
## Points are uploaded as tightly packed xyz floats (PackedVector3Array bytes).
const BYTES_PER_POINT := 12
const BYTES_PER_CASCADE := 48
const BYTES_PER_SAMPLE := 48
const FLOATS_PER_SAMPLE := 12
const NORMAL_SAMPLE_DISTANCE := 0.25

class QuerySlot:
	var capacity := 0
	var point_buffer := RID()
	var cascade_buffer := RID()
	var sample_buffer := RID()
	## "current_rid:previous_rid" -> uniform set RID.
	var uniform_sets := {}
	var in_flight := false
	var points := PackedVector3Array()
	## [{owner_id, offset, count}] in dispatch order.
	var requests : Array[Dictionary] = []
	var dispatch_time := 0.0

## Frames whose queued queries could not be dispatched because every slot was
## still waiting on a readback. The queries stay queued for the next frame.
var skipped_dispatch_count := 0
## The ocean's interaction simulation, or null while it is off: queries add its
## waves, impulses go to it.
var interaction : WaterInteractionSim

var _device : RenderingDevice
## Callable(body : PhysicsBody3D) -> bool: whether body carries a hull that pushes
## water in the interaction simulation (its queries leave those waves out).
var _is_wave_making_body : Callable
## The ocean clock (s), advanced once per frame (advance_clock()), and the physics
## frame, interpolation fraction and physics step at that moment.
var _clock := 0.0
var _clock_physics_frame := 0
var _clock_physics_fraction := 0.0
var _physics_step := 0.0
var _shader : RID
var _pipeline : RID
var _slots : Array[QuerySlot] = []
var _queued := {}   # owner_id -> [PackedVector3Array points, bool include interaction]
var _owners := {}   # owner_id -> true, for owners that have not been released
var _results := {}  # owner_id -> WaterSurfaceQueryResult
var _retired := false
## Bound in place of the interaction render texture while the simulation is off.
var _no_interaction_texture : RID
var _displacement_sampler : RID


## Sampler for the wave displacement maps in compute shaders (ocean_sampling.glslinc):
## repeat wrapping and bilinear filtering, as the water material samples them.
static func create_displacement_sampler_state() -> RDSamplerState:
	return RenderingContext.linear_sampler_state(RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT)


func _init(device : RenderingDevice, is_wave_making_body : Callable) -> void:
	_device = device
	_is_wave_making_body = is_wave_making_body
	var shader_file : RDShaderFile = load(SHADER_PATH)
	var spirv := shader_file.get_spirv()
	if spirv.compile_error_compute.is_empty():
		_shader = _device.shader_create_from_spirv(spirv)
		_pipeline = _device.compute_pipeline_create(_shader)
	else:
		# Queries stay queued and never answer: floating bodies wait frozen.
		push_error("%s failed to compile; water surface queries are off: %s" % [SHADER_PATH, spirv.compile_error_compute])
	for i in SLOT_COUNT:
		_slots.push_back(QuerySlot.new())
	var texture_format := RDTextureFormat.new()
	texture_format.format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
	texture_format.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
	var empty_texel := PackedByteArray()
	empty_texel.resize(8)
	_no_interaction_texture = _device.texture_create(texture_format, RDTextureView.new(), [empty_texel])
	_displacement_sampler = _device.sampler_create(create_displacement_sampler_state())


## Heights include the interaction simulation's waves, except for points on a
## body that makes waves itself: the simulation is one summed field, so such a
## body cannot tell its own waves from others', and read back after the query
## delay its own waves act as a lagging spring that drives it.
func submit_query(query_owner : Object, points : PackedVector3Array, body : PhysicsBody3D = null) -> void:
	if _retired:
		push_error("Surface query submitted after the ocean was freed.")
		return
	if points.is_empty():
		push_error("Surface queries need at least one point; release the owner instead.")
		return
	if body == null and query_owner is Node:
		body = find_physics_body(query_owner)
	var owner_id := query_owner.get_instance_id()
	_owners[owner_id] = true
	_queued[owner_id] = [points, body == null or not _is_wave_making_body.call(body)]


func get_query_result(query_owner : Object) -> WaterSurfaceQueryResult:
	return _results.get(query_owner.get_instance_id())


func get_query_age(result : WaterSurfaceQueryResult) -> float:
	if not Engine.is_in_physics_frame():
		return _clock - result.dispatch_time
	# Several ticks may fall between two frames, each at its own moment: a frame's
	# clock lies _clock_physics_fraction of a tick past its last tick.
	var ticks_since_frame := Engine.get_physics_frames() - _clock_physics_frame
	var tick_time := _clock + (float(ticks_since_frame - 1) - _clock_physics_fraction) * _physics_step
	return tick_time - result.dispatch_time


func release_query(query_owner : Object) -> void:
	var owner_id := query_owner.get_instance_id()
	_owners.erase(owner_id)
	_queued.erase(owner_id)
	_results.erase(owner_id)


func get_clock() -> float:
	return _clock


func can_add_impulses() -> bool:
	return interaction != null


func add_impulse(world_position : Vector3, radius : float, amplitude : float) -> void:
	if interaction != null:
		interaction.add_impulse(world_position, radius, amplitude)


## Sets the ocean clock for this frame; physics_step is the physics tick length.
func advance_clock(clock : float, physics_step : float) -> void:
	_clock = clock
	_clock_physics_frame = Engine.get_physics_frames()
	_clock_physics_fraction = Engine.get_physics_interpolation_fraction()
	_physics_step = physics_step


## node itself or its nearest PhysicsBody3D ancestor, or null.
static func find_physics_body(node : Node) -> PhysicsBody3D:
	while node != null and not node is PhysicsBody3D:
		node = node.get_parent()
	return node as PhysicsBody3D


## Displacement textures are recreated when the wave generator is rebuilt. Uniform
## sets that referenced the old textures are freed by the RenderingDevice together
## with those textures, so only the cache entries need to go.
func clear_uniform_set_cache() -> void:
	for slot in _slots:
		slot.uniform_sets.clear()


## Dispatches every queued query. interaction_window is (center x, center z,
## fade start, fade end), see OceanSystem._get_interaction_window().
func dispatch(displacement_a : RID, displacement_b : RID, cascade_data : PackedByteArray, cascade_count : int, water_level : float, interaction_window : Vector4, interaction_cell_size : float) -> void:
	if _queued.is_empty() or not _pipeline.is_valid():
		return
	var slot := _get_idle_slot()
	if slot == null:
		skipped_dispatch_count += 1
		return

	# Owners whose heights add the interaction simulation first: the shader adds it
	# to the points before interaction_point_count.
	var points := PackedVector3Array()
	var requests : Array[Dictionary] = []
	var interaction_enabled := interaction != null
	var interaction_point_count := 0
	for with_interaction in [true, false]:
		for owner_id in _queued:
			if _queued[owner_id][1] != with_interaction:
				continue
			var owner_points : PackedVector3Array = _queued[owner_id][0]
			requests.push_back({"owner_id": owner_id, "offset": points.size(), "count": owner_points.size()})
			points.append_array(owner_points)
		if with_interaction and interaction_enabled:
			interaction_point_count = points.size()
	_queued.clear()

	_ensure_slot_capacity(slot, points.size(), cascade_data.size())
	var point_data := points.to_byte_array()
	_device.buffer_update(slot.point_buffer, 0, point_data.size(), point_data)
	_device.buffer_update(slot.cascade_buffer, 0, cascade_data.size(), cascade_data)

	var push_constant := RenderingContext.create_push_constant([
		points.size(),
		cascade_count,
		water_level,
		NORMAL_SAMPLE_DISTANCE,
		interaction_window.x,
		interaction_window.y,
		interaction_cell_size,
		interaction_window.z,
		interaction_window.w,
		interaction_point_count,
	])
	var interaction_texture := interaction.render_texture if interaction_enabled else _no_interaction_texture
	var compute_list := _device.compute_list_begin()
	_device.compute_list_bind_compute_pipeline(compute_list, _pipeline)
	_device.compute_list_bind_uniform_set(compute_list, _get_uniform_set(slot, displacement_a, displacement_b, interaction_texture), 0)
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
	_device.free_rid(_no_interaction_texture)
	_device.free_rid(_displacement_sampler)
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
		var result := WaterSurfaceQueryResult.new()
		result.points = slot.points.slice(offset, offset + count)
		result.samples.assign(samples.slice(offset, offset + count))
		result.dispatch_time = slot.dispatch_time
		_results[owner_id] = result


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
	slot.cascade_buffer = _device.storage_buffer_create(cascade_bytes)
	slot.sample_buffer = _device.storage_buffer_create(capacity * BYTES_PER_SAMPLE)


func _free_slot_buffers(slot : QuerySlot) -> void:
	if slot.capacity == 0:
		return
	# Uniform sets depend on these buffers and are freed with them.
	_device.free_rid(slot.point_buffer)
	_device.free_rid(slot.cascade_buffer)
	_device.free_rid(slot.sample_buffer)
	slot.uniform_sets.clear()
	slot.capacity = 0


func _get_uniform_set(slot : QuerySlot, displacement_a : RID, displacement_b : RID, interaction_texture : RID) -> RID:
	var key := "%d:%d:%d" % [displacement_a.get_id(), displacement_b.get_id(), interaction_texture.get_id()]
	if slot.uniform_sets.has(key):
		return slot.uniform_sets[key]
	var uniforms : Array[RDUniform] = [
		RenderingContext.buffer_uniform(0, slot.point_buffer),
		RenderingContext.buffer_uniform(1, slot.cascade_buffer),
		RenderingContext.buffer_uniform(2, slot.sample_buffer),
		RenderingContext.sampled_uniform(3, _displacement_sampler, displacement_a),
		RenderingContext.sampled_uniform(4, _displacement_sampler, displacement_b),
		RenderingContext.image_uniform(5, interaction_texture),
	]
	var uniform_set := _device.uniform_set_create(uniforms, _shader, 0)
	slot.uniform_sets[key] = uniform_set
	return uniform_set


func _unpack_samples(points : PackedVector3Array, data : PackedByteArray) -> Array[WaterSurfaceSample]:
	var values := data.to_float32_array()
	var samples : Array[WaterSurfaceSample] = []
	samples.resize(points.size())
	for i in points.size():
		var o := i * FLOATS_PER_SAMPLE
		var sample := WaterSurfaceSample.new()
		sample.position = points[i]
		sample.displacement = Vector3(values[o], values[o + 1], values[o + 2])
		sample.height = values[o + 3]
		sample.normal = Vector3(values[o + 4], values[o + 5], values[o + 6])
		sample.surface_velocity = Vector3(values[o + 8], values[o + 9], values[o + 10])
		samples[i] = sample
	return samples
