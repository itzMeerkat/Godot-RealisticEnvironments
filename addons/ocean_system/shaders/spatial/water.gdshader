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
// Solid angle (sr) of the sun's (and the moon's) disk, about 0.53 degrees across.
#define LIGHT_DISK_SOLID_ANGLE 6.8e-5
// Foam lighting (light()): wrap of its diffuse term, and strength and sharpness of the
// light it lets through toward the viewer.
#define FOAM_WRAP 0.6
#define FOAM_TRANSMISSION 0.5
#define FOAM_TRANSMISSION_POWER 4.0
// Refinement steps of the planar reflection hit along a pixel's reflected ray.
#define PLANAR_REFLECTION_STEPS 3

uniform vec4 water_color : source_color;
uniform vec4 foam_color : source_color;

uniform float water_diffuse_strength : hint_range(0.0, 1.0) = 0.08;
uniform vec4 water_scatter_color : source_color = vec4(0.045, 0.18, 0.20, 1.0);
uniform float clear_roughness : hint_range(0.0, 1.0) = 0.10;
uniform float foam_roughness : hint_range(0.0, 1.0) = 0.24;
uniform float normal_strength : hint_range(0.0, 1.0) = 1.0; // Global normal strength
uniform float foam_intensity : hint_range(0.0, 4.0) = 1.0; // multiplies the wave foam coverage
// Foam pattern with uniformly distributed values (textures/generate_foam_detail.py): foam
// shows where pattern > 1 - coverage, which covers exactly `coverage` of the area.
uniform sampler2D foam_detail : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform float foam_detail_tile_size = 3.0; // meters per pattern tile
uniform vec4 sky_top_color : source_color = vec4(0.12, 0.42, 0.78, 1.0);
uniform vec4 sky_horizon_color : source_color = vec4(0.58, 0.78, 0.94, 1.0);
uniform vec4 sky_ground_horizon_color : source_color = vec4(0.16, 0.24, 0.28, 1.0);
uniform vec4 sky_ground_bottom_color : source_color = vec4(0.01, 0.02, 0.03, 1.0);
uniform vec3 sky_sun_direction = vec3(0.0, 0.2, -1.0);
uniform vec4 sky_sun_color : source_color = vec4(1.0, 0.92, 0.72, 1.0);
uniform float sky_sun_visibility : hint_range(0.0, 1.0) = 1.0;
// Clouds from the sky source (SkySystem.get_cloud_cubemap()): rgb premultiplied
// radiance, a opacity, with a mip chain for rough reflections. Set at runtime by OceanSystem.
uniform bool sky_clouds_enabled = false;
uniform samplerCube sky_cloud_cubemap : filter_linear_mipmap;
uniform bool sky_reflection_enabled = true;
uniform float sky_reflection_strength : hint_range(0.0, 2.0) = 1.0;
uniform float sky_reflection_f0 : hint_range(0.0, 0.12) = 0.02;
uniform float sky_horizon_boost : hint_range(0.0, 3.0) = 0.85;
uniform float sun_specular_strength : hint_range(0.0, 4.0) = 1.0;
// Stochastic glints (see glitter_scale()): facets per square meter of water, 0 = smooth highlight.
uniform float sun_glitter_density : hint_range(0.0, 10000000.0) = 1000000.0;
uniform float sun_glitter_rate : hint_range(0.0, 60.0) = 12.0; // glint patterns per second
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
uniform int water_debug_view : hint_range(0, 15) = 0;
uniform bool planar_reflection_enabled = false;
// Linear HDR, rgb premultiplied by geometry coverage (a), with a mip chain (PlanarReflectionCaptureEffect).
uniform sampler2D planar_reflection_texture : filter_linear_mipmap, repeat_disable;
// Distance (m) from the mirrored camera to the surface each texel shows, 0 = no geometry.
uniform sampler2D planar_reflection_distance : filter_nearest, repeat_disable;
uniform mat4 planar_reflection_view_projection;
uniform vec3 planar_reflection_camera_position; // the mirrored camera
uniform float planar_reflection_texel_angle = 0.001; // radians per mip-0 texel at the image center
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
uniform sampler2DArray normals : hint_normal, filter_linear_mipmap, repeat_enable; // Each layer represents one wave cascade.
uniform sampler2DArray previous_displacements : filter_linear_mipmap, repeat_enable;
uniform sampler2DArray previous_normals : hint_normal, filter_linear_mipmap, repeat_enable;
uniform float wave_blend_alpha = 1.0;

