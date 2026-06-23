class_name PlanarReflectionClipEffect
extends CompositorEffect

const WORKGROUP_SIZE := 8

const CLIP_SHADER := """
#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rgba16f, set = 0, binding = 0) uniform image2D color_image;
layout(set = 0, binding = 1) uniform sampler2D depth_texture;

layout(push_constant, std430) uniform Params {
	mat4 inv_view_projection;
	vec2 raster_size;
	float water_level;
	float clip_bias;
} params;

void main() {
	ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size = ivec2(params.raster_size);
	if (pixel.x >= size.x || pixel.y >= size.y) {
		return;
	}

	float depth = texelFetch(depth_texture, pixel, 0).r;
	vec2 uv = (vec2(pixel) + vec2(0.5)) / params.raster_size;
	vec4 clip_position = vec4(uv * 2.0 - 1.0, depth, 1.0);
	vec4 world_position = params.inv_view_projection * clip_position;
	if (abs(world_position.w) < 0.00001) {
		return;
	}
	world_position.xyz /= world_position.w;

	if (world_position.y < params.water_level - params.clip_bias) {
		imageStore(color_image, pixel, vec4(0.0));
	}
}
"""

var water_level := 0.0 :
	set(value):
		_params_mutex.lock()
		water_level = value
		_params_mutex.unlock()
var clip_bias := 0.03 :
	set(value):
		_params_mutex.lock()
		clip_bias = value
		_params_mutex.unlock()

var _rd : RenderingDevice
var _shader := RID()
var _pipeline := RID()
var _sampler := RID()
var _params_mutex := Mutex.new()


func _init() -> void:
	effect_callback_type = EFFECT_CALLBACK_TYPE_POST_TRANSPARENT
	access_resolved_depth = true
	access_resolved_color = true
	_rd = RenderingServer.get_rendering_device()
	_compile_shader()
	_create_sampler()


func _notification(what: int) -> void:
	if what != NOTIFICATION_PREDELETE or _rd == null:
		return
	if _shader.is_valid():
		_rd.free_rid(_shader)
		_shader = RID()
		_pipeline = RID()
	if _sampler.is_valid():
		_rd.free_rid(_sampler)
		_sampler = RID()


func _render_callback(callback_type: int, render_data: RenderData) -> void:
	if callback_type != EFFECT_CALLBACK_TYPE_POST_TRANSPARENT or _rd == null:
		return
	if not _pipeline.is_valid() or not _sampler.is_valid():
		return

	var render_scene_buffers := render_data.get_render_scene_buffers() as RenderSceneBuffersRD
	if render_scene_buffers == null:
		return
	var size := render_scene_buffers.get_internal_size()
	if size.x <= 0 or size.y <= 0:
		return

	var render_scene_data := render_data.get_render_scene_data()
	if render_scene_data == null:
		return

	var x_groups := int(ceili(float(size.x) / float(WORKGROUP_SIZE)))
	var y_groups := int(ceili(float(size.y) / float(WORKGROUP_SIZE)))
	var view_count := render_scene_buffers.get_view_count()
	for view in range(view_count):
		var color_image := render_scene_buffers.get_color_layer(view)
		var depth_texture := render_scene_buffers.get_depth_layer(view)
		if not color_image.is_valid() or not depth_texture.is_valid():
			continue

		var uniforms : Array[RDUniform] = []
		var color_uniform := RDUniform.new()
		color_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
		color_uniform.binding = 0
		color_uniform.add_id(color_image)
		uniforms.append(color_uniform)

		var depth_uniform := RDUniform.new()
		depth_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
		depth_uniform.binding = 1
		depth_uniform.add_id(_sampler)
		depth_uniform.add_id(depth_texture)
		uniforms.append(depth_uniform)

		var uniform_set := UniformSetCacheRD.get_cache(_shader, 0, uniforms)
		var push_constant := _create_push_constant(render_scene_data, view, size)

		var compute_list := _rd.compute_list_begin()
		_rd.compute_list_bind_compute_pipeline(compute_list, _pipeline)
		_rd.compute_list_bind_uniform_set(compute_list, uniform_set, 0)
		_rd.compute_list_set_push_constant(compute_list, push_constant, push_constant.size())
		_rd.compute_list_dispatch(compute_list, x_groups, y_groups, 1)
		_rd.compute_list_end()


func _compile_shader() -> void:
	if _rd == null:
		return
	var shader_source := RDShaderSource.new()
	shader_source.language = RenderingDevice.SHADER_LANGUAGE_GLSL
	shader_source.source_compute = CLIP_SHADER
	var shader_spirv := _rd.shader_compile_spirv_from_source(shader_source)
	if shader_spirv.compile_error_compute != "":
		push_error(shader_spirv.compile_error_compute)
		return
	_shader = _rd.shader_create_from_spirv(shader_spirv)
	if _shader.is_valid():
		_pipeline = _rd.compute_pipeline_create(_shader)


func _create_sampler() -> void:
	if _rd == null:
		return
	var sampler_state := RDSamplerState.new()
	sampler_state.min_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	sampler_state.mag_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	sampler_state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	sampler_state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	_sampler = _rd.sampler_create(sampler_state)


func _create_push_constant(render_scene_data: RenderSceneData, view: int, size: Vector2i) -> PackedByteArray:
	var projection := render_scene_data.get_view_projection(view)
	var camera_transform := render_scene_data.get_cam_transform()
	var view_projection := projection * Projection(camera_transform.affine_inverse())
	var inv_view_projection := view_projection.inverse()

	_params_mutex.lock()
	var current_water_level := water_level
	var current_clip_bias := clip_bias
	_params_mutex.unlock()

	var data := PackedFloat32Array()
	_add_projection(data, inv_view_projection)
	data.push_back(float(size.x))
	data.push_back(float(size.y))
	data.push_back(current_water_level)
	data.push_back(current_clip_bias)
	return data.to_byte_array()


func _add_projection(data: PackedFloat32Array, projection: Projection) -> void:
	_add_vector4(data, projection.x)
	_add_vector4(data, projection.y)
	_add_vector4(data, projection.z)
	_add_vector4(data, projection.w)


func _add_vector4(data: PackedFloat32Array, value: Vector4) -> void:
	data.push_back(value.x)
	data.push_back(value.y)
	data.push_back(value.z)
	data.push_back(value.w)
