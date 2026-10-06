#[compute]
#version 450
/*
 * Multiple-scattering LUT (Hillaire 2020, "A Scalable and Production Ready Sky and
 * Atmosphere Rendering Technique"): for a point at altitude h under a key light with
 * cosine mu_light to the local up, the radiance of all scattering orders above the
 * first, per unit of the light's irradiance and of the scattering coefficient there.
 * Layout: atmosphere_multiple_scattering() (atmosphere_common.glslinc).
 *
 * One workgroup per texel, one invocation per direction over the whole sphere. Each
 * direction integrates the second order (isotropic phase, light dimmed by the
 * transmittance LUT, plus the sea's diffuse reflection where the ray ends on it) and
 * the share of isotropic light the path scatters back toward the point. Treating every
 * higher order like the second gives the geometric series L2 / (1 - f). The haze is
 * the transport haze (atmosphere_haze_transport_share()): with its forward peak taken
 * out, what is left scatters nearly isotropically, as the series assumes.
 */

#include "atmosphere_common.glslinc"

#define MS_SQRT_DIRECTIONS 8
#define MS_DIRECTIONS 64
#define MS_STEPS 20

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler2D transmittance_lut;
layout(rgba16f, set = 0, binding = 1) uniform restrict writeonly image2D ms_image;

layout(push_constant, std430) restrict readonly uniform PushConstants {
	float haze_density;      // extinction at sea level (1/m)
	float haze_scale_height; // m
	float top_altitude;      // m
	float haze_anisotropy;   // the lobe's g
} pc;

shared vec3 shared_second_order[MS_DIRECTIONS];
shared vec3 shared_transfer[MS_DIRECTIONS];

void main() {
	ivec2 size = imageSize(ms_image);
	ivec2 texel = ivec2(gl_WorkGroupID.xy);
	uint index = gl_LocalInvocationIndex;
	float mu_light = 2.0 * atmosphere_uv_to_unit((float(texel.x) + 0.5) / float(size.x), float(size.x)) - 1.0;
	float h = atmosphere_ms_altitude(atmosphere_uv_to_unit((float(texel.y) + 0.5) / float(size.y), float(size.y)), pc.top_altitude, pc.haze_scale_height);
	h = clamp(h, 0.0, pc.top_altitude * 0.999);

	// Directions spread evenly over the sphere: uniform in mu and azimuth.
	float u = (float(index % MS_SQRT_DIRECTIONS) + 0.5) / float(MS_SQRT_DIRECTIONS);
	float v = (float(index / MS_SQRT_DIRECTIONS) + 0.5) / float(MS_SQRT_DIRECTIONS);
	float mu = 1.0 - 2.0 * v;
	float phi = 2.0 * ATMOSPHERE_PI * u;
	float sin_zenith = sqrt(max(1.0 - mu * mu, 0.0));
	vec3 direction = vec3(sin_zenith * cos(phi), mu, sin_zenith * sin(phi));
	vec3 light = vec3(sqrt(max(1.0 - mu_light * mu_light, 0.0)), mu_light, 0.0);
	float cos_light = dot(direction, light);

	float r0 = ATMOSPHERE_EARTH_RADIUS + h;
	float haze_density = pc.haze_density * atmosphere_haze_transport_share(pc.haze_anisotropy);
	float t_sea = atmosphere_distance_to_sea(h, mu);
	float t_end = t_sea >= 0.0 ? t_sea : atmosphere_distance_to_top(h, mu, pc.top_altitude);
	vec3 transmittance = vec3(1.0);
	vec3 second_order = vec3(0.0);
	vec3 transfer = vec3(0.0);
	float previous_t = 0.0;
	float previous_h = h;
	for (int i = 1; i <= MS_STEPS; ++i) {
		float s = float(i) / float(MS_STEPS);
		float t = t_end * s * s;
		float step_h = atmosphere_altitude_along(h, mu, t);
		vec3 rayleigh;
		float haze;
		vec3 extinction;
		atmosphere_segment_media(previous_h, step_h, haze_density, pc.haze_scale_height, rayleigh, haze, extinction);
		vec3 segment_transmittance = exp(-extinction * (t - previous_t));
		// Integral of transmittance * scattering over the segment.
		vec3 scattered = transmittance * (1.0 - segment_transmittance) / max(extinction, vec3(1e-12)) * (rayleigh + haze);
		float t_mid = 0.5 * (previous_t + t);
		float h_mid = min(atmosphere_altitude_along(h, mu, t_mid), pc.top_altitude);
		float mu_light_mid = (r0 * mu_light + t_mid * cos_light) / (ATMOSPHERE_EARTH_RADIUS + h_mid);
		vec3 light_transmittance = atmosphere_light_transmittance(transmittance_lut, h_mid, clamp(mu_light_mid, -1.0, 1.0), pc.top_altitude);
		second_order += scattered * light_transmittance / (4.0 * ATMOSPHERE_PI);
		transfer += scattered;
		transmittance *= segment_transmittance;
		previous_t = t;
		previous_h = step_h;
	}
	if (t_sea >= 0.0) {
		float mu_light_sea = clamp((r0 * mu_light + t_end * cos_light) / ATMOSPHERE_EARTH_RADIUS, -1.0, 1.0);
		vec3 light_transmittance = atmosphere_light_transmittance(transmittance_lut, 0.0, mu_light_sea, pc.top_altitude);
		second_order += transmittance * light_transmittance * max(mu_light_sea, 0.0) * (ATMOSPHERE_SEA_ALBEDO / ATMOSPHERE_PI);
	}
	shared_second_order[index] = second_order;
	shared_transfer[index] = transfer;
	barrier();
	for (uint stride = MS_DIRECTIONS / 2; stride > 0; stride /= 2) {
		if (index < stride) {
			shared_second_order[index] += shared_second_order[index + stride];
			shared_transfer[index] += shared_transfer[index + stride];
		}
		barrier();
	}
	if (index == 0) {
		// Means over the sphere: each direction stands for 4 pi / N sr, and the phase is 1 / (4 pi).
		vec3 mean_second_order = shared_second_order[0] / float(MS_DIRECTIONS);
		vec3 mean_transfer = shared_transfer[0] / float(MS_DIRECTIONS);
		imageStore(ms_image, texel, vec4(mean_second_order / max(1.0 - mean_transfer, vec3(1e-3)), 1.0));
	}
}
