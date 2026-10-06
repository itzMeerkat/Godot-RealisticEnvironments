class_name CloudRenderer
extends RefCounted
## Renders volumetric clouds into [member cubemap] with compute shaders on the
## main RenderingDevice. Owned by SkySystem; see the sky_system README.
##
## Per frame: the weather pass writes a camera-centred coverage/type/density map,
## the raymarch pass refreshes 1 / update_stride^2 of the cubemap texels, and the
## mip pass rebuilds the cubemap's mip chain from them.

const NOISE_BAKE_SHADER := preload("res://addons/sky_system/shaders/compute/cloud_noise_bake.glsl")
const WEATHER_SHADER := preload("res://addons/sky_system/shaders/compute/cloud_weather.glsl")
const RAYMARCH_SHADER := preload("res://addons/sky_system/shaders/compute/cloud_raymarch.glsl")
const MIP_DOWNSAMPLE_SHADER := preload("res://addons/sky_system/shaders/compute/cloud_mip_downsample.glsl")

const SHAPE_NOISE_SIZE := 128
const DETAIL_NOISE_SIZE := 64
const WEATHER_MAP_SIZE := 512
const PLANET_RADIUS := 6360000.0
## Extinction (1/m) of cloud at density 1. CloudPreset.density multiplies it.
const BASE_EXTINCTION := 0.04
## Length of the first step toward the light; later steps grow linearly.
const LIGHT_STEP_LENGTH := 80.0
## Forward-scattering anisotropy of the cloud phase function.
const PHASE_G := 0.6
## The camera is kept at least this far below the cloud base.
const MIN_BASE_CLEARANCE := 50.0
## Raymarch faces dispatched: every cube face but -Y.
const RENDERED_FACE_COUNT := 5
## Bytes of the raymarch Params buffer: eight vec4s, packed by _pack_params().
const PARAMS_SIZE := 8 * 16

## Sampled by the sky, the starfield and the ocean. rgb: premultiplied cloud
## radiance, a: opacity. Only the upper hemisphere is written. Has a full mip
## chain (2x2 box filtered per face) for blurred lookups, e.g. rough reflections.
var cubemap := TextureCubemapRD.new()

## 1, 2 or 4: each frame refreshes one texel of every stride x stride block.
var update_stride := 4
## Steps along each view ray.
var view_steps := 64
## Steps toward the light from each cloud sample.
var light_steps := 6
## Rays end after this distance (m); also sizes the weather map.
var max_distance := 120000.0
## Weight of a texel's previous value when it is refreshed (0 replaces it).
var history_weight := 0.6

var _device : RenderingDevice
var _face_size : int
## Freed in reverse order by release().
var _owned_rids : Array[RID] = []
var _cubemap_rid : RID
var _weather_pipeline : RID
var _weather_set : RID
var _raymarch_pipeline : RID
var _raymarch_set : RID
var _mip_pipeline : RID
## _mip_sets[level - 1] reads level - 1 and writes level.
var _mip_sets : Array[RID] = []
var _params_buffer : RID
var _frame := 0
## Frames left that replace texels instead of blending them with history.
var _fresh_frames := 0


