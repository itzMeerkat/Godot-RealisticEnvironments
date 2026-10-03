// Haze over the sea (SkySystem, CloudPreset haze_*): aerosol or fog droplets whose
// density falls off exponentially with height above the sea. Rays follow the earth's
// curve, so a ray toward the horizon stays low and the horizon itself is fully hazed.
// Single scattering of the dominant light (sun or moon, Henyey-Greenstein phase) plus an
// isotropic ambient term (skylight and light scattered many times), all set by SkySystem.
//
// Copies of these functions: SkyHazeEffect (the scene's geometry, GLSL) and the ocean's
// water.gdshader (its sky reflection). Change them together.

#define HAZE_EARTH_RADIUS 6371000.0
#define HAZE_STEPS 12
// Rays to infinity are followed until they are this many scale heights above sea level.
#define HAZE_TOP_SCALE_HEIGHTS 12.0
// Rays that run into the sea are cut off here (m).
#define HAZE_MAX_RAY_LENGTH 1000000.0
// Share of the scattering in the forward lobe (haze_anisotropy); the rest is isotropic.
#define HAZE_FORWARD_SHARE 0.75
// Angle (rad) over which the clouds toward the light are averaged to shade the haze.
#define HAZE_CLOUD_SHADE_ANGLE 0.04

uniform float sea_level = 0.0; // world height of the sea surface (SkySystem.sea_level)
uniform float haze_density = 0.0; // extinction at sea level (1/m): 3.912 / visibility
uniform float haze_scale_height = 1000.0; // m
uniform float haze_anisotropy = 0.97; // Henyey-Greenstein g of the forward lobe
uniform vec3 haze_light_direction = vec3(0.0, 1.0, 0.0); // toward the sun or moon
// Radiance per unit phase function (1/sr) scattered from the light: pi * its color *
// energy as it reaches the sea (after the haze above).
uniform vec3 haze_light_color = vec3(0.0);
uniform vec3 haze_ambient_color = vec3(0.0); // isotropic in-scattered radiance
// Multiplies the cloud opacity toward the light (SkySystem.cloud_haze_shadow_strength).
uniform float haze_cloud_shadow_strength = 1.0;

/* Mean of exp(-h / H) along a segment over which h goes linearly from a to b. */
float haze_mean_density(float height_a, float height_b) {
	float a = max(height_a, 0.0) / haze_scale_height;
	float x = max(height_b, 0.0) / haze_scale_height - a;
	float density_a = exp(-a);
	return abs(x) < 1e-4 ? density_a * (1.0 - 0.5 * x) : density_a * (1.0 - exp(-x)) / x;
}

/*
 * Optical depth of a ray of this length leaving start_height (m above sea level). Its
 * height above the curved sea is h0 + t dir.y + t^2 (1 - dir.y^2) / 2R, integrated
 * exactly over HAZE_STEPS pieces along which it is taken as linear.
 */
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
	return haze_density * step_length * sum;
}

/* Length after which a ray to infinity has left the haze (see HAZE_TOP_SCALE_HEIGHTS). */
float haze_ray_length(float start_height, vec3 direction) {
	float curvature = (1.0 - direction.y * direction.y) * (0.5 / HAZE_EARTH_RADIUS);
	float rise = max(HAZE_TOP_SCALE_HEIGHTS * haze_scale_height - start_height, 0.0);
	// Positive root of t^2 curvature + t dir.y - rise = 0, in the form that stays exact
	// for steep rays (curvature -> 0).
	float denominator = direction.y + sqrt(direction.y * direction.y + 4.0 * curvature * rise);
	return min(2.0 * rise / max(denominator, 1e-9), HAZE_MAX_RAY_LENGTH);
}

/*
 * Aerosols and droplets scatter like Mie particles: a narrow forward (diffraction) peak
 * and a broad rest. A Henyey-Greenstein lobe alone with their mean g (about 0.7) spreads
 * the glow around the sun far too wide; a sharp lobe (g about 0.97) holding 75 % of the
 * scattering plus an isotropic rest keeps that mean.
 */
float haze_phase(float cos_theta) {
	float g = haze_anisotropy;
	float denominator = 1.0 + g * g - 2.0 * g * cos_theta;
	float lobe = (1.0 - g * g) / (4.0 * PI * denominator * sqrt(denominator));
	return mix(1.0 / (4.0 * PI), lobe, HAZE_FORWARD_SHARE);
}

/*
 * Share of the light that reaches the haze through the clouds (a cloud cubemap, a =
 * opacity). The clouds lie above the haze, and the haze that glows around the light is
 * within a few km of the camera, so it is lit through the clouds over the camera in the
 * light's direction, taken over a patch about as wide as the forward lobe. The patch is
 * kept above the horizon: the cubemap's lower half holds no clouds. The opacity is
 * scaled by haze_cloud_shadow_strength, a manual tuning knob.
 */
float haze_cloud_light_transmittance(samplerCube clouds, vec3 light_direction) {
	vec3 direction = normalize(vec3(light_direction.x, max(light_direction.y, HAZE_CLOUD_SHADE_ANGLE), light_direction.z));
	// A texel at the centre of a cube face spans 2 / size radians.
	float lod = log2(max(HAZE_CLOUD_SHADE_ANGLE * float(textureSize(clouds, 0).x) * 0.5, 1.0));
	return 1.0 - clamp(textureLod(clouds, direction, lod).a * haze_cloud_shadow_strength, 0.0, 1.0);
}

/*
 * Background seen through haze of this optical depth along direction; light_visibility
 * is the share of the light that reaches the haze (haze_cloud_light_transmittance()).
 */
vec3 haze_apply(vec3 background, vec3 direction, float optical_depth, float light_visibility) {
	float transmittance = exp(-optical_depth);
	vec3 inscattered = haze_light_color * (light_visibility * haze_phase(dot(direction, haze_light_direction))) + haze_ambient_color;
	return background * transmittance + inscattered * (1.0 - transmittance);
}
