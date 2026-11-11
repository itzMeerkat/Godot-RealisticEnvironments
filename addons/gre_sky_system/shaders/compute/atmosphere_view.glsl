#[compute]
#version 450
/*
 * View volume: what the atmosphere does to light along every ray from an observer. One
 * invocation marches one ray (an azimuth from the light and a view angle, see
 * atmosphere_view_y()) out to its end at the sea or in space, and stores at each slice:
 *   transmittance_image  rgb: transmittance from the observer to that distance
 *   inscatter_image      rgb: light scattered toward the observer, all but the lobe
 *                        (the air's Rayleigh phase depends only on the ray and the
 *                        light, which the texel fixes, so it is baked in)
 *   inscatter_lobe_image rgb: the same for the haze's forward lobe, per unit of its
 *                        phase function (1/sr); consumers multiply by
 *                        atmosphere_henyey_greenstein(dot(view, light), g)
 * so a consumer composites background * transmittance + inscatter + lobe * phase. The
 * lobe's phase is left out because it is far narrower than a texel. In-scatter reaches
 * the observer through the transport haze (atmosphere_haze_transport_share()), the
 * background through all of it.
 *
 * Slices, by the volume's depth:
 *   more than 2: atmosphere_slice_distance() (the camera's volume);
 *   2: at the cloud layer (distance to cloud_altitude, or the ray's end if sooner), and
 *      the ray's end (the sea's volume: the sky the water reflects, with its clouds);
 *   1: the ray's end only.
 * A ray that ends on the sea adds, in its last slice, the sunlight the sea reflects
 * diffusely (ATMOSPHERE_SEA_ALBEDO) seen through the atmosphere: the ground below the
 * horizon, for the sky's radiance map and the light the clouds get from below.
 *
 * Light: the key light (sun or moon) at light_color above the atmosphere, dimmed by every
 * medium down to each sample (transmittance LUT, with the planet's shadow) and, below
 * the cloud layer, by the clouds (cloud_shade()), scattered once, integrated per
 * wavelength with the view ray's own transmittance (atmosphere_common.glslinc); plus every higher
 * order from the multiple-scattering LUT, isotropic. The other body (secondary_*) adds
 * the same without the haze's lobe (its haze scattering counts as isotropic): the volume
 * is laid out around the key light and symmetric about its vertical plane, so the
 * secondary light's phase and angle are averaged over each texel's two mirrored
 * directions, and the clouds shade it by their mean cover.
 *
 * Below the cloud layer the clouds also light the air and the sea: the cloud base, seen
 * as a dome of its mean radiance overhead (cloud_dome), scatters isotropically. Under an
 * overcast deck that is nearly all the light there is.
 *
 * Airglow: the upper atmosphere's own light (O, Na and OH emission at 85-100 km), the
 * main light of a moonless sky. A thin shell at AIRGLOW_ALTITUDE of zenith radiance
 * pc.airglow; a ray that reaches space sees it times the van Rhijn factor (its slant path
 * through the shell, up to ~6x at the horizon), dimmed by the air below like the
 * in-scatter. It goes into the ray's end only.
 */

#include "atmosphere_common.glslinc"

// Integration steps between two slices, and from the last regular slice to the ray's end.
#define SLICE_STEPS 2
#define TAIL_STEPS 32
// Angle (rad) over which the clouds toward the light are averaged to shade the air near
// the observer, and the distance (m) beyond which the mean cover overhead shades it instead.
#define CLOUD_SHADE_ANGLE 0.04
#define CLOUD_SHADE_LOCAL_DISTANCE 5000.0
// Altitude (m) of the airglow shell (the 557.7 nm oxygen layer lies at ~97 km, OH at ~87 km).
#define AIRGLOW_ALTITUDE 90000.0

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler2D transmittance_lut;
// The cloud cubemap (a = opacity), or a transparent placeholder.
layout(set = 0, binding = 1) uniform samplerCube cloud_cubemap;
layout(rgba16f, set = 0, binding = 2) uniform restrict writeonly image3D transmittance_image;
layout(rgba16f, set = 0, binding = 3) uniform restrict writeonly image3D inscatter_image;
layout(rgba16f, set = 0, binding = 4) uniform restrict writeonly image3D inscatter_lobe_image;
layout(set = 0, binding = 5) uniform sampler2D ms_lut;

