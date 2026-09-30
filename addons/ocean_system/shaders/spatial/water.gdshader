shader_type spatial;
render_mode world_vertex_coords, cull_disabled, shadows_disabled;
/**
 * Water uses Godot's built-in spatial PBR lighting. The shader only provides
 * displacement, normals, foam color, and dynamic material properties.
 */

#define MAX_CASCADES 8
#define MAX_NEAR_HULLS 8

uniform vec4 water_color : source_color;
uniform vec4 foam_color : source_color;

uniform float water_diffuse_strength : hint_range(0.0, 1.0) = 0.08;
uniform vec4 water_scatter_color : source_color = vec4(0.045, 0.18, 0.20, 1.0);
uniform float clear_roughness : hint_range(0.0, 1.0) = 0.10;
uniform float foam_roughness : hint_range(0.0, 1.0) = 0.24;
uniform float clear_specular : hint_range(0.0, 1.0) = 0.25;
uniform float foam_specular : hint_range(0.0, 1.0) = 0.08;
uniform float slope_roughness_strength : hint_range(0.0, 4.0) = 0.55;
uniform float normal_strength : hint_range(0.0, 1.0) = 1.0; // Global normal strength
uniform float foam_intensity : hint_range(0.0, 4.0) = 1.25;
uniform float foam_threshold : hint_range(0.0, 2.0) = 0.05;
uniform float foam_softness : hint_range(0.01, 2.0) = 0.35;
uniform vec4 sky_top_color : source_color = vec4(0.12, 0.42, 0.78, 1.0);
uniform vec4 sky_horizon_color : source_color = vec4(0.58, 0.78, 0.94, 1.0);
uniform vec4 sky_ground_horizon_color : source_color = vec4(0.16, 0.24, 0.28, 1.0);
uniform vec4 sky_ground_bottom_color : source_color = vec4(0.01, 0.02, 0.03, 1.0);
uniform vec3 sky_sun_direction = vec3(0.0, 0.2, -1.0);
uniform vec4 sky_sun_color : source_color = vec4(1.0, 0.92, 0.72, 1.0);
uniform float sky_sun_visibility : hint_range(0.0, 1.0) = 1.0;
uniform bool sky_reflection_enabled = true;
uniform float sky_reflection_strength : hint_range(0.0, 2.0) = 0.55;
uniform float sky_reflection_fresnel_power : hint_range(0.25, 8.0) = 5.0;
uniform float sky_reflection_f0 : hint_range(0.0, 0.12) = 0.02;
uniform float sky_horizon_boost : hint_range(0.0, 3.0) = 0.85;
uniform float sky_reflection_roughness_strength : hint_range(0.0, 2.0) = 0.75;
uniform float sky_reflection_far_roughness : hint_range(0.0, 1.0) = 0.35;
uniform float sun_glitter_strength : hint_range(0.0, 4.0) = 0.42;
uniform float sun_glitter_power : hint_range(8.0, 512.0) = 64.0;
uniform float sun_glitter_low_sun_boost : hint_range(0.0, 4.0) = 1.4;
uniform float sun_scatter_strength : hint_range(0.0, 2.0) = 0.24;
uniform float sun_scatter_base : hint_range(0.0, 1.0) = 0.08;
uniform float sun_scatter_phase_power : hint_range(0.25, 8.0) = 2.0;
uniform float sun_scatter_normal_power : hint_range(0.25, 4.0) = 0.75;
uniform float sun_scatter_slope_strength : hint_range(0.0, 2.0) = 0.65;
uniform float sun_scatter_distance_strength : hint_range(0.0, 2.0) = 0.25;
uniform bool crest_glow_enabled = true;
uniform vec4 crest_glow_color : source_color = vec4(0.08, 0.58, 0.46, 1.0);
uniform float crest_glow_strength : hint_range(0.0, 4.0) = 0.75;
uniform float crest_glow_emission_strength : hint_range(0.0, 2.0) = 0.35;
uniform float crest_height_start : hint_range(-2.0, 4.0) = 0.18;
uniform float crest_height_end : hint_range(-2.0, 6.0) = 0.85;
uniform float crest_slope_start : hint_range(0.0, 4.0) = 0.18;
uniform float crest_slope_end : hint_range(0.0, 8.0) = 0.85;
uniform float crest_back_view_power : hint_range(0.25, 8.0) = 1.6;
uniform float crest_back_normal_power : hint_range(0.25, 8.0) = 1.25;
uniform float crest_low_sun_start : hint_range(-0.1, 1.0) = 0.02;
uniform float crest_low_sun_end : hint_range(-0.1, 1.0) = 0.38;
uniform int water_debug_view : hint_range(0, 13) = 0;
uniform bool planar_reflection_enabled = false;
uniform sampler2D planar_reflection_texture;
uniform mat4 planar_reflection_view_projection;
uniform float planar_reflection_strength : hint_range(0.0, 1.0) = 0.0;
uniform float planar_reflection_distortion : hint_range(0.0, 0.08) = 0.018;
uniform float planar_reflection_fresnel_power : hint_range(0.25, 8.0) = 4.0;
uniform float planar_reflection_plane_y = 0.0;
uniform bool use_bicubic_normals = true;
uniform int fragment_cascade_limit : hint_range(1, 8) = 3;
uniform bool enable_far_lod = true;
uniform float near_ocean_radius = 256.0;
uniform float far_lod_radius = 7000.0;
uniform float far_lod_blend_distance : hint_range(1.0, 4000.0) = 1400.0;
uniform float far_lod_curve : hint_range(0.25, 4.0) = 1.8;
uniform float far_low_frequency_tile_length : hint_range(1.0, 512.0) = 32.0;
uniform float far_normal_strength : hint_range(0.0, 2.0) = 0.14;
uniform float far_foam_coverage : hint_range(0.0, 1.0) = 0.24;
uniform float far_foam_threshold_boost : hint_range(0.0, 1.0) = 0.2; // Historical name: widens far foam softness.
// Hulls near the camera (see OceanSystem._update_hull_cutouts and HullProfile).
uniform int near_hull_count = 0;
uniform vec4 near_hull_world_to_local_x[MAX_NEAR_HULLS]; // rows of the world-to-hull affine transform: xyz basis row, w origin
uniform vec4 near_hull_world_to_local_y[MAX_NEAR_HULLS];
uniform vec4 near_hull_world_to_local_z[MAX_NEAR_HULLS];
uniform vec4 near_hull_spheres[MAX_NEAR_HULLS]; // world center xyz, (radius + feather)^2
uniform vec4 near_hull_rects[MAX_NEAR_HULLS];   // profile min z, min y, 1 / length, 1 / height
uniform vec4 near_hull_params[MAX_NEAR_HULLS];  // profile layer, center x, feather (m), edge foam
uniform sampler2DArray hull_profiles : filter_linear, repeat_disable; // R = inner half-width over (z, y)

