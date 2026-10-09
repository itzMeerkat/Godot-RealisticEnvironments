shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled;

// Catalog stars (SkySystem's StarCatalog), one camera-facing quad each, drawn at
// infinity behind everything. The mesh holds per vertex: VERTEX the star's J2000
// equatorial direction (MODEL_MATRIX turns it to the world's sky), UV the quad's
// corner (-1..1), CUSTOM0 rgb its colour (luminance 1) times its illuminance in lux
// above the atmosphere. A star's light is spread over a small gaussian footprint
// on screen, so its brightness does not depend on the resolution. The planets follow
// as quads whose CUSTOM0 a is their index + 1: their direction and light come from
// planet_directions / planet_light (they move), and they do not twinkle (their disks
// average the turbulence out).
//
// The output is unlit ALBEDO, which Godot does not expose: it is written pre-exposed
// (illuminance_scale holds the exposure).

#include "res://addons/sky_system/shaders/atmosphere.gdshaderinc"

// Lux to the scene's irradiance, times the exposure and SkySystem.star_brightness.
uniform float illuminance_scale = 0.0;
// Spread (std. deviation, pixels) of a faint star's footprint.
uniform float footprint_sigma = 0.7;
// Log-amplitude spread of a star's twinkling at the zenith (CloudPreset.star_scintillation).
uniform float scintillation = 0.15;
uniform float time = 0.0;
// SkySystem's planets (PLANET_NAMES order): J2000 equatorial directions and illuminance
// (lux, rgb) above the atmosphere.
uniform vec3 planet_directions[5];
uniform vec3 planet_light[5];
// SkySystem.sea_level. Cameras below it (the ocean's mirrored reflection camera) draw no
// planets: the water reflects them itself, as glints (SkySystem.get_planet_*()).
uniform float sea_level = 0.0;
// Clouds hide the stars; set by SkySystem like the sky shader's cloud uniforms.
uniform bool clouds_enabled = false;
uniform samplerCube cloud_cubemap : filter_linear;

// Pre-exposed radiance at the footprint's centre.
varying flat vec3 star_radiance;
// Position in the footprint, in units of its sigma.
varying vec2 footprint;

float hash13(vec3 p) {
	p = fract(p * 0.1031);
	p += dot(p, p.zyx + 31.32);
	return fract((p.x + p.y) * p.z);
}

// Unit-variance noise in time: three sines at hashed frequencies (1.5-7 Hz) and phases.
float twinkle_noise(vec3 seed) {
	float sum = 0.0;
	for (int i = 0; i < 3; i++) {
		vec3 s = seed + float(i) * 17.31;
		float frequency = mix(1.5, 7.0, hash13(s));
		sum += sin(6.2831853 * (frequency * time + hash13(s.zxy + 4.7)));
	}
	return sum * 0.8164966;
}

// Relative air mass toward a direction of sine elevation y (Kasten and Young 1989).
float air_mass(float y) {
	float elevation = degrees(asin(clamp(y, 0.0, 1.0)));
	return 1.0 / (max(y, 0.0) + 0.50572 * pow(elevation + 6.07995, -1.6364));
}

void vertex() {
	int planet = int(CUSTOM0.a + 0.5) - 1;
	vec3 equatorial = planet >= 0 ? planet_directions[planet] : VERTEX;
	vec3 direction = normalize(mat3(MODEL_MATRIX) * equatorial);
	vec3 radiance = (planet >= 0 ? planet_light[planet] : CUSTOM0.rgb) * illuminance_scale;
	float horizon = atmosphere_enabled ? atmosphere_horizon_mu(atmosphere_observer.w) : 0.0;
	if (direction.y < horizon || (planet >= 0 && CAMERA_POSITION_WORLD.y < sea_level)) {
		radiance = vec3(0.0);
	} else {
		if (atmosphere_enabled) {
			vec3 transmittance;
			vec3 inscatter;
			atmosphere_along(direction, -1.0, transmittance, inscatter);
			radiance *= transmittance;
		}
		if (clouds_enabled) {
			radiance *= 1.0 - textureLod(cloud_cubemap, direction, 0.0).a;
		}
		// Twinkling grows with the air mass (Young 1967: variance ~ X^3) and turns
		// colourful near the horizon, where dispersion splits the colours' paths.
		float x = air_mass(direction.y);
		float spread = planet >= 0 ? 0.0 : min(scintillation * pow(x, 1.5), 0.8);
		vec3 seed = VERTEX * 1000.0;
		vec3 noise = mix(vec3(twinkle_noise(seed)),
				vec3(twinkle_noise(seed + 1.1), twinkle_noise(seed + 2.3), twinkle_noise(seed + 3.7)),
				clamp((x - 2.0) / 10.0, 0.0, 1.0));
		radiance *= exp(spread * noise - 0.5 * spread * spread);
	}

	vec3 view_direction = mat3(VIEW_MATRIX) * direction;
	vec4 clip = PROJECTION_MATRIX * vec4(view_direction, 0.0);
	// The solid angle of a pixel there: the pixel's size on the plane at depth 1
	// times cos^3 of the angle off the view axis (abs: Godot flips y for Vulkan).
	vec2 pixel = 2.0 / abs(vec2(PROJECTION_MATRIX[0][0], PROJECTION_MATRIX[1][1]) * VIEWPORT_SIZE);
	float cos_off_axis = max(-view_direction.z, 1e-3);
	float pixel_solid_angle = pixel.x * pixel.y * cos_off_axis * cos_off_axis * cos_off_axis;
	// Irradiance into radiance over a unit gaussian footprint of sigma pixels. Stars
	// that would burn out widen it (energy kept), as bright stars look bigger to the eye.
	float peak = dot(radiance, vec3(0.2126, 0.7152, 0.0722)) / (6.2831853 * footprint_sigma * footprint_sigma * pixel_solid_angle);
	float sigma = footprint_sigma * clamp(pow(max(peak, 1e-6), 0.25), 1.0, 3.0);
	star_radiance = radiance / (6.2831853 * sigma * sigma * pixel_solid_angle);
	// Stars too faint to show collapse their quad.
	float extent = peak > 1e-4 ? 3.0 : 0.0;
	footprint = UV * extent;
	clip.xy += UV * (extent * sigma * 2.0 / VIEWPORT_SIZE) * clip.w;
	// At the far plane (reversed z), behind every surface.
	clip.z = 0.0;
	POSITION = clip;
}

void fragment() {
	ALBEDO = star_radiance * exp(-0.5 * dot(footprint, footprint));
}
