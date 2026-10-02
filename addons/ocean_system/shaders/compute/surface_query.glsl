#[compute]
#version 460
/**
 * Samples the rendered ocean surface at arbitrary world-space points. Used by
 * buoyancy/gameplay queries, where reading back whole displacement textures
 * would be far too expensive.
 *
 * Heights include the interaction simulation's eta = h + p rather than the
 * visible h, so a hull's own rest depression (h = -p) never costs buoyancy, and
 * only outside hulls (render .w = hull coverage). Under a hull, eta is mostly
 * the water that hull radiated itself; fed back into its buoyancy after the
 * readback delay it acts as a lagging spring and pumps energy into heave. Hulls
 * feel the incident (FFT) waves; bodies without a hull footprint also feel
 * wakes and splashes.
 */

#define WORKGROUP_SIZE 64U

layout(local_size_x = WORKGROUP_SIZE, local_size_y = 1, local_size_z = 1) in;

layout(push_constant) restrict readonly uniform PushConstants {
	uint point_count;
	uint cascade_count;
	float water_level;
	float normal_sample_distance;
	vec2 interaction_center;      // world XZ of the simulation window center
	float interaction_cell_size;
	float interaction_fade_start; // Chebyshev distance from the center (m)
	float interaction_fade_end;
	uint interaction_enabled;
};

#define OCEAN_SAMPLING_SET 0
#define OCEAN_CASCADE_BUFFER_BINDING 1
#define OCEAN_DISPLACEMENT_A_BINDING 3
#define OCEAN_DISPLACEMENT_B_BINDING 4
#include "ocean_sampling.glslinc"

struct SurfaceSample {
	vec4 displacement_height; // xyz = displacement of the surface point, w = height
	vec4 normal_data;         // xyz = normal, w = unused
	vec4 surface_velocity;    // xyz = displacement velocity, w = unused
};

layout(std430, set = 0, binding = 0) restrict readonly buffer PointBuffer {
	vec4 points[];
};

layout(std430, set = 0, binding = 2) restrict writeonly buffer SampleBuffer {
	SurfaceSample samples[];
};

// Interaction render texture (rgba16f: h, eta, foam), wrap-around addressed.
layout(rgba16f, set = 0, binding = 5) restrict readonly uniform image2D interaction_render;

// Bilinear eta weighted by (1 - hull coverage) of each texel.
float sample_interaction_eta(vec2 p) {
	if (interaction_enabled == 0U) {
		return 0.0;
	}
	vec2 from_center = abs(p - interaction_center);
	float fade = 1.0 - smoothstep(interaction_fade_start, interaction_fade_end, max(from_center.x, from_center.y));
	if (fade <= 0.0) {
		return 0.0;
	}
	ivec2 dims = imageSize(interaction_render);
	vec2 q = p / interaction_cell_size - 0.5;
	ivec2 base = ivec2(floor(q));
	vec2 f = q - vec2(base);
	ivec2 p0 = base & (dims - 1);
	ivec2 p1 = (p0 + 1) & (dims - 1);
	vec4 t00 = imageLoad(interaction_render, p0);
	vec4 t10 = imageLoad(interaction_render, ivec2(p1.x, p0.y));
	vec4 t01 = imageLoad(interaction_render, ivec2(p0.x, p1.y));
	vec4 t11 = imageLoad(interaction_render, p1);
	float e00 = t00.y * (1.0 - t00.w);
	float e10 = t10.y * (1.0 - t10.w);
	float e01 = t01.y * (1.0 - t01.w);
	float e11 = t11.y * (1.0 - t11.w);
	return mix(mix(e00, e10, f.x), mix(e01, e11, f.x), f.y) * fade;
}

float sample_total_height(vec2 p) {
	return ocean_sample_surface_height(p) + sample_interaction_eta(p);
}

void main() {
	uint index = gl_GlobalInvocationID.x;
	if (index >= point_count) {
		return;
	}

	vec2 p = points[index].xz;
	vec2 source = ocean_invert_horizontal_displacement(p);
	vec3 visual_displacement;
	vec3 velocity;
	ocean_sample_displacement_and_velocity(source, visual_displacement, velocity);
	visual_displacement.y += sample_interaction_eta(p);

	float e = max(normal_sample_distance, 0.001);
	float h_l = sample_total_height(p + vec2(-e, 0.0));
	float h_r = sample_total_height(p + vec2( e, 0.0));
	float h_b = sample_total_height(p + vec2(0.0, -e));
	float h_f = sample_total_height(p + vec2(0.0,  e));
	vec3 normal = normalize(vec3(h_l - h_r, 2.0 * e, h_b - h_f));

	samples[index].displacement_height = vec4(visual_displacement, water_level + visual_displacement.y);
	samples[index].normal_data = vec4(normal, 0.0);
	samples[index].surface_velocity = vec4(velocity, 0.0);
}
