shader_type spatial;
render_mode world_vertex_coords, cull_disabled;
/**
 * Lights (the sun) shade the water in light(): Lambert diffuse and a GGX
 * specular highlight whose roughness includes the wave slopes a pixel does not
 * resolve, so glints are sharp up close and merge into a broad sun path in the
 * distance. Sky and planar reflections are computed here and added as EMISSION;
 * SPECULAR = 0 turns off the engine's own sky reflection, which would double them.
 */

#define MAX_CASCADES 8
#define MAX_NEAR_HULLS 8
#define MAX_LOD_LEVELS 16

uniform vec4 water_color : source_color;
uniform vec4 foam_color : source_color;

uniform float water_diffuse_strength : hint_range(0.0, 1.0) = 0.08;
uniform vec4 water_scatter_color : source_color = vec4(0.045, 0.18, 0.20, 1.0);
uniform float clear_roughness : hint_range(0.0, 1.0) = 0.10;
uniform float foam_roughness : hint_range(0.0, 1.0) = 0.24;
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
// Clouds from the sky source (SkySystem.get_cloud_cubemap()): rgb premultiplied
// radiance, a opacity. Set at runtime by OceanSystem.
uniform bool sky_clouds_enabled = false;
uniform samplerCube sky_cloud_cubemap : filter_linear;
uniform bool sky_reflection_enabled = true;
uniform float sky_reflection_strength : hint_range(0.0, 2.0) = 1.0;
uniform float sky_reflection_fresnel_power : hint_range(0.25, 8.0) = 5.0;
uniform float sky_reflection_f0 : hint_range(0.0, 0.12) = 0.02;
uniform float sky_horizon_boost : hint_range(0.0, 3.0) = 0.85;
uniform float sun_specular_strength : hint_range(0.0, 4.0) = 1.0;
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
uniform int water_debug_view : hint_range(0, 14) = 0;
uniform bool planar_reflection_enabled = false;
uniform sampler2D planar_reflection_texture;
uniform mat4 planar_reflection_view_projection;
uniform float planar_reflection_strength : hint_range(0.0, 1.0) = 0.0; // how much reflected geometry covers the sky behind it
uniform float planar_reflection_plane_y = 0.0;
uniform bool use_bicubic_normals = true;
uniform int fragment_cascade_limit : hint_range(1, 8) = 3;
// Far-ocean shading fade (foam, reflection): 0 near, 1 far.
uniform float far_lod_start_distance = 192.0;
uniform float far_lod_blend_distance : hint_range(1.0, 4000.0) = 1400.0;
uniform float far_lod_curve : hint_range(0.25, 4.0) = 1.8;
// CDLOD mesh (OceanSystem._update_lod_grid). Off for the editor's preview plane.
uniform bool lod_grid_enabled = false;
uniform float lod_ranges[MAX_LOD_LEVELS];       // beyond range(L), level-L vertices sit on the level L + 1 lattice
uniform float lod_morph_starts[MAX_LOD_LEVELS]; // level-L vertices morph between this and range(L)
uniform int lod_top_level = 0;
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
uniform float near_hull_top_offsets[MAX_NEAR_HULLS]; // cutout reach above the station top, in profile heights
uniform sampler2DArray hull_profiles : filter_linear, repeat_disable; // R = inner half-width over (z, y), B = station top

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
// Displacement maps carry mip chains: coarse vertices read prefiltered waves.
uniform sampler2DArray displacements : filter_linear_mipmap, repeat_enable; // Each layer represents one wave cascade.
// Normal maps: xy mean slope, z mean squared slope, w foam; full mip chain (mip_downsample.glsl).
uniform sampler2DArray normals : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable; // Each layer represents one wave cascade.
uniform sampler2DArray previous_displacements : filter_linear_mipmap, repeat_enable;
uniform sampler2DArray previous_normals : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform float wave_blend_alpha = 1.0;

varying float foam_factor;
varying vec3 water_world_position;
// Fragment -> light(): multiplies the specular highlight (foam covers it).
varying float light_specular_scale;