layout(push_constant, std430) restrict readonly uniform PushConstants {
	float observer_altitude; // m above sea level, within [0, top_altitude)
	float haze_density;      // extinction at sea level (1/m)
	float haze_scale_height; // m
	float top_altitude;      // m
	vec3 light_direction;    // world, toward the light
	float max_distance;      // m, distance of the last regular slice
	vec3 light_color;        // irradiance above the atmosphere: pi * energy (white)
	float cloud_shadow_strength; // multiplies the cloud opacity toward the light
	float cloud_altitude;    // m, the cloud layer's base: where a two-slice volume stores its first slice
	float cloud_top_altitude; // m, the cloud layer's top: above it the clouds shade nothing
	float haze_anisotropy;   // the lobe's g
	float airglow_red;       // the airglow's zenith radiance (rgb, in the padding of the vec3s)
	vec3 secondary_direction; // world, toward the other body
	float airglow_green;
	vec3 secondary_color;    // its irradiance above the atmosphere: pi * energy (white)
	float airglow_blue;
	float haze_wavelength_exponent; // atmosphere_haze_optics()
} pc;

// Per spectral sample: transmittance from the observer, the same through the transport
// haze (which in-scatter reaches the observer by), and the key light's single scattering
// (all but the lobe, and the lobe per unit phase). Stored as linear sRGB.
float spectral_transmittance[ATMOSPHERE_SPECTRAL_SAMPLES];
float spectral_transport[ATMOSPHERE_SPECTRAL_SAMPLES];
float spectral_inscatter[ATMOSPHERE_SPECTRAL_SAMPLES];
float spectral_lobe[ATMOSPHERE_SPECTRAL_SAMPLES];
float haze_spectrum[ATMOSPHERE_SPECTRAL_SAMPLES];
// The transport as linear sRGB, and the in-scatter of the light not integrated per
// wavelength (higher orders, the secondary light, the cloud dome, airglow, the sea).
vec3 transport;
vec3 inscatter;

// atmosphere_haze_transport_share() of the haze's g, and atmosphere_haze_optics().
float haze_transport_share;
vec4 haze_optics;

// Share of the key light that comes through the clouds: toward the light over the
// observer, and through the mean cover overhead.
float cloud_light_local;
float cloud_light_mean;
// The clouds' mean radiance overhead (premultiplied: the gaps count as black).
vec3 cloud_dome;

void init_cloud_light() {
	vec3 direction = normalize(vec3(pc.light_direction.x, max(pc.light_direction.y, CLOUD_SHADE_ANGLE), pc.light_direction.z));
	// A texel at the centre of a cube face spans 2 / size radians.
	float lod = log2(max(CLOUD_SHADE_ANGLE * float(textureSize(cloud_cubemap, 0).x) * 0.5, 1.0));
	cloud_light_local = 1.0 - clamp(textureLod(cloud_cubemap, direction, lod).a * pc.cloud_shadow_strength, 0.0, 1.0);
	// The top face's last mip: its mean opacity, about 45 degrees around the zenith.
	float mean_lod = float(textureQueryLevels(cloud_cubemap) - 1);
	vec4 mean_cloud = textureLod(cloud_cubemap, vec3(0.0, 1.0, 0.0), mean_lod);
	cloud_light_mean = 1.0 - clamp(mean_cloud.a * pc.cloud_shadow_strength, 0.0, 1.0);
	cloud_dome = mean_cloud.rgb;
}

/*
 * Share of the key light the clouds let through to a point at altitude h, distance t
 * from the observer. Only air below the cloud layer is in their shadow. Near the
 * observer it is the shadow toward the light over the observer (a sun behind a cloud
 * darkens the haze around the camera and its glow); farther out the clouds over each
 * point are unknown here, so the mean cover stands in for them.
 */
