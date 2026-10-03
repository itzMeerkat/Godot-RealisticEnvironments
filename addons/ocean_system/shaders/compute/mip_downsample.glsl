#[compute]
#version 460
/**
 * Builds one mip level of a wave map layer with a 2x2 box filter of the level
 * above (WaveGenerator runs it for the displacement and the normal maps).
 * Every channel averages linearly. For normal maps that is mean slope (xy),
 * mean squared slope (z) and foam (w), so z - |xy|^2 is the slope variance
 * inside a texel (isotropic LEAN mapping), which the water shader turns into
 * roughness.
 */

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

// 2D views of one layer: mip level - 1 and level.
layout(rgba16f, set = 0, binding = 0) restrict readonly uniform image2D source;
layout(rgba16f, set = 0, binding = 1) restrict writeonly uniform image2D target;

layout(push_constant) restrict readonly uniform PushConstants {
	ivec2 target_size;
};

void main() {
	const ivec2 id = ivec2(gl_GlobalInvocationID.xy);
	if (any(greaterThanEqual(id, target_size))) return; // The last levels are smaller than a workgroup.

	const ivec2 source_id = id * 2;
	vec4 sum = imageLoad(source, source_id);
	sum += imageLoad(source, source_id + ivec2(1, 0));
	sum += imageLoad(source, source_id + ivec2(0, 1));
	sum += imageLoad(source, source_id + ivec2(1, 1));
	imageStore(target, id, sum * 0.25);
}
