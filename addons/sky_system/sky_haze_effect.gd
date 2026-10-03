@tool
class_name SkyHazeEffect
extends CompositorEffect
## Haze over the scene's geometry: blends every opaque pixel toward the haze's
## in-scattered light by the optical depth between the camera and the pixel, with
## the same model as the sky shader (shaders/haze.gdshaderinc, copied into
## HAZE_SHADER), which hazes the background. SkySystem sets the parameters; the
## effect sits in the WorldEnvironment's compositor (sky_system.tscn).
##
## Runs after the transparent pass: with MSAA the transparent pass renders into
## the multisampled buffer and its resolve would overwrite an earlier result.
## Transparent surfaces are hazed by the opaque depth behind them.

const WORKGROUP_SIZE := 8

const HAZE_SHADER := """
#version 450

#define PI 3.14159265359
#define HAZE_EARTH_RADIUS 6371000.0
#define HAZE_STEPS 12
#define HAZE_FORWARD_SHARE 0.75

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rgba16f, set = 0, binding = 0) uniform restrict image2D color_image;
layout(set = 0, binding = 1) uniform sampler2D depth_texture;

layout(push_constant, std430) uniform Params {
	mat4 inv_view_projection; // to camera-relative world positions
	vec3 light_direction;
	float haze_density;
	vec3 light_color;
	float haze_scale_height;
	vec3 ambient_color;
	float haze_anisotropy;
	float camera_height; // above sea level
	float pad_0;
	float pad_1;
	float pad_2;
} params;

// As haze.gdshaderinc.
float haze_mean_density(float height_a, float height_b) {
	float a = max(height_a, 0.0) / params.haze_scale_height;
	float x = max(height_b, 0.0) / params.haze_scale_height - a;
	float density_a = exp(-a);
	return abs(x) < 1e-4 ? density_a * (1.0 - 0.5 * x) : density_a * (1.0 - exp(-x)) / x;
}

float haze_optical_depth(float start_height, vec3 direction, float ray_length) {
	float curvature = (1.0 - direction.y * direction.y) * (0.5 / HAZE_EARTH_RADIUS);
	float step_length = ray_length / float(HAZE_STEPS);
	float previous_height = start_height;
	float sum = 0.0;
	for (int i = 1; i <= HAZE_STEPS; ++i) {
		float t = step_length * float(i);
		float height = start_height + t * (direction.y + t * curvature);
		sum += haze_mean_density(previous_height, height);
		previous_height = height;
	}
	return params.haze_density * step_length * sum;
}

float haze_phase(float cos_theta) {
	float g = params.haze_anisotropy;
	float denominator = 1.0 + g * g - 2.0 * g * cos_theta;
	float lobe = (1.0 - g * g) / (4.0 * PI * denominator * sqrt(denominator));
	return mix(1.0 / (4.0 * PI), lobe, HAZE_FORWARD_SHARE);
}

void main() {
	ivec2 size = imageSize(color_image);
	ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
	if (any(greaterThanEqual(pixel, size))) {
		return;
	}
	float depth = texelFetch(depth_texture, pixel, 0).r;
	// Reverse Z: the background (sky) is at 0 and hazes itself.
	if (depth <= 0.0) {
		return;
	}
	vec2 uv = (vec2(pixel) + vec2(0.5)) / vec2(size);
	vec4 clip_position = params.inv_view_projection * vec4(uv * 2.0 - 1.0, depth, 1.0);
	vec3 offset = clip_position.xyz / clip_position.w;
	float ray_length = length(offset);
	vec3 direction = offset / ray_length;
	float transmittance = exp(-haze_optical_depth(params.camera_height, direction, ray_length));
	vec3 inscattered = params.light_color * haze_phase(dot(direction, params.light_direction)) + params.ambient_color;
	vec4 color = imageLoad(color_image, pixel);
	color.rgb = color.rgb * transmittance + inscattered * (1.0 - transmittance);
	imageStore(color_image, pixel, color);
}
"""

## Extinction at sea level (1/m); 0 turns the effect off.
var haze_density := 0.0 :
	set(value):
		_params_mutex.lock()
		haze_density = value
		_params_mutex.unlock()
var haze_scale_height := 1000.0 :
	set(value):
		_params_mutex.lock()
		haze_scale_height = value
		_params_mutex.unlock()
