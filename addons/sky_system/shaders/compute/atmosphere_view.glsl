#[compute]
#version 450
/*
 * View volume: what the atmosphere does to light along every ray from an observer. One
 * invocation marches one ray (an azimuth from the light and a view angle, see
 * atmosphere_view_y()) out to its end at the sea or in space, and stores at each slice
 * distance (atmosphere_slice_distance()):
 *   transmittance_image  rgb: transmittance from the observer to that distance
 *   inscatter_image      rgb: light scattered toward the observer, isotropic part
 *   inscatter_lobe_image rgb: the same for the haze's forward lobe, per unit of its
 *                        phase function (1/sr); consumers multiply by
 *                        atmosphere_henyey_greenstein(dot(view, light), g)
 * so a consumer composites background * transmittance + inscatter + lobe * phase. The
 * phase is left out because the haze's lobe is far narrower than a texel.
 *
 * Light: the key light (sun or moon) at light_color above the atmosphere, dimmed by the
 * clouds toward it and by every medium down to each sample (transmittance LUT, with
 * the planet's shadow: haze high up under a low sun is lit red), plus the isotropic
 * ambient_color (sky light and multiple scattering) wherever there is haze.
 *
 * The rays themselves cross only the haze (see atmosphere_common.glslinc), so they end
 * at the sea or at haze_top_altitude, above which there is no haze to speak of.
 */

#include "atmosphere_common.glslinc"

// Integration steps between two slices, and from the last regular slice to the ray's end.
#define SLICE_STEPS 2
#define TAIL_STEPS 32
// Angle (rad) over which the clouds toward the light are averaged to shade the atmosphere.
#define CLOUD_SHADE_ANGLE 0.04

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler2D transmittance_lut;
// The cloud cubemap (a = opacity), or a transparent placeholder.
layout(set = 0, binding = 1) uniform samplerCube cloud_cubemap;
layout(rgba16f, set = 0, binding = 2) uniform restrict writeonly image3D transmittance_image;
layout(rgba16f, set = 0, binding = 3) uniform restrict writeonly image3D inscatter_image;
layout(rgba16f, set = 0, binding = 4) uniform restrict writeonly image3D inscatter_lobe_image;

layout(push_constant, std430) restrict readonly uniform PushConstants {
	float observer_altitude; // m above sea level, within [0, top_altitude)
	float haze_density;      // extinction at sea level (1/m)
	float haze_scale_height; // m
	float top_altitude;      // m
	vec3 light_direction;    // world, toward the light
	float max_distance;      // m, distance of the last regular slice
	vec3 light_color;        // radiance per unit phase function above the atmosphere: pi * color * energy
	float cloud_shadow_strength; // multiplies the cloud opacity toward the light
	vec3 ambient_color;      // isotropic in-scattered radiance
	float haze_top_altitude; // m, where view rays end; <= top_altitude
} pc;

vec3 transmittance;
vec3 inscatter;
vec3 inscatter_lobe;

/* Share of the key light that comes through the clouds over the observer. */
float cloud_light_transmittance() {
	vec3 direction = normalize(vec3(pc.light_direction.x, max(pc.light_direction.y, CLOUD_SHADE_ANGLE), pc.light_direction.z));
	// A texel at the centre of a cube face spans 2 / size radians.
	float lod = log2(max(CLOUD_SHADE_ANGLE * float(textureSize(cloud_cubemap, 0).x) * 0.5, 1.0));
	return 1.0 - clamp(textureLod(cloud_cubemap, direction, lod).a * pc.cloud_shadow_strength, 0.0, 1.0);
}

/* Transmittance from space to altitude h along mu; 0 where the planet is in the way. */
vec3 light_transmittance(float h, float mu) {
	if (mu < atmosphere_horizon_mu(h)) {
		return vec3(0.0);
	}
	vec2 size = vec2(textureSize(transmittance_lut, 0));
	return textureLod(transmittance_lut, atmosphere_transmittance_uv(h, mu, pc.top_altitude, size), 0.0).rgb;
}

/*
 * Integrates the ray from t_start to t_end in `steps` segments, spaced linearly or (when
 * quadratic) densest at the start. Each segment's own extinction is exact for the
 * exponential profile; its light is taken at its middle.
 */
