shader_type sky;

uniform vec4 sky_top_color : source_color = vec4(0.12, 0.42, 0.78, 1.0);
uniform vec4 sky_horizon_color : source_color = vec4(0.58, 0.78, 0.94, 1.0);
uniform vec4 ground_bottom_color : source_color = vec4(0.01, 0.02, 0.03, 1.0);
uniform vec4 ground_horizon_color : source_color = vec4(0.16, 0.24, 0.28, 1.0);

uniform vec3 sun_direction = vec3(1.0, 0.0, 0.0);
uniform vec4 sun_color : source_color = vec4(1.0, 0.92, 0.72, 1.0);
uniform float sun_visibility : hint_range(0.0, 1.0) = 1.0;
uniform float sun_disk_size : hint_range(0.001, 0.1) = 0.012;
uniform float sun_halo_size : hint_range(0.01, 0.5) = 0.16;
uniform float radiance_sun_disk_strength : hint_range(0.0, 3.0) = 0.16;
uniform float radiance_sun_halo_strength : hint_range(0.0, 1.0) = 0.18;

uniform vec3 moon_direction = vec3(-1.0, 0.0, 0.0);
uniform vec4 moon_color : source_color = vec4(0.72, 0.78, 1.0, 1.0);
uniform float moon_visibility : hint_range(0.0, 1.0) = 0.0;
uniform float moon_disk_size : hint_range(0.001, 0.1) = 0.010;

float body_disk(vec3 view_direction, vec3 body_direction, float disk_size) {
	float alignment = dot(normalize(view_direction), normalize(body_direction));
	return smoothstep(1.0 - disk_size * 1.6, 1.0 - disk_size, alignment);
}

float body_halo(vec3 view_direction, vec3 body_direction, float halo_size) {
	float alignment = dot(normalize(view_direction), normalize(body_direction));
	return smoothstep(1.0 - halo_size, 1.0, alignment);
}

void sky() {
	float horizon_blend = smoothstep(-0.08, 0.45, EYEDIR.y);
	vec3 upper_sky = mix(sky_horizon_color.rgb, sky_top_color.rgb, horizon_blend);
	vec3 lower_sky = mix(ground_horizon_color.rgb, ground_bottom_color.rgb, smoothstep(0.0, -0.55, EYEDIR.y));
	vec3 sky_color = mix(lower_sky, upper_sky, step(0.0, EYEDIR.y));

	float sun_disk = body_disk(EYEDIR, sun_direction, sun_disk_size);
	float sun_halo = body_halo(EYEDIR, sun_direction, sun_halo_size) * 0.32;
	float moon_disk = body_disk(EYEDIR, moon_direction, moon_disk_size);
	float moon_halo = body_halo(EYEDIR, moon_direction, 0.08) * 0.08;

	float sun_disk_strength = 3.0;
	float sun_halo_strength = 1.0;
	if (AT_CUBEMAP_PASS) {
		sun_disk_strength = radiance_sun_disk_strength;
		sun_halo_strength = radiance_sun_halo_strength;
	}

	sky_color += sun_color.rgb * (sun_disk * sun_disk_strength + sun_halo * sun_halo_strength) * sun_visibility;
	sky_color += moon_color.rgb * (moon_disk * 0.9 + moon_halo) * moon_visibility;
	COLOR = sky_color;
}