## sky_ambient_buffer: AtmosphereRenderer.sky_ambient_buffer, the sky's light at the
## cloud layer; it must outlive this renderer.
func _init(device : RenderingDevice, face_size : int, sky_ambient_buffer : RID) -> void:
	_device = device
	_face_size = face_size
	var linear_repeat := _own(_device.sampler_create(_make_sampler_state(RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT)))
	var linear_clamp := _own(_device.sampler_create(_make_sampler_state(RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE)))

	var storage_usage := RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
	var shape_noise := _own(_create_texture(RenderingDevice.TEXTURE_TYPE_3D, RenderingDevice.DATA_FORMAT_R8_UNORM, Vector3i.ONE * SHAPE_NOISE_SIZE, 1, storage_usage))
	var detail_noise := _own(_create_texture(RenderingDevice.TEXTURE_TYPE_3D, RenderingDevice.DATA_FORMAT_R8_UNORM, Vector3i.ONE * DETAIL_NOISE_SIZE, 1, storage_usage))
	var weather_map := _own(_create_texture(RenderingDevice.TEXTURE_TYPE_2D, RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT, Vector3i(WEATHER_MAP_SIZE, WEATHER_MAP_SIZE, 1), 1, storage_usage))
	var mip_count := 1 # down to 1x1
	while face_size >> mip_count > 0:
		mip_count += 1
	_cubemap_rid = _own(_create_texture(RenderingDevice.TEXTURE_TYPE_CUBE, RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT, Vector3i(face_size, face_size, 1), 6, storage_usage | RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT, mip_count))
	# The lower hemisphere is never written and must read as "no cloud".
	_device.texture_clear(_cubemap_rid, Color(0.0, 0.0, 0.0, 0.0), 0, mip_count, 0, 6)
	cubemap.texture_rd_rid = _cubemap_rid
	# Storage bindings need single-mip views.
	var mip_views : Array[RID] = []
	for mip in mip_count:
		mip_views.push_back(_own(_device.texture_create_shared_from_slice(RDTextureView.new(), _cubemap_rid, 0, mip, 1, RenderingDevice.TEXTURE_SLICE_CUBEMAP)))

	_params_buffer = _own(_device.storage_buffer_create(PARAMS_SIZE))

	var noise_shader := _load_shader(NOISE_BAKE_SHADER)
	var noise_pipeline := _own(_device.compute_pipeline_create(noise_shader))
	var shape_set := _own(_device.uniform_set_create([_image_uniform(0, shape_noise)], noise_shader, 0))
	var detail_set := _own(_device.uniform_set_create([_image_uniform(0, detail_noise)], noise_shader, 0))

	var weather_shader := _load_shader(WEATHER_SHADER)
	_weather_pipeline = _own(_device.compute_pipeline_create(weather_shader))
	_weather_set = _own(_device.uniform_set_create([_image_uniform(0, weather_map)], weather_shader, 0))

	var raymarch_shader := _load_shader(RAYMARCH_SHADER)
	_raymarch_pipeline = _own(_device.compute_pipeline_create(raymarch_shader))
	_raymarch_set = _own(_device.uniform_set_create([
		_image_uniform(0, mip_views[0]),
		_sampled_uniform(1, linear_repeat, shape_noise),
		_sampled_uniform(2, linear_repeat, detail_noise),
		_sampled_uniform(3, linear_clamp, weather_map),
		_buffer_uniform(4, _params_buffer),
		_buffer_uniform(5, sky_ambient_buffer),
	], raymarch_shader, 0))

	var mip_shader := _load_shader(MIP_DOWNSAMPLE_SHADER)
	_mip_pipeline = _own(_device.compute_pipeline_create(mip_shader))
	for mip in range(1, mip_count):
		_mip_sets.push_back(_own(_device.uniform_set_create([_image_uniform(0, mip_views[mip - 1]), _image_uniform(1, mip_views[mip])], mip_shader, 0)))

	var compute_list := _device.compute_list_begin()
	_device.compute_list_bind_compute_pipeline(compute_list, noise_pipeline)
	for bake in [[shape_set, 0, SHAPE_NOISE_SIZE], [detail_set, 1, DETAIL_NOISE_SIZE]]:
		_device.compute_list_bind_uniform_set(compute_list, bake[0], 0)
		var push_constant := _pack([bake[1]])
		_device.compute_list_set_push_constant(compute_list, push_constant, push_constant.size())
		var groups : int = ceili(bake[2] / 4.0)
		_device.compute_list_dispatch(compute_list, groups, groups, groups)
	_device.compute_list_end()
	restart_history()


## Frees every GPU resource; the owner must call it before dropping the
## renderer. The renderer is unusable afterwards.
func release() -> void:
	cubemap.texture_rd_rid = RID()
	for i in range(_owned_rids.size() - 1, -1, -1):
		_device.free_rid(_owned_rids[i])
	_owned_rids.clear()


## Makes the next full refresh replace the cubemap instead of blending into it,
## e.g. after a jump between presets.
func restart_history() -> void:
	_fresh_frames = update_stride * update_stride


