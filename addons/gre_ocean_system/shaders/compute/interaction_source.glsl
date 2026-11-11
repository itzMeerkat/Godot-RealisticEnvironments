#[compute]
#version 460
/**
 * Interactive waves, step 1 (GREOceanInteraction): the hulls' sources and the damped
 * border, from the last state (the FFT buffer's output half: h + i dh/dt per texel)
 * into its input half.
 *
 * A hull adds water where its footprint arrives and takes it away where it leaves:
 * h += T_now - T_previous, with T its depth profile and the previous footprint moved
 * along with the water since, so only motion relative to the water makes waves (a
 * thin-ship source: a bow crest, a stern trough and, through the dispersion, the Kelvin
 * wake). Cells the window entered since the last step start flat; a band along the
 * window's edge damps the waves before they reach it.
 */

#include "interaction_common.glslinc"

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(std430, set = 0, binding = 0) restrict buffer FFTBuffer {
	vec2 data[]; // input half, then output half: map_size^2 each
};

layout(std430, set = 0, binding = 1) restrict readonly buffer HullBuffer {
	InteractionHull hulls[];
};

layout(push_constant) restrict readonly uniform PushConstants {
	int origin_x;          // the window's first cell
	int origin_z;
	int previous_origin_x; // ... at the last step
	int previous_origin_z;
	float cell_size;       // m
	uint hull_count;
	float border_width;    // m
	float border_damping;  // 1/s at the edge
	float delta;           // s
};

void main() {
	int map_size = int(gl_NumWorkGroups.x * gl_WorkGroupSize.x);
	ivec2 texel = ivec2(gl_GlobalInvocationID.xy);
	ivec2 origin = ivec2(origin_x, origin_z);
	ivec2 cell = interaction_cell(texel, origin, map_size);
	uint index = uint(texel.y * map_size + texel.x);
	vec2 state = data[uint(map_size * map_size) + index];
	if (cell != interaction_cell(texel, ivec2(previous_origin_x, previous_origin_z), map_size)) {
		state = vec2(0.0);
	}

	vec2 p = (vec2(cell) + 0.5) * cell_size;
	for (uint i = 0u; i < hull_count; ++i) {
		InteractionHull hull = hulls[i];
		state.x += interaction_hull_depth(hull.pose, hull.shape, p, 1.0) - interaction_hull_depth(hull.previous_pose, hull.previous_shape, p, 1.0);
	}

	vec2 inside = vec2(cell - origin) + 0.5;
	vec2 to_edge = min(inside, vec2(map_size) - inside) * cell_size;
	float border = clamp(1.0 - min(to_edge.x, to_edge.y) / border_width, 0.0, 1.0);
	state *= exp(-border_damping * border * border * delta);
	data[index] = state;
}
