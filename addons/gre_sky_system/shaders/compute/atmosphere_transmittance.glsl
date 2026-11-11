#[compute]
#version 450
/*
 * Transmittance LUT: the share of light that crosses the atmosphere from space down to
 * a point at altitude h, arriving along a direction with cosine mu to the local up.
 * Layout: atmosphere_transmittance_uv() (atmosphere_common.glslinc). Rays that hit the
 * sea are not stored; the planet shadows them. GRESkySystem._get_atmosphere_transmittance()
 * integrates the same path on the CPU for the scene's lights.
 */

#include "atmosphere_common.glslinc"

// Steps along each ray, spaced quadratically: dense near the start, where the air is
// densest, sparse toward the top.
#define TRANSMITTANCE_STEPS 40

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rgba16f, set = 0, binding = 0) uniform restrict writeonly image2D transmittance_image;

layout(push_constant, std430) restrict readonly uniform PushConstants {
	float haze_density;      // extinction at sea level (1/m)
	float haze_scale_height; // m
	float top_altitude;      // m
	float haze_anisotropy;   // the lobe's g: the haze is seen for transport (atmosphere_haze_transport_share())
	float haze_wavelength_exponent; // atmosphere_haze_optics()
} pc;

void main() {
	ivec2 size = imageSize(transmittance_image);
	ivec2 texel = ivec2(gl_GlobalInvocationID.xy);
	if (any(greaterThanEqual(texel, size))) {
		return;
	}
	vec2 uv = (vec2(texel) + 0.5) / vec2(size);
	vec2 altitude_mu = atmosphere_transmittance_altitude_mu(uv, pc.top_altitude, vec2(size));
	float h = altitude_mu.x;
	float mu = altitude_mu.y;
	float ray_length = atmosphere_distance_to_top(h, mu, pc.top_altitude);
	// The haze's optical depth light transport sees: its forward peak's scattering is
	// left out, its absorption (atmosphere_haze_optics()) stays.
	float albedo = atmosphere_haze_optics(pc.haze_wavelength_exponent).a;
	float haze_transport = 1.0 - albedo * (1.0 - atmosphere_haze_transport_share(pc.haze_anisotropy));
	vec3 optical_depth = vec3(0.0);
	float previous_t = 0.0;
	float previous_h = h;
	for (int i = 1; i <= TRANSMITTANCE_STEPS; ++i) {
		float s = float(i) / float(TRANSMITTANCE_STEPS);
		float t = ray_length * s * s;
		float step_h = atmosphere_altitude_along(h, mu, t);
		optical_depth += vec3(ATMOSPHERE_RAYLEIGH_SCATTERING_550 * atmosphere_exponential_mean(previous_h, step_h, ATMOSPHERE_RAYLEIGH_SCALE_HEIGHT),
				pc.haze_density * haze_transport * atmosphere_exponential_mean(previous_h, step_h, pc.haze_scale_height),
				ATMOSPHERE_OZONE_ABSORPTION_550 * atmosphere_ozone_mean(previous_h, step_h)) * (t - previous_t);
		previous_t = t;
		previous_h = step_h;
	}
	// Optical depths at 550 nm, not colour: consumers integrate them over the spectrum.
	imageStore(transmittance_image, texel, vec4(optical_depth, 1.0));
}