## Frames needed to refresh every texel once.
func get_refresh_frames() -> int:
	return update_stride * update_stride


## Records the weather and raymarch passes for this frame. light_color: the key
## light's irradiance at the cloud layer; sky_light_scale multiplies the sky's light.
func render(camera_position : Vector3, preset : CloudPreset, wind_offset : Vector2, evolution_time : float,
		light_direction : Vector3, light_color : Color, sky_light_scale : float) -> void:
	assert(update_stride in [1, 2, 4], "CloudRenderer.update_stride must be 1, 2 or 4.")
	var cloud_camera := Vector3(camera_position.x, clampf(camera_position.y, 0.0, preset.base_altitude - MIN_BASE_CLEARANCE), camera_position.z)
	var params := _pack_params(cloud_camera, preset, wind_offset, evolution_time, light_direction, light_color, sky_light_scale)
	_device.buffer_update(_params_buffer, 0, params.size(), params)

	var cycle_length := update_stride * update_stride
	var cycle_index := _frame % cycle_length
	var cycle := _frame / cycle_length
	var offset := _pattern_offset(cycle_index)
	var jitter := Vector2(_halton(cycle + 1, 2), _halton(cycle + 1, 3)) - Vector2(0.5, 0.5)
	var history := 0.0 if _fresh_frames > 0 else history_weight

	var compute_list := _device.compute_list_begin()
	_device.compute_list_bind_compute_pipeline(compute_list, _weather_pipeline)
	_device.compute_list_bind_uniform_set(compute_list, _weather_set, 0)
	var weather_push := _pack([
		cloud_camera.x, cloud_camera.z, max_distance * 2.0, evolution_time,
		wind_offset.x, wind_offset.y, preset.weather_scale, preset.coverage,
		preset.coverage_variation, preset.cloud_type, preset.type_variation, preset.density_variation,
	])
	_device.compute_list_set_push_constant(compute_list, weather_push, weather_push.size())
	var weather_groups := ceili(WEATHER_MAP_SIZE / 8.0)
	_device.compute_list_dispatch(compute_list, weather_groups, weather_groups, 1)
	_device.compute_list_add_barrier(compute_list)

	_device.compute_list_bind_compute_pipeline(compute_list, _raymarch_pipeline)
	_device.compute_list_bind_uniform_set(compute_list, _raymarch_set, 0)
	var raymarch_push := _pack([offset.x, offset.y, update_stride, _face_size, jitter.x, jitter.y, history, float(_frame % 4096) * 0.618])
	_device.compute_list_set_push_constant(compute_list, raymarch_push, raymarch_push.size())
	var raymarch_groups := ceili(ceili(_face_size / float(update_stride)) / 8.0)
	_device.compute_list_dispatch(compute_list, raymarch_groups, raymarch_groups, RENDERED_FACE_COUNT)

	# Every level, every frame: each refresh touches texels all over the top level.
	for mip in range(1, _mip_sets.size() + 1):
		_device.compute_list_add_barrier(compute_list)
		# Bound after the barrier: a barrier re-applies the last push constant
		# (the raymarch's, before the first level) to the bound pipeline.
		_device.compute_list_bind_compute_pipeline(compute_list, _mip_pipeline)
		var source_size := maxi(_face_size >> (mip - 1), 1)
		var target_size := maxi(_face_size >> mip, 1)
		_device.compute_list_bind_uniform_set(compute_list, _mip_sets[mip - 1], 0)
		var mip_push := _pack([source_size, target_size])
		_device.compute_list_set_push_constant(compute_list, mip_push, mip_push.size())
		var mip_groups := ceili(target_size / 8.0)
		_device.compute_list_dispatch(compute_list, mip_groups, mip_groups, RENDERED_FACE_COUNT)
	_device.compute_list_end()

	_frame += 1
	_fresh_frames = maxi(_fresh_frames - 1, 0)


