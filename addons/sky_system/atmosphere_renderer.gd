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

## Haze (CloudPreset haze_*): extinction at sea level (1/m) and scale height (m).
var haze_density := 0.0
var haze_scale_height := 1000.0
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
## Freed in reverse order by release().
var _owned_rids : Array[RID] = []
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
	_linear_clamp = _own(_device.sampler_create(_make_sampler_state()))
	var storage_usage := RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
	_transmittance_rid = _own(_create_texture(RenderingDevice.TEXTURE_TYPE_2D, Vector3i(TRANSMITTANCE_SIZE.x, TRANSMITTANCE_SIZE.y, 1), storage_usage))
	_multiple_scattering_rid = _own(_create_texture(RenderingDevice.TEXTURE_TYPE_2D, Vector3i(MULTIPLE_SCATTERING_SIZE.x, MULTIPLE_SCATTERING_SIZE.y, 1), storage_usage))
	for i in 3:
		_view_rids.push_back(_own(_create_texture(RenderingDevice.TEXTURE_TYPE_3D, VIEW_SIZE, storage_usage)))
		_sea_rids.push_back(_own(_create_texture(RenderingDevice.TEXTURE_TYPE_3D, Vector3i(VIEW_SIZE.x, VIEW_SIZE.y, 2), storage_usage)))
		_cloud_layer_rids.push_back(_own(_create_texture(RenderingDevice.TEXTURE_TYPE_3D, Vector3i(VIEW_SIZE.x, VIEW_SIZE.y, 1), storage_usage)))
	view_transmittance.texture_rd_rid = _view_rids[0]
	view_inscatter.texture_rd_rid = _view_rids[1]
	view_inscatter_lobe.texture_rd_rid = _view_rids[2]
	sea_transmittance.texture_rd_rid = _sea_rids[0]
	sea_inscatter.texture_rd_rid = _sea_rids[1]
	sea_inscatter_lobe.texture_rd_rid = _sea_rids[2]
	sky_ambient_buffer = _own(_device.storage_buffer_create(SKY_LIGHT_SIZE, PackedByteArray()))
	camera_sky_light_buffer = _own(_device.storage_buffer_create(SKY_LIGHT_SIZE, PackedByteArray()))

	var no_cloud_format := RDTextureFormat.new()
	no_cloud_format.texture_type = RenderingDevice.TEXTURE_TYPE_CUBE
	no_cloud_format.format = RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM
	no_cloud_format.width = 1
	no_cloud_format.height = 1
	no_cloud_format.array_layers = 6
	no_cloud_format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	var transparent_face := PackedByteArray([0, 0, 0, 0])
	_no_cloud_cubemap = _own(_device.texture_create(no_cloud_format, RDTextureView.new(), [transparent_face, transparent_face, transparent_face, transparent_face, transparent_face, transparent_face]))

	var transmittance_shader := _load_shader(TRANSMITTANCE_SHADER)
	_transmittance_pipeline = _own(_device.compute_pipeline_create(transmittance_shader))
	_transmittance_set = _own(_device.uniform_set_create([_image_uniform(0, _transmittance_rid)], transmittance_shader, 0))
	var multiple_scattering_shader := _load_shader(MULTIPLE_SCATTERING_SHADER)
	_multiple_scattering_pipeline = _own(_device.compute_pipeline_create(multiple_scattering_shader))
	_multiple_scattering_set = _own(_device.uniform_set_create([
		_sampled_uniform(0, _transmittance_rid),
		_image_uniform(1, _multiple_scattering_rid),
	], multiple_scattering_shader, 0))
	_view_shader = _load_shader(VIEW_SHADER)
	_view_pipeline = _own(_device.compute_pipeline_create(_view_shader))
	_ambient_shader = _load_shader(AMBIENT_SHADER)
	_ambient_pipeline = _own(_device.compute_pipeline_create(_ambient_shader))