// Interaction simulation (WaterInteractionSim): rgba16f h, eta, foam, wrap-around addressed.
uniform bool interaction_enabled = false;
uniform sampler2D interaction_render : repeat_enable, filter_linear;
uniform vec4 interaction_window = vec4(0.0); // window center x, center z, fade start, fade end (Chebyshev distance from center, m)
uniform float interaction_inv_extent = 0.0;  // 1 / window size (m)
uniform float interaction_cell_size = 0.5;

group_uniforms cascade_data;
uniform vec4 map_scales[MAX_CASCADES];               // Scales for displacement/normal maps. Packed: [uv scale, displacement scale, normal scale]
uniform vec4 spectrum_blend_states[MAX_CASCADES];    // Packed: [active layer, pending layer, active weight, pending weight]; pending weight is 0 unless a spectrum crossfade is running
uniform int num_cascades = 0;
uniform sampler2DArray displacements;         // Each layer represents one wave cascade.
uniform sampler2DArray normals : hint_normal; // Each layer represents one wave cascade.
uniform sampler2DArray previous_displacements;
uniform sampler2DArray previous_normals : hint_normal;
uniform float wave_blend_alpha = 1.0;

varying float foam_factor;
varying float distance_to_camera;
varying float distance_lod;
varying vec3 water_world_position;

