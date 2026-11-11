class_name GRECloudRenderer
extends RefCounted
## Renders the volumetric cloud layer with compute shaders on the main
## RenderingDevice. Owned by GRESkySystem.
##
## Per frame: the weather pass writes a camera-centred coverage/type/density map;
## the raymarch pass refreshes 1 / update_stride^2 of the texels of two cubemaps,
## and the mip pass rebuilds their mip chains:
## - [member sea_cubemap]: the clouds seen from the sea below the camera (the
##   water's reflection, the atmosphere's cloud shadows);
## - [member camera_cubemap]: the clouds seen from the camera, wherever it is (the
##   sky's radiance map and the light meter).
## The camera's own view is traced on screen by GREVolumetricCloudEffect, from the same
## noise, weather map and parameters ([method get_trace_resources]).

const NOISE_BAKE_SHADER := preload("res://addons/gre_sky_system/shaders/compute/cloud_noise_bake.glsl")
const WEATHER_SHADER := preload("res://addons/gre_sky_system/shaders/compute/cloud_weather.glsl")
const RAYMARCH_SHADER := preload("res://addons/gre_sky_system/shaders/compute/cloud_raymarch.glsl")
const MIP_DOWNSAMPLE_SHADER := preload("res://addons/gre_sky_system/shaders/compute/cloud_mip_downsample.glsl")

const SHAPE_NOISE_SIZE := 128
const DETAIL_NOISE_SIZE := 64
const WEATHER_MAP_SIZE := 512
## Edge length in texels of the camera cubemap's faces: it only feeds blurred light.
const CAMERA_CUBEMAP_SIZE := 256
## Extinction (1/m) of cloud at density 1. GRECloudPreset.density multiplies it.
const BASE_EXTINCTION := 0.04
## Longest march toward the light (m): it ends at the layer's top, or here.
const MAX_LIGHT_DISTANCE := 10000.0
## Henyey-Greenstein g of cloud droplets.
const PHASE_G := 0.85
## The sea cubemap's observer is kept at least this far below the cloud base.
const MIN_BASE_CLEARANCE := 50.0
## Faces each cubemap's raymarch and mip passes dispatch (face_mode in the shaders):
## the sea's every face but -Y, the camera's all six.
const SEA_FACE_COUNT := 5
const CAMERA_FACE_COUNT := 6
## Bytes of the Params buffer (cloud_common.glslinc): seven vec4s, packed by _pack_params().
const PARAMS_SIZE := 7 * 16

## The clouds seen from the sea surface below the camera (rgb: premultiplied cloud
## radiance, a: opacity; only the upper hemisphere is written). Full mip chain
## (2x2 box filtered per face) for blurred lookups, e.g. rough reflections.
var sea_cubemap := TextureCubemapRD.new()
## The clouds seen from the camera (CAMERA_CUBEMAP_SIZE, every face), encoded and
## filtered the same way.
var camera_cubemap := TextureCubemapRD.new()

## 1, 2 or 4: each frame refreshes one texel of every stride x stride block.
var update_stride := 4 :
	set(value):
		if value not in [1, 2, 4]:
			push_error("GRECloudRenderer.update_stride must be 1, 2 or 4; keeping %d." % update_stride)
			return
		update_stride = value
## Steps along each view ray.
var view_steps := 64
## Steps toward the light from each cloud sample.
var light_steps := 6
## Rays end after this distance (m); also sizes the weather map.
var max_distance := 120000.0
## Weight of a texel's previous value when it is refreshed (0 replaces it).
var history_weight := 0.6

var _device : RenderingDevice
## Owns every GPU resource; freed by release().
var _context : GRERenderingContext
var _shape_noise : RID
var _detail_noise : RID
var _weather_map : RID
var _sky_ambient_buffer : RID
var _transmittance_lut : RID
var _weather_pipeline : RID
var _weather_set : RID
var _raymarch_pipeline : RID
var _mip_pipeline : RID
## Per cubemap: [face size, face mode, face count, raymarch set, mip sets (Array[RID],
## [level - 1] reads level - 1 and writes level)].
var _cubemaps : Array[Array] = []
var _params_buffer : RID
var _frame := 0
## Frames left that replace texels instead of blending them with history.
var _fresh_frames := 0


