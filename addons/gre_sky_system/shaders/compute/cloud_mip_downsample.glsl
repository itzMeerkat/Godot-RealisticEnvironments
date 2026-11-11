#[compute]
#version 450
/**
 * Builds one mip level of a cloud cubemap with a 2x2 box filter of the level
 * above, per face (no filtering across face edges). Premultiplied radiance and
 * opacity average linearly, so every level composites like the top one.
 * Consumers read coarser levels for blurred cloud reflections.
 */

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

// Cube views of one mip each: level - 1 and level.
layout(rgba16f, set = 0, binding = 0) uniform restrict readonly imageCube source;
layout(rgba16f, set = 0, binding = 1) uniform restrict writeonly imageCube target;

layout(push_constant, std430) restrict readonly uniform PushConstants {
	int source_size;
	int target_size;
	int face_mode; // as cloud_raymarch.glsl: 0 every face but -Y (it stays cleared), 1 every face
} pc;

const int SEA_FACES[5] = int[](0, 1, 2, 4, 5);

void main() {
	ivec2 texel = ivec2(gl_GlobalInvocationID.xy);
	if (any(greaterThanEqual(texel, ivec2(pc.target_size)))) {
		return;
	}
	int face = pc.face_mode == 0 ? SEA_FACES[gl_GlobalInvocationID.z] : int(gl_GlobalInvocationID.z);
	// Clamped: a level with an odd size drops its last row and column.
	ivec2 last = ivec2(pc.source_size - 1);
	ivec2 source_texel = texel * 2;
	vec4 sum = imageLoad(source, ivec3(min(source_texel, last), face));
	sum += imageLoad(source, ivec3(min(source_texel + ivec2(1, 0), last), face));
	sum += imageLoad(source, ivec3(min(source_texel + ivec2(0, 1), last), face));
	sum += imageLoad(source, ivec3(min(source_texel + ivec2(1, 1), last), face));
	imageStore(target, ivec3(texel, face), sum * 0.25);
}
