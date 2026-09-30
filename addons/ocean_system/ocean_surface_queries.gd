class_name OceanSurfaceQueries
extends RefCounted
## Batches every owner's surface query points into one compute dispatch per frame
## and reads the results back asynchronously. Owned by OceanSystem.
##
## A ring of SLOT_COUNT buffer sets lets new dispatches start while earlier
## readbacks are still in flight; each slot is reused only after its readback
## has been delivered.

const SHADER_PATH := 'res://addons/ocean_system/shaders/compute/surface_query.glsl'
const SLOT_COUNT := 3
const WORKGROUP_SIZE := 64
const BYTES_PER_POINT := 16
const BYTES_PER_CASCADE := 32
const BYTES_PER_SAMPLE := 48
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

var _device : RenderingDevice
var _shader : RID
var _pipeline : RID
var _slots : Array[QuerySlot] = []
var _queued := {}   # owner_id -> PackedVector3Array
var _owners := {}   # owner_id -> true, for owners that have not been released
var _results := {}  # owner_id -> WaterSurfaceQueryResult
var _retired := false
## Bound in place of the interaction render texture while the simulation is off.
var _no_interaction_texture : RID


func _init(device : RenderingDevice) -> void:
	_device = device
	var shader_file : RDShaderFile = load(SHADER_PATH)
	_shader = _device.shader_create_from_spirv(shader_file.get_spirv())
	_pipeline = _device.compute_pipeline_create(_shader)
	for i in SLOT_COUNT:
		_slots.push_back(QuerySlot.new())
	var texture_format := RDTextureFormat.new()
	texture_format.format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
	texture_format.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
	var empty_texel := PackedByteArray()
	empty_texel.resize(8)
	_no_interaction_texture = _device.texture_create(texture_format, RDTextureView.new(), [empty_texel])


func submit(owner_id : int, points : PackedVector3Array) -> void:
	assert(not _retired, "Surface query submitted after the ocean was freed.")
	assert(not points.is_empty(), "Surface queries need at least one point.")
	_owners[owner_id] = true
	_queued[owner_id] = points


## Returns null until the first result for owner_id has been read back.
func get_result(owner_id : int) -> WaterSurfaceQueryResult:
	return _results.get(owner_id)


func release(owner_id : int) -> void:
	_owners.erase(owner_id)
	_queued.erase(owner_id)
	_results.erase(owner_id)


## Displacement textures are recreated when the wave generator is rebuilt. Uniform
## sets that referenced the old textures are freed by the RenderingDevice together
## with those textures, so only the cache entries need to go.
func clear_uniform_set_cache() -> void:
	for slot in _slots:
		slot.uniform_sets.clear()


## interaction_texture is the interaction simulation's render texture, or an
## invalid RID when the simulation is off. interaction_window is (center x,
## center z, fade start, fade end), see OceanSystem._get_interaction_window().
func dispatch(current_displacement : RID, previous_displacement : RID, cascade_data : PackedByteArray, cascade_count : int, water_level : float, wave_blend_alpha : float, wave_blend_duration : float, time : float, interaction_texture : RID, interaction_window : Vector4, interaction_cell_size : float) -> void:
	if _queued.is_empty():
		return
	var slot := _get_idle_slot()
	if slot == null:
		skipped_dispatch_count += 1
		return

	var points := PackedVector3Array()
	var requests : Array[Dictionary] = []
	for owner_id in _queued:
		var owner_points : PackedVector3Array = _queued[owner_id]
		requests.push_back({"owner_id": owner_id, "offset": points.size(), "count": owner_points.size()})
		points.append_array(owner_points)
	_queued.clear()

	_ensure_slot_capacity(slot, points.size(), cascade_data.size())
	var point_data := _pack_points(points)
	_device.buffer_update(slot.point_buffer, 0, point_data.size(), point_data)
	_device.buffer_update(slot.cascade_buffer, 0, cascade_data.size(), cascade_data)

	var interaction_enabled := interaction_texture.is_valid()
	var push_constant := RenderingContext.create_push_constant([
		points.size(),
		cascade_count,
		water_level,
		wave_blend_alpha,
		maxf(wave_blend_duration, 1.0 / 60.0),
		NORMAL_SAMPLE_DISTANCE,
		interaction_window.x,
		interaction_window.y,
		interaction_cell_size,
		interaction_window.z,
		interaction_window.w,
		1 if interaction_enabled else 0,
	])
	var interaction := interaction_texture if interaction_enabled else _no_interaction_texture
	var compute_list := _device.compute_list_begin()
	_device.compute_list_bind_compute_pipeline(compute_list, _pipeline)
	_device.compute_list_bind_uniform_set(compute_list, _get_uniform_set(slot, current_displacement, previous_displacement, interaction), 0)
	_device.compute_list_set_push_constant(compute_list, push_constant, push_constant.size())
	_device.compute_list_dispatch(compute_list, ceili(float(points.size()) / float(WORKGROUP_SIZE)), 1, 1)
	_device.compute_list_end()

	slot.in_flight = true
	slot.points = points
	slot.requests = requests
	slot.dispatch_time = time
	# The callback may run outside the main thread's frame logic; hand the data
	# over deferred. The lambda also keeps this object alive until it runs.
	var on_read := func(data : PackedByteArray) -> void:
		_on_samples_read.call_deferred(slot, data)
	var error := _device.buffer_get_data_async(slot.sample_buffer, on_read, 0, points.size() * BYTES_PER_SAMPLE)
	assert(error == OK, "buffer_get_data_async failed: %s" % error_string(error))


