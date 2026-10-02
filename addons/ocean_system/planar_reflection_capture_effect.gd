class_name PlanarReflectionCaptureEffect
extends CompositorEffect
## Captures the planar reflection camera's color for the water: copies it, linear
## HDR before tonemapping, into [member texture] and builds that texture's mip
## chain, so rough water can read a reflection blurred to its roughness, and
## each pixel's distance from the camera into [member distance_texture], so the
## water can find where its own reflected rays hit. Pixels whose depth puts them
## below the water plane are cleared (when clip_below_water is set), so
## submerged geometry is not reflected.
##
## The owner sizes the texture with set_size() on the main thread, to the
## reflection viewport's size; the passes run in the render callback.

const WORKGROUP_SIZE := 8

const CAPTURE_SHADER := """
#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rgba16f, set = 0, binding = 0) uniform restrict readonly image2D color_image;
layout(set = 0, binding = 1) uniform sampler2D depth_texture;
layout(rgba16f, set = 0, binding = 2) uniform restrict writeonly image2D capture_image; // mip 0
layout(r32f, set = 0, binding = 3) uniform restrict writeonly image2D distance_image;

layout(push_constant, std430) uniform Params {
	mat4 inv_view_projection;
	vec2 raster_size;
	float water_level;
	float clip_bias;
	vec3 camera_position;
	float clip_below_water; // 1 or 0
} params;

void main() {
	ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
	if (any(greaterThanEqual(pixel, ivec2(params.raster_size)))) {
		return;
	}
	// The background is cleared to (0, 0, 0, 0), so color is premultiplied by coverage.
	vec4 color = imageLoad(color_image, pixel);
	float depth = texelFetch(depth_texture, pixel, 0).r;
	vec2 uv = (vec2(pixel) + vec2(0.5)) / params.raster_size;
	vec4 clip_position = params.inv_view_projection * vec4(uv * 2.0 - 1.0, depth, 1.0);
	vec3 world_position = clip_position.xyz / clip_position.w;
	if (params.clip_below_water > 0.0 && world_position.y < params.water_level - params.clip_bias) {
		color = vec4(0.0);
	}
	imageStore(capture_image, pixel, color);
	// 0 where there is no (opaque) geometry: the background or clipped pixels.
	imageStore(distance_image, pixel, vec4(color.a > 0.5 ? distance(world_position, params.camera_position) : 0.0));
}
"""

const DOWNSAMPLE_SHADER := """
#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

// 2D views of one mip each: level - 1 and level.
layout(rgba16f, set = 0, binding = 0) uniform restrict readonly image2D source;
layout(rgba16f, set = 0, binding = 1) uniform restrict writeonly image2D target;

layout(push_constant, std430) uniform Params {
	ivec2 source_size;
	ivec2 target_size;
} params;

void main() {
	ivec2 texel = ivec2(gl_GlobalInvocationID.xy);
	if (any(greaterThanEqual(texel, params.target_size))) {
		return;
	}
	// 2x2 box; clamped, so a level with an odd size drops its last row or column.
	ivec2 last = params.source_size - 1;
	ivec2 source_texel = texel * 2;
	vec4 sum = imageLoad(source, min(source_texel, last));
	sum += imageLoad(source, min(source_texel + ivec2(1, 0), last));
	sum += imageLoad(source, min(source_texel + ivec2(0, 1), last));
	sum += imageLoad(source, min(source_texel + ivec2(1, 1), last));
	imageStore(target, texel, sum * 0.25);
}
"""

## The captured reflection: rgb premultiplied by a (geometry coverage), with a
## full mip chain. Empty until set_size().
var texture := Texture2DRD.new()
## Distance (m) from the camera to the surface each texel of [member texture]
## shows, 0 where it shows no geometry. One mip; read it unfiltered.
var distance_texture := Texture2DRD.new()

var water_level := 0.0 :
	set(value):
		_params_mutex.lock()
		water_level = value
		_params_mutex.unlock()
var clip_below_water := true :
	set(value):
		_params_mutex.lock()
		clip_below_water = value
		_params_mutex.unlock()
var clip_bias := 0.03 :
	set(value):
		_params_mutex.lock()
		clip_bias = value
		_params_mutex.unlock()

