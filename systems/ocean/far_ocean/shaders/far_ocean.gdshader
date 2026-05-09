shader_type spatial;
render_mode world_vertex_coords, cull_disabled, depth_prepass_alpha, blend_mix, shadows_disabled;

#define MAX_CASCADES 8
#define REFLECTANCE  0.02

global uniform vec4 water_color : source_color;
global uniform vec4 foam_color : source_color;

uniform float inner_radius = 150.0;
uniform float inner_fade_width = 96.0;
uniform float horizon_fade_start = 5200.0;
uniform float horizon_fade_end = 6800.0;
uniform float displacement_strength : hint_range(0.0, 4.0) = 1.0;
uniform float normal_strength : hint_range(0.0, 2.0) = 0.42;
uniform float roughness : hint_range(0.0, 1.0) = 0.65;
uniform float horizon_brightness : hint_range(0.0, 1.0) = 0.04;
uniform float specular_strength : hint_range(0.0, 1.0) = 0.55;
uniform float sea_state : hint_range(0.0, 2.0) = 0.0;
uniform float sea_state_influence : hint_range(0.0, 3.0) = 1.0;
uniform float foam_intensity : hint_range(0.0, 4.0) = 1.25;
uniform float foam_threshold : hint_range(0.0, 2.0) = 0.05;
uniform float foam_softness : hint_range(0.01, 2.0) = 0.35;
uniform int fragment_cascade_limit : hint_range(1, 8) = 3;
uniform float low_frequency_tile_length : hint_range(1.0, 512.0) = 64.0;
uniform float lod_blend_distance : hint_range(1.0, 4000.0) = 1200.0;
uniform float lod_curve : hint_range(0.25, 4.0) = 1.7;
uniform float far_swell_visibility : hint_range(0.0, 1.0) = 0.52;
uniform float far_wave_contrast : hint_range(0.0, 1.0) = 0.28;
uniform float far_foam_coverage : hint_range(0.0, 1.0) = 0.36;
uniform float far_foam_threshold_boost : hint_range(0.0, 1.0) = 0.18;

group_uniforms cascade_data;
uniform vec4 map_scales[MAX_CASCADES];
global uniform uint num_cascades;
global uniform sampler2DArray displacements;
global uniform sampler2DArray normals : hint_normal;
global uniform sampler2DArray previous_displacements;
global uniform sampler2DArray previous_normals : hint_normal;
global uniform float wave_blend_alpha;

varying float distance_to_camera;
varying vec2 ocean_uv;
varying float far_ocean_alpha;
varying float wave_height;
varying float foam_factor;
varying float fresnel;
varying float horizon_factor;

float get_cascade_lod_weight(vec4 scales, float distance_lod) {
	if (scales.z == 0.0 && scales.w == 0.0) {
		return 0.0;
	}

	float tile_length = 1.0 / max(min(scales.x, scales.y), 0.0001);
	float far_weight = smoothstep(low_frequency_tile_length * 0.55, low_frequency_tile_length * 1.35, tile_length);
	return mix(1.0, far_weight, distance_lod);
}

float get_distance_lod() {
	float linear_lod = smoothstep(inner_radius + inner_fade_width, inner_radius + inner_fade_width + lod_blend_distance, distance_to_camera);
	return pow(linear_lod, lod_curve);
}

void vertex() {
	ocean_uv = VERTEX.xz;
	distance_to_camera = length(VERTEX.xz - CAMERA_POSITION_WORLD.xz);
	float inner_fade = smoothstep(inner_radius, inner_radius + inner_fade_width, distance_to_camera);
	float horizon_fade = 1.0 - smoothstep(horizon_fade_start, horizon_fade_end, distance_to_camera);
	far_ocean_alpha = inner_fade * horizon_fade;
	horizon_factor = smoothstep(inner_radius + inner_fade_width, horizon_fade_end, distance_to_camera);
	float distance_lod = get_distance_lod();

	vec3 displacement = vec3(0.0);
	for (uint i = 0U; i < num_cascades; ++i) {
		vec4 scales = map_scales[i];
		float cascade_weight = get_cascade_lod_weight(scales, distance_lod);
		if (cascade_weight <= 0.0 || scales.z == 0.0) {
			continue;
		}
		vec3 coords = vec3(ocean_uv * scales.xy, float(i));
		vec3 previous_displacement = texture(previous_displacements, coords).xyz;
		vec3 current_displacement = texture(displacements, coords).xyz;
		displacement += mix(previous_displacement, current_displacement, wave_blend_alpha) * scales.z * cascade_weight;
	}

	float near_displacement_fade = min(exp(-(distance_to_camera - 150.0) * 0.007), 1.0);
	float ocean_state = clamp(sea_state * sea_state_influence, 0.0, 2.0);
	float swell_state = smoothstep(0.35, 1.35, ocean_state);
	float swell_visibility = far_swell_visibility * swell_state;
	float ocean_displacement_fade = max(near_displacement_fade, swell_visibility * distance_lod);
	float horizon_displacement_fade = 1.0 - smoothstep(horizon_fade_start * 0.7, horizon_fade_end, distance_to_camera);
	float wave_contrast = 1.0 + far_wave_contrast * swell_state * (1.0 - horizon_factor * 0.65);
	displacement.y = sign(displacement.y) * pow(abs(displacement.y) + 0.0001, mix(1.0, 0.86, far_wave_contrast * swell_state)) * wave_contrast;
	VERTEX += displacement * displacement_strength * ocean_displacement_fade * horizon_displacement_fade;
	wave_height = displacement.y;
}