float cloud_shade(float h, float t) {
	float shade = mix(cloud_light_local, cloud_light_mean, smoothstep(0.0, CLOUD_SHADE_LOCAL_DISTANCE, t));
	float below = 1.0 - smoothstep(pc.cloud_altitude, pc.cloud_top_altitude, h);
	return mix(1.0, shade, below);
}

/* The same for the secondary light: the mean cover everywhere. */
float cloud_shade_secondary(float h) {
	float below = 1.0 - smoothstep(pc.cloud_altitude, pc.cloud_top_altitude, h);
	return mix(1.0, cloud_light_mean, below);
}

/*
 * Light the cloud base sends to a point at altitude h, per unit of scattering
 * coefficient: a dome of radiance cloud_dome over the upper hemisphere, scattered
 * isotropically (the Rayleigh phase averages the same over a hemisphere): half of it.
 */
vec3 cloud_dome_inscatter(float h) {
	float below = 1.0 - smoothstep(pc.cloud_altitude, pc.cloud_top_altitude, h);
	return cloud_dome * (0.5 * below);
}

// The secondary light in the volume's frame for the texel's direction: its cosine to the
// ray averaged over the two mirrored directions, and its Rayleigh phase averaged likewise.
float secondary_cos;
float secondary_rayleigh_phase;

/*
 * Integrates the ray from t_start to t_end in `steps` segments, spaced linearly or (when
 * quadratic) densest at the start. Each segment's own extinction is exact for the
 * media's profiles; its light is taken at its middle.
 */
/* Linear sRGB of a spectrum (ATMOSPHERE_SPECTRUM_TO_RGB), clamped at 0. */
vec3 spectral_band(float spectrum[ATMOSPHERE_SPECTRAL_SAMPLES]) {
	vec3 band = vec3(0.0);
	for (int k = 0; k < ATMOSPHERE_SPECTRAL_SAMPLES; ++k) {
		band += ATMOSPHERE_SPECTRUM_TO_RGB[k] * spectrum[k];
	}
	return max(band, vec3(0.0));
}

