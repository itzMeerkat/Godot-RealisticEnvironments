#[compute]
#version 460
/**
 * Clears cells that entered the simulation window after it moved with the
 * camera: texels whose world cell under the new origin differs from the one
 * under the old origin.
 */

#include "iwave_common.glslinc"

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(rgba32f, set = 0, binding = 0) restrict writeonly uniform image2D state;
layout(rgba16f, set = 0, binding = 1) restrict writeonly uniform image2D render;

layout(push_constant) restrict readonly uniform PushConstants {
	ivec2 old_origin;
	ivec2 new_origin;
	int grid_size;
};

void main() {
	ivec2 texel = ivec2(gl_GlobalInvocationID.xy);
	if (iwave_texel_to_cell(texel, old_origin, grid_size) == iwave_texel_to_cell(texel, new_origin, grid_size)) {
		return;
	}
	imageStore(state, texel, vec4(0.0, 0.0, IWAVE_NO_PRESSURE, IWAVE_NO_PRESSURE));
	imageStore(render, texel, vec4(0.0));
}
