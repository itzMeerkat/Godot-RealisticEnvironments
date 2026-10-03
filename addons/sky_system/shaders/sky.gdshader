shader_type sky;

#include "res://addons/sky_system/shaders/haze.gdshaderinc"

uniform vec4 sky_top_color : source_color = vec4(0.12, 0.42, 0.78, 1.0);
uniform vec4 sky_horizon_color : source_color = vec4(0.58, 0.78, 0.94, 1.0);
uniform vec4 ground_bottom_color : source_color = vec4(0.01, 0.02, 0.03, 1.0);
uniform vec4 ground_horizon_color : source_color = vec4(0.16, 0.24, 0.28, 1.0);

uniform vec3 sun_direction = vec3(1.0, 0.0, 0.0);
uniform vec4 sun_color : source_color = vec4(1.0, 0.92, 0.72, 1.0);
uniform float sun_visibility : hint_range(0.0, 1.0) = 1.0;
// The sun's light above the haze, color * energy * pi (irradiance in the units of the
// scene's lights). The disk shows it spread over its solid angle.
uniform vec3 sun_irradiance = vec3(3.0);
uniform float sun_disk_size : hint_range(0.001, 0.05) = 0.00465;
uniform float sun_halo_size : hint_range(0.01, 0.5) = 0.075;
uniform float radiance_sun_disk_strength : hint_range(0.0, 3.0) = 0.16;
uniform float radiance_sun_halo_strength : hint_range(0.0, 1.0) = 0.18;

uniform vec3 moon_direction = vec3(-1.0, 0.0, 0.0);
uniform vec4 moon_color : source_color = vec4(0.72, 0.78, 1.0, 1.0);
uniform float moon_visibility : hint_range(0.0, 1.0) = 0.0;
uniform float moon_disk_size : hint_range(0.001, 0.05) = 0.00465;
uniform float moon_phase : hint_range(0.0, 1.0) = 1.0;

// Volumetric clouds rendered by CloudRenderer: rgb is premultiplied radiance,
// a is opacity. SkySystem sets both through the RenderingServer so the runtime
// texture is never saved into the material. The sky shows mip 0; a blurred mip
// shades the haze (haze_cloud_light_transmittance()).
uniform bool clouds_enabled = false;
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
	// The sea's horizon is below eye level (the earth curves away): the sky reaches
	// down to it, and the gradients run from it rather than from eye level.
	float camera_height = POSITION.y - sea_level;
	float horizon_dip = sqrt(2.0 * max(camera_height, 0.0) / HAZE_EARTH_RADIUS);
	float elevation = EYEDIR.y + horizon_dip;
	float horizon_blend = smoothstep(-0.08, 0.45, elevation);
	vec3 upper_sky = mix(sky_horizon_color.rgb, sky_top_color.rgb, horizon_blend);
	vec3 lower_sky = mix(ground_horizon_color.rgb, ground_bottom_color.rgb, 1.0 - smoothstep(-0.55, 0.0, elevation));
	vec3 sky_color = mix(lower_sky, upper_sky, step(0.0, elevation));

	float sun_disk = body_disk(EYEDIR, sun_direction, sun_disk_size);
	float sun_halo = body_halo(EYEDIR, sun_direction, sun_halo_size) * 0.32;
	float moon_disk = body_disk(EYEDIR, moon_direction, moon_disk_size);
	float moon_halo = body_halo(EYEDIR, moon_direction, 0.08) * 0.08;
	float moon_lit = moon_lighting(EYEDIR, moon_direction, sun_direction, moon_disk_size);

	// The disk at its real radiance: the sun's irradiance over the disk's solid angle,
	// far brighter than anything around it, the haze's glow included; that glow is the
	// sun's halo (haze.gdshaderinc). The radiance map (ambient light and reflections)
	// keeps a faint disk and halo instead: a disk that bright would sparkle in every
	// glossy reflection.
	vec3 sun_disk_color = sun_irradiance / (PI * sun_disk_size * sun_disk_size);
	float sun_halo_strength = 0.0;
	if (AT_CUBEMAP_PASS) {
		sun_disk_color = sun_color.rgb * radiance_sun_disk_strength;
		sun_halo_strength = radiance_sun_halo_strength;
	}

	sky_color += (sun_disk_color * sun_disk + sun_color.rgb * sun_halo * sun_halo_strength) * sun_visibility;
	sky_color += moon_color.rgb * (moon_disk * moon_lit * 0.9 + moon_halo * moon_phase) * moon_visibility;
	if (clouds_enabled) {
		vec4 cloud = textureLod(cloud_cubemap, EYEDIR, 0.0);
		sky_color = sky_color * (1.0 - cloud.a) + cloud.rgb;
	}
	// Clouds sit above the haze, so it lies over them too, and clouds in front of the
	// light shade it: the glow around a covered sun goes out.
	if (haze_density > 0.0) {
		float haze_light_visibility = clouds_enabled ? haze_cloud_light_transmittance(cloud_cubemap, haze_light_direction) : 1.0;
		sky_color = haze_apply(sky_color, EYEDIR, haze_optical_depth(camera_height, EYEDIR, haze_ray_length(camera_height, EYEDIR)), haze_light_visibility);
	}
	COLOR = sky_color;
}