float get_distance_lod(float dist) {
	if (!enable_far_lod) {
		return 0.0;
	}
	float linear_lod = smoothstep(near_ocean_radius * 0.75, near_ocean_radius + far_lod_blend_distance, dist);
	return pow(linear_lod, far_lod_curve);
}

float get_cascade_lod_weight(vec4 scales, float lod) {
	if (!enable_far_lod || lod <= 0.0) {
		return 1.0;
	}
	float tile_length = 1.0 / max(min(scales.x, scales.y), 0.0001);
	float far_weight = smoothstep(far_low_frequency_tile_length * 0.55, far_low_frequency_tile_length * 1.35, tile_length);
	return mix(1.0, far_weight, lod);
}

/** 1 inside the interaction window, fading to 0 before its absorbing border. */
float interaction_fade(vec2 xz) {
	vec2 from_center = abs(xz - interaction_window.xy);
	return 1.0 - smoothstep(interaction_window.z, interaction_window.w, max(from_center.x, from_center.y));
}

/** Interaction render texel at world XZ; repeat addressing matches the wrap-around grid. */
vec4 sample_interaction(vec2 xz) {
	return textureLod(interaction_render, xz * interaction_inv_extent, 0.0);
}

void vertex() {
	UV = VERTEX.xz;
	distance_to_camera = length(VERTEX.xz - CAMERA_POSITION_WORLD.xz);
	distance_lod = get_distance_lod(distance_to_camera);

	// Read displacements from displacement maps.
	vec3 displacement = vec3(0);
	for (uint i = 0U; i < uint(num_cascades); ++i) {
		vec4 scales = map_scales[i];
		if (scales.z == 0.0)
			continue;
		float cascade_weight = get_cascade_lod_weight(scales, distance_lod);
		if (cascade_weight <= 0.0)
			continue;
		vec4 blend_state = spectrum_blend_states[i];
		vec3 active_coords = vec3(UV*scales.xy, blend_state.x);
		vec3 cascade_displacement = mix(texture(previous_displacements, active_coords).xyz, texture(displacements, active_coords).xyz, wave_blend_alpha) * blend_state.z;
		// Uniform branch: the pending spectrum is only sampled during a crossfade.
		if (blend_state.w > 0.0) {
			vec3 pending_coords = vec3(UV*scales.xy, blend_state.y);
			cascade_displacement += mix(texture(previous_displacements, pending_coords).xyz, texture(displacements, pending_coords).xyz, wave_blend_alpha) * blend_state.w;
		}
		displacement += cascade_displacement * scales.z * cascade_weight;
	}
	VERTEX += displacement;
	if (interaction_enabled) {
		// Sampled at the displaced position: the simulation lives at final surface positions.
		VERTEX.y += sample_interaction(VERTEX.xz).x * interaction_fade(VERTEX.xz);
	}
	water_world_position = VERTEX;
}

/** Filter weights for a cubic B-spline. */
vec4 cubic_weights(float a) {
	float a2 = a*a;
	float a3 = a2*a;
	
	float w0 =-a3     + a2*3.0 - a*3.0 + 1.0;
	float w1 = a3*3.0 - a2*6.0         + 4.0;
	float w2 =-a3*3.0 + a2*3.0 + a*3.0 + 1.0;
	float w3 = a3;
	return vec4(w0, w1, w2, w3) / 6.0;
}

