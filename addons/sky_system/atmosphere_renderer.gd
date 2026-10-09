class_name AtmosphereRenderer
extends RefCounted
## Builds the atmosphere's lookup textures with compute shaders on the main
## RenderingDevice, once per frame. Owned by SkySystem; see the sky_system README.
##
## The atmosphere model lives only in these passes (shaders/compute/atmosphere_*.glsl):
## every consumer (sky, starfield, aerial perspective, water, transparent materials,
## clouds) samples their results instead of integrating the atmosphere itself.
##
## Per frame: the transmittance LUT; the multiple-scattering LUT from it; three view
## volumes from both: one for the camera (view_*, every distance up to max_distance
## and the ray's end), one for an observer on the sea (sea_*, at the cloud layer and
## at the ray's end: the sky the water reflects) and one at the cloud layer (ray ends
## only); and from the last and the first, the sky light at the cloud layer
## (sky_ambient_buffer) and at the camera (camera_sky_light_buffer).

const TRANSMITTANCE_SHADER := preload("res://addons/sky_system/shaders/compute/atmosphere_transmittance.glsl")
const MULTIPLE_SCATTERING_SHADER := preload("res://addons/sky_system/shaders/compute/atmosphere_multiple_scattering.glsl")
const VIEW_SHADER := preload("res://addons/sky_system/shaders/compute/atmosphere_view.glsl")
const AMBIENT_SHADER := preload("res://addons/sky_system/shaders/compute/atmosphere_ambient.glsl")

## Rows run up to the 100 km top, densest near the sea: 256 of them keep a 150 m
## sea fog layer several rows deep.
const TRANSMITTANCE_SIZE := Vector2i(256, 256)
## Key light's cosine x altitude (log-spaced in haze scale heights).
const MULTIPLE_SCATTERING_SIZE := Vector2i(32, 32)
## View volumes: azimuth from the light x view angle x distance slices.
const VIEW_SIZE := Vector3i(32, 128, 64)
## Distance (m) of the camera volume's last regular slice; farther points read it.
## Beyond the cameras' far planes (the demo uses 60 km).
const MAX_DISTANCE := 100000.0
## Where the air ends (m): its density is e^-12 of the sea level's there, and the
## ozone layer lies below.
const AIR_TOP_ALTITUDE := 100000.0
## The atmosphere reaches at least this many haze scale heights up.
const HAZE_TOP_SCALE_HEIGHTS := 12.0
## Bytes of a sky light buffer: three vec4s (atmosphere_ambient.glsl).
const SKY_LIGHT_SIZE := 48

## Camera view volume (sampled by the sky, starfield, aerial perspective and transparent
## materials): rgb transmittance, rgb in-scatter but the lobe, rgb lobe in-scatter per
## unit phase.
var view_transmittance := Texture3DRD.new()
var view_inscatter := Texture3DRD.new()
var view_inscatter_lobe := Texture3DRD.new()
## The same for an observer on the sea, two slices: at the cloud layer (distance to
## cloud_altitude) and at the ray's end. The sky the water reflects.
var sea_transmittance := Texture3DRD.new()
var sea_inscatter := Texture3DRD.new()
var sea_inscatter_lobe := Texture3DRD.new()
## Storage buffers of the sky's light (atmosphere_ambient.glsl: rgb mean radiance above,
## below, irradiance on a level surface), written on the GPU:
## at the cloud layer (cloud_ambient_altitude), clear sky: the clouds' ambient light;
var sky_ambient_buffer : RID
## at the camera, through the clouds: the sky's share of the scene's light meter (read
## back by SkySystem).
var camera_sky_light_buffer : RID

## Haze (CloudPreset haze_*): extinction at sea level (1/m), scale height (m) and its
## forward lobe's Henyey-Greenstein g.
var haze_density := 0.0
var haze_scale_height := 1000.0
var haze_anisotropy := 0.97
## Toward the key light (sun or moon).
var light_direction := Vector3.UP
## The key light above the atmosphere: pi * energy, white.
var light_color := Color.BLACK
## The other body, the same way: it lights the atmosphere too, without the haze's lobe.
var secondary_direction := Vector3.DOWN
var secondary_color := Color.BLACK
## Multiplies the cloud opacity toward the light where it shades the atmosphere.
var cloud_shadow_strength := 1.0
## Altitudes (m) of the cloud layer's base (where the sea volume's first slice lies)
## and top: the clouds shade the air below the layer.
var cloud_altitude := 1500.0
var cloud_top_altitude := 4500.0
## Altitude (m) the clouds' ambient light is measured at (the layer's middle).
var cloud_ambient_altitude := 3000.0

