#[compute]
#version 450
/*
 * Sky light at an observer, integrated over the observer's view volume (its last slice:
 * the rays' ends). One workgroup. Writes:
 *   above, below: the mean radiance of the upper and of the lower hemisphere; the clouds
 *       read them as their ambient light (cloud_raymarch.glsl, binding 5), from the
 *       volume at the cloud layer;
 *   irradiance: the sky's light on a level surface facing up (cosine-weighted upper
 *       hemisphere), the sky's share of the scene's light meter (SkySystem
 *       get_scene_illuminance(), from the camera's volume).
 *
 * The haze's lobe is narrower than a texel: its whole in-scatter (lobe per unit phase
 * toward the light, times the phase's integral, 1) goes to the hemisphere holding the
 * light.
 *
 * With use_clouds, the clouds cover the sky: each direction shows its ray's end through
 * the clouds' gaps plus the clouds' own light (the air in front of them is not split
 * off: close enough for a meter). The volume at the cloud layer must not use them.
 */

#include "atmosphere_common.glslinc"

#define THREADS 256
// Cloud cubemap level read per texel: about the volume's azimuth texel (pi / 32 rad)
// for 1024 faces.
#define CLOUD_LOD 5.0

layout(local_size_x = THREADS, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler3D inscatter_volume;
layout(set = 0, binding = 1) uniform sampler3D inscatter_lobe_volume;
layout(set = 0, binding = 2, std430) restrict writeonly buffer SkyAmbient {
	vec4 above;      // rgb mean radiance of the upper hemisphere
	vec4 below;      // rgb mean radiance of the lower hemisphere
	vec4 irradiance; // rgb irradiance on a level surface facing up
} sky_ambient;
// The cloud cubemap (a = opacity), or a transparent placeholder.
layout(set = 0, binding = 3) uniform samplerCube cloud_cubemap;

layout(push_constant, std430) restrict readonly uniform PushConstants {
	float observer_altitude; // m, the volume's
	float use_clouds;        // 1: composite the clouds over the sky; 0: the clear sky
	float pad_0;
	float pad_1;
	vec3 light_direction;    // world, toward the key light
	float pad_2;
} pc;

shared vec3 shared_above[THREADS];
shared vec3 shared_below[THREADS];
shared vec3 shared_irradiance[THREADS];

// The light's horizontal direction and its perpendicular: the volume's frame in the world.
vec3 frame_x;
vec3 frame_z;

/* Clouds in the volume's direction (phi from the light, mu), averaged with its mirror image. */
vec4 clouds_toward(float phi, float mu) {
	float sin_zenith = sqrt(max(1.0 - mu * mu, 0.0));
	vec3 along = frame_x * (sin_zenith * cos(phi)) + vec3(0.0, mu, 0.0);
	vec3 across = frame_z * (sin_zenith * sin(phi));
	return 0.5 * (textureLod(cloud_cubemap, along + across, CLOUD_LOD) + textureLod(cloud_cubemap, along - across, CLOUD_LOD));
}

void main() {
	uint index = gl_LocalInvocationIndex;
	ivec3 size = textureSize(inscatter_volume, 0);
	int slice = size.z - 1;
	float h = pc.observer_altitude;
	vec2 light_xz = pc.light_direction.xz;
	frame_x = length(light_xz) > 1e-5 ? vec3(normalize(light_xz), 0.0).xzy : vec3(1.0, 0.0, 0.0);
	frame_z = vec3(-frame_x.z, 0.0, frame_x.x);
	// Azimuth texel centres sit at k / (n - 1) of a half-turn; the volume shows one half
	// of the sky (it is symmetric about the light's vertical plane), so each texel
	// stands for twice its own share.
	float azimuth_step = ATMOSPHERE_PI / float(size.x - 1);
	vec3 above = vec3(0.0);
	vec3 below = vec3(0.0);
	vec3 irradiance = vec3(0.0);
	for (int i = int(index); i < size.x * size.y; i += THREADS) {
		int x = i % size.x;
		int y = i / size.x;
		float azimuth_width = (x == 0 || x == size.x - 1) ? 0.5 * azimuth_step : azimuth_step;
		float mu_top = atmosphere_view_mu(h, float(y) / float(size.y));
		float mu_bottom = atmosphere_view_mu(h, float(y + 1) / float(size.y));
		float mu = atmosphere_view_mu(h, (float(y) + 0.5) / float(size.y));
		vec3 radiance = texelFetch(inscatter_volume, ivec3(x, y, slice), 0).rgb;
		if (pc.use_clouds > 0.5 && mu > 0.0) {
			vec4 cloud = clouds_toward(float(x) * azimuth_step, mu);
			radiance = radiance * (1.0 - cloud.a) + cloud.rgb;
		}
		if (mu >= 0.0) {
			above += radiance * (2.0 * azimuth_width * (mu_top - mu_bottom));
			// Integral of the cosine over the texel's band above the horizon.
			float top = max(mu_top, 0.0);
			float bottom = max(mu_bottom, 0.0);
			irradiance += radiance * (azimuth_width * (top * top - bottom * bottom));
		} else {
			below += radiance * (2.0 * azimuth_width * (mu_top - mu_bottom));
		}
	}
	shared_above[index] = above;
	shared_below[index] = below;
	shared_irradiance[index] = irradiance;
	barrier();
	for (uint stride = THREADS / 2; stride > 0; stride /= 2) {
		if (index < stride) {
			shared_above[index] += shared_above[index + stride];
			shared_below[index] += shared_below[index + stride];
			shared_irradiance[index] += shared_irradiance[index + stride];
		}
		barrier();
	}
	if (index == 0) {
		float light_y = pc.light_direction.y;
		vec3 size_f = vec3(size);
		vec3 uvw = vec3(atmosphere_unit_to_uv(0.0, size_f.x),
				clamp(atmosphere_view_y(h, light_y), 0.5 / size_f.y, 1.0 - 0.5 / size_f.y), (float(slice) + 0.5) / size_f.z);
		vec3 lobe = textureLod(inscatter_lobe_volume, uvw, 0.0).rgb;
		if (pc.use_clouds > 0.5 && light_y > 0.0) {
			lobe *= 1.0 - textureLod(cloud_cubemap, pc.light_direction, CLOUD_LOD).a;
		}
		vec3 total_above = shared_above[0] + (light_y >= 0.0 ? lobe : vec3(0.0));
		vec3 total_below = shared_below[0] + (light_y >= 0.0 ? vec3(0.0) : lobe);
		sky_ambient.above = vec4(total_above / (2.0 * ATMOSPHERE_PI), 1.0);
		sky_ambient.below = vec4(total_below / (2.0 * ATMOSPHERE_PI), 1.0);
		sky_ambient.irradiance = vec4(shared_irradiance[0] + lobe * max(light_y, 0.0), 1.0);
	}
}
