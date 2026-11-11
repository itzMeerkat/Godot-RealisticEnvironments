#[compute]
#version 460
/**
 * Interactive waves, step 5 (GREOceanInteraction): the map the water samples, in two
 * dispatches.
 *
 * Pass 0 writes each cell's drawn height into the FFT buffer's input half (free until
 * the next step): soft-limited, and zero inside the hulls' footprints, so waves never
 * show through a hull. Pass 1 writes the map at the cell's texel: that height, its
 * slopes (central differences, soft-limited) and their squared length. Every channel
 * averages linearly, so the mips hold the mean slope and the slope variance a texel
 * hides (as the wave normal maps do).
 */

#include "interaction_common.glslinc"

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(std430, set = 0, binding = 0) restrict buffer FFTBuffer {
	vec2 data[]; // input half, then output half: map_size^2 each
};

layout(std430, set = 0, binding = 1) restrict readonly buffer HullBuffer {
	InteractionHull hulls[];
};

// (height, slope x, slope z, squared slope), mip 0.
layout(rgba16f, set = 0, binding = 2) restrict writeonly uniform image2D interaction_map;

layout(push_constant) restrict readonly uniform PushConstants {
	int pass_index;
	int origin_x; // the window's first cell
	int origin_z;
	float cell_size;  // m
	uint hull_count;
	float max_height; // m: heights approach it smoothly
	float max_slope;  // slopes approach it smoothly
};

// The texel at offset from texel, wrapped (cells repeat every map_size texels).
uint wrapped_index(ivec2 texel, ivec2 offset, int map_size) {
	ivec2 t = (texel + offset) & (map_size - 1);
	return uint(t.y * map_size + t.x);
}

void main() {
	int map_size = int(gl_NumWorkGroups.x * gl_WorkGroupSize.x);
	ivec2 texel = ivec2(gl_GlobalInvocationID.xy);
	uint index = uint(texel.y * map_size + texel.x);

	if (pass_index == 0) {
		ivec2 cell = interaction_cell(texel, ivec2(origin_x, origin_z), map_size);
		vec2 p = (vec2(cell) + 0.5) * cell_size;
		float coverage = 0.0;
		for (uint i = 0u; i < hull_count; ++i) {
			InteractionHull hull = hulls[i];
			if (hull.shape.w > 0.0 && !interaction_outside_bounds(hull.pose, hull.shape, p, 1.0)) {
				coverage = max(coverage, 1.0 - smoothstep(0.75, 1.0, interaction_footprint_radius(hull.pose, hull.shape, p)));
			}
		}
		float h = data[uint(map_size * map_size) + index].x;
		data[index] = vec2(max_height * tanh(h / max_height) * (1.0 - coverage), 0.0);
		return;
	}

	float h = data[index].x;
	vec2 slope = vec2(
		data[wrapped_index(texel, ivec2(1, 0), map_size)].x - data[wrapped_index(texel, ivec2(-1, 0), map_size)].x,
		data[wrapped_index(texel, ivec2(0, 1), map_size)].x - data[wrapped_index(texel, ivec2(0, -1), map_size)].x) / (2.0 * cell_size);
	slope /= sqrt(1.0 + dot(slope, slope) / (max_slope * max_slope));
	imageStore(interaction_map, texel, vec4(h, slope, dot(slope, slope)));
}