func _pack_params(camera_position : Vector3, preset : CloudPreset, wind_offset : Vector2, evolution_time : float,
		light_direction : Vector3, light_color : Color, sky_light_scale : float) -> PackedByteArray:
	return PackedFloat32Array([
		camera_position.x, camera_position.y, camera_position.z, PLANET_RADIUS,
		preset.base_altitude, preset.base_altitude + preset.thickness, max_distance, 0.0,
		camera_position.x, camera_position.z, max_distance * 2.0, BASE_EXTINCTION * preset.density,
		wind_offset.x, wind_offset.y, evolution_time, sky_light_scale,
		preset.shape_scale, preset.detail_scale, preset.detail_erosion, preset.scattering_albedo,
		light_direction.x, light_direction.y, light_direction.z, 0.0,
		light_color.r, light_color.g, light_color.b, 0.0,
		float(view_steps), float(light_steps), LIGHT_STEP_LENGTH, PHASE_G,
	]).to_byte_array()


## Ordered-dither sequence, so consecutive frames refresh texels far apart.
func _pattern_offset(index : int) -> Vector2i:
	match update_stride:
		1:
			return Vector2i.ZERO
		2:
			return [Vector2i(0, 0), Vector2i(1, 1), Vector2i(1, 0), Vector2i(0, 1)][index]
	const BAYER_4 : Array[Vector2i] = [
		Vector2i(0, 0), Vector2i(2, 2), Vector2i(2, 0), Vector2i(0, 2),
		Vector2i(1, 1), Vector2i(3, 3), Vector2i(3, 1), Vector2i(1, 3),
		Vector2i(1, 0), Vector2i(3, 2), Vector2i(3, 0), Vector2i(1, 2),
		Vector2i(0, 1), Vector2i(2, 3), Vector2i(2, 1), Vector2i(0, 3),
	]
	return BAYER_4[index]


static func _halton(index : int, base : int) -> float:
	var result := 0.0
	var fraction := 1.0 / base
	while index > 0:
		result += fraction * (index % base)
		index /= base
		fraction /= base
	return result


func _own(rid : RID) -> RID:
	assert(rid.is_valid(), "CloudRenderer failed to create a GPU resource.")
	_owned_rids.push_back(rid)
	return rid


func _load_shader(shader_file : RDShaderFile) -> RID:
	var spirv := shader_file.get_spirv()
	assert(spirv.compile_error_compute.is_empty(), "Cloud compute shader failed to compile: %s" % spirv.compile_error_compute)
	return _own(_device.shader_create_from_spirv(spirv))


func _create_texture(type : RenderingDevice.TextureType, format : RenderingDevice.DataFormat, size : Vector3i, layers : int, usage : int, mipmaps := 1) -> RID:
	var texture_format := RDTextureFormat.new()
	texture_format.texture_type = type
	texture_format.format = format
	texture_format.width = size.x
	texture_format.height = size.y
	texture_format.depth = size.z
	texture_format.array_layers = layers
	texture_format.mipmaps = mipmaps
	texture_format.usage_bits = usage
	return _device.texture_create(texture_format, RDTextureView.new())


static func _make_sampler_state(repeat_mode : RenderingDevice.SamplerRepeatMode) -> RDSamplerState:
	var state := RDSamplerState.new()
	state.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	state.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	state.repeat_u = repeat_mode
	state.repeat_v = repeat_mode
	state.repeat_w = repeat_mode
	return state


static func _image_uniform(binding : int, texture : RID) -> RDUniform:
	var uniform := RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	uniform.binding = binding
	uniform.add_id(texture)
	return uniform


static func _sampled_uniform(binding : int, sampler : RID, texture : RID) -> RDUniform:
	var uniform := RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	uniform.binding = binding
	uniform.add_id(sampler)
	uniform.add_id(texture)
	return uniform


static func _buffer_uniform(binding : int, buffer : RID) -> RDUniform:
	var uniform := RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	uniform.binding = binding
	uniform.add_id(buffer)
	return uniform


## Push-constant bytes at the exact size the shader declares (4 bytes per value).
static func _pack(values : Array) -> PackedByteArray:
	var bytes := PackedByteArray()
	bytes.resize(values.size() * 4)
	for i in values.size():
		if values[i] is int:
			bytes.encode_s32(i * 4, values[i])
		else:
			bytes.encode_float(i * 4, values[i])
	return bytes
