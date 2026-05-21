shader_type spatial;
render_mode world_vertex_coords, cull_disabled, shadows_disabled;
/**
 * Water uses Godot's built-in spatial PBR lighting. The shader only provides
 * displacement, normals, foam color, and dynamic material properties.
 */

#define MAX_CASCADES 8
#define MAX_HULL_CUTOUTS 16
#define MAX_MANUAL_FOAM_SOURCES 96

uniform vec4 water_color : source_color;
uniform vec4 foam_color : source_color;

uniform float clear_roughness : hint_range(0.0, 1.0) = 0.06;
uniform float foam_roughness : hint_range(0.0, 1.0) = 0.24;
uniform float clear_specular : hint_range(0.0, 1.0) = 0.85;
uniform float foam_specular : hint_range(0.0, 1.0) = 0.35;
uniform float slope_roughness_strength : hint_range(0.0, 4.0) = 0.55;
uniform float normal_strength : hint_range(0.0, 1.0) = 1.0; // Global normal strength
uniform float foam_intensity : hint_range(0.0, 4.0) = 1.25;
uniform float foam_threshold : hint_range(0.0, 2.0) = 0.05;
uniform float foam_softness : hint_range(0.01, 2.0) = 0.35;
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
uniform float far_foam_threshold_boost : hint_range(0.0, 1.0) = 0.2;
uniform int hull_cutout_count = 0;
uniform vec4 hull_cutout_centers[MAX_HULL_CUTOUTS]; // xyz center, feather in meters
uniform vec4 hull_cutout_axes[MAX_HULL_CUTOUTS];    // right.xz, forward.xz
uniform vec4 hull_cutout_shapes[MAX_HULL_CUTOUTS];  // max half width, half length, foam amount, shape type
uniform vec4 hull_cutout_verticals[MAX_HULL_CUTOUTS]; // min y, max y, height feather, unused
uniform vec4 hull_cutout_widths[MAX_HULL_CUTOUTS]; // start half width, end half width, unused, unused
uniform int manual_foam_count = 0;
uniform vec4 manual_foam_sources[MAX_MANUAL_FOAM_SOURCES]; // xz center, radius, amount
uniform vec4 manual_foam_shapes[MAX_MANUAL_FOAM_SOURCES]; // direction.xz, half length, unused

group_uniforms cascade_data;
uniform vec4 map_scales[MAX_CASCADES];               // Scales for displacement/normal maps. Packed: [uv scale, displacement scale, normal scale]
uniform vec4 spectrum_blend_states[MAX_CASCADES];    // Packed: [active layer, pending layer, blend alpha, unused]
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

float get_hull_cutout_sdf(vec3 world_position, int index) {
	vec4 center = hull_cutout_centers[index];
	vec4 axes = hull_cutout_axes[index];
	vec4 shape = hull_cutout_shapes[index];
	vec4 widths = hull_cutout_widths[index];
	vec2 delta = world_position.xz - center.xz;
	vec2 right = normalize(axes.xy);
	vec2 forward = normalize(axes.zw);
	vec2 local = vec2(dot(delta, right), dot(delta, forward));
	float half_length = max(shape.y, 0.001);
	float half_width = shape.x;
	if (shape.w > 0.5) {
		float t = clamp(local.y / (half_length * 2.0) + 0.5, 0.0, 1.0);
		half_width = mix(widths.x, widths.y, t);
	}
	vec2 q = vec2(abs(local.x) - half_width, abs(local.y) - half_length);
	return length(max(q, vec2(0.0))) + min(max(q.x, q.y), 0.0);
}

float get_hull_cutout_height_mask(vec3 world_position, int index) {
	vec4 vertical = hull_cutout_verticals[index];
	float height_feather = max(vertical.z, 0.001);
	return 1.0 - smoothstep(vertical.y, vertical.y + height_feather, world_position.y);
}

float sample_manual_foam(vec3 world_position) {
	float foam = 0.0;
	for (int i = 0; i < min(manual_foam_count, MAX_MANUAL_FOAM_SOURCES); ++i) {
		vec4 source = manual_foam_sources[i];
		vec4 shape = manual_foam_shapes[i];
		float radius = max(source.z, 0.001);
		vec2 delta = world_position.xz - source.xy;
		float half_length = max(shape.z, 0.0);
		if (half_length > 0.001) {
			vec2 direction = normalize(shape.xy);
			delta -= direction * clamp(dot(delta, direction), -half_length, half_length);
		}
		float dist = length(delta) / radius;
		float spot = (1.0 - smoothstep(0.15, 1.0, dist)) * source.w;
		foam = max(foam, spot);
	}
	return clamp(foam, 0.0, 1.0);
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
		vec3 pending_coords = vec3(UV*scales.xy, blend_state.y);
		vec3 previous_active = texture(previous_displacements, active_coords).xyz;
		vec3 current_active = texture(displacements, active_coords).xyz;
		vec3 previous_pending = texture(previous_displacements, pending_coords).xyz;
		vec3 current_pending = texture(displacements, pending_coords).xyz;
		vec3 active_displacement = mix(previous_active, current_active, wave_blend_alpha);
		vec3 pending_displacement = mix(previous_pending, current_pending, wave_blend_alpha);
		displacement += mix(active_displacement, pending_displacement, blend_state.z) * scales.z * cascade_weight;
	}
	VERTEX += displacement;
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