## Frees GPU resources when the owning ocean goes away. Readbacks already in
## flight are ignored when they arrive.
func retire() -> void:
	_retired = true
	for slot in _slots:
		_free_slot_buffers(slot)
	_device.free_rid(_no_interaction_texture)
	_device.free_rid(_shader)
	_owners.clear()
	_queued.clear()
	_results.clear()


func _on_samples_read(slot : QuerySlot, data : PackedByteArray) -> void:
	slot.in_flight = false
	if _retired:
		return
	assert(data.size() == slot.points.size() * BYTES_PER_SAMPLE, "Surface query readback has the wrong size.")
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
		for i in count:
			result.samples.push_back(samples[offset + i])
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


func _get_uniform_set(slot : QuerySlot, current_displacement : RID, previous_displacement : RID, interaction : RID) -> RID:
	var key := "%d:%d:%d" % [current_displacement.get_id(), previous_displacement.get_id(), interaction.get_id()]
	if slot.uniform_sets.has(key):
		return slot.uniform_sets[key]
	var uniforms : Array[RDUniform] = [
		_make_uniform(0, RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, slot.point_buffer),
		_make_uniform(1, RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, slot.cascade_buffer),
		_make_uniform(2, RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, slot.sample_buffer),
		_make_uniform(3, RenderingDevice.UNIFORM_TYPE_IMAGE, current_displacement),
		_make_uniform(4, RenderingDevice.UNIFORM_TYPE_IMAGE, previous_displacement),
		_make_uniform(5, RenderingDevice.UNIFORM_TYPE_IMAGE, interaction),
	]
	var uniform_set := _device.uniform_set_create(uniforms, _shader, 0)
	slot.uniform_sets[key] = uniform_set
	return uniform_set


func _make_uniform(binding : int, uniform_type : RenderingDevice.UniformType, id : RID) -> RDUniform:
	var uniform := RDUniform.new()
	uniform.binding = binding
	uniform.uniform_type = uniform_type
	uniform.add_id(id)
	return uniform


func _pack_points(points : PackedVector3Array) -> PackedByteArray:
	var data := PackedByteArray()
	data.resize(points.size() * BYTES_PER_POINT)
	for i in points.size():
		var offset := i * BYTES_PER_POINT
		var point := points[i]
		data.encode_float(offset, point.x)
		data.encode_float(offset + 4, point.y)
		data.encode_float(offset + 8, point.z)
		data.encode_float(offset + 12, 0.0)
	return data


func _unpack_samples(points : PackedVector3Array, data : PackedByteArray) -> Array[WaterSurfaceSample]:
	var samples : Array[WaterSurfaceSample] = []
	samples.resize(points.size())
	for i in points.size():
		var offset := i * BYTES_PER_SAMPLE
		var sample := WaterSurfaceSample.new()
		sample.position = points[i]
		sample.displacement = Vector3(data.decode_float(offset), data.decode_float(offset + 4), data.decode_float(offset + 8))
		sample.height = data.decode_float(offset + 12)
		sample.normal = Vector3(data.decode_float(offset + 16), data.decode_float(offset + 20), data.decode_float(offset + 24))
		sample.surface_velocity = Vector3(data.decode_float(offset + 32), data.decode_float(offset + 36), data.decode_float(offset + 40))
		samples[i] = sample
	return samples
