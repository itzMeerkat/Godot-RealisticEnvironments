#[compute]
#version 450
/**
 * Copies the planar reflection camera's colour (linear HDR, before tonemapping) into
 * mip 0 of the capture texture and each pixel's distance from the camera into the
 * distance texture (GREPlanarReflectionCaptureEffect). Pixels whose depth puts them below
 * the water plane are cleared when clip_below_water is set, so submerged geometry is
 * not reflected.
 */

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