var _rd : RenderingDevice
var _capture_shader := RID()
var _capture_pipeline := RID()
var _downsample_shader := RID()
var _downsample_pipeline := RID()
var _sampler := RID()
var _params_mutex := Mutex.new()
## Guarded by _params_mutex: the capture texture, its size and its per-mip views.
var _size := Vector2i.ZERO
var _texture_rid := RID()
var _mip_views : Array[RID] = []
var _distance_rid := RID()


func _init() -> void:
	effect_callback_type = EFFECT_CALLBACK_TYPE_POST_TRANSPARENT
	access_resolved_depth = true
	access_resolved_color = true
	_rd = RenderingServer.get_rendering_device()
	_capture_shader = _compile_shader(CAPTURE_SHADER)
	_capture_pipeline = _rd.compute_pipeline_create(_capture_shader)
	_downsample_shader = _compile_shader(DOWNSAMPLE_SHADER)
	_downsample_pipeline = _rd.compute_pipeline_create(_downsample_shader)
	var sampler_state := RDSamplerState.new()
	sampler_state.min_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	sampler_state.mag_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	sampler_state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	sampler_state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	_sampler = _rd.sampler_create(sampler_state)


func _notification(what: int) -> void:
	if what != NOTIFICATION_PREDELETE:
		return
	# Inline: the script's own methods can't be called during predelete.
	texture.texture_rd_rid = RID()
	distance_texture.texture_rd_rid = RID()
	for view in _mip_views:
		_rd.free_rid(view)
	if _texture_rid.is_valid():
		_rd.free_rid(_texture_rid)
	if _distance_rid.is_valid():
		_rd.free_rid(_distance_rid)
	# Freeing a shader frees its pipeline.
	_rd.free_rid(_capture_shader)
	_rd.free_rid(_downsample_shader)
	_rd.free_rid(_sampler)


## (Re)creates the capture texture for a reflection viewport of this size.
## Call it on the main thread whenever the viewport is resized.
func set_size(size: Vector2i) -> void:
	if size == _size:
		return
	var mip_count := 1 # down to 1x1
	while maxi(size.x, size.y) >> mip_count > 0:
		mip_count += 1
	var format := RDTextureFormat.new()
	format.texture_type = RenderingDevice.TEXTURE_TYPE_2D
	format.format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
	format.width = size.x
	format.height = size.y
	format.mipmaps = mip_count
	format.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT
	var texture_rid := _rd.texture_create(format, RDTextureView.new())
	assert(texture_rid.is_valid(), "PlanarReflectionCaptureEffect failed to create its texture.")
	# Nothing is captured before the first render: read as "no geometry".
	_rd.texture_clear(texture_rid, Color(0.0, 0.0, 0.0, 0.0), 0, mip_count, 0, 1)
	# Storage bindings need single-mip views.
	var mip_views : Array[RID] = []
	for mip in mip_count:
		mip_views.push_back(_rd.texture_create_shared_from_slice(RDTextureView.new(), texture_rid, 0, mip, 1, RenderingDevice.TEXTURE_SLICE_2D))
	format.format = RenderingDevice.DATA_FORMAT_R32_SFLOAT
	format.mipmaps = 1
	var distance_rid := _rd.texture_create(format, RDTextureView.new())
	assert(distance_rid.is_valid(), "PlanarReflectionCaptureEffect failed to create its distance texture.")
	_rd.texture_clear(distance_rid, Color(0.0, 0.0, 0.0, 0.0), 0, 1, 0, 1)
	_free_texture()
	_params_mutex.lock()
	_size = size
	_texture_rid = texture_rid
	_mip_views = mip_views
	_distance_rid = distance_rid
	_params_mutex.unlock()
	texture.texture_rd_rid = texture_rid
	distance_texture.texture_rd_rid = distance_rid


func _free_texture() -> void:
	texture.texture_rd_rid = RID()
	distance_texture.texture_rd_rid = RID()
	_params_mutex.lock()
	for view in _mip_views:
		_rd.free_rid(view)
	if _texture_rid.is_valid():
		_rd.free_rid(_texture_rid)
	if _distance_rid.is_valid():
		_rd.free_rid(_distance_rid)
	_mip_views = []
	_texture_rid = RID()
	_distance_rid = RID()
	_size = Vector2i.ZERO
	_params_mutex.unlock()