void march(float mu, float cos_light, vec3 key_light, float t_start, float t_end, int steps, bool quadratic) {
	float h0 = pc.observer_altitude;
	float r0 = ATMOSPHERE_EARTH_RADIUS + h0;
	float previous_t = t_start;
	float previous_h = atmosphere_altitude_along(h0, mu, t_start);
	for (int i = 1; i <= steps; ++i) {
		float s = float(i) / float(steps);
		float t = t_start + (t_end - t_start) * (quadratic ? s * s : s);
		float h = atmosphere_altitude_along(h0, mu, t);
		float dt = t - previous_t;
		vec3 segment_transmittance = exp(-atmosphere_haze_mean_extinction(previous_h, h, pc.haze_density, pc.haze_scale_height) * dt);
		float t_mid = 0.5 * (previous_t + t);
		float h_mid = min(atmosphere_altitude_along(h0, mu, t_mid), pc.top_altitude);
		// The light's cosine to the local up there: the planet curves under the ray.
		float mu_light = (r0 * pc.light_direction.y + t_mid * cos_light) / (ATMOSPHERE_EARTH_RADIUS + h_mid);
		vec3 sun = key_light * light_transmittance(h_mid, clamp(mu_light, -1.0, 1.0));
		// Haze scatters all it removes (albedo 1): the share of this segment's light that
		// reaches the observer.
		vec3 weight = transmittance * (1.0 - segment_transmittance);
		inscatter_lobe += weight * sun * ATMOSPHERE_HAZE_FORWARD_SHARE;
		inscatter += weight * (sun * ((1.0 - ATMOSPHERE_HAZE_FORWARD_SHARE) / (4.0 * ATMOSPHERE_PI)) + pc.ambient_color);
		transmittance *= segment_transmittance;
		previous_t = t;
		previous_h = h;
	}
}

void store(ivec3 texel) {
	imageStore(transmittance_image, texel, vec4(transmittance, 1.0));
	imageStore(inscatter_image, texel, vec4(inscatter, 1.0));
	imageStore(inscatter_lobe_image, texel, vec4(inscatter_lobe, 1.0));
}

void main() {
	ivec3 size = imageSize(transmittance_image);
	ivec2 texel = ivec2(gl_GlobalInvocationID.xy);
	if (any(greaterThanEqual(texel, size.xy))) {
		return;
	}
	float h0 = pc.observer_altitude;
	float mu = atmosphere_view_mu(h0, (float(texel.y) + 0.5) / float(size.y));
	float phi = atmosphere_uv_to_unit((float(texel.x) + 0.5) / float(size.x), float(size.x)) * ATMOSPHERE_PI;
	// In the frame where the light lies in the +x half of the xy plane.
	float sin_zenith = sqrt(max(1.0 - mu * mu, 0.0));
	vec3 direction = vec3(sin_zenith * cos(phi), mu, sin_zenith * sin(phi));
	vec3 light = vec3(sqrt(max(1.0 - pc.light_direction.y * pc.light_direction.y, 0.0)), pc.light_direction.y, 0.0);
	float cos_light = dot(direction, light);
	vec3 key_light = pc.light_color * cloud_light_transmittance();

	float t_sea = atmosphere_distance_to_sea(h0, mu);
	// An observer above haze_top_altitude: a ray that dips toward the sea and misses it
	// ends back at the observer's altitude, past all the haze it crosses.
	float t_end = t_sea >= 0.0 ? t_sea : atmosphere_distance_to_top(h0, mu, max(pc.haze_top_altitude, h0));
	transmittance = vec3(1.0);
	inscatter = vec3(0.0);
	inscatter_lobe = vec3(0.0);
	float t = 0.0;
	if (size.z > 1) {
		store(ivec3(texel, 0));
		for (int k = 1; k < size.z - 1; ++k) {
			float target = min(atmosphere_slice_distance(k, size.z, pc.max_distance), t_end);
			if (target > t) {
				march(mu, cos_light, key_light, t, target, SLICE_STEPS, false);
				t = target;
			}
			store(ivec3(texel, k));
		}
	}
	if (t_end > t) {
		march(mu, cos_light, key_light, t, t_end, TAIL_STEPS, true);
	}
	store(ivec3(texel, size.z - 1));
}
