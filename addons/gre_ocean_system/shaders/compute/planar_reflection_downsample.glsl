#[compute]
#version 450
/**
 * One level of the planar reflection capture's mip chain
 * (GREPlanarReflectionCaptureEffect): a 2x2 box filter of the level above.
 */

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

// 2D views of one mip each: level - 1 and level.
layout(rgba16f, set = 0, binding = 0) uniform restrict readonly image2D source;
layout(rgba16f, set = 0, binding = 1) uniform restrict writeonly image2D target;

layout(push_constant, std430) uniform Params {
	ivec2 source_size;
	ivec2 target_size;
} params;

void main() {
	ivec2 texel = ivec2(gl_GlobalInvocationID.xy);
	if (any(greaterThanEqual(texel, params.target_size))) {
		return;
	}
	// 2x2 box; clamped, so a level with an odd size drops its last row or column.
	ivec2 last = params.source_size - 1;
	ivec2 source_texel = texel * 2;
	vec4 sum = imageLoad(source, min(source_texel, last));
	sum += imageLoad(source, min(source_texel + ivec2(1, 0), last));
	sum += imageLoad(source, min(source_texel + ivec2(0, 1), last));
	sum += imageLoad(source, min(source_texel + ivec2(1, 1), last));
	imageStore(target, texel, sum * 0.25);
}