## sky_ambient_buffer, transmittance_lut: GREAtmosphereRenderer's sky light at the cloud
## layer and transmittance LUT; they must outlive this renderer.
func _init(device : RenderingDevice, sea_face_size : int, sky_ambient_buffer : RID, transmittance_lut : RID) -> void:
	_device = device
	_sky_ambient_buffer = sky_ambient_buffer
	_transmittance_lut = transmittance_lut
	_context = GRERenderingContext.new(device)
	var linear_repeat := _context.create_sampler(GRERenderingContext.linear_sampler_state(RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT))
	var linear_clamp := _context.create_sampler(GRERenderingContext.linear_sampler_state(RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE))

	var storage_usage := RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
	_shape_noise = _context.create_texture_rid(RenderingDevice.TEXTURE_TYPE_3D, RenderingDevice.DATA_FORMAT_R8_UNORM, Vector3i.ONE * SHAPE_NOISE_SIZE, storage_usage)
	_detail_noise = _context.create_texture_rid(RenderingDevice.TEXTURE_TYPE_3D, RenderingDevice.DATA_FORMAT_R8_UNORM, Vector3i.ONE * DETAIL_NOISE_SIZE, storage_usage)
	_weather_map = _context.create_texture_rid(RenderingDevice.TEXTURE_TYPE_2D, RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT, Vector3i(WEATHER_MAP_SIZE, WEATHER_MAP_SIZE, 1), storage_usage)
	_params_buffer = _context.create_storage_buffer(PARAMS_SIZE).rid

	var noise_shader := _context.load_shader_file(NOISE_BAKE_SHADER)
	var noise_pipeline := _context.create_compute_pipeline(noise_shader)
	var shape_set := _context.create_uniform_set([GRERenderingContext.image_uniform(0, _shape_noise)], noise_shader)
	var detail_set := _context.create_uniform_set([GRERenderingContext.image_uniform(0, _detail_noise)], noise_shader)

	var weather_shader := _context.load_shader_file(WEATHER_SHADER)
	_weather_pipeline = _context.create_compute_pipeline(weather_shader)
	_weather_set = _context.create_uniform_set([GRERenderingContext.image_uniform(0, _weather_map)], weather_shader)

	var raymarch_shader := _context.load_shader_file(RAYMARCH_SHADER)
	_raymarch_pipeline = _context.create_compute_pipeline(raymarch_shader)
	var mip_shader := _context.load_shader_file(MIP_DOWNSAMPLE_SHADER)
	_mip_pipeline = _context.create_compute_pipeline(mip_shader)
	for cubemap in [[sea_cubemap, sea_face_size, 0, SEA_FACE_COUNT], [camera_cubemap, CAMERA_CUBEMAP_SIZE, 1, CAMERA_FACE_COUNT]]:
		var face_size : int = cubemap[1]
		var mip_count := 1 # down to 1x1
		while face_size >> mip_count > 0:
			mip_count += 1
		var cubemap_rid := _context.create_texture_rid(RenderingDevice.TEXTURE_TYPE_CUBE, RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT, Vector3i(face_size, face_size, 1), storage_usage | RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT, 6, mip_count)
		# Faces never written (the sea's -Y) must read as "no cloud".
		_device.texture_clear(cubemap_rid, Color(0.0, 0.0, 0.0, 0.0), 0, mip_count, 0, 6)
		var texture : TextureCubemapRD = cubemap[0]
		texture.texture_rd_rid = cubemap_rid
		# Storage bindings need single-mip views.
		var mip_views : Array[RID] = []
		for mip in mip_count:
			mip_views.push_back(_context.own(_device.texture_create_shared_from_slice(RDTextureView.new(), cubemap_rid, 0, mip, 1, RenderingDevice.TEXTURE_SLICE_CUBEMAP)))
		# sky_ambient_buffer belongs to the GREAtmosphereRenderer, which must outlive this set.
		var raymarch_set := _context.create_uniform_set([
			GRERenderingContext.image_uniform(0, mip_views[0]),
			GRERenderingContext.sampled_uniform(1, linear_repeat, _shape_noise),
			GRERenderingContext.sampled_uniform(2, linear_repeat, _detail_noise),
			GRERenderingContext.sampled_uniform(3, linear_clamp, _weather_map),
			GRERenderingContext.buffer_uniform(4, _params_buffer),
			GRERenderingContext.buffer_uniform(5, sky_ambient_buffer),
			GRERenderingContext.sampled_uniform(6, linear_clamp, transmittance_lut),
		], raymarch_shader)
		var mip_sets : Array[RID] = []
		for mip in range(1, mip_count):
			mip_sets.push_back(_context.create_uniform_set([GRERenderingContext.image_uniform(0, mip_views[mip - 1]), GRERenderingContext.image_uniform(1, mip_views[mip])], mip_shader))
		_cubemaps.push_back([face_size, cubemap[2], cubemap[3], raymarch_set, mip_sets])

	var compute_list := _device.compute_list_begin()
	_device.compute_list_bind_compute_pipeline(compute_list, noise_pipeline)
	for bake in [[shape_set, 0, SHAPE_NOISE_SIZE], [detail_set, 1, DETAIL_NOISE_SIZE]]:
		_device.compute_list_bind_uniform_set(compute_list, bake[0], 0)
		var push_constant := GRERenderingContext.create_push_constant([bake[1]])
		_device.compute_list_set_push_constant(compute_list, push_constant, push_constant.size())
		var groups : int = ceili(bake[2] / 4.0)
		_device.compute_list_dispatch(compute_list, groups, groups, groups)
	_device.compute_list_end()
	restart_history()