float get_distance_lod(float dist) {
	float linear_lod = smoothstep(far_lod_start_distance, far_lod_start_distance + far_lod_blend_distance, dist);
	return pow(linear_lod, far_lod_curve);
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
	// Vertex spacing (m), for prefiltering the displacement; 0 on the editor's preview plane.
	float vertex_spacing = 0.0;
	if (lod_grid_enabled) {
		// One CDLOD node per multimesh instance (identity transform). The mesh is a
		// grid whose UVs are its lattice coordinates; INSTANCE_CUSTOM holds the
		// node's world origin x, z, its vertex spacing and its level.
		int level = int(INSTANCE_CUSTOM.w + 0.5);
		vertex_spacing = INSTANCE_CUSTOM.z;
		vec2 xz = INSTANCE_CUSTOM.xy + UV * vertex_spacing;
		float camera_distance = distance(CAMERA_POSITION_WORLD, vec3(xz.x, VERTEX.y, xz.y));
		// Geomorphing: with distance, odd lattice vertices slide onto their even
		// neighbours, i.e. onto the next level's lattice, and on through coarser
		// levels. Positions then depend only on the world position, so nodes of
		// different levels meet without cracks. Nodes never reach more than two
		// levels beyond their own (OceanSystem.LOD_RANGE_FACTOR).
		for (int k = level; k < min(level + 2, lod_top_level); ++k) {
			float morph = clamp((camera_distance - lod_morph_starts[k]) / (lod_ranges[k] - lod_morph_starts[k]), 0.0, 1.0);
			if (morph <= 0.0)
				break;
			vec2 lattice = round(xz / vertex_spacing);
			xz = (lattice - mod(lattice, 2.0) * morph) * vertex_spacing;
			vertex_spacing *= 1.0 + morph;
			if (morph < 1.0)
				break;
		}
		VERTEX.xz = xz;
	}
	UV = VERTEX.xz;

	// Read displacements from displacement maps, prefiltered to the vertex spacing
	// (a mip whose texels are as wide as the spacing): waves shorter than the
	// mesh can show are averaged away instead of aliasing.
	float map_size = float(textureSize(displacements, 0).x);
	vec3 displacement = vec3(0);
	for (uint i = 0U; i < uint(num_cascades); ++i) {
		vec4 scales = map_scales[i];
		if (scales.z == 0.0)
			continue;
		float lod = log2(max(vertex_spacing * map_size * max(scales.x, scales.y), 1.0));
		vec4 blend_state = spectrum_blend_states[i];
		vec3 active_coords = vec3(UV*scales.xy, blend_state.x);
		vec3 cascade_displacement = mix(textureLod(previous_displacements, active_coords, lod).xyz, textureLod(displacements, active_coords, lod).xyz, wave_blend_alpha) * blend_state.z;
		// Uniform branch: the pending spectrum is only sampled during a crossfade.
		if (blend_state.w > 0.0) {
			vec3 pending_coords = vec3(UV*scales.xy, blend_state.y);
			cascade_displacement += mix(textureLod(previous_displacements, pending_coords, lod).xyz, textureLod(displacements, pending_coords, lod).xyz, wave_blend_alpha) * blend_state.w;
		}
		displacement += cascade_displacement * scales.z;
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
	// Explicit LOD 0 (the maps have no mips), so this may run in divergent control flow.
	return mix(
		mix(textureLod(sampler, vec3(h.yw, uvw.z), 0.0), textureLod(sampler, vec3(h.xw, uvw.z), 0.0), w.x),
		mix(textureLod(sampler, vec3(h.yz, uvw.z), 0.0), textureLod(sampler, vec3(h.xz, uvw.z), 0.0), w.x), w.y);
}

/**
 * Normal/foam sample of one spectrum layer, blended between the previous and current FFT output.
 * Filtered over the pixel footprint (trilinear/anisotropic from explicit gradients, so it may
 * run after the hull discard). bilinear_weight 1 skips the bicubic filter (8 extra reads),
 * which only helps under magnification.
 */
vec4 sample_normal_layer(vec3 coords, vec2 coords_dx, vec2 coords_dy, float bilinear_weight) {
	vec4 previous_sample = textureGrad(previous_normals, coords, coords_dx, coords_dy);
	vec4 current_sample = textureGrad(normals, coords, coords_dx, coords_dy);
	if (use_bicubic_normals && bilinear_weight < 1.0) {
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

/** Sky gradient without clouds. */
vec3 sample_sky_gradient(vec3 direction) {
	float upper_blend = smoothstep(0.0, 0.55, direction.y);
	vec3 upper_sky = mix(sky_horizon_color.rgb * sky_horizon_boost, sky_top_color.rgb, upper_blend);

	float lower_blend = smoothstep(0.0, 0.55, -direction.y);
	vec3 lower_sky = mix(sky_ground_horizon_color.rgb, sky_ground_bottom_color.rgb, lower_blend);

	float horizon_blend = smoothstep(-0.035, 0.055, direction.y);
	return mix(lower_sky, upper_sky, horizon_blend);
}

/** Composites the sky source's clouds over a sky color seen in direction. */
vec3 composite_clouds(vec3 sky, vec3 direction) {
	if (!sky_clouds_enabled) {
		return sky;
	}
	// Explicit LOD (the cubemap has no mips): called from divergent control flow.
	vec4 cloud = textureLod(sky_cloud_cubemap, direction, 0.0);
	return sky * (1.0 - cloud.a) + cloud.rgb;
}

vec3 sample_rough_procedural_environment(vec3 direction, float roughness) {
	float rough = saturate(roughness);
	vec3 sharp = composite_clouds(sample_sky_gradient(direction), direction);
	float broad_weight = smoothstep(0.05, 0.55, rough);
	if (broad_weight <= 0.0) {
		return sharp;
	}
	vec3 upper_dir = safe_normalize_vec3(vec3(direction.x, direction.y + rough * 0.65, direction.z), direction);
	vec3 lower_dir = safe_normalize_vec3(vec3(direction.x, direction.y - rough * 0.45, direction.z), direction);
	vec3 center_dir = safe_normalize_vec3(mix(direction, vec3(0.0, 1.0, 0.0), rough * 0.25), direction);
	// The gradient is cheap and blurred over three directions; clouds are read
	// once, along the broad lobe's center.
	vec3 broad_gradient = sample_sky_gradient(center_dir) * 0.5
		+ sample_sky_gradient(upper_dir) * 0.3
		+ sample_sky_gradient(lower_dir) * 0.2;
	return mix(sharp, composite_clouds(broad_gradient, center_dir), broad_weight);
}

float ggx_distribution(float no_h, float roughness) {
	float alpha = max(roughness * roughness, 0.0009);
	float alpha2 = alpha * alpha;
	float denom = no_h * no_h * (alpha2 - 1.0) + 1.0;
	return alpha2 / max(3.14159265 * denom * denom, 0.00001);
}

/** Height-correlated Smith visibility, G / (4 N.L N.V). */
float smith_ggx_visibility(float no_v, float no_l, float roughness) {
	float alpha = max(roughness * roughness, 0.0009);
	float alpha2 = alpha * alpha;
	float lambda_v = no_l * sqrt(no_v * no_v * (1.0 - alpha2) + alpha2);
	float lambda_l = no_v * sqrt(no_l * no_l * (1.0 - alpha2) + alpha2);
	return 0.5 / max(lambda_v + lambda_l, 0.00001);
}

/** Specular BRDF of the water surface (GGX, Schlick Fresnel with the water's f0), without N.L. */
float water_specular_brdf(vec3 normal, vec3 view, vec3 light_direction, float roughness) {
	vec3 half_vector = safe_normalize_vec3(view + light_direction, normal);
	float no_v = max(dot(normal, view), 0.0001);
	float no_l = saturate(dot(normal, light_direction));
	float distribution = ggx_distribution(saturate(dot(normal, half_vector)), roughness);
	float visibility = smith_ggx_visibility(no_v, no_l, roughness);
	float fresnel = fresnel_schlick(saturate(dot(view, half_vector)), sky_reflection_f0, 5.0);
	return distribution * visibility * fresnel;
}

void fragment() {
	// Screen-space derivatives of the world XZ position, taken before any discard:
	// the pixel footprint for normal map filtering.
	vec2 uv_dx = dFdx(UV);
	vec2 uv_dy = dFdy(UV);
	float meters_per_screen_pixel = max(abs(uv_dx.x) + abs(uv_dy.x), abs(uv_dx.y) + abs(uv_dy.y));

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
		if (profile_uv.x < 0.0 || profile_uv.x > 1.0 || profile_uv.y < 0.0)
			continue; // Beyond the bow/stern or below the keel.
		vec4 params = near_hull_params[i];
		// Explicit LOD: these lookups sit in divergent control flow, where implicit derivatives are undefined.
		// Above this station's top (plus the offset) there is no hull; up to there,
		// heights above the top use the width at the top.
		float station_top = textureLod(hull_profiles, vec3(profile_uv.x, 0.5, params.x), 0.0).b;
		if (profile_uv.y > station_top + 0.5 / float(textureSize(hull_profiles, 0).y) + near_hull_top_offsets[i])
			continue;
		float half_width = textureLod(hull_profiles, vec3(profile_uv.x, min(profile_uv.y, station_top), params.x), 0.0).r;
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
	// Total variance of the slopes inside the pixel footprint, over all cascades.
	float slope_variance = 0.0;
	foam_factor = 0.0;
	float raw_wave_slope = 0.0;
	vec3 world_normal = vec3(0.0, 1.0, 0.0);
	float sky_reflection_amount = 0.0;
	vec3 reflected_sky_color = vec3(0.0);
	vec3 sun_scatter_radiance = vec3(0.0);
	float sun_specular_amount = 0.0;
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
			vec4 blend_state = spectrum_blend_states[i];
			// Mix between bicubic and bilinear filtering depending on the world space pixels per meter.
			// This is dependent on the tile size as well as displacement/normal map resolution.
			// Where one screen pixel covers two or more texels (minification) bicubic adds nothing.
			float pixels_per_meter = map_size * min(scales.x, scales.y);
			float bilinear_weight = max(min(1.0, pixels_per_meter * 0.1), smoothstep(1.0, 2.0, meters_per_screen_pixel * pixels_per_meter));
			vec2 coords_dx = uv_dx * scales.xy;
			vec2 coords_dy = uv_dy * scales.xy;
			vec4 active_sample = sample_normal_layer(vec3(UV*scales.xy, blend_state.x), coords_dx, coords_dy, bilinear_weight);
			vec2 cascade_gradient = active_sample.xy * blend_state.z;
			// Slopes the filtered sample averaged away: E|g|^2 - |E g|^2 (mip_downsample.glsl).
			float cascade_variance = max(active_sample.z - dot(active_sample.xy, active_sample.xy), 0.0) * blend_state.z * blend_state.z;
			float cascade_foam = active_sample.w;
			// Uniform branch: the pending spectrum is only sampled during a crossfade.
			if (blend_state.w > 0.0) {
				vec4 pending_sample = sample_normal_layer(vec3(UV*scales.xy, blend_state.y), coords_dx, coords_dy, bilinear_weight);
				cascade_gradient += pending_sample.xy * blend_state.w;
				// The two spectra are independent, so their variances add with squared weights.
				cascade_variance += max(pending_sample.z - dot(pending_sample.xy, pending_sample.xy), 0.0) * blend_state.w * blend_state.w;
				// Foam is a non-negative mask, so it crossfades linearly rather than by equal power.
				cascade_foam = mix(active_sample.w, pending_sample.w, blend_state.w / (blend_state.z + blend_state.w));
			}
			vec2 normal_signal = cascade_gradient * scales.w;
			cascade_variance *= scales.w * scales.w;
			float tile_length = 1.0 / max(min(scales.x, scales.y), 0.0001);
			float macro_weight = smoothstep(18.0, 80.0, tile_length);
			gradient += normal_signal;
			slope_variance += cascade_variance;
			foam_signal += cascade_foam;
			macro_gradient += normal_signal * macro_weight;
			// RMS slope (resolved + unresolved): the same at every filter level.
			micro_slope_energy += sqrt(dot(normal_signal, normal_signal) + cascade_variance) * (1.0 - macro_weight);
		}

		raw_wave_slope = length(gradient);
		micro_slope_energy = saturate(micro_slope_energy * 0.75 + raw_wave_slope * 0.15);
		macro_world_normal = normalize(vec3(-macro_gradient.x * 0.45, 1.0, -macro_gradient.y * 0.45));
		float visible_foam_signal = foam_signal * 0.75 * foam_intensity;
		float far_foam_softness = foam_softness * (1.0 + far_foam_threshold_boost * fragment_distance_lod * 4.0);
		float foam_distance_fade = mix(1.0, far_foam_coverage, fragment_distance_lod);
		foam_factor = smoothstep(foam_threshold, foam_threshold + far_foam_softness, visible_foam_signal) * exp(-dist*0.0075) * foam_distance_fade;

		gradient = (gradient + interaction_gradient) * normal_strength;
		slope_variance *= normal_strength * normal_strength;
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
	// GGX alpha (perceptual roughness squared) widened by the unresolved slope variance
	// (Toksvig / LEAN: alpha^2 += variance). clear_roughness is the micro-roughness of
	// ripples shorter than the smallest cascade.
	float base_alpha = clear_roughness * clear_roughness;
	effective_reflection_roughness = saturate(sqrt(sqrt(base_alpha * base_alpha + slope_variance)));

	// One Fresnel reflectance for everything the water reflects: the sky, and the
	// scene geometry of the planar reflection in front of it.
	float sky_fresnel = fresnel_schlick(no_v, sky_reflection_f0, sky_reflection_fresnel_power);
	float rough_fresnel_floor = sky_reflection_f0 + effective_reflection_roughness * (0.05 + micro_slope_energy * 0.08);
	sky_reflection_amount = saturate(sky_reflection_strength * max(sky_fresnel, rough_fresnel_floor) * clear_water_mask * mix(1.0, 1.18, fragment_distance_lod));
	if (sky_reflection_enabled) {
		reflected_sky_color = sample_rough_procedural_environment(reflection_direction, effective_reflection_roughness);
	}
	vec3 reflected_color = reflected_sky_color;

	// The highlight itself is lit in light(); this copy (per unit of sun irradiance) is for the debug view.
	sun_specular_amount = water_specular_brdf(world_normal, view_direction_world, sun_dir, effective_reflection_roughness) * saturate(dot(world_normal, sun_dir));

	sun_scatter_no_l = pow(saturate(dot(macro_world_normal, sun_dir)), sun_scatter_normal_power);
	view_sun_phase = pow(saturate(dot(view_direction_world, sun_dir)), sun_scatter_phase_power);
	float scatter_slope = mix(1.0, 0.5 + micro_slope_energy, sun_scatter_slope_strength);
	float scatter_distance = 1.0 + fragment_distance_lod * sun_scatter_distance_strength;
	sun_scatter_amount = sun_scatter_strength * sky_sun_visibility * sun_scatter_no_l * (sun_scatter_base + view_sun_phase) * scatter_slope * scatter_distance * clear_water_mask;
	sun_scatter_radiance = water_scatter_color.rgb * sky_sun_color.rgb * sun_scatter_amount;

	// Reflected scene geometry hides the sky behind it (alpha: geometry coverage).
	if (planar_reflection_enabled && planar_reflection_strength > 0.0) {
		// The mirrored camera sees, through the water point, whatever a flat mirror
		// would reflect there. With waves, follow this pixel's reflected ray instead:
		// look up a point along it. For flat water every point on the ray projects
		// to the same texel; with waves the reflection breaks up like real water.
		// The distance along the ray (to the reflected object) is unknown; the
		// camera distance is a fair guess for ships near the water point.
		float reflected_distance = max(length(CAMERA_POSITION_WORLD - water_world_position), 1.0);
		vec3 reflected_point = water_world_position + reflection_direction * reflected_distance;
		vec4 reflection_clip = planar_reflection_view_projection * vec4(reflected_point, 1.0);
		float reflection_w = reflection_clip.w;
		if (abs(reflection_w) < 0.0001) {
			reflection_w = 0.0001;
		}
		vec2 reflection_uv = reflection_clip.xy / reflection_w * 0.5 + 0.5;
		reflection_uv.y = 1.0 - reflection_uv.y;
		vec2 reflection_bounds = step(vec2(0.0), reflection_uv) * step(reflection_uv, vec2(1.0));
		float reflection_in_bounds = reflection_bounds.x * reflection_bounds.y * step(0.0001, reflection_clip.w);
		vec4 reflected_sample = texture(planar_reflection_texture, reflection_uv);
		// A rough surface spreads the reflection over a wide lobe that one planar
		// texel cannot represent: there the geometry fades into the blurred sky.
		float sharpness = 1.0 - smoothstep(0.25, 0.6, effective_reflection_roughness);
		float geometry_coverage = planar_reflection_strength * reflection_in_bounds * reflected_sample.a * sharpness;
		reflected_color = mix(reflected_color, reflected_sample.rgb, geometry_coverage);
	}
	vec3 reflection_radiance = reflected_color * sky_reflection_amount;

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
			debug_color = vec3(1.0) - exp(-vec3(sun_specular_amount)); // tonemapped
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
		} else if (water_debug_view == 14) {
			debug_color = vec3(sqrt(slope_variance));
		}
		ALBEDO = debug_color;
		METALLIC = 0.0;
		ROUGHNESS = 1.0;
		SPECULAR = 0.0;
		EMISSION = vec3(0.0);
		light_specular_scale = 0.0;
	} else {
		ALBEDO = base_albedo;
		METALLIC = 0.0;
		ROUGHNESS = mix(effective_reflection_roughness, foam_roughness, foam_factor);
		SPECULAR = 0.0; // No engine sky reflection: it is in EMISSION (see the header).
		EMISSION = reflection_radiance + sun_scatter_radiance + crest_emission;
		light_specular_scale = sun_specular_strength * clear_water_mask;
	}
}

/**
 * Replaces Godot's per-light shading. LIGHT_COLOR includes PI, so these match the
 * engine's Lambert diffuse and specular conventions.
 */
void light() {
	float no_l = dot(NORMAL, LIGHT);
	DIFFUSE_LIGHT += LIGHT_COLOR * ATTENUATION * max(no_l, 0.0) / PI;
	if (no_l > 0.0) {
		SPECULAR_LIGHT += LIGHT_COLOR * ATTENUATION * (no_l / PI) * water_specular_brdf(NORMAL, VIEW, LIGHT, ROUGHNESS) * light_specular_scale;
	}
}
