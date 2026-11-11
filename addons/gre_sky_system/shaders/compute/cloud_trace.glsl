#[versions]

single = "";
msaa = "#define USE_MSAA";

#[compute]
#version 450
/*
 * Traces the clouds for the camera (cloud_common.glslinc): one cloud pixel of every 2x2
 * block of the cloud buffer per frame (cloud_screen_common.glslinc), from the camera
 * wherever it is, up to the scene's surface. Writes per block: rgb in-scattered
 * radiance (premultiplied) and a opacity, as seen at the cloud; and (x) the cloud's
 * distance (opacity-weighted), or without cloud where the ray enters the layer (at
 * least MIN_REPROJECTION_DISTANCE; SKY_DISTANCE if it never does), for reprojection,
 * (y) the scene's distance the ray stopped at.
 */

VERSION_DEFINES

#define CLOUD_TRANSMITTANCE_BINDING 10
#include "atmosphere_common.glslinc"
#include "cloud_common.glslinc"
#define FRAME_BINDING 6
#define DEPTH_BINDING 7
#include "cloud_screen_common.glslinc"

// Nearest distance a cloud-free ray is reprojected at: the camera inside the layer.
#define MIN_REPROJECTION_DISTANCE 50.0

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rgba16f, set = 0, binding = 8) uniform restrict writeonly image2D trace_color;
layout(rg32f, set = 0, binding = 9) uniform restrict writeonly image2D trace_distance;

void main() {
	ivec2 block = ivec2(gl_GlobalInvocationID.xy);
	if (any(greaterThanEqual(block, imageSize(trace_color)))) {
		return;
	}
	ivec2 cloud_pixel = min(block * 2 + frame.pattern.xy, ivec2(frame.sizes.zw) - 1);
	ivec2 pixel = cloud_to_screen(cloud_pixel);
	vec3 direction = screen_direction(pixel);
	float limit = scene_distance(pixel);
	// A camera under the sea surface traces from it.
	float altitude = max(frame.camera.y, 0.0);
	float jitter = cloud_hash12(vec2(cloud_pixel) + frame.settings.z);
	float cloud_distance;
	vec4 cloud = cloud_march(frame.camera.xz, altitude, direction, limit, jitter, cloud_distance);
	if (cloud_distance < 0.0) {
		vec4 segments = cloud_ray_segments(altitude, direction.y, limit);
		bool in_layer = segments.y > segments.x || segments.w > segments.z;
		float entry = segments.y > segments.x ? segments.x : segments.z;
		cloud_distance = in_layer ? max(entry, MIN_REPROJECTION_DISTANCE) : SKY_DISTANCE;
	}
	imageStore(trace_color, block, cloud);
	imageStore(trace_distance, block, vec4(cloud_distance, limit, 0.0, 0.0));
}
