class_name RenderingContext extends Object
## Owns the RenderingDevice resources of one compute feature and frees them
## together, newest first (free() the context, or let its owner do it).
##
## Creation failures are reported with push_error() and leave [member failed]
## set; owners check it once after building their resources and disable the
## feature instead of dispatching with invalid RIDs.

class Descriptor:
	var rid : RID
	var type : RenderingDevice.UniformType

	func _init(rid_ : RID, type_ : RenderingDevice.UniformType) -> void:
		rid = rid_; type = type_

var device : RenderingDevice
## True once any resource failed to be created.
var failed := false
var _owned : Array[RID] = []
var _shader_cache := {}

func _init(rendering_device : RenderingDevice) -> void:
	device = rendering_device

func _notification(what : int) -> void:
	if what == NOTIFICATION_PREDELETE:
		# Newest first: uniform sets and views go before the resources they reference.
		# Resources of other contexts that a set here references must outlive this one.
		for i in range(_owned.size() - 1, -1, -1):
			device.free_rid(_owned[i])
		_owned.clear()
		_shader_cache.clear()

## Frees rid with the context. An invalid rid (a failed creation) is reported.
func own(rid : RID) -> RID:
	if not rid.is_valid():
		failed = true
		push_error("RenderingContext: creating a GPU resource failed (see the error above).")
		return rid
	_owned.push_back(rid)
	return rid

# --- WRAPPER FUNCTIONS ---
## Starts a compute list on the device (RenderingDevice.compute_list_begin()).
func compute_list_begin() -> int: return device.compute_list_begin()
## Ends the current compute list and submits it.
func compute_list_end() -> void: device.compute_list_end()
## Orders the dispatches of compute_list: those after the barrier see what those before it wrote.
## Re-applies the last push constant to the bound pipeline, so every pass sets its own.
func compute_list_add_barrier(compute_list : int) -> void: device.compute_list_add_barrier(compute_list)

# --- RESOURCES ---
## version selects a `#[versions]` entry of the shader file (empty for files without one).
func load_shader(path : String, version := &"") -> RID:
	return load_shader_file(load(path), version)

## Compiles an imported .glsl (version: its #[versions] entry, empty for the default) and
## owns the shader. Reports compile errors and sets [member failed]; returns an invalid RID then.
func load_shader_file(shader_file : RDShaderFile, version := &"") -> RID:
	var key := "%s:%s" % [shader_file.resource_path, version]
	if _shader_cache.has(key):
		return _shader_cache[key]
	var spirv := shader_file.get_spirv(version)
	if not spirv.compile_error_compute.is_empty():
		failed = true
		push_error("%s [%s]: %s" % [shader_file.resource_path, version, spirv.compile_error_compute])
		return RID()
	var shader := own(device.shader_create_from_spirv(spirv))
	_shader_cache[key] = shader
	return shader

## Creates and owns a compute pipeline for shader.
func create_compute_pipeline(shader : RID) -> RID:
	return own(device.compute_pipeline_create(shader)) if shader.is_valid() else RID()

## Creates and owns a sampler with the given state.
func create_sampler(state : RDSamplerState) -> RID:
	return own(device.sampler_create(state))

## Creates and owns a uniform set of uniforms for set_index of shader.
func create_uniform_set(uniforms : Array, shader : RID, set_index := 0) -> RID:
	return own(device.uniform_set_create(uniforms, shader, set_index)) if shader.is_valid() else RID()

## Creates and owns a storage buffer of size bytes, filled with data when given.
func create_storage_buffer(size : int, data := PackedByteArray()) -> Descriptor:
	if size > data.size():
		var padding := PackedByteArray(); padding.resize(size - data.size())
		data += padding
	return Descriptor.new(own(device.storage_buffer_create(data.size(), data)), RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER)

## A texture of any type (2D, 2D array, 3D, cube) with uninitialized contents
## unless data holds one PackedByteArray per layer.
func create_texture_rid(type : RenderingDevice.TextureType, format : RenderingDevice.DataFormat, size : Vector3i, usage : int, layers := 1, mipmaps := 1, data : Array = []) -> RID:
	var texture_format := RDTextureFormat.new()
	texture_format.texture_type = type
	texture_format.format = format
	texture_format.width = size.x
	texture_format.height = size.y
	texture_format.depth = size.z
	texture_format.array_layers = layers
	texture_format.mipmaps = mipmaps
	texture_format.usage_bits = usage
	return own(device.texture_create(texture_format, RDTextureView.new(), data))

