#[versions]

single = "";
msaa = "#define USE_MSAA";

#[compute]
#version 450
/*
 * Rebuilds the whole cloud buffer (cloud_screen_common.glslinc) from this frame's
 * traces (cloud_trace.glsl, one pixel of every 2x2 block) and the previous frame's
 * buffer. Each pixel takes the trace nearby whose ray stopped at the same surface
 * (its own block's if it can), and reprojects the cloud into the previous frame at
 * that trace's cloud distance (a point at that distance, or a direction for the sky),
 * so the clouds stay put while the camera turns or flies.
 *   traced pixel: its trace, blended with the history (frame.settings.y) to average
 *     the jittered steps of several frames;
 *   other pixels: the history, or the matched trace where there is none (off screen
 *     last frame, a reset, or another surface there last frame: a moving object).
 * The history is clamped to the range of the traces around the block that saw the
 * same surface, which bounds the ghosting of fast motion.
 * Writes the cloud (rgb radiance premultiplied, a opacity) and (x) the cloud's distance,
 * (y) the scene's distance at the pixel, which the composite matches pixels by.
 */

VERSION_DEFINES

#define FRAME_BINDING 0
#define DEPTH_BINDING 1
#include "cloud_screen_common.glslinc"

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 2) uniform sampler2D trace_color;
layout(set = 0, binding = 3) uniform sampler2D trace_distance;
layout(set = 0, binding = 4) uniform sampler2D history_color;
layout(set = 0, binding = 5) uniform sampler2D history_distance;
layout(rgba16f, set = 0, binding = 6) uniform restrict writeonly image2D cloud_color;
layout(rg32f, set = 0, binding = 7) uniform restrict writeonly image2D cloud_distance;

// Relative difference of two scene distances that still counts as the same surface.
#define SAME_SURFACE 0.05

float surface_mismatch(float a, float b) {
	return abs(a - b) / max(min(a, b), 1.0);
}

void main() {
	ivec2 cloud_pixel = ivec2(gl_GlobalInvocationID.xy);
	ivec2 cloud_size = ivec2(frame.sizes.zw);
	if (any(greaterThanEqual(cloud_pixel, cloud_size))) {
		return;
	}
	ivec2 block = cloud_pixel / 2;
	ivec2 trace_size = textureSize(trace_color, 0);
	// A clamped trace (odd buffer sizes) stands for the block's last pixel.
	bool traced = cloud_pixel == min(block * 2 + frame.pattern.xy, cloud_size - 1);
	ivec2 pixel = cloud_to_screen(cloud_pixel);
	float scene = scene_distance(pixel);
	vec3 direction = screen_direction(pixel);

	// The trace that saw this pixel's surface: the block's own, else the best neighbour.
	ivec2 match = block;
	float best_mismatch = surface_mismatch(texelFetch(trace_distance, block, 0).y, scene);
	if (!traced && best_mismatch > SAME_SURFACE) {
		for (int i = 0; i < 9; i++) {
			ivec2 neighbour = clamp(block + ivec2(i % 3 - 1, i / 3 - 1), ivec2(0), trace_size - 1);
			float mismatch = surface_mismatch(texelFetch(trace_distance, neighbour, 0).y, scene);
			if (mismatch < best_mismatch) {
				best_mismatch = mismatch;
				match = neighbour;
			}
		}
	}
	vec4 fresh = texelFetch(trace_color, match, 0);
	float fresh_distance = texelFetch(trace_distance, match, 0).x;
	// No trace saw this surface: the cloud in front of it is unknown, unless it lies
	// nearer than the clouds (an object below them).
	if (best_mismatch > SAME_SURFACE && scene < fresh_distance) {
		fresh = vec4(0.0);
	}

	vec4 result = fresh;
	float result_distance = fresh_distance;
	if (frame.camera_motion.w > 0.5) {
		vec4 previous_clip = fresh_distance < SKY_DISTANCE
				? frame.previous_view_projection * vec4(direction * fresh_distance + frame.camera_motion.xyz, 1.0)
				: frame.previous_view_projection * vec4(direction, 0.0);
		vec2 previous_uv = previous_clip.xy / previous_clip.w * 0.5 + 0.5;
		if (previous_clip.w > 0.0 && all(greaterThanEqual(previous_uv, vec2(0.0))) && all(lessThanEqual(previous_uv, vec2(1.0)))) {
			// Screen uv to the cloud buffer's texture uv (cloud pixel p sits at screen 2p + 0.5).
			vec2 history_uv = ((previous_uv * frame.sizes.xy - 0.5) * 0.5 + 0.5) / frame.sizes.zw;
			vec2 previous_distances = textureLod(history_distance, history_uv, 0.0).xy;
			// The same surface there last frame (else a moving object uncovered or covered it).
			if (surface_mismatch(previous_distances.y, scene) <= SAME_SURFACE) {
				vec4 history = textureLod(history_color, history_uv, 0.0);
				vec4 low = vec4(1.0e30);
				vec4 high = vec4(-1.0e30);
				for (int i = 0; i < 9; i++) {
					ivec2 neighbour = clamp(block + ivec2(i % 3 - 1, i / 3 - 1), ivec2(0), trace_size - 1);
					if (surface_mismatch(texelFetch(trace_distance, neighbour, 0).y, scene) <= SAME_SURFACE) {
						vec4 neighbour_cloud = texelFetch(trace_color, neighbour, 0);
						low = min(low, neighbour_cloud);
						high = max(high, neighbour_cloud);
					}
				}
				if (low.a <= high.a) {
					history = clamp(history, low, high);
				}
				if (traced) {
					result = mix(fresh, history, frame.settings.y);
				} else {
					result = history;
					result_distance = previous_distances.x;
				}
			}
		}
	}
	imageStore(cloud_color, cloud_pixel, result);
	imageStore(cloud_distance, cloud_pixel, vec4(result_distance, scene, 0.0, 0.0));
}