## Frees every GPU resource; the owner must call it before dropping the renderer,
## after unbinding the textures and the buffer from their consumers. Unusable afterwards.
func release() -> void:
	for texture in [view_transmittance, view_inscatter, view_inscatter_lobe, sea_transmittance, sea_inscatter, sea_inscatter_lobe]:
		texture.texture_rd_rid = RID()
	for i in range(_owned_rids.size() - 1, -1, -1):
		_device.free_rid(_owned_rids[i])
	_owned_rids.clear()


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
	var media_push := _pack([haze_density, haze_scale_height, top, 0.0])
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
			_image_uniform(2, targets[0]),
			_image_uniform(3, targets[1]),
			_image_uniform(4, targets[2]),
			_sampled_uniform(5, _multiple_scattering_rid),
		])
		_device.compute_list_bind_uniform_set(compute_list, view_set, 0)
		var view_push := _pack([
			volume[0], haze_density, haze_scale_height, top,
			light_direction.x, light_direction.y, light_direction.z, MAX_DISTANCE,
			light_color.r * exposure, light_color.g * exposure, light_color.b * exposure, cloud_shadow_strength,
			cloud_altitude, cloud_top_altitude, 0.0, 0.0,
			secondary_direction.x, secondary_direction.y, secondary_direction.z, 0.0,
			secondary_color.r * exposure, secondary_color.g * exposure, secondary_color.b * exposure, 0.0,
		])
		_device.compute_list_set_push_constant(compute_list, view_push, view_push.size())
		_device.compute_list_dispatch(compute_list, ceili(VIEW_SIZE.x / 8.0), ceili(VIEW_SIZE.y / 8.0), 1)
	_device.compute_list_add_barrier(compute_list)

	for light in [[ambient_altitude, _cloud_layer_rids, sky_ambient_buffer, 0.0], [get_observer_altitude(camera_altitude), _view_rids, camera_sky_light_buffer, 1.0]]:
		_device.compute_list_bind_compute_pipeline(compute_list, _ambient_pipeline)
		var volumes : Array[RID] = light[1]
		var buffer_uniform := RDUniform.new()
		buffer_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		buffer_uniform.binding = 2
		buffer_uniform.add_id(light[2])
		var ambient_set := UniformSetCacheRD.get_cache(_ambient_shader, 0, [
			_sampled_uniform(0, volumes[1]),
			_sampled_uniform(1, volumes[2]),
			buffer_uniform,
			_sampled_uniform(3, clouds),
		])
		_device.compute_list_bind_uniform_set(compute_list, ambient_set, 0)
		var ambient_push := _pack([light[0], light[3], 0.0, 0.0, light_direction.x, light_direction.y, light_direction.z, 0.0])
		_device.compute_list_set_push_constant(compute_list, ambient_push, ambient_push.size())
		_device.compute_list_dispatch(compute_list, 1, 1, 1)
	_device.compute_list_end()


func _own(rid : RID) -> RID:
	assert(rid.is_valid(), "AtmosphereRenderer failed to create a GPU resource.")
	_owned_rids.push_back(rid)
	return rid


func _load_shader(shader_file : RDShaderFile) -> RID:
	var spirv := shader_file.get_spirv()
	assert(spirv.compile_error_compute.is_empty(), "Atmosphere compute shader failed to compile: %s" % spirv.compile_error_compute)
	return _own(_device.shader_create_from_spirv(spirv))


func _create_texture(type : RenderingDevice.TextureType, size : Vector3i, usage : int) -> RID:
	var texture_format := RDTextureFormat.new()
	texture_format.texture_type = type
	texture_format.format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
	texture_format.width = size.x
	texture_format.height = size.y
	texture_format.depth = size.z
	texture_format.usage_bits = usage
	return _device.texture_create(texture_format, RDTextureView.new())


static func _make_sampler_state() -> RDSamplerState:
	var state := RDSamplerState.new()
	state.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	state.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	state.mip_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	state.repeat_w = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	return state


static func _image_uniform(binding : int, texture : RID) -> RDUniform:
	var uniform := RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	uniform.binding = binding
	uniform.add_id(texture)
	return uniform


func _sampled_uniform(binding : int, texture : RID) -> RDUniform:
	var uniform := RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	uniform.binding = binding
	uniform.add_id(_linear_clamp)
	uniform.add_id(texture)
	return uniform


## Push-constant bytes at the exact size the shader declares (4 bytes per value).
static func _pack(values : Array) -> PackedByteArray:
	return PackedFloat32Array(values).to_byte_array()