var _device : RenderingDevice
## Owns every GPU resource; freed by release().
var _context : RenderingContext
var _transmittance_pipeline : RID
var _transmittance_set : RID
var _multiple_scattering_pipeline : RID
var _multiple_scattering_set : RID
var _view_shader : RID
var _view_pipeline : RID
var _ambient_shader : RID
var _ambient_pipeline : RID
var _transmittance_rid : RID
var _multiple_scattering_rid : RID
var _view_rids : Array[RID] = []
var _sea_rids : Array[RID] = []
var _cloud_layer_rids : Array[RID] = []
var _linear_clamp : RID
var _no_cloud_cubemap : RID


func _init(device : RenderingDevice) -> void:
	_device = device
	_context = RenderingContext.new(device)
	_linear_clamp = _context.create_sampler(RenderingContext.linear_sampler_state(RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE, true))
	var storage_usage := RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
	_transmittance_rid = _create_texture(RenderingDevice.TEXTURE_TYPE_2D, Vector3i(TRANSMITTANCE_SIZE.x, TRANSMITTANCE_SIZE.y, 1), storage_usage)
	_multiple_scattering_rid = _create_texture(RenderingDevice.TEXTURE_TYPE_2D, Vector3i(MULTIPLE_SCATTERING_SIZE.x, MULTIPLE_SCATTERING_SIZE.y, 1), storage_usage)
	for i in 3:
		_view_rids.push_back(_create_texture(RenderingDevice.TEXTURE_TYPE_3D, VIEW_SIZE, storage_usage))
		_sea_rids.push_back(_create_texture(RenderingDevice.TEXTURE_TYPE_3D, Vector3i(VIEW_SIZE.x, VIEW_SIZE.y, 2), storage_usage))
		_cloud_layer_rids.push_back(_create_texture(RenderingDevice.TEXTURE_TYPE_3D, Vector3i(VIEW_SIZE.x, VIEW_SIZE.y, 1), storage_usage))
	view_transmittance.texture_rd_rid = _view_rids[0]
	view_inscatter.texture_rd_rid = _view_rids[1]
	view_inscatter_lobe.texture_rd_rid = _view_rids[2]
	sea_transmittance.texture_rd_rid = _sea_rids[0]
	sea_inscatter.texture_rd_rid = _sea_rids[1]
	sea_inscatter_lobe.texture_rd_rid = _sea_rids[2]
	sky_ambient_buffer = _context.create_storage_buffer(SKY_LIGHT_SIZE).rid
	camera_sky_light_buffer = _context.create_storage_buffer(SKY_LIGHT_SIZE).rid

	var transparent_face := PackedByteArray([0, 0, 0, 0])
	var faces : Array[PackedByteArray] = []
	for face in 6:
		faces.push_back(transparent_face)
	_no_cloud_cubemap = _context.create_texture_rid(RenderingDevice.TEXTURE_TYPE_CUBE, RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM, Vector3i.ONE, RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT, 6, 1, faces)

	var transmittance_shader := _context.load_shader_file(TRANSMITTANCE_SHADER)
	_transmittance_pipeline = _context.create_compute_pipeline(transmittance_shader)
	_transmittance_set = _context.create_uniform_set([RenderingContext.image_uniform(0, _transmittance_rid)], transmittance_shader)
	var multiple_scattering_shader := _context.load_shader_file(MULTIPLE_SCATTERING_SHADER)
	_multiple_scattering_pipeline = _context.create_compute_pipeline(multiple_scattering_shader)
	_multiple_scattering_set = _context.create_uniform_set([
		_sampled_uniform(0, _transmittance_rid),
		RenderingContext.image_uniform(1, _multiple_scattering_rid),
	], multiple_scattering_shader)
	_view_shader = _context.load_shader_file(VIEW_SHADER)
	_view_pipeline = _context.create_compute_pipeline(_view_shader)
	_ambient_shader = _context.load_shader_file(AMBIENT_SHADER)
	_ambient_pipeline = _context.create_compute_pipeline(_ambient_shader)


## Frees every GPU resource; the owner must call it before dropping the renderer,
## after unbinding the textures and the buffer from their consumers. Unusable afterwards.
func release() -> void:
	for texture in [view_transmittance, view_inscatter, view_inscatter_lobe, sea_transmittance, sea_inscatter, sea_inscatter_lobe]:
		texture.texture_rd_rid = RID()
	_context.free()
	_context = null


## True when a GPU resource failed to be created; the owner must release() it
## instead of rendering.
func has_failed() -> bool:
	return _context.failed


## Altitude (m) where the atmosphere ends.
func get_top_altitude() -> float:
	return maxf(AIR_TOP_ALTITUDE, HAZE_TOP_SCALE_HEIGHTS * haze_scale_height)


## The observer altitude the camera volume is built for: the camera's, kept inside the
## atmosphere (consumers must map directions with this value, not their own).
func get_observer_altitude(camera_altitude : float) -> float:
	return clampf(camera_altitude, 0.0, get_top_altitude() * 0.999)


