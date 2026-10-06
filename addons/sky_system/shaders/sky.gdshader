shader_type sky;
/*
 * The sky: space (the sun's and the moon's disks) seen through the atmosphere, whose
 * view volume holds everything else (the blue sky, twilight, the haze's glow, the sea
 * below the horizon), with the clouds inside it at their base's distance.
 */

#include "res://addons/sky_system/shaders/atmosphere.gdshaderinc"

uniform vec3 sun_direction = vec3(1.0, 0.0, 0.0);
// Colour of the sun's light at the sea (brightest channel 1).
uniform vec4 sun_color : source_color = vec4(1.0, 0.92, 0.72, 1.0);
// Share of the disk above the horizon.
uniform float sun_visibility : hint_range(0.0, 1.0) = 1.0;
// The sun's light through the air but not the haze, pi * energy * transmittance
// (irradiance in the units of the scene's lights). The disk shows it spread over its
// solid angle; the haze dims it here (the atmosphere's view volume).
uniform vec3 sun_irradiance = vec3(3.0);
uniform float sun_disk_size : hint_range(0.001, 0.05) = 0.00465;
uniform float sun_halo_size : hint_range(0.01, 0.5) = 0.075;
uniform float radiance_sun_disk_strength : hint_range(0.0, 3.0) = 0.16;
uniform float radiance_sun_halo_strength : hint_range(0.0, 1.0) = 0.18;

uniform vec3 moon_direction = vec3(-1.0, 0.0, 0.0);
// As the sun's: the full moon's light, so the lit part of the disk shows it.
uniform vec4 moon_color : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform vec3 moon_irradiance = vec3(0.1);
uniform float moon_visibility : hint_range(0.0, 1.0) = 0.0;
uniform float moon_disk_size : hint_range(0.001, 0.05) = 0.00465;
uniform float moon_phase : hint_range(0.0, 1.0) = 1.0;

// Volumetric clouds rendered by CloudRenderer: rgb is premultiplied radiance,
// a is opacity. SkySystem sets both through the RenderingServer so the runtime
// texture is never saved into the material. The sky shows mip 0.
uniform bool clouds_enabled = false;
// Altitude (m) of the cloud layer's base, where the atmosphere in front of the clouds
// ends; sent with the cloud uniforms.
uniform float cloud_base_altitude = 1500.0;
uniform samplerCube cloud_cubemap : filter_linear_mipmap;

float body_disk(vec3 view_direction, vec3 body_direction, float disk_size) {
	float alignment = dot(normalize(view_direction), normalize(body_direction));
	float angular_distance = acos(clamp(alignment, -1.0, 1.0));
	float edge_size = max(disk_size * 0.18, 0.0005);
	return 1.0 - smoothstep(disk_size, disk_size + edge_size, angular_distance);
}

float body_halo(vec3 view_direction, vec3 body_direction, float halo_size) {
	float alignment = dot(normalize(view_direction), normalize(body_direction));
	float angular_distance = acos(clamp(alignment, -1.0, 1.0));
	return 1.0 - smoothstep(0.0, halo_size, angular_distance);
}

float moon_lighting(vec3 view_direction, vec3 body_direction, vec3 light_direction, float disk_size) {
	vec3 moon_dir = normalize(body_direction);
	vec3 view_dir = normalize(view_direction);
	vec3 sun_dir = normalize(light_direction);
	vec3 tangent_x = sun_dir - moon_dir * dot(sun_dir, moon_dir);
	float tangent_len = length(tangent_x);
	if (tangent_len < 0.0001) {
		tangent_x = cross(moon_dir, vec3(0.0, 1.0, 0.0));
		if (length(tangent_x) < 0.0001) {
			tangent_x = cross(moon_dir, vec3(1.0, 0.0, 0.0));
		}
		tangent_x = normalize(tangent_x);
	} else {
		tangent_x /= tangent_len;
	}
	vec3 tangent_y = normalize(cross(moon_dir, tangent_x));
	vec3 offset = view_dir - moon_dir * dot(view_dir, moon_dir);
	float x = dot(offset, tangent_x) / max(disk_size, 0.0001);
	float y = dot(offset, tangent_y) / max(disk_size, 0.0001);
	float radius_sq = clamp(x * x + y * y, 0.0, 1.0);
	float z = sqrt(1.0 - radius_sq);
	vec3 surface_normal = normalize(tangent_x * x + tangent_y * y - moon_dir * z);
	float lit = smoothstep(-0.015, 0.015, dot(surface_normal, sun_dir));
	return lit;
}

void sky() {
	float sun_disk = body_disk(EYEDIR, sun_direction, sun_disk_size);
	float sun_halo = body_halo(EYEDIR, sun_direction, sun_halo_size) * 0.32;
	float moon_disk = body_disk(EYEDIR, moon_direction, moon_disk_size);
	float moon_halo = body_halo(EYEDIR, moon_direction, sun_halo_size) * 0.32;
	float moon_lit = moon_lighting(EYEDIR, moon_direction, sun_direction, moon_disk_size);

	// The disks at their real radiance: the light's irradiance over the disk's solid
	// angle, far brighter than anything around them, the haze's glow included; that glow
	// is their halo (the atmosphere's forward lobe). The radiance map (ambient light and
	// reflections) keeps faint disks and halos instead (radiance_sun_*_strength times the
	// radiance of a white diffuser in their light): disks that bright would sparkle in
	// every glossy reflection.
	vec3 sun_disk_color = sun_irradiance / (PI * sun_disk_size * sun_disk_size);
	vec3 moon_disk_color = moon_irradiance / (PI * moon_disk_size * moon_disk_size);
	vec3 sun_halo_color = vec3(0.0);
	vec3 moon_halo_color = vec3(0.0);
	if (AT_CUBEMAP_PASS) {
		sun_disk_color = sun_irradiance / PI * radiance_sun_disk_strength;
		moon_disk_color = moon_irradiance / PI * radiance_sun_disk_strength;
		sun_halo_color = sun_irradiance / PI * radiance_sun_halo_strength;
		moon_halo_color = moon_irradiance / PI * radiance_sun_halo_strength * moon_phase;
	}
	vec3 space = (sun_disk_color * sun_disk + sun_halo_color * sun_halo) * sun_visibility
			+ (moon_disk_color * moon_disk * moon_lit + moon_halo_color * moon_halo) * moon_visibility;

	vec4 cloud = clouds_enabled ? textureLod(cloud_cubemap, EYEDIR, 0.0) : vec4(0.0);
	if (atmosphere_enabled) {
		// The camera's altitude comes from the atmosphere, not POSITION: a sky that reads
		// POSITION re-renders its radiance map whenever the camera moves (SkySystem
		// refreshes it instead, see _refresh_sky_radiance()). The atmosphere and the
		// clouds are pre-exposed; Godot exposes the sky's output itself.
		COLOR = atmosphere_sky_with_clouds(EYEDIR, cloud, atmosphere_distance_to_altitude(EYEDIR, cloud_base_altitude), space * atmosphere_exposure) / atmosphere_exposure;
		// Godot renders the radiance map exposed, then exposes the light it gives again
		// (Godot 4.8): the map gets the sky unexposed.
		if (AT_CUBEMAP_PASS) {
			COLOR /= atmosphere_exposure;
		}
	} else {
		COLOR = space * (1.0 - cloud.a) + cloud.rgb;
	}
}
