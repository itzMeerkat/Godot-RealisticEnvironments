#[compute]
#version 460
/**
 * Interactive waves, foam (GREOceanInteraction): the foam hulls churn up, as coverage per
 * cell (0-1) that the water adds to the whitecaps' (foam_signal), so it gets the same
 * lace, roughness and lighting.
 *
 * Each step the foam moves with the surface drift: its data by whole cells (never
 * resampled, so it never blurs), the rest as an offset (foam_offset: the foam of a
 * cell lies at its centre plus it), which the water applies when it samples the map,
 * so the foam moves smoothly. It fades by decay. Its sources:
 *   - hulls: each holds the coverage its speed through the water churns up (foam.x)
 *     over its footprint grown by foam_reach, so the foam rings the waterline; what it
 *     leaves behind is the wake's trail. Its width follows the hull, its density the
 *     speed (not the draft), and a hull riding the swell churns nothing;
 *   - crests: the simulated waves' slope past a threshold, where wake crests break,
 *     growing the coverage toward crest_max_coverage (lace, never a solid sheet).
 * The state lives in two halves of foam_buffer, read one step, written the next.
 */

#include "interaction_common.glslinc"

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(std430, set = 0, binding = 0) restrict readonly buffer FFTBuffer {
	vec2 data[]; // input half, then output half (x: the simulated height h)
};

layout(std430, set = 0, binding = 1) restrict readonly buffer HullBuffer {
	InteractionHull hulls[];
};

layout(std430, set = 0, binding = 2) restrict buffer FoamBuffer {
	float foam[]; // two halves of map_size^2: the coverage per texel
};

// (coverage, 0, 0, 0), mip 0.
layout(rgba16f, set = 0, binding = 3) restrict writeonly uniform image2D foam_map;

layout(push_constant) restrict readonly uniform PushConstants {
	int origin_x;          // the window's first cell
	int origin_z;
	int previous_origin_x; // ... at the last step
	int previous_origin_z;
	int shift_x;           // cells the foam drifts this step
	int shift_z;
	int read_half;         // the foam_buffer half holding the last step's foam
	uint hull_count;
	float cell_size;       // m
	float delta;           // s
	float decay;           // share of the foam left after the step
	float foam_reach;      // the hull footprint grown by this for foam
	float crest_slope;     // slope past which crests foam ...
	float crest_rate;      // ... growing coverage at this rate (1/s) per unit of slope ...
	float crest_max_coverage; // ... toward this
	float foam_offset_x;   // m: where the foam lies past its cell's centre
	float foam_offset_z;
};

uint texel_index(ivec2 texel, int map_size) {
	ivec2 t = texel & (map_size - 1);
	return uint(t.y * map_size + t.x);
}

void main() {
	int map_size = int(gl_NumWorkGroups.x * gl_WorkGroupSize.x);
	uint count = uint(map_size * map_size);
	ivec2 texel = ivec2(gl_GlobalInvocationID.xy);
	ivec2 cell = interaction_cell(texel, ivec2(origin_x, origin_z), map_size);

	// Last step's foam, from where the drift brought it; none if that cell was not in
	// the window then.
	ivec2 source_cell = cell - ivec2(shift_x, shift_z);
	ivec2 source_texel = source_cell & (map_size - 1);
	float coverage = 0.0;
	if (interaction_cell(source_texel, ivec2(previous_origin_x, previous_origin_z), map_size) == source_cell) {
		coverage = foam[uint(read_half) * count + texel_index(source_texel, map_size)];
	}
	coverage *= decay;

	vec2 p = (vec2(cell) + 0.5) * cell_size + vec2(foam_offset_x, foam_offset_z);
	for (uint i = 0u; i < hull_count; ++i) {
		InteractionHull hull = hulls[i];
		if (hull.foam.x > 0.0 && !interaction_outside_bounds(hull.pose, hull.shape, p, foam_reach)) {
			float r = interaction_footprint_radius(hull.pose, hull.shape, p);
			// Densest along the middle, fading out past the waterline.
			coverage = max(coverage, hull.foam.x * (1.0 - smoothstep(0.4, foam_reach, r)));
		}
	}
	vec2 slope = vec2(
		data[count + texel_index(texel + ivec2(1, 0), map_size)].x - data[count + texel_index(texel - ivec2(1, 0), map_size)].x,
		data[count + texel_index(texel + ivec2(0, 1), map_size)].x - data[count + texel_index(texel - ivec2(0, 1), map_size)].x) / (2.0 * cell_size);
	float rate = crest_rate * max(length(slope) - crest_slope, 0.0);
	coverage += max(crest_max_coverage - coverage, 0.0) * min(rate * delta, 1.0);

	uint index = uint(texel.y * map_size + texel.x);
	foam[uint(1 - read_half) * count + index] = coverage;
	imageStore(foam_map, texel, vec4(coverage, 0.0, 0.0, 0.0));
}