void fragment() {
	float ocean_state = clamp(sea_state * sea_state_influence, 0.0, 2.0);
	float detail_blend = smoothstep(inner_radius + inner_fade_width * 0.25, inner_radius + inner_fade_width, distance_to_camera);
	float distance_lod = get_distance_lod();

	vec3 gradient = vec3(0.0);
	uint cascade_count = min(num_cascades, uint(fragment_cascade_limit));
	for (uint i = 0U; i < cascade_count; ++i) {
		vec4 scales = map_scales[i];
		float cascade_weight = get_cascade_lod_weight(scales, distance_lod);
		if (cascade_weight <= 0.0) {
			continue;
		}
		vec3 coords = vec3(ocean_uv * scales.xy, float(i));
		vec4 previous_normal_sample = texture(previous_normals, coords);
		vec4 current_normal_sample = texture(normals, coords);
		vec4 normal_sample = mix(previous_normal_sample, current_normal_sample, wave_blend_alpha);
		gradient += normal_sample.xyw * vec3(scales.ww, 1.0) * cascade_weight;
	}

	float foam_signal = gradient.z * 0.75 * foam_intensity;
	float foam_edge = foam_threshold + far_foam_threshold_boost * distance_lod * mix(0.55, 1.0, clamp(ocean_state, 0.0, 1.0));
	float foam_distance_fade = mix(1.0, far_foam_coverage, distance_lod);
	foam_factor = smoothstep(foam_edge, foam_edge + foam_softness, foam_signal) * exp(-distance_to_camera * 0.0075) * foam_distance_fade;
	vec3 surface_color = mix(water_color.rgb, foam_color.rgb, foam_factor);

	float matched_normal_strength = mix(1.0, normal_strength, detail_blend);
	float normal_distance_fade = mix(0.015, matched_normal_strength, exp(-distance_to_camera * 0.0175));
	float horizon_normal_fade = 1.0 - smoothstep(horizon_fade_start * 0.65, horizon_fade_end, distance_to_camera);
	gradient.xy *= normal_distance_fade * horizon_normal_fade;
	NORMAL = (VIEW_MATRIX * vec4(normalize(vec3(-gradient.x, 1.0, -gradient.y)), 0.0)).xyz;

	fresnel = mix(pow(1.0 - dot(VIEW, NORMAL), 5.0 * exp(-2.69 * roughness)) / (1.0 + 22.7 * pow(roughness, 1.5)), 1.0, REFLECTANCE);
	float near_water_roughness = clamp(roughness + (1.0 - fresnel) * foam_factor * 0.35, 0.0, 1.0);
	float far_water_roughness = clamp(roughness + foam_factor * 0.22 + ocean_state * 0.015 + horizon_factor * 0.04, 0.0, 1.0);

	vec3 horizon_color = water_color.rgb * (1.0 + horizon_brightness);
	ALBEDO = mix(surface_color, horizon_color, horizon_factor * 0.45);
	ROUGHNESS = mix(near_water_roughness, far_water_roughness, detail_blend);
	SPECULAR = clamp(specular_strength, 0.0, 1.0);
	ALPHA = far_ocean_alpha;
}

float smith_masking_shadowing(in float cos_theta, in float alpha) {
	float a = cos_theta / (alpha * sqrt(1.0 - cos_theta * cos_theta));
	float a_sq = a * a;
	return a < 1.6 ? (1.0 - 1.259 * a + 0.396 * a_sq) / (3.535 * a + 2.181 * a_sq) : 0.0;
}

float ggx_distribution(in float cos_theta, in float alpha) {
	float a_sq = alpha * alpha;
	float d = 1.0 + (a_sq - 1.0) * cos_theta * cos_theta;
	return a_sq / (PI * d * d);
}

void light() {
	vec3 halfway = normalize(LIGHT + VIEW);
	float dot_nl = max(dot(NORMAL, LIGHT), 2e-5);
	float dot_nv = max(dot(NORMAL, VIEW), 2e-5);

	float light_mask = smith_masking_shadowing(roughness, dot_nv);
	float view_mask = smith_masking_shadowing(roughness, dot_nl);
	float microfacet_distribution = ggx_distribution(dot(NORMAL, halfway), roughness);
	float geometric_attenuation = 1.0 / (1.0 + light_mask + view_mask);
	SPECULAR_LIGHT += fresnel * microfacet_distribution * geometric_attenuation / (4.0 * dot_nv + 0.1) * ATTENUATION * LIGHT_COLOR * specular_strength;

	const vec3 sss_modifier = vec3(0.9, 1.15, 0.85);
	float sss_height = max(0.0, wave_height + 2.5) * pow(max(dot(LIGHT, -VIEW), 0.0), 4.0) * pow(0.5 - 0.5 * dot(LIGHT, NORMAL), 3.0);
	float sss_near = 0.5 * pow(dot_nv, 2.0);
	float lambertian = 0.5 * dot_nl;
	vec3 water_scatter = water_color.rgb * sss_modifier;
	vec3 water_diffuse = (sss_height + sss_near) * water_scatter / (1.0 + light_mask) + lambertian * water_color.rgb;
	DIFFUSE_LIGHT += mix(water_diffuse, foam_color.rgb, foam_factor) * (1.0 - fresnel) * ATTENUATION * LIGHT_COLOR;
}
