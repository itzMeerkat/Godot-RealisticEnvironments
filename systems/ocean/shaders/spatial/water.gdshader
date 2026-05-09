shader_type spatial;
render_mode world_vertex_coords, cull_disabled, shadows_disabled;
/**
 * Water lighting model roughly follows the 2019 GDC talk: "Wakes, Explosions and Lighting: Interactive Water Simulation in Atlas".
 * Source: https://gpuopen.com/gdc-presentations/2019/gdc-2019-agtd6-interactive-water-simulation-in-atlas.pdf
 */

#define MAX_CASCADES 8    // I am unsure how to generalize this.
#define REFLECTANCE  0.02 // Reflectance from air to water (eta=1.33).

global uniform vec4 water_color : source_color;
global uniform vec4 foam_color : source_color;

uniform float roughness : hint_range(0.0, 1.0) = 0.4;
uniform float specular_strength : hint_range(0.0, 1.0) = 0.55;
uniform float normal_strength : hint_range(0.0, 1.0) = 1.0; // Global normal strength
uniform float foam_intensity : hint_range(0.0, 4.0) = 1.25;
uniform float foam_threshold : hint_range(0.0, 2.0) = 0.05;
uniform float foam_softness : hint_range(0.01, 2.0) = 0.35;
uniform bool use_bicubic_normals = false;
uniform int fragment_cascade_limit : hint_range(1, 8) = 3;
uniform bool enable_geometry_morph = false;
uniform float generated_clipmap_extent = 256.0;

group_uniforms cascade_data;
uniform vec4 map_scales[MAX_CASCADES];               // Scales for displacement/normal maps. Packed: [uv scale, displacement scale, normal scale]
global uniform uint num_cascades;
global uniform sampler2DArray displacements;         // Each layer represents one wave cascade.
global uniform sampler2DArray normals : hint_normal; // Each layer represents one wave cascade.
global uniform sampler2DArray previous_displacements;
global uniform sampler2DArray previous_normals : hint_normal;
global uniform float wave_blend_alpha;

varying float wave_height;
varying float foam_factor;
varying float fresnel;

void vertex() {
	if (enable_geometry_morph) {
		float dist = max(abs(VERTEX.x - CAMERA_POSITION_WORLD.x), abs(VERTEX.z - CAMERA_POSITION_WORLD.z));
		float morph_start = COLOR.r * generated_clipmap_extent;
		float morph_end = COLOR.g * generated_clipmap_extent;
		float morph_factor = smoothstep(morph_start, morph_end, dist) * COLOR.b;
		vec2 morph_target = (MODEL_MATRIX * vec4(UV2.x, 0.0, UV2.y, 1.0)).xz;
		VERTEX.xz = mix(VERTEX.xz, morph_target, morph_factor);
	}
	UV = VERTEX.xz;
	float distance_factor = min(exp(-(length(VERTEX.xz - CAMERA_POSITION_WORLD.xz) - 150.0)*0.007), 1.0); // Displacement amonut falls off after 150m.

	// Read displacements from displacement maps.
	vec3 displacement = vec3(0);
	for (uint i = 0U; i < num_cascades; ++i) {
		vec4 scales = map_scales[i];
		if (scales.z == 0.0)
			continue;
		vec3 coords = vec3(UV*scales.xy, float(i));
		vec3 previous_displacement = texture(previous_displacements, coords).xyz;
		vec3 current_displacement = texture(displacements, coords).xyz;
		displacement += mix(previous_displacement, current_displacement, wave_blend_alpha) * scales.z;
	}
	VERTEX += displacement * distance_factor;
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
	float map_size = float(textureSize(normals, 0).x);
	float dist = length(VERTEX.xz - CAMERA_POSITION_WORLD.xz);
	// Read foam and normal information from normal maps.
	vec3 gradient = vec3(0);
	uint cascade_count = min(num_cascades, uint(fragment_cascade_limit));
	for (uint i = 0U; i < cascade_count; ++i) {
		vec4 scales = map_scales[i];
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
		gradient += normal_sample.xyw * vec3(scales.ww, 1.0);
	}
		
	float foam_signal = gradient.z * 0.75 * foam_intensity;
	foam_factor = smoothstep(foam_threshold, foam_threshold + foam_softness, foam_signal) * exp(-dist*0.0075);
	ALBEDO = mix(water_color.rgb, foam_color.rgb, foam_factor);

	gradient *= mix(0.015, normal_strength, exp(-dist*0.0175)); // Blend normal with terrain normal as distance increases.
	NORMAL = (VIEW_MATRIX * vec4(normalize(vec3(-gradient.x, 1.0, -gradient.y)), 0.0)).xyz;

	fresnel = mix(pow(1.0 - dot(VIEW, NORMAL), 5.0*exp(-2.69*roughness)) / (1.0 + 22.7*pow(roughness, 1.5)), 1.0, REFLECTANCE);
	ROUGHNESS = clamp(roughness + (1.0 - fresnel) * foam_factor * 0.35, 0.0, 1.0);
}

float smith_masking_shadowing(in float cos_theta, in float alpha) {
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
	float dot_nl = max(dot(NORMAL, LIGHT), 2e-5);
	float dot_nv = max(dot(NORMAL, VIEW), 2e-5);

	// --- SPECULAR ---
	float light_mask = smith_masking_shadowing(roughness, dot_nv);
	float view_mask = smith_masking_shadowing(roughness, dot_nl);
	float microfacet_distribution = ggx_distribution(dot(NORMAL, halfway), roughness);
	float geometric_attenuation = 1.0 / (1.0 + light_mask + view_mask);
	SPECULAR_LIGHT += fresnel * microfacet_distribution * geometric_attenuation / (4.0 * dot_nv + 0.1) * ATTENUATION * LIGHT_COLOR * specular_strength;

	// --- DIFFUSE ---
	const vec3 sss_modifier = vec3(0.9,1.15,0.85); // Subsurface scattering produces a 'greener' color.
	float sss_height = 1.0*max(0.0, wave_height + 2.5) * pow(max(dot(LIGHT, -VIEW), 0.0), 4.0) * pow(0.5 - 0.5 * dot(LIGHT, NORMAL), 3.0);
	float sss_near = 0.5*pow(dot_nv, 2.0);
	float lambertian = 0.5*dot_nl;
	vec3 water_scatter = water_color.rgb * sss_modifier;
	vec3 water_diffuse = (sss_height + sss_near) * water_scatter / (1.0 + light_mask) + lambertian * water_color.rgb;
	DIFFUSE_LIGHT += mix(water_diffuse, foam_color.rgb, foam_factor) * (1.0 - fresnel) * ATTENUATION * LIGHT_COLOR;
}
