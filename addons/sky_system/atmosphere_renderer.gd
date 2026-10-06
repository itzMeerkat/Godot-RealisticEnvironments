class_name AtmosphereRenderer
extends RefCounted
## Builds the atmosphere's lookup textures with compute shaders on the main
## RenderingDevice, once per frame. Owned by SkySystem; see the sky_system README.
##
## The atmosphere model lives only in these passes (shaders/compute/atmosphere_*.glsl):
## every consumer (sky, starfield, aerial perspective, water, transparent materials)
## samples the textures instead of integrating the haze itself.
##
## Per frame: the transmittance LUT, then two view volumes from it: one for the
## camera (view_*, every distance up to max_distance and the ray's end) and one for
## an observer on the sea (sea_*, the ray's end only: the sky the water reflects).

const TRANSMITTANCE_SHADER := preload("res://addons/sky_system/shaders/compute/atmosphere_transmittance.glsl")
const VIEW_SHADER := preload("res://addons/sky_system/shaders/compute/atmosphere_view.glsl")

## Rows run up to the 100 km top, densest near the sea: 256 of them keep a 150 m
## sea fog layer several rows deep.
const TRANSMITTANCE_SIZE := Vector2i(256, 256)
## View volumes: azimuth from the light x view angle x distance slices.
const VIEW_SIZE := Vector3i(32, 128, 64)
## Distance (m) of the camera volume's last regular slice; farther points read it.
## Beyond the cameras' far planes (the demo uses 60 km).
const MAX_DISTANCE := 100000.0
## Where the air ends (m): its density is e^-12 of the sea level's there, and the
## ozone layer lies below.
const AIR_TOP_ALTITUDE := 100000.0
## The haze ends this many haze scale heights above the sea (view rays end there).
const HAZE_TOP_SCALE_HEIGHTS := 12.0

## Camera view volume (sampled by the sky, starfield, aerial perspective and transparent
## materials): rgb transmittance, rgb isotropic in-scatter, rgb lobe in-scatter per unit phase.
var view_transmittance := Texture3DRD.new()
var view_inscatter := Texture3DRD.new()
var view_inscatter_lobe := Texture3DRD.new()
## The same for an observer on the sea, ray ends only (one slice): the reflected sky.
var sea_transmittance := Texture3DRD.new()
var sea_inscatter := Texture3DRD.new()
var sea_inscatter_lobe := Texture3DRD.new()

## Haze (CloudPreset haze_*): extinction at sea level (1/m) and scale height (m).
var haze_density := 0.0
var haze_scale_height := 1000.0
## Toward the key light (sun or moon).
var light_direction := Vector3.UP
## The key light above the atmosphere: pi * color * energy.
var light_color := Color.BLACK
## Isotropic in-scattered radiance (sky light and multiple scattering).
var ambient_color := Color.BLACK
## Multiplies the cloud opacity toward the light where it shades the atmosphere.
var cloud_shadow_strength := 1.0

var _device : RenderingDevice
## Freed in reverse order by release().
var _owned_rids : Array[RID] = []
var _transmittance_pipeline : RID
var _transmittance_set : RID
var _view_shader : RID
var _view_pipeline : RID
var _transmittance_rid : RID
var _view_rids : Array[RID] = []
var _sea_rids : Array[RID] = []
var _linear_clamp : RID
var _no_cloud_cubemap : RID


func _init(device : RenderingDevice) -> void:
	_device = device
	_linear_clamp = _own(_device.sampler_create(_make_sampler_state()))
	var storage_usage := RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
	_transmittance_rid = _own(_create_texture(RenderingDevice.TEXTURE_TYPE_2D, Vector3i(TRANSMITTANCE_SIZE.x, TRANSMITTANCE_SIZE.y, 1), storage_usage))
	for i in 3:
		_view_rids.push_back(_own(_create_texture(RenderingDevice.TEXTURE_TYPE_3D, VIEW_SIZE, storage_usage)))
		_sea_rids.push_back(_own(_create_texture(RenderingDevice.TEXTURE_TYPE_3D, Vector3i(VIEW_SIZE.x, VIEW_SIZE.y, 1), storage_usage)))
	view_transmittance.texture_rd_rid = _view_rids[0]
	view_inscatter.texture_rd_rid = _view_rids[1]
	view_inscatter_lobe.texture_rd_rid = _view_rids[2]
	sea_transmittance.texture_rd_rid = _sea_rids[0]
	sea_inscatter.texture_rd_rid = _sea_rids[1]
	sea_inscatter_lobe.texture_rd_rid = _sea_rids[2]

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
	_view_shader = _load_shader(VIEW_SHADER)
	_view_pipeline = _own(_device.compute_pipeline_create(_view_shader))