void march(float mu, float cos_light, float key_light, float t_start, float t_end, int steps, bool quadratic) {
	float h0 = pc.observer_altitude;
	float r0 = ATMOSPHERE_EARTH_RADIUS + h0;
	float rayleigh_phase = atmosphere_rayleigh_phase(cos_light);
	float previous_t = t_start;
	float previous_h = atmosphere_altitude_along(h0, mu, t_start);
	for (int i = 1; i <= steps; ++i) {
		float s = float(i) / float(steps);
		float t = t_start + (t_end - t_start) * (quadratic ? s * s : s);
		float h = atmosphere_altitude_along(h0, mu, t);
		float dt = t - previous_t;
		// The media's coefficients at 550 nm over the segment (atmosphere_segment_media()).
		float rayleigh_550 = ATMOSPHERE_RAYLEIGH_SCATTERING_550 * atmosphere_exponential_mean(previous_h, h, ATMOSPHERE_RAYLEIGH_SCALE_HEIGHT);
		float haze_550 = pc.haze_density * atmosphere_exponential_mean(previous_h, h, pc.haze_scale_height);
		float ozone_550 = ATMOSPHERE_OZONE_ABSORPTION_550 * atmosphere_ozone_mean(previous_h, h);
		float t_mid = 0.5 * (previous_t + t);
		float h_mid = min(atmosphere_altitude_along(h0, mu, t_mid), pc.top_altitude);
		// The light's cosine to the local up there: the planet curves under the ray.
		float mu_light = clamp((r0 * pc.light_direction.y + t_mid * cos_light) / (ATMOSPHERE_EARTH_RADIUS + h_mid), -1.0, 1.0);
		float light = key_light * cloud_shade(h_mid, t_mid);
		vec3 sun_depth = atmosphere_light_optical_depth(transmittance_lut, h_mid, mu_light, pc.top_altitude);
		// The key light's single scattering, per wavelength. path: the integral of the
		// transport transmittance from the observer over the segment, per unit of
		// scattering coefficient; its band average carries the rest below.
		vec3 path_band = vec3(0.0);
		for (int k = 0; k < ATMOSPHERE_SPECTRAL_SAMPLES; ++k) {
			float rayleigh_k = rayleigh_550 * ATMOSPHERE_RAYLEIGH_SPECTRUM[k];
			float haze_extinction_k = haze_550 * haze_spectrum[k];
			float haze_k = haze_extinction_k * haze_optics.a;
			float extinction_k = rayleigh_k + haze_extinction_k + ozone_550 * ATMOSPHERE_OZONE_SPECTRUM[k];
			float extinction_transport_k = extinction_k - haze_k * (1.0 - haze_transport_share);
			float segment_transport_k = exp(-extinction_transport_k * dt);
			float path_k = spectral_transport[k] * (1.0 - segment_transport_k) / max(extinction_transport_k, 1e-12);
			float sun_k = light * exp(-(sun_depth.r * ATMOSPHERE_RAYLEIGH_SPECTRUM[k] + sun_depth.g * haze_spectrum[k] + sun_depth.b * ATMOSPHERE_OZONE_SPECTRUM[k]));
			spectral_lobe[k] += path_k * haze_k * sun_k * ATMOSPHERE_HAZE_FORWARD_SHARE;
			spectral_inscatter[k] += path_k * sun_k * (rayleigh_k * rayleigh_phase + haze_k * ((1.0 - ATMOSPHERE_HAZE_FORWARD_SHARE) / (4.0 * ATMOSPHERE_PI)));
			path_band += ATMOSPHERE_SPECTRUM_TO_RGB[k] * path_k;
			spectral_transmittance[k] *= exp(-extinction_k * dt);
			spectral_transport[k] *= segment_transport_k;
		}
		path_band = max(path_band, vec3(0.0));
		// The rest, in linear sRGB band averages.
		vec3 rayleigh;
		vec3 haze;
		vec3 extinction;
		atmosphere_segment_media(previous_h, h, pc.haze_density, pc.haze_scale_height, haze_optics, 1.0, rayleigh, haze, extinction);
		vec3 haze_transport = haze * haze_transport_share;
		vec3 multiple = light * atmosphere_multiple_scattering(ms_lut, h_mid, mu_light, pc.top_altitude, pc.haze_scale_height);
		inscatter += path_band * (rayleigh + haze_transport) * multiple;
		float mu_secondary = clamp((r0 * pc.secondary_direction.y + t_mid * secondary_cos) / (ATMOSPHERE_EARTH_RADIUS + h_mid), -1.0, 1.0);
		vec3 light_secondary = pc.secondary_color * cloud_shade_secondary(h_mid);
		vec3 sun_secondary = light_secondary * atmosphere_light_transmittance(transmittance_lut, h_mid, mu_secondary, pc.top_altitude, haze_spectrum);
		vec3 multiple_secondary = light_secondary * atmosphere_multiple_scattering(ms_lut, h_mid, mu_secondary, pc.top_altitude, pc.haze_scale_height);
		inscatter += path_band * (rayleigh * (sun_secondary * secondary_rayleigh_phase + multiple_secondary)
				+ haze * sun_secondary / (4.0 * ATMOSPHERE_PI) + haze_transport * multiple_secondary);
		inscatter += path_band * (rayleigh + haze_transport) * cloud_dome_inscatter(h_mid);
		transport = spectral_band(spectral_transport);
		previous_t = t;
		previous_h = h;
	}
}

/*
 * van Rhijn factor: an observer at altitude h looking along mu crosses the airglow shell
 * on a path 1 / cos(zenith angle at the shell) times its thickness. 0 when the observer
 * is above the shell.
 */
float airglow_van_rhijn(float h, float mu) {
	if (h >= AIRGLOW_ALTITUDE) {
		return 0.0;
	}
	float ratio = (ATMOSPHERE_EARTH_RADIUS + h) / (ATMOSPHERE_EARTH_RADIUS + AIRGLOW_ALTITUDE);
	return inversesqrt(max(1.0 - ratio * ratio * (1.0 - mu * mu), 1e-4));
}