varying float foam_factor;
varying vec3 water_world_position;
// Fragment -> light(): multiplies the specular highlight (foam covers it).
varying float light_specular_scale;
// Fragment -> light(), for glitter_scale(): random numbers of the pixel's glint cells, for
// (fine level, coarse level) x (current pattern, next pattern).
varying vec4 glitter_random;
// Facets in a fine and in a coarse cell, fine-to-coarse blend, current-to-next pattern blend.
varying vec4 glitter_cells;

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
	// LOD 0: only used under magnification. Explicit, so this may run in divergent control flow.
	return mix(
		mix(textureLod(sampler, vec3(h.yw, uvw.z), 0.0), textureLod(sampler, vec3(h.xw, uvw.z), 0.0), w.x),
		mix(textureLod(sampler, vec3(h.yz, uvw.z), 0.0), textureLod(sampler, vec3(h.xz, uvw.z), 0.0), w.x), w.y);
}

/**
 * One spectrum layer's (mean slope xy, unresolved slope variance, foam), blended between the
 * previous and current FFT output. Trilinear at mip lod (explicit, so it may run after the hull
 * discard). bilinear_weight 1 skips the bicubic filter (8 extra reads), which only helps under
 * magnification.
 */
vec4 sample_normal_layer(vec3 coords, float lod, float bilinear_weight) {
	vec4 previous_sample = textureLod(previous_normals, coords, lod);
	vec4 current_sample = textureLod(normals, coords, lod);
	if (use_bicubic_normals && bilinear_weight < 1.0) {
		previous_sample = mix(texture_bicubic(previous_normals, coords), previous_sample, bilinear_weight);
		current_sample = mix(texture_bicubic(normals, coords), current_sample, bilinear_weight);
	}
	// Slopes the filter averaged away: E|g|^2 - |E g|^2 (mip_downsample.glsl), per frame, as
	// blending two frames' slopes is not roughness. Interpolating texels with different slopes
	// also raises it, but while a pixel covers less than a texel that spread is drawn (the
	// interpolated slope varies across pixels), not missed: count it from one texel up.
	float previous_variance = max(previous_sample.z - dot(previous_sample.xy, previous_sample.xy), 0.0);
	float current_variance = max(current_sample.z - dot(current_sample.xy, current_sample.xy), 0.0);
	vec4 blended = mix(previous_sample, current_sample, wave_blend_alpha);
	blended.z = mix(previous_variance, current_variance, wave_blend_alpha) * min(lod, 1.0);
	return blended;
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

float fresnel_schlick(float no_v, float f0) {
	return f0 + (1.0 - f0) * pow(1.0 - saturate(no_v), 5.0);
}

/**
 * Fresnel reflectance averaged over a rough surface (Bruneton, Neyret, Holzschuch,
 * "Real-time Realistic Ocean Lighting using Seamless Transitions from Geometry to
 * BRDF", 2010), for the mean normal and an isotropic slope deviation sigma per
 * axis. Unresolved facets seen at grazing angles tilt toward the viewer, so a
 * rough sea reflects much less than a mirror there.
 */
float rough_fresnel(float no_v, float sigma, float f0) {
	float mean = pow(1.0 - saturate(no_v), 5.0 * exp(-2.69 * sigma)) / (1.0 + 22.7 * pow(sigma, 1.5));
	return f0 + (1.0 - f0) * mean;
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

/**
 * Composites the sky source's clouds over a sky color seen in direction, blurred
 * over the reflection lobe of GGX roughness (perceptual).
 */
vec3 composite_clouds(vec3 sky, vec3 direction, float roughness) {
	if (!sky_clouds_enabled) {
		return sky;
	}
	// Reflected directions spread with an angular deviation of about sqrt(2) alpha
	// (twice the normal's, slope deviation alpha / sqrt(2)). A box-filtered mip of
	// texels 2^lod wide (about 2 / face size radians each at mip 0) has deviation
	// 2^lod * texel / sqrt(12); matching the two gives the level.
	float alpha = roughness * roughness;
	float lod = log2(max(alpha * float(textureSize(sky_cloud_cubemap, 0).x) * 2.45, 1.0));
	// Explicit LOD: called from divergent control flow.
	vec4 cloud = textureLod(sky_cloud_cubemap, direction, lod);
	return sky * (1.0 - cloud.a) + cloud.rgb;
}

vec3 sample_rough_procedural_environment(vec3 direction, float roughness) {
	float rough = saturate(roughness);
	vec3 sky = sample_sky_gradient(direction);
	vec3 cloud_direction = direction;
	float broad_weight = smoothstep(0.05, 0.55, rough);
	if (broad_weight > 0.0) {
		vec3 upper_dir = safe_normalize_vec3(vec3(direction.x, direction.y + rough * 0.65, direction.z), direction);
		vec3 lower_dir = safe_normalize_vec3(vec3(direction.x, direction.y - rough * 0.45, direction.z), direction);
		vec3 center_dir = safe_normalize_vec3(mix(direction, vec3(0.0, 1.0, 0.0), rough * 0.25), direction);
		// The gradient is cheap and blurred over three directions; clouds are
		// prefiltered (cubemap mips), read once toward the broad lobe's center.
		vec3 broad_gradient = sample_sky_gradient(center_dir) * 0.5
			+ sample_sky_gradient(upper_dir) * 0.3
			+ sample_sky_gradient(lower_dir) * 0.2;
		sky = mix(sky, broad_gradient, broad_weight);
		cloud_direction = safe_normalize_vec3(mix(direction, center_dir, broad_weight), direction);
	}
	return composite_clouds(sky, cloud_direction, rough);
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
	float fresnel = fresnel_schlick(saturate(dot(view, half_vector)), sky_reflection_f0);
	return distribution * visibility * fresnel;
}

/** Uniform random number in [0, 1) for integer coordinates (PCG3D hash). */
float hash_uniform(ivec3 key) {
	uvec3 v = uvec3(key) * 1664525u + 1013904223u;
	v.x += v.y * v.z; v.y += v.z * v.x; v.z += v.x * v.y;
	v ^= v >> 16u;
	v.x += v.y * v.z; v.y += v.z * v.x; v.z += v.x * v.y;
	return float(v.x >> 8u) / 16777216.0;
}

/**
 * Glint multiplier of one cell with `facets` facets, of which a share `aligned_fraction` reflects
 * the light into the eye: the aligned count is Poisson distributed (drawn with uniform u), and
 * its ratio to the mean is the multiplier, so the mean highlight stays the GGX one.
 */
float glint_cell(float facets, float aligned_fraction, float u) {
	float mean = facets * aligned_fraction;
	if (mean <= 0.0) {
		return 1.0;
	}
	float count = 0.0;
	if (mean < 8.0) {
		// Inverse of the Poisson CDF.
		float probability = exp(-mean);
		float cumulative = probability;
		for (int k = 1; k < 24 && u > cumulative; ++k) {
			count += 1.0;
			probability *= mean / count;
			cumulative += probability;
		}
	} else {
		// Nearly normal: logistic approximation of the normal quantile (std 1).
		float z = log(max(u, 1e-6) / max(1.0 - u, 1e-6)) * 0.5513;
		count = max(mean + sqrt(mean) * z, 0.0);
	}
	return count / mean;
}

/**
 * Stochastic sun glitter (after Zirr & Kaplanyan 2016 and Deliot & Belcour 2023). The GGX
 * highlight is the mean over many tiny facets; a pixel holds a finite number of them, and the
 * few that point the light's disk at the eye flash as glints. World cells about a pixel wide
 * (two levels, blended) draw their aligned facet count; patterns change sun_glitter_rate times a
 * second and crossfade.
 */
float glitter_scale(vec3 normal, vec3 view, vec3 light_direction, float roughness) {
	vec3 half_vector = safe_normalize_vec3(view + light_direction, normal);
	float no_h = saturate(dot(normal, half_vector));
	float vo_h = max(dot(view, half_vector), 0.0001);
	// Share of facet normals inside the half-vector cone of the light's disk.
	float aligned_fraction = min(ggx_distribution(no_h, roughness) * no_h * LIGHT_DISK_SOLID_ANGLE / (4.0 * vo_h), 1.0);
	float fine = mix(glint_cell(glitter_cells.x, aligned_fraction, glitter_random.x), glint_cell(glitter_cells.x, aligned_fraction, glitter_random.y), glitter_cells.w);
	float coarse = mix(glint_cell(glitter_cells.y, aligned_fraction, glitter_random.z), glint_cell(glitter_cells.y, aligned_fraction, glitter_random.w), glitter_cells.w);
	return mix(fine, coarse, glitter_cells.z);
}

/**
 * Planar reflection texture coordinates of a world point (w = 1) or of a direction at
 * infinity (w = 0); z is 1 inside the image, else 0.
 */
vec3 planar_reflection_project(vec4 point) {
	vec4 clip = planar_reflection_view_projection * point;
	if (clip.w <= 0.0001) {
		return vec3(0.0);
	}
	vec2 uv = clip.xy / clip.w * 0.5 + 0.5;
	uv.y = 1.0 - uv.y;
	float inside = all(greaterThanEqual(uv, vec2(0.0))) && all(lessThanEqual(uv, vec2(1.0))) ? 1.0 : 0.0;
	return vec3(uv, inside);
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
			// Isotropic mip covering the pixel footprint's area. The slopes it averages
			// away become roughness (slope variance) instead of aliasing into sparkle.
			// Sizing it by the footprint's longer axis instead counts every slope along
			// a grazing footprint as round blur, which turns the water milky.
			float footprint = sqrt(length(uv_dx * scales.xy) * length(uv_dy * scales.xy)) * map_size;
			float lod = log2(max(footprint, 1.0));
			vec4 active_sample = sample_normal_layer(vec3(UV*scales.xy, blend_state.x), lod, bilinear_weight);
			vec2 cascade_gradient = active_sample.xy * blend_state.z;
			float cascade_variance = active_sample.z * blend_state.z * blend_state.z;
			float cascade_foam = active_sample.w;
			// Uniform branch: the pending spectrum is only sampled during a crossfade.
			if (blend_state.w > 0.0) {
				vec4 pending_sample = sample_normal_layer(vec3(UV*scales.xy, blend_state.y), lod, bilinear_weight);
				cascade_gradient += pending_sample.xy * blend_state.w;
				// The two spectra are independent, so their variances add with squared weights.
				cascade_variance += pending_sample.z * blend_state.w * blend_state.w;
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
		// Foam is coverage (fft_unpack.glsl), so its mips hold the covered share of
		// each texel: right at every distance, with no fade.
		foam_factor = saturate(foam_signal * foam_intensity);

		gradient = (gradient + interaction_gradient) * normal_strength;
		slope_variance *= normal_strength * normal_strength;
		world_normal = normalize(vec3(-gradient.x, 1.0, -gradient.y));
		NORMAL = (VIEW_MATRIX * vec4(world_normal, 0.0)).xyz;
	}
	float foam_coverage = max(max(foam_factor, hull_edge_foam), interaction_foam);
	// Reveal the coverage as foam lace: white where the pattern exceeds 1 - coverage,
	// with a narrow edge. On the rest-position grid (UV), so the lace rides with the
	// water. Once the pattern's texels shrink below a pixel its mips flatten toward
	// 0.5 and the threshold no longer keeps the area; there plain coverage takes over.
	// Explicit LOD: this follows the hull discard.
	float detail_texels = max(length(uv_dx), length(uv_dy)) / foam_detail_tile_size * float(textureSize(foam_detail, 0).x);
	float detail_lod = log2(max(detail_texels, 1.0));
	float detail = textureLod(foam_detail, UV / foam_detail_tile_size, detail_lod).r;
	const float FOAM_EDGE = 0.12;
	float foam_threshold = (1.0 - foam_coverage) * (1.0 + FOAM_EDGE) - FOAM_EDGE;
	float revealed_foam = smoothstep(foam_threshold, foam_threshold + FOAM_EDGE, detail);
	// Thin foam (low coverage: old or barely formed) is translucent, dense foam opaque.
	float foam_opacity = mix(0.35, 1.0, foam_coverage);
	foam_factor = mix(revealed_foam, foam_coverage, saturate(detail_lod * 0.25)) * foam_opacity;

	vec3 view_direction_world = safe_normalize_vec3(CAMERA_POSITION_WORLD - water_world_position, vec3(0.0, 0.0, 1.0));
	vec3 sun_dir = safe_normalize_vec3(sky_sun_direction, vec3(0.0, 0.2, -1.0));
	vec3 reflection_direction = reflect(-view_direction_world, world_normal);
	// A ray reflected below the horizon hits the next wave and goes on upward;
	// mirroring it up stands in for that second bounce (the sky gradient's
	// ground colors are for looking down, not for reflections).
	reflection_direction.y = abs(reflection_direction.y);
	float low_sun = sky_low_sun_factor(sun_dir);
	float clear_water_mask = 1.0 - foam_factor * 0.85;
	float no_v = saturate(dot(world_normal, view_direction_world));
	// GGX alpha (perceptual roughness squared) widened by the unresolved slope variance
	// (Toksvig / LEAN: alpha^2 += variance). clear_roughness is the micro-roughness of
	// ripples shorter than the smallest cascade.
	float base_alpha = clear_roughness * clear_roughness;
	effective_reflection_roughness = saturate(sqrt(sqrt(base_alpha * base_alpha + slope_variance)));

	// One Fresnel reflectance for everything the water reflects: the sky, and the
	// scene geometry of the planar reflection in front of it. Averaged over the
	// same slopes as the roughness: alpha^2 = 2 sigma^2 per axis.
	float slope_sigma = sqrt(base_alpha * base_alpha + slope_variance) * 0.70710678;
	float sky_fresnel = rough_fresnel(no_v, slope_sigma, sky_reflection_f0);
	// The water body's color is light that entered the water and scattered back
	// out: only the share the surface does not reflect leaves toward the eye.
	// Foam lies on top, so it is not dimmed.
	vec3 water_body_albedo = water_color.rgb * water_diffuse_strength * (1.0 - sky_fresnel);
	// Bubble cells (low pattern values) are a little darker than the lace between them.
	vec3 base_albedo = mix(water_body_albedo, foam_color.rgb * mix(0.75, 1.0, detail), foam_factor);
	sky_reflection_amount = saturate(sky_reflection_strength * sky_fresnel * clear_water_mask);
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
		// Find what this pixel's reflected ray (about its own wave normal) hits. The
		// mirrored camera sees every surface a ray from the water plane can reach,
		// and the capture stores each texel's surface distance. Start with the ray's
		// end at infinity; then repeatedly project the end, read the surface seen
		// there, and move the end to that surface's distance along the ray. A texel
		// with no geometry means the ray goes on to the sky.
		vec4 ray_end = vec4(reflection_direction, 0.0);
		float hit_distance = 0.0;
		vec3 reflection_uv = planar_reflection_project(ray_end);
		for (int i = 0; i < PLANAR_REFLECTION_STEPS && reflection_uv.z > 0.0; ++i) {
			// Explicit LOD: this follows the hull discard.
			float surface_distance = textureLod(planar_reflection_distance, reflection_uv.xy, 0.0).r;
			if (surface_distance <= 0.0)
				break;
			vec3 texel_ray = ray_end.w > 0.0 ? normalize(ray_end.xyz - planar_reflection_camera_position) : reflection_direction;
			vec3 surface = planar_reflection_camera_position + texel_ray * surface_distance;
			hit_distance = max(dot(surface - water_world_position, reflection_direction), 0.0);
			ray_end = vec4(water_world_position + reflection_direction * hit_distance, 1.0);
			reflection_uv = planar_reflection_project(ray_end);
		}
		// Blurred over the reflection lobe like the clouds (composite_clouds): the
		// reflected rays spread by about sqrt(2) alpha, which the mirrored camera sees
		// scaled by (distance from the water) / (distance from the mirrored camera).
		float lobe_scale = ray_end.w > 0.0 ? hit_distance / max(distance(ray_end.xyz, planar_reflection_camera_position), 0.001) : 1.0;
		float alpha = effective_reflection_roughness * effective_reflection_roughness;
		float reflection_lod = log2(max(alpha * 4.9 * lobe_scale / planar_reflection_texel_angle, 1.0));
		vec4 reflected_sample = textureLod(planar_reflection_texture, reflection_uv.xy, reflection_lod);
		float geometry_coverage = planar_reflection_strength * reflection_uv.z;
		reflected_color = reflected_color * (1.0 - geometry_coverage * reflected_sample.a) + reflected_sample.rgb * geometry_coverage;
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
		} else if (water_debug_view == 15) {
			debug_color = vec3(foam_factor);
		}
		ALBEDO = debug_color;
		METALLIC = 0.0;
		ROUGHNESS = 1.0;
		SPECULAR = 0.0;
		EMISSION = vec3(0.0);
		light_specular_scale = 0.0;
		glitter_cells = vec4(0.0);
	} else {
		ALBEDO = base_albedo;
		METALLIC = 0.0;
		ROUGHNESS = mix(effective_reflection_roughness, foam_roughness, foam_factor);
		SPECULAR = 0.0; // No engine sky reflection: it is in EMISSION (see the header).
		EMISSION = reflection_radiance + sun_scatter_radiance + crest_emission;
		light_specular_scale = sun_specular_strength * clear_water_mask;

		// Glint cells on the rest-position grid (UV), so patterns ride with the water.
		// Cell sides are powers of two around the pixel footprint's size.
		float footprint_area = max(abs(uv_dx.x * uv_dy.y - uv_dx.y * uv_dy.x), 1e-8);
		float cell_level = 0.5 * log2(footprint_area);
		float fine_level = floor(cell_level);
		float fine_size = exp2(fine_level);
		ivec2 fine_cell = ivec2(floor(UV / fine_size));
		ivec2 coarse_cell = ivec2(floor(UV / (2.0 * fine_size)));
		float pattern_time = TIME * sun_glitter_rate;
		int pattern = int(floor(pattern_time));
		int level_key = int(fine_level) * 65536;
		glitter_random = vec4(
			hash_uniform(ivec3(fine_cell, level_key + pattern)),
			hash_uniform(ivec3(fine_cell, level_key + pattern + 1)),
			hash_uniform(ivec3(coarse_cell, level_key + 65536 + pattern)),
			hash_uniform(ivec3(coarse_cell, level_key + 65536 + pattern + 1)));
		float fine_facets = sun_glitter_density * fine_size * fine_size;
		glitter_cells = vec4(fine_facets, fine_facets * 4.0, cell_level - fine_level, fract(pattern_time));
	}
}

