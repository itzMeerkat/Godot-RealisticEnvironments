#[compute]
#version 460
/**
 * Adds queued point impulses (splashes) to the wave state. Each impulse adds a
 * Gaussian to eta_n only, which acts as an instant vertical velocity kick.
 */

#include "iwave_common.glslinc"

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(rgba32f, set = 0, binding = 0) restrict uniform image2D state;

layout(std430, set = 0, binding = 1) restrict readonly buffer ImpulseBuffer {
	vec4 impulses[]; // world x, world z, radius (m), amplitude (m)
};

layout(push_constant) restrict readonly uniform PushConstants {
	ivec2 origin;
	int grid_size;
	float cell_size;
	uint impulse_count;
};

void main() {
	ivec2 texel = ivec2(gl_GlobalInvocationID.xy);
	vec2 position = iwave_cell_center(iwave_texel_to_cell(texel, origin, grid_size), cell_size);
	float added = 0.0;
	for (uint i = 0U; i < impulse_count; ++i) {
		vec4 impulse = impulses[i];
		vec2 offset = (position - impulse.xy) / impulse.z;
		float distance_squared = dot(offset, offset);
		if (distance_squared < 9.0) {
			added += impulse.w * exp(-distance_squared);
		}
	}
	if (added == 0.0) {
		return;
	}
	vec4 value = imageLoad(state, texel);
	value.x += added;
	imageStore(state, texel, value);
}