## Records this frame's passes for a camera at camera_altitude (m above the sea).
## cloud_cubemap: the clouds' RenderingDevice cubemap, or an empty RID. exposure: the
## camera's exposure, which every result but the transmittance is stored at
## (pre-exposed: the light is scaled by it).
func render(camera_altitude : float, cloud_cubemap : RID, exposure : float) -> void:
	var top := get_top_altitude()
	var media_push := RenderingContext.create_float_push_constant([haze_density, haze_scale_height, top, haze_anisotropy])
	var compute_list := _device.compute_list_begin()
	_device.compute_list_bind_compute_pipeline(compute_list, _transmittance_pipeline)
	_device.compute_list_bind_uniform_set(compute_list, _transmittance_set, 0)
	_device.compute_list_set_push_constant(compute_list, media_push, media_push.size())
	_device.compute_list_dispatch(compute_list, ceili(TRANSMITTANCE_SIZE.x / 8.0), ceili(TRANSMITTANCE_SIZE.y / 8.0), 1)
	_device.compute_list_add_barrier(compute_list)

	# Bound after each barrier: a barrier re-applies the last push constant to the bound pipeline.
	_device.compute_list_bind_compute_pipeline(compute_list, _multiple_scattering_pipeline)
	_device.compute_list_bind_uniform_set(compute_list, _multiple_scattering_set, 0)
	_device.compute_list_set_push_constant(compute_list, media_push, media_push.size())
	_device.compute_list_dispatch(compute_list, MULTIPLE_SCATTERING_SIZE.x, MULTIPLE_SCATTERING_SIZE.y, 1)
	_device.compute_list_add_barrier(compute_list)

	var clouds := cloud_cubemap if cloud_cubemap.is_valid() else _no_cloud_cubemap
	var ambient_altitude := clampf(cloud_ambient_altitude, 0.0, top * 0.999)
	for volume in [[get_observer_altitude(camera_altitude), _view_rids, VIEW_SIZE.z], [0.0, _sea_rids, 2], [ambient_altitude, _cloud_layer_rids, 1]]:
		_device.compute_list_bind_compute_pipeline(compute_list, _view_pipeline)
		var targets : Array[RID] = volume[1]
		var view_set := UniformSetCacheRD.get_cache(_view_shader, 0, [
			_sampled_uniform(0, _transmittance_rid),
			_sampled_uniform(1, clouds),
			RenderingContext.image_uniform(2, targets[0]),
			RenderingContext.image_uniform(3, targets[1]),
			RenderingContext.image_uniform(4, targets[2]),
			_sampled_uniform(5, _multiple_scattering_rid),
		])
		_device.compute_list_bind_uniform_set(compute_list, view_set, 0)
		var view_push := RenderingContext.create_float_push_constant([
			volume[0], haze_density, haze_scale_height, top,
			light_direction.x, light_direction.y, light_direction.z, MAX_DISTANCE,
			light_color.r * exposure, light_color.g * exposure, light_color.b * exposure, cloud_shadow_strength,
			cloud_altitude, cloud_top_altitude, haze_anisotropy, 0.0,
			secondary_direction.x, secondary_direction.y, secondary_direction.z, 0.0,
			secondary_color.r * exposure, secondary_color.g * exposure, secondary_color.b * exposure, 0.0,
		])
		_device.compute_list_set_push_constant(compute_list, view_push, view_push.size())
		_device.compute_list_dispatch(compute_list, ceili(VIEW_SIZE.x / 8.0), ceili(VIEW_SIZE.y / 8.0), 1)
	_device.compute_list_add_barrier(compute_list)

	for light in [[ambient_altitude, _cloud_layer_rids, sky_ambient_buffer, 0.0], [get_observer_altitude(camera_altitude), _view_rids, camera_sky_light_buffer, 1.0]]:
		_device.compute_list_bind_compute_pipeline(compute_list, _ambient_pipeline)
		var volumes : Array[RID] = light[1]
		var ambient_set := UniformSetCacheRD.get_cache(_ambient_shader, 0, [
			_sampled_uniform(0, volumes[1]),
			_sampled_uniform(1, volumes[2]),
			RenderingContext.buffer_uniform(2, light[2]),
			_sampled_uniform(3, clouds),
		])
		_device.compute_list_bind_uniform_set(compute_list, ambient_set, 0)
		var ambient_push := RenderingContext.create_float_push_constant([light[0], light[3], 0.0, 0.0, light_direction.x, light_direction.y, light_direction.z, 0.0])
		_device.compute_list_set_push_constant(compute_list, ambient_push, ambient_push.size())
		_device.compute_list_dispatch(compute_list, 1, 1, 1)
	_device.compute_list_end()



func _create_texture(type : RenderingDevice.TextureType, size : Vector3i, usage : int) -> RID:
	return _context.create_texture_rid(type, RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT, size, usage)


func _sampled_uniform(binding : int, texture : RID) -> RDUniform:
	return RenderingContext.sampled_uniform(binding, _linear_clamp, texture)