## Frees every GPU resource; the owner must call it before dropping the renderer,
## after unbinding the textures from their consumers. Unusable afterwards.
func release() -> void:
	for texture in [view_transmittance, view_inscatter, view_inscatter_lobe, sea_transmittance, sea_inscatter, sea_inscatter_lobe]:
		texture.texture_rd_rid = RID()
	for i in range(_owned_rids.size() - 1, -1, -1):
		_device.free_rid(_owned_rids[i])
	_owned_rids.clear()


## Altitude (m) where the atmosphere ends.
func get_top_altitude() -> float:
	return maxf(AIR_TOP_ALTITUDE, get_haze_top_altitude())


## Altitude (m) where the haze ends.
func get_haze_top_altitude() -> float:
	return HAZE_TOP_SCALE_HEIGHTS * haze_scale_height


## The observer altitude the camera volume is built for: the camera's, kept inside the
## atmosphere (consumers must map directions with this value, not their own).
func get_observer_altitude(camera_altitude : float) -> float:
	return clampf(camera_altitude, 0.0, get_top_altitude() * 0.999)


## Records this frame's passes for a camera at camera_altitude (m above the sea).
## cloud_cubemap: the clouds' RenderingDevice cubemap, or an empty RID.
func render(camera_altitude : float, cloud_cubemap : RID) -> void:
	var top := get_top_altitude()
	var compute_list := _device.compute_list_begin()
	_device.compute_list_bind_compute_pipeline(compute_list, _transmittance_pipeline)
	_device.compute_list_bind_uniform_set(compute_list, _transmittance_set, 0)
	var transmittance_push := _pack([haze_density, haze_scale_height, top, 0.0])
	_device.compute_list_set_push_constant(compute_list, transmittance_push, transmittance_push.size())
	_device.compute_list_dispatch(compute_list, ceili(TRANSMITTANCE_SIZE.x / 8.0), ceili(TRANSMITTANCE_SIZE.y / 8.0), 1)
	_device.compute_list_add_barrier(compute_list)

	var clouds := cloud_cubemap if cloud_cubemap.is_valid() else _no_cloud_cubemap
	for volume in [[get_observer_altitude(camera_altitude), _view_rids], [0.0, _sea_rids]]:
		# Bound after the barrier: a barrier re-applies the last push constant to the bound pipeline.
		_device.compute_list_bind_compute_pipeline(compute_list, _view_pipeline)
		var targets : Array[RID] = volume[1]
		var view_set := UniformSetCacheRD.get_cache(_view_shader, 0, [
			_sampled_uniform(0, _transmittance_rid),
			_sampled_uniform(1, clouds),
			_image_uniform(2, targets[0]),
			_image_uniform(3, targets[1]),
			_image_uniform(4, targets[2]),
		])
		_device.compute_list_bind_uniform_set(compute_list, view_set, 0)
		var view_push := _pack([
			volume[0], haze_density, haze_scale_height, top,
			light_direction.x, light_direction.y, light_direction.z, MAX_DISTANCE,
			light_color.r, light_color.g, light_color.b, cloud_shadow_strength,
			ambient_color.r, ambient_color.g, ambient_color.b, get_haze_top_altitude(),
		])
		_device.compute_list_set_push_constant(compute_list, view_push, view_push.size())
		_device.compute_list_dispatch(compute_list, ceili(VIEW_SIZE.x / 8.0), ceili(VIEW_SIZE.y / 8.0), 1)
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