/** Performs bicubic B-spline filtering on the provided sampler. */
// Source: https://developer.nvidia.com/gpugems/gpugems2/part-iii-high-quality-rendering/chapter-20-fast-third-order-texture-filtering
vec4 texture_bicubic(in sampler2DArray sampler, in vec3 uvw) {
	vec2 dims = vec2(textureSize(sampler, 0).xy);
	vec2 dims_inv = 1.0 / dims;
	uvw.xy = uvw.xy*dims + 0.5;
	
	vec2 fuv = fract(uvw.xy);
	vec4 wx = cubic_weights(fuv.x);
	vec4 wy = cubic_weights(fuv.y);

	vec4 g = vec4(wx.xz + wx.yw, wy.xz + wy.yw);
	vec4 h = (vec4(wx.yw, wy.yw) / g + vec2(-1.5, 0.5).xyxy + floor(uvw.xy).xxyy)*dims_inv.xxyy;
	vec2 w = g.xz / (g.xz + g.yw);
    return mix(
		mix(texture(sampler, vec3(h.yw, uvw.z)), texture(sampler, vec3(h.xw, uvw.z)), w.x),
		mix(texture(sampler, vec3(h.yz, uvw.z)), texture(sampler, vec3(h.xz, uvw.z)), w.x), w.y); 
}

/** Normal/foam sample of one spectrum layer, blended between the previous and current FFT output. */
vec4 sample_normal_layer(vec3 coords, float bilinear_weight) {
	vec4 previous_sample = texture(previous_normals, coords);
	vec4 current_sample = texture(normals, coords);
	if (use_bicubic_normals) {
		previous_sample = mix(texture_bicubic(previous_normals, coords), previous_sample, bilinear_weight);
		current_sample = mix(texture_bicubic(normals, coords), current_sample, bilinear_weight);
	}
	return mix(previous_sample, current_sample, wave_blend_alpha);
}

float saturate(float value) {
	return clamp(value, 0.0, 1.0);
}

vec3 safe_normalize_vec3(vec3 value, vec3 fallback) {
	if (dot(value, value) < 0.000001) {
		return fallback;
	}
	return normalize(value);
}

float safe_smoothstep(float edge0, float edge1, float value) {
	return smoothstep(edge0, max(edge1, edge0 + 0.0001), value);
}

float sky_low_sun_factor(vec3 sun_dir) {
	return sky_sun_visibility * (1.0 - safe_smoothstep(crest_low_sun_start, crest_low_sun_end, sun_dir.y));
}

float fresnel_schlick(float no_v, float f0, float power) {
	return f0 + (1.0 - f0) * pow(1.0 - saturate(no_v), power);
}

vec3 sample_procedural_environment(vec3 direction) {
	float upper_blend = smoothstep(0.0, 0.55, direction.y);
	vec3 upper_sky = mix(sky_horizon_color.rgb * sky_horizon_boost, sky_top_color.rgb, upper_blend);

	float lower_blend = smoothstep(0.0, 0.55, -direction.y);
	vec3 lower_sky = mix(sky_ground_horizon_color.rgb, sky_ground_bottom_color.rgb, lower_blend);

	float horizon_blend = smoothstep(-0.035, 0.055, direction.y);
	return mix(lower_sky, upper_sky, horizon_blend);
}

vec3 sample_rough_procedural_environment(vec3 direction, float roughness) {
	float rough = saturate(roughness);
	vec3 sharp = sample_procedural_environment(direction);
	vec3 upper_dir = safe_normalize_vec3(vec3(direction.x, direction.y + rough * 0.65, direction.z), direction);
	vec3 lower_dir = safe_normalize_vec3(vec3(direction.x, direction.y - rough * 0.45, direction.z), direction);
	vec3 center_dir = safe_normalize_vec3(mix(direction, vec3(0.0, 1.0, 0.0), rough * 0.25), direction);
	vec3 broad = sample_procedural_environment(center_dir) * 0.5
		+ sample_procedural_environment(upper_dir) * 0.3
		+ sample_procedural_environment(lower_dir) * 0.2;
	return mix(sharp, broad, smoothstep(0.05, 0.55, rough));
}

float ggx_distribution(float no_h, float roughness) {
	float alpha = max(roughness * roughness, 0.0009);
	float alpha2 = alpha * alpha;
	float denom = no_h * no_h * (alpha2 - 1.0) + 1.0;
	return alpha2 / max(3.14159265 * denom * denom, 0.00001);
}

