#[compute]
#version 460
/**
 * Samples the rendered ocean surface at arbitrary world-space points. Used by
 * gameplay queries, where reading back whole displacement textures would be far
 * too expensive.
 *
 * The interactive waves: the first interaction_point_count points (GREOceanSystem's camera)
 * get their drawn height (the map). Every other point gets its owner's response times the
 * simulated waves (GREOceanInteraction's state: height and rate, soft-limited as drawn);
 * inside a rim around the owner's own hull (GREOceanSurfaceQueries._write_owner_record())
 * those are interpolated from the rim, so a hull never feels the water it displaces
 * itself.
 */

#define WORKGROUP_SIZE 64U

layout(local_size_x = WORKGROUP_SIZE, local_size_y = 1, local_size_z = 1) in;

layout(push_constant) restrict readonly uniform PushConstants {
	uint point_count;
	uint cascade_count;
	float water_level;
	float normal_sample_distance;
	uint interaction_point_count;
	// The interactive waves' window (GREOceanInteraction.get_window()) and where they
	// start to fade out (share of the half size), as interaction_fade() in water.gdshaderinc.
	float interaction_center_x;
	float interaction_center_z;
	float interaction_half_size;
	float interaction_map_scale;
	float interaction_fade_start;
	// The simulation's state (GREOceanInteraction): its first cell, cells per side (0: no
	// simulation), cell size (m) and soft height limit (m).
	int interaction_origin_x;
	int interaction_origin_z;
	int interaction_map_size;
	float interaction_cell_size;
	float interaction_max_height;
};

#define OCEAN_SAMPLING_SET 0
#define OCEAN_CASCADE_BUFFER_BINDING 1
#define OCEAN_DISPLACEMENT_A_BINDING 3
#define OCEAN_DISPLACEMENT_B_BINDING 4
#include "ocean_sampling.glslinc"
#include "interaction_common.glslinc"

#define TAU 6.283185307179586
#define RIM_SAMPLES 8

struct SurfaceSample {
	vec4 displacement_height; // xyz = displacement of the surface point, w = height
	vec4 normal_data;         // xyz = normal, w = unused
	vec4 surface_velocity;    // xyz = displacement velocity, w = unused
};

layout(std430, set = 0, binding = 0) restrict readonly buffer PointBuffer {
	vec4 points[]; // xyz = world position, w = its owner's record (OwnerBuffer)
};

// One per query owner (GREOceanSurfaceQueries.dispatch()): the rim around its hull's
// footprint as InteractionHull's pose (centre x, z, length axis x, z) and shape (half
// length, half beam, exponent; exponent 0: no hull), and shape.w its wave response.
struct QueryOwner {
	vec4 pose;
	vec4 shape;
};

layout(std430, set = 0, binding = 6) restrict readonly buffer OwnerBuffer {
	QueryOwner owners[];
};

// GREOceanInteraction's FFT buffer: input half, then output half, the state h + i dh/dt.
layout(std430, set = 0, binding = 7) restrict readonly buffer InteractionState {
	vec2 interaction_state[];
};

layout(std430, set = 0, binding = 2) restrict writeonly buffer SampleBuffer {
	SurfaceSample samples[];
};

// The interactive waves' map (GREOceanInteraction): x = height at a rest position, repeating
// every window; repeat, linear sampler.
layout(set = 0, binding = 5) uniform sampler2D interaction_map;

// The simulated (h, dh/dt) of a cell; nothing outside the window.
vec2 interaction_cell_state(ivec2 cell) {
	ivec2 local = cell - ivec2(interaction_origin_x, interaction_origin_z);
	if (any(lessThan(local, ivec2(0))) || any(greaterThanEqual(local, ivec2(interaction_map_size)))) {
		return vec2(0.0);
	}
	ivec2 texel = cell & (interaction_map_size - 1);
	return interaction_state[uint(interaction_map_size * (interaction_map_size + texel.y) + texel.x)];
}

