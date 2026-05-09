shader_type spatial;
render_mode world_vertex_coords, cull_disabled, shadows_disabled;
/**
 * Water lighting model roughly follows the 2019 GDC talk: "Wakes, Explosions and Lighting: Interactive Water Simulation in Atlas".
 * Source: https://gpuopen.com/gdc-presentations/2019/gdc-2019-agtd6-interactive-water-simulation-in-atlas.pdf
 */

#define MAX_CASCADES 8
#define REFLECTANCE  0.02 // Reflectance from air to water (eta=1.33).

uniform vec4 water_color : source_color;
uniform vec4 foam_color : source_color;

uniform float roughness : hint_range(0.0, 1.0) = 0.4;
uniform float specular_strength : hint_range(0.0, 1.0) = 0.55;
uniform float direct_light_strength : hint_range(0.0, 4.0) = 1.45;
uniform float water_scatter_strength : hint_range(0.0, 4.0) = 1.1;
uniform float sun_glint_strength : hint_range(0.0, 4.0) = 1.25;
uniform float normal_strength : hint_range(0.0, 1.0) = 1.0; // Global normal strength
uniform float foam_intensity : hint_range(0.0, 4.0) = 1.25;
uniform float foam_threshold : hint_range(0.0, 2.0) = 0.05;
uniform float foam_softness : hint_range(0.01, 2.0) = 0.35;
uniform bool use_bicubic_normals = false;
uniform int fragment_cascade_limit : hint_range(1, 8) = 3;
uniform bool enable_far_lod = true;
uniform float near_ocean_radius = 256.0;
uniform float far_lod_radius = 7000.0;
uniform float far_lod_blend_distance : hint_range(1.0, 4000.0) = 1400.0;
uniform float far_lod_curve : hint_range(0.25, 4.0) = 1.8;
uniform float far_low_frequency_tile_length : hint_range(1.0, 512.0) = 64.0;
uniform float far_normal_strength : hint_range(0.0, 2.0) = 0.14;
uniform float far_foam_coverage : hint_range(0.0, 1.0) = 0.24;
uniform float far_foam_threshold_boost : hint_range(0.0, 1.0) = 0.2;

group_uniforms cascade_data;
uniform vec4 map_scales[MAX_CASCADES];               // Scales for displacement/normal maps. Packed: [uv scale, displacement scale, normal scale]
uniform int num_cascades = 0;
uniform sampler2DArray displacements;         // Each layer represents one wave cascade.
uniform sampler2DArray normals : hint_normal; // Each layer represents one wave cascade.
uniform sampler2DArray previous_displacements;
uniform sampler2DArray previous_normals : hint_normal;
uniform float wave_blend_alpha = 1.0;

varying float wave_height;
varying float foam_factor;
varying float fresnel;
varying float lighting_roughness;
varying float distance_to_camera;
varying float distance_lod;

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
		vec3 coords = vec3(UV*scales.xy, float(i));
		vec3 previous_displacement = texture(previous_displacements, coords).xyz;
		vec3 current_displacement = texture(displacements, coords).xyz;
		displacement += mix(previous_displacement, current_displacement, wave_blend_alpha) * scales.z * cascade_weight;
	}
	VERTEX += displacement;
	wave_height = displacement.y;
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