var haze_anisotropy := 0.97 :
	set(value):
		_params_mutex.lock()
		haze_anisotropy = value
		_params_mutex.unlock()
var sea_level := 0.0 :
	set(value):
		_params_mutex.lock()
		sea_level = value
		_params_mutex.unlock()
## Toward the sun or moon.
var light_direction := Vector3.UP :
	set(value):
		_params_mutex.lock()
		light_direction = value
		_params_mutex.unlock()
## Radiance per unit phase function (see haze.gdshaderinc).
var light_color := Color.BLACK :
	set(value):
		_params_mutex.lock()
		light_color = value
		_params_mutex.unlock()
var ambient_color := Color.BLACK :
	set(value):
		_params_mutex.lock()
		ambient_color = value
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
	# Without a RenderingDevice (Compatibility renderer) the compositor does not run.
	if _rd == null:
		return
	var shader_source := RDShaderSource.new()
	shader_source.language = RenderingDevice.SHADER_LANGUAGE_GLSL
	shader_source.source_compute = HAZE_SHADER
	var spirv := _rd.shader_compile_spirv_from_source(shader_source)
	assert(spirv.compile_error_compute.is_empty(), "Sky haze shader failed to compile: %s" % spirv.compile_error_compute)
	_shader = _rd.shader_create_from_spirv(spirv)
	assert(_shader.is_valid(), "Sky haze shader could not be created.")
	_pipeline = _rd.compute_pipeline_create(_shader)
	var sampler_state := RDSamplerState.new()
	sampler_state.min_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	sampler_state.mag_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	_sampler = _rd.sampler_create(sampler_state)


func _notification(what: int) -> void:
	if what != NOTIFICATION_PREDELETE or _rd == null:
		return
	# Freeing a shader frees its pipeline.
	_rd.free_rid(_shader)
	_rd.free_rid(_sampler)


func _render_callback(_callback_type: int, render_data: RenderData) -> void:
	_params_mutex.lock()
	var density := haze_density
	var params := [light_direction.x, light_direction.y, light_direction.z, haze_density,
		light_color.r, light_color.g, light_color.b, haze_scale_height,
		ambient_color.r, ambient_color.g, ambient_color.b, haze_anisotropy]
	var camera_sea_level := sea_level
	_params_mutex.unlock()
	if density <= 0.0:
		return
	var render_scene_buffers := render_data.get_render_scene_buffers() as RenderSceneBuffersRD
	var render_scene_data := render_data.get_render_scene_data()
	var size := render_scene_buffers.get_internal_size()
	var camera_transform := render_scene_data.get_cam_transform()
	# Camera-relative: positions stay precise far from the world origin.
	var camera_rotation := Transform3D(camera_transform.basis, Vector3.ZERO)

	var compute_list := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(compute_list, _pipeline)
	for view in render_scene_buffers.get_view_count():
		var color_uniform := RDUniform.new()
		color_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
		color_uniform.binding = 0
		color_uniform.add_id(render_scene_buffers.get_color_layer(view))
		var depth_uniform := RDUniform.new()
		depth_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
		depth_uniform.binding = 1
		depth_uniform.add_id(_sampler)
		depth_uniform.add_id(render_scene_buffers.get_depth_layer(view))
		var uniform_set := UniformSetCacheRD.get_cache(_shader, 0, [color_uniform, depth_uniform])

		var view_projection := render_scene_data.get_view_projection(view) * Projection(camera_rotation.affine_inverse())
		var inv_view_projection := view_projection.inverse()
		var push := PackedFloat32Array()
		for column in [inv_view_projection.x, inv_view_projection.y, inv_view_projection.z, inv_view_projection.w]:
			push.append_array([column.x, column.y, column.z, column.w])
		push.append_array(params)
		push.append_array([camera_transform.origin.y - camera_sea_level, 0.0, 0.0, 0.0])
		var push_bytes := push.to_byte_array()
		_rd.compute_list_bind_uniform_set(compute_list, uniform_set, 0)
		_rd.compute_list_set_push_constant(compute_list, push_bytes, push_bytes.size())
		_rd.compute_list_dispatch(compute_list, ceili(size.x / float(WORKGROUP_SIZE)), ceili(size.y / float(WORKGROUP_SIZE)), 1)
	_rd.compute_list_end()