## A 2D texture, or a 2D array when num_layers > 0, as a storage-image descriptor.
func create_texture(dimensions : Vector2i, format : RenderingDevice.DataFormat, usage : int, num_layers := 0, data : Array = [], mipmaps := 1) -> Descriptor:
	var type := RenderingDevice.TEXTURE_TYPE_2D if num_layers == 0 else RenderingDevice.TEXTURE_TYPE_2D_ARRAY
	var rid := create_texture_rid(type, format, Vector3i(dimensions.x, dimensions.y, 1), usage, maxi(num_layers, 1), mipmaps, data)
	return Descriptor.new(rid, RenderingDevice.UNIFORM_TYPE_IMAGE)

## A 2D view of one layer and mip level of a texture (array). Storage-image
## bindings of a texture with mipmaps need a single-level view.
func create_texture_slice_view(texture : Descriptor, layer : int, mip : int) -> Descriptor:
	return Descriptor.new(own(device.texture_create_shared_from_slice(RDTextureView.new(), texture.rid, layer, mip, 1, RenderingDevice.TEXTURE_SLICE_2D)), RenderingDevice.UNIFORM_TYPE_IMAGE)

## Creates a descriptor set. The ordering of the provided descriptors matches the binding ordering
## within the shader.
func create_descriptor_set(descriptors : Array[Descriptor], shader : RID, descriptor_set_index := 0) -> RID:
	var uniforms : Array[RDUniform] = []
	for i in descriptors.size():
		var uniform := RDUniform.new()
		uniform.uniform_type = descriptors[i].type
		uniform.binding = i  # This matches the binding in the shader.
		uniform.add_id(descriptors[i].rid)
		uniforms.push_back(uniform)
	return create_uniform_set(uniforms, shader, descriptor_set_index)

## Returns a [Callable] which dispatches a compute pipeline (within a compute list) with the
## provided group counts. The ordering of the provided descriptor sets matches the set ordering
## within the shader.
func create_pipeline(group_counts : Array, descriptor_sets : Array, shader : RID) -> Callable:
	var pipeline := create_compute_pipeline(shader)
	return func(context : RenderingContext, compute_list : int, push_constant := PackedByteArray(), descriptor_set_overrides := []) -> void:
		var list_device := context.device
		var sets : Array = descriptor_sets if descriptor_set_overrides.is_empty() else descriptor_set_overrides
		list_device.compute_list_bind_compute_pipeline(compute_list, pipeline)
		if not push_constant.is_empty():
			list_device.compute_list_set_push_constant(compute_list, push_constant, push_constant.size())
		for i in sets.size():
			list_device.compute_list_bind_uniform_set(compute_list, sets[i], i)
		list_device.compute_list_dispatch(compute_list, group_counts[0], group_counts[1], group_counts[2])

# --- UNIFORMS ---
## A storage-image uniform at binding.
static func image_uniform(binding : int, texture : RID) -> RDUniform:
	return _uniform(binding, RenderingDevice.UNIFORM_TYPE_IMAGE, [texture])

## A sampler-with-texture uniform at binding.
static func sampled_uniform(binding : int, sampler : RID, texture : RID) -> RDUniform:
	return _uniform(binding, RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, [sampler, texture])

## A storage-buffer uniform at binding.
static func buffer_uniform(binding : int, buffer : RID) -> RDUniform:
	return _uniform(binding, RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, [buffer])

static func _uniform(binding : int, uniform_type : RenderingDevice.UniformType, ids : Array[RID]) -> RDUniform:
	var uniform := RDUniform.new()
	uniform.binding = binding
	uniform.uniform_type = uniform_type
	for id in ids:
		uniform.add_id(id)
	return uniform

## Linear filtering with the same repeat mode on every axis.
static func linear_sampler_state(repeat_mode : RenderingDevice.SamplerRepeatMode, mipmaps := false) -> RDSamplerState:
	var state := RDSamplerState.new()
	state.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	state.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	if mipmaps:
		state.mip_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	state.repeat_u = repeat_mode
	state.repeat_v = repeat_mode
	state.repeat_w = repeat_mode
	return state

# --- PUSH CONSTANTS ---
## Push-constant bytes at the exact size the shader declares: 4 bytes per value,
## ints and bools as int32, everything else as float32 (no 16-byte padding).
static func create_push_constant(values : Array) -> PackedByteArray:
	var bytes := PackedByteArray()
	bytes.resize(values.size() * 4)
	for i in values.size():
		match typeof(values[i]):
			TYPE_INT, TYPE_BOOL:
				bytes.encode_s32(i * 4, int(values[i]))
			_:
				bytes.encode_float(i * 4, values[i])
	if bytes.size() > 128:
		push_error("Push constant of %d bytes exceeds the 128 bytes every device supports." % bytes.size())
	return bytes

## The same for blocks whose fields are all float: ints are converted, not reinterpreted.
static func create_float_push_constant(values : Array) -> PackedByteArray:
	var bytes := PackedFloat32Array(values).to_byte_array()
	if bytes.size() > 128:
		push_error("Push constant of %d bytes exceeds the 128 bytes every device supports." % bytes.size())
	return bytes