void fragment() {
	float dist = distance_to_camera;
	vec3 gradient = vec3(0);
	foam_factor = 0.0;

	if (num_cascades > 0) {
		float map_size = float(textureSize(normals, 0).x);
		// Read foam and normal information from normal maps.
		uint cascade_count = min(uint(num_cascades), uint(fragment_cascade_limit));
		for (uint i = 0U; i < cascade_count; ++i) {
			vec4 scales = map_scales[i];
			float cascade_weight = get_cascade_lod_weight(scales, distance_lod);
			if (cascade_weight <= 0.0)
				continue;
			vec3 coords = vec3(UV*scales.xy, float(i));
			vec4 previous_normal_sample = texture(previous_normals, coords);
			vec4 current_normal_sample = texture(normals, coords);
			if (use_bicubic_normals) {
				float ppm = map_size * min(scales.x, scales.y); // Pixels per meter
				// Mix between bicubic and bilinear filtering depending on the world space pixels per meter.
				// This is dependent on the tile size as well as displacement/normal map resolution.
				previous_normal_sample = mix(texture_bicubic(previous_normals, coords), previous_normal_sample, min(1.0, ppm*0.1));
				current_normal_sample = mix(texture_bicubic(normals, coords), current_normal_sample, min(1.0, ppm*0.1));
			}
			vec4 normal_sample = mix(previous_normal_sample, current_normal_sample, wave_blend_alpha);
			gradient += normal_sample.xyw * vec3(scales.ww, 1.0) * cascade_weight;
		}

		float foam_signal = gradient.z * 0.75 * foam_intensity;
		float foam_edge = foam_threshold + far_foam_threshold_boost * distance_lod;
		float foam_distance_fade = mix(1.0, far_foam_coverage, distance_lod);
		foam_factor = smoothstep(foam_edge, foam_edge + foam_softness, foam_signal) * exp(-dist*0.0075) * foam_distance_fade;

		float near_normal_fade = exp(-dist*0.0175);
		float far_normal_fade = max(far_normal_strength * 0.35, 0.015);
		gradient *= mix(0.015, normal_strength, mix(near_normal_fade, far_normal_fade, distance_lod));
		NORMAL = (VIEW_MATRIX * vec4(normalize(vec3(-gradient.x, 1.0, -gradient.y)), 0.0)).xyz;
	}

	ALBEDO = mix(water_color.rgb, foam_color.rgb, foam_factor);

	float cos_view = clamp(dot(VIEW, NORMAL), 0.0, 1.0);
	fresnel = mix(pow(1.0 - cos_view, 5.0*exp(-2.69*roughness)) / (1.0 + 22.7*pow(roughness, 1.5)), 1.0, REFLECTANCE);
	lighting_roughness = clamp(roughness + (1.0 - fresnel) * foam_factor * 0.35, 0.0, 1.0);
	ROUGHNESS = lighting_roughness;
	SPECULAR = clamp(specular_strength, 0.0, 1.0);
}

float smith_masking_shadowing(in float cos_theta, in float alpha) {
	cos_theta = clamp(cos_theta, 0.0001, 0.9999);
	alpha = max(alpha, 0.0001);
	float a = cos_theta / (alpha * sqrt(1.0 - cos_theta*cos_theta)); // Approximate: 1.0 / (alpha * tan(acos(cos_theta)))
	float a_sq = a*a;
	return a < 1.6 ? (1.0 - 1.259*a + 0.396*a_sq) / (3.535*a + 2.181*a_sq) : 0.0;
}

// Source: https://github.com/godotengine/godot/blob/7b56111c297f24304eb911fe75082d8cdc3d4141/drivers/gles3/shaders/scene.glsl#L995
float ggx_distribution(in float cos_theta, in float alpha) {
	float a_sq = alpha*alpha;
	float d = 1.0 + (a_sq - 1.0) * cos_theta * cos_theta;
	return a_sq / (PI * d*d);
}

void light() {
	vec3 halfway = normalize(LIGHT + VIEW);
	float raw_dot_nl = dot(NORMAL, LIGHT);
	float dot_nl = max(raw_dot_nl, 2e-5);
	float dot_nv = max(dot(NORMAL, VIEW), 2e-5);

	// --- SPECULAR ---
	float alpha = max(lighting_roughness, 0.04);
	float light_mask = smith_masking_shadowing(dot_nl, alpha);
	float view_mask = smith_masking_shadowing(dot_nv, alpha);
	float microfacet_distribution = ggx_distribution(max(dot(NORMAL, halfway), 0.0), alpha);
	float geometric_attenuation = 1.0 / (1.0 + light_mask + view_mask);
	float broad_glint = pow(max(dot(reflect(-LIGHT, NORMAL), VIEW), 0.0), mix(96.0, 18.0, lighting_roughness));
	float specular_light = (microfacet_distribution * geometric_attenuation / (4.0 * dot_nv + 0.1) + broad_glint * 0.16) * fresnel * sun_glint_strength;
	SPECULAR_LIGHT += specular_light * ATTENUATION * LIGHT_COLOR * specular_strength;

	// --- DIFFUSE ---
	const vec3 sss_modifier = vec3(0.9,1.15,0.85); // Subsurface scattering produces a 'greener' color.
	float wrapped_light = smoothstep(-0.35, 0.85, raw_dot_nl);
	float forward_scatter = pow(max(dot(LIGHT, -VIEW), 0.0), 2.5);
	float crest_scatter = max(0.0, wave_height + 2.0) * forward_scatter * pow(max(0.0, 0.5 - 0.5 * raw_dot_nl), 2.0);
	float view_scatter = 0.35 * pow(dot_nv, 2.0);
	vec3 water_scatter = water_color.rgb * sss_modifier;
	vec3 water_diffuse = water_color.rgb * (0.18 + 0.82 * wrapped_light) * direct_light_strength;
	water_diffuse += (crest_scatter + view_scatter) * water_scatter * water_scatter_strength / (1.0 + light_mask);
	DIFFUSE_LIGHT += mix(water_diffuse, foam_color.rgb, foam_factor) * (1.0 - fresnel * 0.65) * ATTENUATION * LIGHT_COLOR;
}
