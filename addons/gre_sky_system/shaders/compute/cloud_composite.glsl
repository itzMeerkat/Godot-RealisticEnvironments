#[versions]

single = "";
msaa = "#define USE_MSAA";

#[compute]
#version 450
/*
 * Composites the cloud buffer (cloud_reconstruct.glsl) over the screen after the
 * transparent pass, every pixel already hazed for its own distance (the sky shader,
 * the aerial perspective, transparent materials' FOG). Upsampled from half size,
 * weighting each of the four nearest cloud pixels by how well the scene's distance
 * there matches this pixel's, so clouds do not bleed over objects in front of them;
 * where none matches, the cloud of the closest match shows only if it lies in front
 * of the surface.
 *
 * With MSAA the colour is already resolved: a pixel on an edge mixes a near and a far
 * surface. Each gets its own cloud, weighted by the share of the pixel's samples on
 * it (taking the pixel's colour for the background of both).
 *
 * The cloud (rgb premultiplied radiance at the cloud, a opacity) sits inside the
 * atmosphere at its distance d, read from the camera's view volume (as
 * atmosphere_sky_with_clouds() in atmosphere.gdshaderinc): with the transmittance T and
 * in-scatter I up to d, a pixel showing background B (already hazed: I + T B' with B'
 * the atmosphere behind d) becomes
 *   I + T cloud + (1 - a) (B - I) = B (1 - a) + a I + T cloud.
 */

VERSION_DEFINES

#include "atmosphere_common.glslinc"
#define FRAME_BINDING 0
#define DEPTH_BINDING 1
#include "cloud_screen_common.glslinc"

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 2) uniform sampler2D cloud_color;
layout(set = 0, binding = 3) uniform sampler2D cloud_distance;
layout(set = 0, binding = 4) uniform sampler3D view_transmittance;
layout(set = 0, binding = 5) uniform sampler3D view_inscatter;
layout(set = 0, binding = 6) uniform sampler3D view_inscatter_lobe;
layout(rgba16f, set = 0, binding = 7) uniform restrict image2D color_image;

// How fast a cloud pixel's weight falls with the relative mismatch of the scene's distance.
#define DISTANCE_SHARPNESS 100.0
// Relative distance under which two samples of a pixel count as one surface.
#define SAME_SURFACE 0.02

/*
 * The cloud in front of a surface at scene_distance seen through pixel (rgb premultiplied
 * radiance, a opacity), and its distance.
 */
vec4 cloud_in_front(ivec2 pixel, float scene, out float cloud_distance_out) {
	ivec2 cloud_size = ivec2(frame.sizes.zw);
	vec2 position = vec2(pixel) * 0.5;
	ivec2 base = ivec2(floor(position));
	vec2 f = position - vec2(base);
	vec4 cloud = vec4(0.0);
	float mean_distance = 0.0;
	float total = 0.0;
	vec4 best = vec4(0.0);
	float best_distance = 0.0;
	float best_mismatch = 1.0e30;
	for (int i = 0; i < 4; i++) {
		ivec2 offset = ivec2(i & 1, i >> 1);
		ivec2 tap = min(base + offset, cloud_size - 1);
		vec4 tap_cloud = texelFetch(cloud_color, tap, 0);
		vec2 tap_distance = texelFetch(cloud_distance, tap, 0).xy;
		float mismatch = abs(tap_distance.y - scene) / max(min(tap_distance.y, scene), 1.0);
		float bilinear = (offset.x == 1 ? f.x : 1.0 - f.x) * (offset.y == 1 ? f.y : 1.0 - f.y);
		float weight = bilinear / (1.0 + DISTANCE_SHARPNESS * mismatch);
		cloud += tap_cloud * weight;
		mean_distance += tap_distance.x * weight;
		total += weight;
		if (mismatch < best_mismatch) {
			best_mismatch = mismatch;
			best = tap_cloud;
			best_distance = tap_distance.x;
		}
	}
	if (total >= 0.05) {
		cloud_distance_out = mean_distance / total;
		return cloud / total;
	}
	// Every nearby cloud pixel saw another surface (an edge, a thin object): the closest
	// match's cloud, if it lies in front of this surface.
	cloud_distance_out = best_distance;
	return scene > best_distance ? best : vec4(0.0);
}

void main() {
	ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
	if (any(greaterThanEqual(pixel, ivec2(frame.sizes.xy)))) {
		return;
	}
	// The pixel's nearest and farthest surfaces, and the share of samples on the near one.
	int sample_count = screen_sample_count();
	float near = SKY_DISTANCE;
	float far = 0.0;
	float distances[8];
	for (int i = 0; i < min(sample_count, 8); i++) {
		distances[i] = depth_distance(pixel, screen_sample_depth(pixel, i));
		near = min(near, distances[i]);
		far = max(far, distances[i]);
	}
	bool split = (far - near) > SAME_SURFACE * near;
	float near_share = 1.0;
	if (split) {
		int near_samples = 0;
		for (int i = 0; i < min(sample_count, 8); i++) {
			near_samples += distances[i] - near < far - distances[i] ? 1 : 0;
		}
		near_share = float(near_samples) / float(min(sample_count, 8));
	}

	vec3 direction = screen_direction(pixel);
	vec3 light_direction = frame.atmosphere_light.xyz;
	vec3 volume_size = vec3(textureSize(view_transmittance, 0));
	float covered = 0.0;
	vec3 added = vec3(0.0);
	for (int surface = 0; surface < (split ? 2 : 1); surface++) {
		float scene = surface == 0 ? near : far;
		float share = surface == 0 ? near_share : 1.0 - near_share;
		float cloud_distance_here;
		vec4 cloud = cloud_in_front(pixel, scene, cloud_distance_here);
		if (cloud.a <= 1.0e-4) {
			continue;
		}
		// The atmosphere from the camera to the cloud, in the view volume's frame.
		vec3 offset = frame.atmosphere_offset.xyz + direction * min(cloud_distance_here, scene);
		float length_to_cloud = length(offset);
		vec3 volume_direction = offset / max(length_to_cloud, 1.0e-6);
		vec3 uvw = atmosphere_view_uvw(volume_direction, length_to_cloud, light_direction, frame.atmosphere_offset.w, frame.settings.x, volume_size);
		float phase = atmosphere_henyey_greenstein(dot(volume_direction, light_direction), frame.atmosphere_light.w);
		vec3 transmittance = textureLod(view_transmittance, uvw, 0.0).rgb;
		vec3 inscatter = textureLod(view_inscatter, uvw, 0.0).rgb + textureLod(view_inscatter_lobe, uvw, 0.0).rgb * phase;
		covered += share * cloud.a;
		added += share * (inscatter * cloud.a + transmittance * cloud.rgb);
	}
	if (covered <= 0.0) {
		return;
	}
	vec4 color = imageLoad(color_image, pixel);
	color.rgb = color.rgb * (1.0 - covered) + added;
	imageStore(color_image, pixel, color);
}