func _render_callback(_callback_type: int, render_data: RenderData) -> void:
	var render_scene_buffers := render_data.get_render_scene_buffers() as RenderSceneBuffersRD
	var render_scene_data := render_data.get_render_scene_data()
	var raster_size := render_scene_buffers.get_internal_size()

	_params_mutex.lock()
	var size := _size
	var mip_views := _mip_views.duplicate()
	var distance_rid := _distance_rid
	var push_values := [water_level, clip_bias, 1.0 if clip_below_water else 0.0]
	_params_mutex.unlock()
	if raster_size != size:
		push_error("PlanarReflectionCaptureEffect: render size %s does not match the capture texture %s (set_size() not called after a resize?)." % [raster_size, size])
		return

	# The reflection camera renders one view.
	var color_uniform := RDUniform.new()
	color_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	color_uniform.binding = 0
	color_uniform.add_id(render_scene_buffers.get_color_layer(0))
	var depth_uniform := RDUniform.new()
	depth_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	depth_uniform.binding = 1
	depth_uniform.add_id(_sampler)
	depth_uniform.add_id(render_scene_buffers.get_depth_layer(0))
	var capture_set := UniformSetCacheRD.get_cache(_capture_shader, 0, [color_uniform, depth_uniform, _image_uniform(2, mip_views[0]), _image_uniform(3, distance_rid)])

	var camera_transform := render_scene_data.get_cam_transform()
	var view_projection := render_scene_data.get_view_projection(0) * Projection(camera_transform.affine_inverse())
	var capture_push := PackedFloat32Array()
	var inv_view_projection := view_projection.inverse()
	for column in [inv_view_projection.x, inv_view_projection.y, inv_view_projection.z, inv_view_projection.w]:
		capture_push.append_array([column.x, column.y, column.z, column.w])
	capture_push.append_array([float(size.x), float(size.y), push_values[0], push_values[1]])
	capture_push.append_array([camera_transform.origin.x, camera_transform.origin.y, camera_transform.origin.z, push_values[2]])
	var capture_bytes := capture_push.to_byte_array()

	var compute_list := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(compute_list, _capture_pipeline)
	_rd.compute_list_bind_uniform_set(compute_list, capture_set, 0)
	_rd.compute_list_set_push_constant(compute_list, capture_bytes, capture_bytes.size())
	_rd.compute_list_dispatch(compute_list, ceili(size.x / float(WORKGROUP_SIZE)), ceili(size.y / float(WORKGROUP_SIZE)), 1)
	for mip in range(1, mip_views.size()):
		_rd.compute_list_add_barrier(compute_list)
		# Bound after the barrier: a barrier re-applies the last push constant
		# (the capture's, before the first level) to the bound pipeline.
		_rd.compute_list_bind_compute_pipeline(compute_list, _downsample_pipeline)
		var source_size := Vector2i(maxi(size.x >> (mip - 1), 1), maxi(size.y >> (mip - 1), 1))
		var target_size := Vector2i(maxi(size.x >> mip, 1), maxi(size.y >> mip, 1))
		var downsample_set := UniformSetCacheRD.get_cache(_downsample_shader, 0, [_image_uniform(0, mip_views[mip - 1]), _image_uniform(1, mip_views[mip])])
		_rd.compute_list_bind_uniform_set(compute_list, downsample_set, 0)
		var downsample_push := PackedInt32Array([source_size.x, source_size.y, target_size.x, target_size.y]).to_byte_array()
		_rd.compute_list_set_push_constant(compute_list, downsample_push, downsample_push.size())
		_rd.compute_list_dispatch(compute_list, ceili(target_size.x / float(WORKGROUP_SIZE)), ceili(target_size.y / float(WORKGROUP_SIZE)), 1)
	_rd.compute_list_end()


func _compile_shader(source: String) -> RID:
	var shader_source := RDShaderSource.new()
	shader_source.language = RenderingDevice.SHADER_LANGUAGE_GLSL
	shader_source.source_compute = source
	var spirv := _rd.shader_compile_spirv_from_source(shader_source)
	assert(spirv.compile_error_compute.is_empty(), "Planar reflection capture shader failed to compile: %s" % spirv.compile_error_compute)
	var shader := _rd.shader_create_from_spirv(spirv)
	assert(shader.is_valid(), "Planar reflection capture shader could not be created.")
	return shader


static func _image_uniform(binding: int, texture_rid: RID) -> RDUniform:
	var uniform := RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	uniform.binding = binding
	uniform.add_id(texture_rid)
	return uniform