/**
 * Replaces Godot's per-light shading. LIGHT_COLOR includes PI, so these match the
 * engine's Lambert diffuse and specular conventions.
 */
void light() {
	float no_l = dot(NORMAL, LIGHT);
	// Water body: light refracted into the water and scattered back up. It depends
	// on how high the light is, not on the wave facet; Lambert on the facets made
	// the water look like shaded plastic.
	vec3 up = (VIEW_MATRIX * vec4(0.0, 1.0, 0.0, 0.0)).xyz;
	float body_light = max(dot(up, LIGHT), 0.0);
	// Foam: a layer of bubbles that scatters light through its volume, so facets
	// turned away from the light still get some (wrapped diffuse), and light from
	// behind shines through toward the viewer.
	float foam_light = max(no_l + FOAM_WRAP, 0.0) / (1.0 + FOAM_WRAP)
		+ FOAM_TRANSMISSION * pow(max(dot(-VIEW, LIGHT), 0.0), FOAM_TRANSMISSION_POWER);
	DIFFUSE_LIGHT += LIGHT_COLOR * ATTENUATION * mix(body_light, foam_light, foam_factor) / PI;
	if (no_l > 0.0) {
		float glitter = glitter_cells.x > 0.0 ? glitter_scale(NORMAL, VIEW, LIGHT, ROUGHNESS) : 1.0;
		SPECULAR_LIGHT += LIGHT_COLOR * ATTENUATION * (no_l / PI) * water_specular_brdf(NORMAL, VIEW, LIGHT, ROUGHNESS) * light_specular_scale * glitter;
	}
}