float smith_ggx_visibility(float no_v, float no_l, float roughness) {
	float alpha = roughness * roughness;
	float k = (alpha + 1.0) * (alpha + 1.0) * 0.125;
	float gv = no_v / max(no_v * (1.0 - k) + k, 0.0001);
	float gl = no_l / max(no_l * (1.0 - k) + k, 0.0001);
	return gv * gl;
}

void fragment() {
	// Hide water inside nearby hulls. The test runs on the water-surface point
	// itself, so it is view-independent; pitch and roll come from the transform.
	float hull_edge_foam = 0.0;
	for (int i = 0; i < min(near_hull_count, MAX_NEAR_HULLS); ++i) {
		vec3 to_center = water_world_position - near_hull_spheres[i].xyz;
		if (dot(to_center, to_center) > near_hull_spheres[i].w)
			continue; // Far from this hull.
		vec4 world_position = vec4(water_world_position, 1.0);
		vec3 local = vec3(dot(near_hull_world_to_local_x[i], world_position), dot(near_hull_world_to_local_y[i], world_position), dot(near_hull_world_to_local_z[i], world_position));
		vec2 profile_uv = (local.zy - near_hull_rects[i].xy) * near_hull_rects[i].zw;
		if (any(lessThan(profile_uv, vec2(0.0))) || any(greaterThan(profile_uv, vec2(1.0))))
			continue; // Beyond the bow/stern, above the hull or below the keel.
		vec4 params = near_hull_params[i];
		// Explicit LOD: this lookup sits in divergent control flow, where implicit derivatives are undefined.
		float half_width = textureLod(hull_profiles, vec3(profile_uv, params.x), 0.0).r;
		float hull_sdf = abs(local.x - params.y) - half_width; // < 0 inside the hull
		if (hull_sdf < 0.0) {
			discard;
		}
		hull_edge_foam = max(hull_edge_foam, (1.0 - smoothstep(0.0, max(params.z, 0.001), hull_sdf)) * params.w);
	}

	// Interaction simulation slope and foam (wakes, bow waves, splashes).
	vec2 interaction_gradient = vec2(0.0);
	float interaction_foam = 0.0;
	if (interaction_enabled) {
		vec2 xz = water_world_position.xz;
		float fade = interaction_fade(xz);
		if (fade > 0.0) {
			float e = interaction_cell_size;
			float h_left = sample_interaction(xz - vec2(e, 0.0)).x;
			float h_right = sample_interaction(xz + vec2(e, 0.0)).x;
			float h_back = sample_interaction(xz - vec2(0.0, e)).x;
			float h_front = sample_interaction(xz + vec2(0.0, e)).x;
			interaction_gradient = vec2(h_right - h_left, h_front - h_back) / (2.0 * e) * fade;
			interaction_foam = sample_interaction(xz).z * fade;
		}
	}

	float dist = length(water_world_position.xz - CAMERA_POSITION_WORLD.xz);
	float fragment_distance_lod = get_distance_lod(dist);
	vec2 gradient = vec2(0.0);
	float foam_signal = 0.0;
	float wave_slope = 0.0;
	foam_factor = 0.0;
	float raw_wave_slope = 0.0;
	vec3 world_normal = vec3(0.0, 1.0, 0.0);
	float sky_reflection_amount = 0.0;
	vec3 reflected_sky_color = vec3(0.0);
	vec3 sky_reflection_radiance = vec3(0.0);
	vec3 planar_reflection_radiance = vec3(0.0);
	vec3 sun_scatter_radiance = vec3(0.0);
	float sun_glitter_amount = 0.0;
	float sun_scatter_amount = 0.0;
	float sun_scatter_no_l = 0.0;
	float view_sun_phase = 0.0;
	float micro_slope_energy = 0.0;
	float effective_reflection_roughness = 0.0;
	float crest_height_mask = 0.0;
	float crest_slope_mask = 0.0;
	float crest_backlight_mask = 0.0;
	float crest_glow_mask = 0.0;
	vec2 macro_gradient = vec2(0.0);
	vec3 macro_world_normal = vec3(0.0, 1.0, 0.0);

	if (num_cascades > 0) {
		float map_size = float(textureSize(normals, 0).x);
		// Read foam and normal information from normal maps.
		uint cascade_count = min(uint(num_cascades), uint(fragment_cascade_limit));
		for (uint i = 0U; i < cascade_count; ++i) {
			vec4 scales = map_scales[i];
			float cascade_weight = get_cascade_lod_weight(scales, fragment_distance_lod);
			if (cascade_weight <= 0.0)
				continue;
			vec4 blend_state = spectrum_blend_states[i];
			// Mix between bicubic and bilinear filtering depending on the world space pixels per meter.
			// This is dependent on the tile size as well as displacement/normal map resolution.
			float pixels_per_meter = map_size * min(scales.x, scales.y);
			float bilinear_weight = min(1.0, pixels_per_meter * 0.1);
			vec4 active_sample = sample_normal_layer(vec3(UV*scales.xy, blend_state.x), bilinear_weight);
			vec2 cascade_gradient = active_sample.xy * blend_state.z;
			float cascade_foam = active_sample.w;
			// Uniform branch: the pending spectrum is only sampled during a crossfade.
			if (blend_state.w > 0.0) {
				vec4 pending_sample = sample_normal_layer(vec3(UV*scales.xy, blend_state.y), bilinear_weight);
				cascade_gradient += pending_sample.xy * blend_state.w;
				// Foam is a non-negative mask, so it crossfades linearly rather than by equal power.
				cascade_foam = mix(active_sample.w, pending_sample.w, blend_state.w / (blend_state.z + blend_state.w));
			}
			vec2 normal_signal = cascade_gradient * scales.w * cascade_weight;
			float tile_length = 1.0 / max(min(scales.x, scales.y), 0.0001);
			float macro_weight = smoothstep(18.0, 80.0, tile_length);
			gradient += normal_signal;
			foam_signal += cascade_foam * cascade_weight;
			macro_gradient += normal_signal * macro_weight;
			micro_slope_energy += length(normal_signal) * (1.0 - macro_weight);
		}

		raw_wave_slope = length(gradient);
		micro_slope_energy = saturate(micro_slope_energy * 0.75 + raw_wave_slope * 0.15);
		macro_world_normal = normalize(vec3(-macro_gradient.x * 0.45, 1.0, -macro_gradient.y * 0.45));
		float visible_foam_signal = foam_signal * 0.75 * foam_intensity;
		float far_foam_softness = foam_softness * (1.0 + far_foam_threshold_boost * fragment_distance_lod * 4.0);
		float foam_distance_fade = mix(1.0, far_foam_coverage, fragment_distance_lod);
		foam_factor = smoothstep(foam_threshold, foam_threshold + far_foam_softness, visible_foam_signal) * exp(-dist*0.0075) * foam_distance_fade;
		wave_slope = clamp(length(gradient) * slope_roughness_strength, 0.0, 1.0);

		float near_normal_fade = exp(-dist*0.0175);
		float far_normal_fade = far_normal_strength * 0.35;
		gradient *= normal_strength * mix(max(near_normal_fade, 0.015), far_normal_fade, fragment_distance_lod);
		// Added after the distance fade, which exists to hide high-frequency FFT detail;
		// simulated waves are long and stay near the camera.
		gradient += interaction_gradient * normal_strength;
		world_normal = normalize(vec3(-gradient.x, 1.0, -gradient.y));
		NORMAL = (VIEW_MATRIX * vec4(world_normal, 0.0)).xyz;
	}
	foam_factor = max(max(foam_factor, hull_edge_foam), interaction_foam);

	vec3 water_body_albedo = water_color.rgb * water_diffuse_strength;
	vec3 base_albedo = mix(water_body_albedo, foam_color.rgb, foam_factor);
	vec3 view_direction_world = safe_normalize_vec3(CAMERA_POSITION_WORLD - water_world_position, vec3(0.0, 0.0, 1.0));
	vec3 sun_dir = safe_normalize_vec3(sky_sun_direction, vec3(0.0, 0.2, -1.0));
	vec3 reflection_direction = reflect(-view_direction_world, world_normal);
	float low_sun = sky_low_sun_factor(sun_dir);
	float clear_water_mask = 1.0 - foam_factor * 0.85;
	float no_v = saturate(dot(world_normal, view_direction_world));
	effective_reflection_roughness = saturate(clear_roughness + wave_slope * sky_reflection_roughness_strength + fragment_distance_lod * sky_reflection_far_roughness);

	if (sky_reflection_enabled && sky_reflection_strength > 0.0) {
		reflected_sky_color = sample_rough_procedural_environment(reflection_direction, effective_reflection_roughness);
		float sky_fresnel = fresnel_schlick(no_v, sky_reflection_f0, sky_reflection_fresnel_power);
		float rough_fresnel_floor = sky_reflection_f0 + effective_reflection_roughness * (0.05 + micro_slope_energy * 0.08);
		sky_reflection_amount = saturate(sky_reflection_strength * max(sky_fresnel, rough_fresnel_floor) * clear_water_mask * mix(1.0, 1.18, fragment_distance_lod));
		sky_reflection_radiance = reflected_sky_color * sky_reflection_amount;
	}

	if (sun_glitter_strength > 0.0) {
		vec3 half_vector = safe_normalize_vec3(view_direction_world + sun_dir, world_normal);
		float no_l = saturate(dot(world_normal, sun_dir));
		float no_h = saturate(dot(world_normal, half_vector));
		float vo_h = saturate(dot(view_direction_world, half_vector));
		float glitter_roughness = max(effective_reflection_roughness, 0.035);
		float glitter_distribution = ggx_distribution(no_h, glitter_roughness);
		float glitter_visibility = smith_ggx_visibility(no_v, no_l, glitter_roughness);
		float glitter_fresnel = fresnel_schlick(vo_h, sky_reflection_f0, 5.0);
		float glitter_low_boost = mix(1.0, 1.0 + sun_glitter_low_sun_boost, low_sun);
		float glitter_focus = pow(saturate(dot(reflection_direction, sun_dir)), max(sun_glitter_power * 0.25, 1.0));
		sun_glitter_amount = saturate(glitter_distribution * glitter_visibility * glitter_fresnel * no_l * 0.02)
			* glitter_focus * sun_glitter_strength * sky_sun_visibility * glitter_low_boost * clear_water_mask;
	}

	sun_scatter_no_l = pow(saturate(dot(macro_world_normal, sun_dir)), sun_scatter_normal_power);
	view_sun_phase = pow(saturate(dot(view_direction_world, sun_dir)), sun_scatter_phase_power);
	float scatter_slope = mix(1.0, 0.5 + micro_slope_energy, sun_scatter_slope_strength);
	float scatter_distance = 1.0 + fragment_distance_lod * sun_scatter_distance_strength;
	sun_scatter_amount = sun_scatter_strength * sky_sun_visibility * sun_scatter_no_l * (sun_scatter_base + view_sun_phase) * scatter_slope * scatter_distance * clear_water_mask;
	sun_scatter_radiance = water_scatter_color.rgb * sky_sun_color.rgb * sun_scatter_amount;

	if (planar_reflection_enabled && planar_reflection_strength > 0.0) {
		vec3 reflection_project_position = vec3(water_world_position.x, planar_reflection_plane_y, water_world_position.z);
		vec4 reflection_clip = planar_reflection_view_projection * vec4(reflection_project_position, 1.0);
		float reflection_w = reflection_clip.w;
		if (abs(reflection_w) < 0.0001) {
			reflection_w = 0.0001;
		}
		vec2 reflection_uv = reflection_clip.xy / reflection_w * 0.5 + 0.5;
		reflection_uv.y = 1.0 - reflection_uv.y;
		reflection_uv += gradient * planar_reflection_distortion;
		vec2 reflection_bounds = step(vec2(0.0), reflection_uv) * step(reflection_uv, vec2(1.0));
		float reflection_in_bounds = reflection_bounds.x * reflection_bounds.y * step(0.0001, reflection_clip.w);
		vec4 reflected_sample = texture(planar_reflection_texture, reflection_uv);
		float view_dot = clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0);
		float fresnel = pow(1.0 - view_dot, planar_reflection_fresnel_power);
		float water_reflectance = sky_reflection_f0 + (1.0 - sky_reflection_f0) * fresnel;
		float foam_mask = 1.0 - foam_factor * 0.85;
		float reflected_geometry_mask = reflected_sample.a;
		float reflection_amount = planar_reflection_strength * water_reflectance * foam_mask * reflection_in_bounds * reflected_geometry_mask;
		planar_reflection_radiance = reflected_sample.rgb * reflection_amount;
	}

	vec3 crest_emission = vec3(0.0);
	if (crest_glow_enabled && crest_glow_strength > 0.0) {
		float height_above_water = water_world_position.y - planar_reflection_plane_y;
		crest_height_mask = safe_smoothstep(crest_height_start, crest_height_end, height_above_water);
		crest_slope_mask = safe_smoothstep(crest_slope_start, crest_slope_end, raw_wave_slope);
		float back_view = pow(saturate(-dot(view_direction_world, sun_dir)), crest_back_view_power);
		float back_normal = pow(saturate(dot(-world_normal, sun_dir)), crest_back_normal_power);
		crest_backlight_mask = back_view * back_normal * low_sun;
		crest_glow_mask = crest_height_mask * crest_slope_mask * crest_backlight_mask * clear_water_mask;
		vec3 crest_light = crest_glow_color.rgb * sky_sun_color.rgb;
		crest_emission = crest_light * crest_glow_mask * crest_glow_strength * crest_glow_emission_strength;
	}

	if (water_debug_view > 0) {
		vec3 debug_color = vec3(0.0);
		if (water_debug_view == 1) {
			debug_color = vec3(sky_reflection_amount);
		} else if (water_debug_view == 2) {
			debug_color = reflected_sky_color;
		} else if (water_debug_view == 3) {
			debug_color = vec3(sun_glitter_amount);
		} else if (water_debug_view == 4) {
			debug_color = vec3(crest_height_mask);
		} else if (water_debug_view == 5) {
			debug_color = vec3(crest_slope_mask);
		} else if (water_debug_view == 6) {
			debug_color = vec3(crest_backlight_mask);
		} else if (water_debug_view == 7) {
			debug_color = vec3(crest_glow_mask);
		} else if (water_debug_view == 8) {
			debug_color = vec3(reflection_direction.y * 0.5 + 0.5);
		} else if (water_debug_view == 9) {
			debug_color = vec3(effective_reflection_roughness);
		} else if (water_debug_view == 10) {
			debug_color = vec3(sun_scatter_amount);
		} else if (water_debug_view == 11) {
			debug_color = vec3(sun_scatter_no_l);
		} else if (water_debug_view == 12) {
			debug_color = vec3(view_sun_phase);
		} else if (water_debug_view == 13) {
			debug_color = vec3(micro_slope_energy);
		}
		ALBEDO = debug_color;
		METALLIC = 0.0;
		ROUGHNESS = 1.0;
		SPECULAR = 0.0;
		EMISSION = vec3(0.0);
	} else {
		ALBEDO = base_albedo;
		METALLIC = 0.0;
		ROUGHNESS = mix(clear_roughness, foam_roughness, max(foam_factor, wave_slope));
		SPECULAR = mix(clear_specular, foam_specular, foam_factor);
		EMISSION = sky_reflection_radiance + planar_reflection_radiance + sky_sun_color.rgb * sun_glitter_amount + sun_scatter_radiance + crest_emission;
	}
}