void store(ivec3 texel) {
	imageStore(transmittance_image, texel, vec4(spectral_band(spectral_transmittance), 1.0));
	imageStore(inscatter_image, texel, vec4(spectral_band(spectral_inscatter) + inscatter, 1.0));
	imageStore(inscatter_lobe_image, texel, vec4(spectral_band(spectral_lobe), 1.0));
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
	// White light: one value for every wavelength.
	float key_light = pc.light_color.g;
	haze_transport_share = atmosphere_haze_transport_share(pc.haze_anisotropy);
	haze_optics = atmosphere_haze_optics(pc.haze_wavelength_exponent);
	atmosphere_haze_spectrum(pc.haze_wavelength_exponent, haze_spectrum);
	init_cloud_light();
	// The secondary light in the frame: x along the key light's horizontal direction.
	vec2 key_xz = length(pc.light_direction.xz) > 1e-5 ? normalize(pc.light_direction.xz) : vec2(1.0, 0.0);
	vec3 secondary = vec3(dot(pc.secondary_direction.xz, key_xz), pc.secondary_direction.y,
			dot(pc.secondary_direction.xz, vec2(-key_xz.y, key_xz.x)));
	float across = direction.z * secondary.z;
	secondary_cos = direction.x * secondary.x + direction.y * secondary.y;
	secondary_rayleigh_phase = 0.5 * (atmosphere_rayleigh_phase(secondary_cos + across) + atmosphere_rayleigh_phase(secondary_cos - across));

	float t_sea = atmosphere_distance_to_sea(h0, mu);
	float t_end = t_sea >= 0.0 ? t_sea : atmosphere_distance_to_top(h0, mu, pc.top_altitude);
	for (int k = 0; k < ATMOSPHERE_SPECTRAL_SAMPLES; ++k) {
		spectral_transmittance[k] = 1.0;
		spectral_transport[k] = 1.0;
		spectral_inscatter[k] = 0.0;
		spectral_lobe[k] = 0.0;
	}
	transport = vec3(1.0);
	inscatter = vec3(0.0);
	float t = 0.0;
	if (size.z == 2) {
		float t_cloud = h0 < pc.cloud_altitude ? min(atmosphere_distance_to_top(h0, mu, pc.cloud_altitude), t_end) : 0.0;
		if (t_cloud > 0.0) {
			march(mu, cos_light, key_light, 0.0, t_cloud, TAIL_STEPS, true);
			t = t_cloud;
		}
		store(ivec3(texel, 0));
	} else if (size.z > 2) {
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
	if (t_sea < 0.0) {
		inscatter += transport * vec3(pc.airglow_red, pc.airglow_green, pc.airglow_blue) * airglow_van_rhijn(h0, mu);
	}
	if (t_sea >= 0.0) {
		float mu_light_sea = clamp((ATMOSPHERE_EARTH_RADIUS + h0) * pc.light_direction.y / ATMOSPHERE_EARTH_RADIUS
				+ t_end * cos_light / ATMOSPHERE_EARTH_RADIUS, -1.0, 1.0);
		vec3 sea_irradiance = key_light * cloud_shade(0.0, t_end) * atmosphere_light_transmittance(transmittance_lut, 0.0, mu_light_sea, pc.top_altitude, haze_spectrum) * max(mu_light_sea, 0.0);
		float mu_secondary_sea = clamp(((ATMOSPHERE_EARTH_RADIUS + h0) * pc.secondary_direction.y + t_end * secondary_cos) / ATMOSPHERE_EARTH_RADIUS, -1.0, 1.0);
		sea_irradiance += pc.secondary_color * cloud_shade_secondary(0.0) * atmosphere_light_transmittance(transmittance_lut, 0.0, mu_secondary_sea, pc.top_altitude, haze_spectrum) * max(mu_secondary_sea, 0.0);
		// The cloud dome's irradiance: pi times its radiance.
		sea_irradiance += 2.0 * ATMOSPHERE_PI * cloud_dome_inscatter(0.0);
		inscatter += transport * sea_irradiance * (ATMOSPHERE_SEA_ALBEDO / ATMOSPHERE_PI);
	}
	store(ivec3(texel, size.z - 1));
}