void fragment() {
	float hull_edge_foam = 0.0;
	for (int i = 0; i < min(hull_cutout_count, MAX_HULL_CUTOUTS); ++i) {
		float cutout_sdf = get_hull_cutout_sdf(water_world_position, i);
		float height_mask = get_hull_cutout_height_mask(water_world_position, i);
		if (cutout_sdf < 0.0 && height_mask > 0.5) {
			discard;
		}
		vec4 center = hull_cutout_centers[i];
		vec4 shape = hull_cutout_shapes[i];
		float feather = max(center.w, 0.001);
		hull_edge_foam = max(hull_edge_foam, (1.0 - smoothstep(0.0, feather, cutout_sdf)) * shape.z * height_mask);
	}

	float dist = distance_to_camera;
	vec3 gradient = vec3(0);
	float wave_slope = 0.0;
	foam_factor = 0.0;
	float manual_foam = sample_manual_foam(water_world_position);

	if (num_cascades > 0) {
		float map_size = float(textureSize(normals, 0).x);
		// Read foam and normal information from normal maps.
		uint cascade_count = min(uint(num_cascades), uint(fragment_cascade_limit));
		for (uint i = 0U; i < cascade_count; ++i) {
			vec4 scales = map_scales[i];
			float cascade_weight = get_cascade_lod_weight(scales, distance_lod);
			if (cascade_weight <= 0.0)
				continue;
			vec4 blend_state = spectrum_blend_states[i];
			vec3 active_coords = vec3(UV*scales.xy, blend_state.x);
			vec3 pending_coords = vec3(UV*scales.xy, blend_state.y);
			vec4 previous_active_sample = texture(previous_normals, active_coords);
			vec4 current_active_sample = texture(normals, active_coords);
			vec4 previous_pending_sample = texture(previous_normals, pending_coords);
			vec4 current_pending_sample = texture(normals, pending_coords);
			if (use_bicubic_normals) {
				float ppm = map_size * min(scales.x, scales.y); // Pixels per meter
				// Mix between bicubic and bilinear filtering depending on the world space pixels per meter.
				// This is dependent on the tile size as well as displacement/normal map resolution.
				previous_active_sample = mix(texture_bicubic(previous_normals, active_coords), previous_active_sample, min(1.0, ppm*0.1));
				current_active_sample = mix(texture_bicubic(normals, active_coords), current_active_sample, min(1.0, ppm*0.1));
				previous_pending_sample = mix(texture_bicubic(previous_normals, pending_coords), previous_pending_sample, min(1.0, ppm*0.1));
				current_pending_sample = mix(texture_bicubic(normals, pending_coords), current_pending_sample, min(1.0, ppm*0.1));
			}
			vec4 active_sample = mix(previous_active_sample, current_active_sample, wave_blend_alpha);
			vec4 pending_sample = mix(previous_pending_sample, current_pending_sample, wave_blend_alpha);
			vec4 normal_sample = mix(active_sample, pending_sample, blend_state.z);
			gradient += normal_sample.xyw * vec3(scales.ww, 1.0) * cascade_weight;
		}

		float foam_signal = gradient.z * 0.75 * foam_intensity;
		float foam_edge = foam_threshold + far_foam_threshold_boost * distance_lod;
		float foam_distance_fade = mix(1.0, far_foam_coverage, distance_lod);
		foam_factor = smoothstep(foam_edge, foam_edge + foam_softness, foam_signal) * exp(-dist*0.0075) * foam_distance_fade;
		foam_factor = max(max(foam_factor, hull_edge_foam), manual_foam);
		wave_slope = clamp(length(gradient.xy) * slope_roughness_strength, 0.0, 1.0);

		float near_normal_fade = exp(-dist*0.0175);
		float far_normal_fade = max(far_normal_strength * 0.35, 0.015);
		gradient *= mix(0.015, normal_strength, mix(near_normal_fade, far_normal_fade, distance_lod));
		NORMAL = (VIEW_MATRIX * vec4(normalize(vec3(-gradient.x, 1.0, -gradient.y)), 0.0)).xyz;
	}
	foam_factor = max(max(foam_factor, hull_edge_foam), manual_foam);

	vec3 base_albedo = mix(water_color.rgb, foam_color.rgb, foam_factor);
	if (planar_reflection_enabled && planar_reflection_strength > 0.0) {
		vec3 reflection_project_position = vec3(water_world_position.x, planar_reflection_plane_y, water_world_position.z);
		vec4 reflection_clip = planar_reflection_view_projection * vec4(reflection_project_position, 1.0);
		float reflection_w = reflection_clip.w;
		if (abs(reflection_w) < 0.0001) {
			reflection_w = 0.0001;
		}
		vec2 reflection_uv = reflection_clip.xy / reflection_w * 0.5 + 0.5;
		reflection_uv.y = 1.0 - reflection_uv.y;
		reflection_uv += gradient.xy * planar_reflection_distortion;
		vec2 reflection_bounds = step(vec2(0.0), reflection_uv) * step(reflection_uv, vec2(1.0));
		float reflection_in_bounds = reflection_bounds.x * reflection_bounds.y * step(0.0001, reflection_clip.w);
		vec4 reflected_sample = texture(planar_reflection_texture, reflection_uv);
		float view_dot = clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0);
		float fresnel = pow(1.0 - view_dot, planar_reflection_fresnel_power);
		float water_reflectance = 0.04 + 0.96 * fresnel;
		float foam_mask = 1.0 - foam_factor * 0.85;
		float reflected_geometry_mask = reflected_sample.a;
		float reflection_amount = planar_reflection_strength * water_reflectance * foam_mask * reflection_in_bounds * reflected_geometry_mask;
		base_albedo = mix(base_albedo, reflected_sample.rgb, reflection_amount);
	}

	ALBEDO = base_albedo;
	METALLIC = 0.0;
	ROUGHNESS = mix(clear_roughness, foam_roughness, max(foam_factor, wave_slope));
	SPECULAR = mix(clear_specular, foam_specular, foam_factor);
}