## Frees every GPU resource; the owner must call it before dropping the
## renderer, after unbinding the cubemaps and the trace resources from their
## consumers. The renderer is unusable afterwards.
func release() -> void:
	sea_cubemap.texture_rd_rid = RID()
	camera_cubemap.texture_rd_rid = RID()
	_context.free()
	_context = null


## True when a GPU resource failed to be created; the owner must release() it
## instead of rendering.
func has_failed() -> bool:
	return _context.failed


## What a screen-space trace binds for cloud_common.glslinc: the shape and detail
## noise, the weather map, the Params buffer, the sky ambient buffer (bindings 1-5) and
## the transmittance LUT (CLOUD_TRANSMITTANCE_BINDING). Valid until release().
func get_trace_resources() -> Array[RID]:
	return [_shape_noise, _detail_noise, _weather_map, _params_buffer, _sky_ambient_buffer, _transmittance_lut]


## Makes the next full refresh replace the cubemaps instead of blending into them,
## e.g. after a jump between presets.
func restart_history() -> void:
	_fresh_frames = update_stride * update_stride


## Frames needed to refresh every texel once.
func get_refresh_frames() -> int:
	return update_stride * update_stride


## Records the weather, raymarch and mip passes for this frame. camera_position:
## world x, altitude above the sea (m), world z. light_color: the key light's
## energy above the atmosphere (irradiance / pi); atmosphere_top: the atmosphere's top
## altitude (m) for its transmittance LUT; haze_wavelength_exponent: the haze's
## (GRECloudPreset), for the LUT's colour; sky_light_scale multiplies the sky's light.
func render(camera_position : Vector3, preset : GRECloudPreset, wind_offset : Vector2, evolution_time : float,
		light_direction : Vector3, light_color : Color, atmosphere_top : float, haze_wavelength_exponent : float, sky_light_scale : float) -> void:
	var params := _pack_params(camera_position, preset, wind_offset, evolution_time, light_direction, light_color, atmosphere_top, haze_wavelength_exponent, sky_light_scale)
	_device.buffer_update(_params_buffer, 0, params.size(), params)

	var cycle_length := update_stride * update_stride
	var cycle_index := _frame % cycle_length
	@warning_ignore("integer_division")
	var cycle := _frame / cycle_length
	var offset := _pattern_offset(cycle_index)
	var jitter := Vector2(_halton(cycle + 1, 2), _halton(cycle + 1, 3)) - Vector2(0.5, 0.5)
	var history := 0.0 if _fresh_frames > 0 else history_weight
	var frame_seed := float(_frame % 4096) * 0.618
	var sea_observer := Vector3(camera_position.x, clampf(camera_position.y, 0.0, preset.base_altitude - MIN_BASE_CLEARANCE), camera_position.z)
	var camera_observer := Vector3(camera_position.x, maxf(camera_position.y, 0.0), camera_position.z)

	var compute_list := _device.compute_list_begin()
	_device.compute_list_bind_compute_pipeline(compute_list, _weather_pipeline)
	_device.compute_list_bind_uniform_set(compute_list, _weather_set, 0)
	var weather_push := GRERenderingContext.create_push_constant([
		camera_position.x, camera_position.z, max_distance * 2.0, evolution_time,
		wind_offset.x, wind_offset.y, preset.weather_scale, preset.coverage,
		preset.coverage_variation, preset.cloud_type, preset.type_variation, preset.density_variation,
	])
	_device.compute_list_set_push_constant(compute_list, weather_push, weather_push.size())
	var weather_groups := ceili(WEATHER_MAP_SIZE / 8.0)
	_device.compute_list_dispatch(compute_list, weather_groups, weather_groups, 1)
	_device.compute_list_add_barrier(compute_list)

	for i in _cubemaps.size():
		var cubemap := _cubemaps[i]
		var face_size : int = cubemap[0]
		var observer := sea_observer if i == 0 else camera_observer
		_device.compute_list_bind_compute_pipeline(compute_list, _raymarch_pipeline)
		_device.compute_list_bind_uniform_set(compute_list, cubemap[3], 0)
		var raymarch_push := GRERenderingContext.create_push_constant([offset.x, offset.y, update_stride, face_size,
			jitter.x, jitter.y, history, frame_seed, observer.x, observer.y, observer.z, cubemap[1]])
		_device.compute_list_set_push_constant(compute_list, raymarch_push, raymarch_push.size())
		var raymarch_groups := ceili(ceili(face_size / float(update_stride)) / 8.0)
		_device.compute_list_dispatch(compute_list, raymarch_groups, raymarch_groups, cubemap[2])

	# Every level, every frame: each refresh touches texels all over the top level.
	var mip_count := 0
	for cubemap in _cubemaps:
		mip_count = maxi(mip_count, (cubemap[4] as Array).size())
	for mip in range(1, mip_count + 1):
		_device.compute_list_add_barrier(compute_list)
		# Bound after the barrier: a barrier re-applies the last push constant
		# (the raymarch's, before the first level) to the bound pipeline.
		_device.compute_list_bind_compute_pipeline(compute_list, _mip_pipeline)
		for cubemap in _cubemaps:
			var mip_sets : Array[RID] = cubemap[4]
			if mip > mip_sets.size():
				continue
			var face_size : int = cubemap[0]
			var source_size := maxi(face_size >> (mip - 1), 1)
			var target_size := maxi(face_size >> mip, 1)
			_device.compute_list_bind_uniform_set(compute_list, mip_sets[mip - 1], 0)
			var mip_push := GRERenderingContext.create_push_constant([source_size, target_size, cubemap[1]])
			_device.compute_list_set_push_constant(compute_list, mip_push, mip_push.size())
			var mip_groups := ceili(target_size / 8.0)
			_device.compute_list_dispatch(compute_list, mip_groups, mip_groups, cubemap[2])
	_device.compute_list_end()

	_frame += 1
	_fresh_frames = maxi(_fresh_frames - 1, 0)


func _pack_params(camera_position : Vector3, preset : GRECloudPreset, wind_offset : Vector2, evolution_time : float,
		light_direction : Vector3, light_color : Color, atmosphere_top : float, haze_wavelength_exponent : float, sky_light_scale : float) -> PackedByteArray:
	return PackedFloat32Array([
		preset.base_altitude, preset.base_altitude + preset.thickness, max_distance, atmosphere_top,
		camera_position.x, camera_position.z, max_distance * 2.0, BASE_EXTINCTION * preset.density,
		wind_offset.x, wind_offset.y, evolution_time, sky_light_scale,
		preset.shape_scale, preset.detail_scale, preset.detail_erosion, preset.scattering_albedo,
		light_direction.x, light_direction.y, light_direction.z, haze_wavelength_exponent,
		light_color.r, light_color.g, light_color.b, 0.0,
		float(view_steps), float(light_steps), MAX_LIGHT_DISTANCE, PHASE_G,
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