// The simulated (h, dh/dt) at the rest position p, bilinear between cell centres, the
// height soft-limited as drawn (interaction_output.glsl) and the rate with it.
vec2 interaction_waves(vec2 p) {
	vec2 c = p / interaction_cell_size - 0.5;
	ivec2 c0 = ivec2(floor(c));
	vec2 f = c - vec2(c0);
	vec2 state = mix(
		mix(interaction_cell_state(c0), interaction_cell_state(c0 + ivec2(1, 0)), f.x),
		mix(interaction_cell_state(c0 + ivec2(0, 1)), interaction_cell_state(c0 + ivec2(1, 1)), f.x), f.y);
	float limited = tanh(state.x / interaction_max_height);
	return vec2(interaction_max_height * limited, state.y * (1.0 - limited * limited));
}

// The waves owner feels at p: inside the rim around its hull, blended from the rim's mean
// at the centre to the rim straight out from the centre at the rim itself.
vec2 felt_waves(vec2 p, QueryOwner owner) {
	if (owner.shape.z <= 0.0) {
		return interaction_waves(p);
	}
	float r = interaction_footprint_radius(owner.pose, owner.shape, p);
	if (r >= 1.0) {
		return interaction_waves(p);
	}
	vec2 center = owner.pose.xy;
	vec2 length_axis = owner.pose.zw;
	vec2 beam_axis = vec2(-length_axis.y, length_axis.x);
	vec2 rim_mean = vec2(0.0);
	for (int i = 0; i < RIM_SAMPLES; ++i) {
		float angle = TAU * (float(i) + 0.5) / float(RIM_SAMPLES);
		vec2 offset = length_axis * (cos(angle) * owner.shape.x) + beam_axis * (sin(angle) * owner.shape.y);
		float radius = interaction_footprint_radius(owner.pose, owner.shape, center + offset);
		rim_mean += interaction_waves(center + offset / radius);
	}
	rim_mean /= float(RIM_SAMPLES);
	vec2 outward = center + (p - center) / max(r, 1e-3);
	return mix(rim_mean, interaction_waves(outward), r);
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

	// The rendered surface's normal from its tangents at the surface point over p: the
	// displaced positions of its rest neighbours (no inversion needed, unlike heights at
	// world offsets).
	float e = max(normal_sample_distance, 0.001);
	vec3 tangent_x = vec3(2.0 * e, 0.0, 0.0) + ocean_sample_visual_displacement(source + vec2(e, 0.0)) - ocean_sample_visual_displacement(source - vec2(e, 0.0));
	vec3 tangent_z = vec3(0.0, 0.0, 2.0 * e) + ocean_sample_visual_displacement(source + vec2(0.0, e)) - ocean_sample_visual_displacement(source - vec2(0.0, e));

	float height = water_level + visual_displacement.y;
	vec2 window_offset = abs(source - vec2(interaction_center_x, interaction_center_z)) / interaction_half_size;
	float fade = 1.0 - smoothstep(interaction_fade_start, 1.0, max(window_offset.x, window_offset.y));
	QueryOwner owner = owners[uint(points[index].w)];
	if (index < interaction_point_count) {
		height += textureLod(interaction_map, source * interaction_map_scale, 0.0).x * fade;
	} else if (interaction_map_size > 0 && owner.shape.w > 0.0 && fade > 0.0) {
		// The waves are sampled at rest positions, as the water draws them.
		float response = owner.shape.w * fade;
		vec2 waves = felt_waves(source, owner);
		height += waves.x * response;
		// dh/dt of linear waves is the water's vertical velocity there.
		velocity.y += waves.y * response;
		tangent_x.y += (felt_waves(source + vec2(e, 0.0), owner).x - felt_waves(source - vec2(e, 0.0), owner).x) * response;
		tangent_z.y += (felt_waves(source + vec2(0.0, e), owner).x - felt_waves(source - vec2(0.0, e), owner).x) * response;
	}
	vec3 normal = normalize(cross(tangent_z, tangent_x));
	samples[index].displacement_height = vec4(visual_displacement, height);
	samples[index].normal_data = vec4(normal, 0.0);
	samples[index].surface_velocity = vec4(velocity, 0.0);
}
