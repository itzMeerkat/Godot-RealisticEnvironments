#[compute]
#version 460
/**
 * Builds up to five mip levels of a wave map layer in one dispatch, for the
 * displacement map (workgroups with z = 0) and the normal map (z = 1) together
 * (WaveGenerator). Each 16 x 16 workgroup box-filters a 32 x 32 tile of the source
 * level into the next level, then keeps halving that tile in shared memory: 16, 8,
 * 4, 2 and 1 texels. Repeated 2x2 averages compose, so every level is the same box
 * filter of the source as level-by-level downsampling.
 *
 * Every channel averages linearly. For normal maps that is mean slope (xy), mean
 * squared slope (z) and foam (w), so z - |xy|^2 is the slope variance inside a
 * texel (isotropic LEAN mapping), which the water shader turns into roughness.
 */

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

// 2D views of one layer: the source level and the next five (bindings past
// level_count repeat a real level and are never written).
layout(rgba16f, set = 0, binding = 0) restrict readonly uniform image2D displacement_source;
layout(rgba16f, set = 0, binding = 1) restrict writeonly uniform image2D displacement_level_1;
layout(rgba16f, set = 0, binding = 2) restrict writeonly uniform image2D displacement_level_2;
layout(rgba16f, set = 0, binding = 3) restrict writeonly uniform image2D displacement_level_3;
layout(rgba16f, set = 0, binding = 4) restrict writeonly uniform image2D displacement_level_4;
layout(rgba16f, set = 0, binding = 5) restrict writeonly uniform image2D displacement_level_5;
layout(rgba16f, set = 0, binding = 6) restrict readonly uniform image2D normal_source;
layout(rgba16f, set = 0, binding = 7) restrict writeonly uniform image2D normal_level_1;
layout(rgba16f, set = 0, binding = 8) restrict writeonly uniform image2D normal_level_2;
layout(rgba16f, set = 0, binding = 9) restrict writeonly uniform image2D normal_level_3;
layout(rgba16f, set = 0, binding = 10) restrict writeonly uniform image2D normal_level_4;
layout(rgba16f, set = 0, binding = 11) restrict writeonly uniform image2D normal_level_5;

layout(push_constant) restrict readonly uniform PushConstants {
	int source_size;  // edge of the source level (texels)
	int level_count;  // levels written: 1-5
};

shared vec4 tile[16][16];

vec4 load_source(bool normal, ivec2 coord) {
	return normal ? imageLoad(normal_source, coord) : imageLoad(displacement_source, coord);
}

void store_level(bool normal, int level, ivec2 coord, vec4 value) {
	if (normal) {
		switch (level) {
			case 1: imageStore(normal_level_1, coord, value); break;
			case 2: imageStore(normal_level_2, coord, value); break;
			case 3: imageStore(normal_level_3, coord, value); break;
			case 4: imageStore(normal_level_4, coord, value); break;
			default: imageStore(normal_level_5, coord, value); break;
		}
	} else {
		switch (level) {
			case 1: imageStore(displacement_level_1, coord, value); break;
			case 2: imageStore(displacement_level_2, coord, value); break;
			case 3: imageStore(displacement_level_3, coord, value); break;
			case 4: imageStore(displacement_level_4, coord, value); break;
			default: imageStore(displacement_level_5, coord, value); break;
		}
	}
}

void main() {
	const bool normal = gl_WorkGroupID.z == 1u;
	const ivec2 local = ivec2(gl_LocalInvocationID.xy);
	const ivec2 group = ivec2(gl_WorkGroupID.xy);
	int size = source_size >> 1;

	// The first level, from the source in memory.
	ivec2 coord = group * 16 + local;
	vec4 value = vec4(0.0);
	if (all(lessThan(coord, ivec2(size)))) {
		ivec2 source = coord * 2;
		value = (load_source(normal, source) + load_source(normal, source + ivec2(1, 0))
				+ load_source(normal, source + ivec2(0, 1)) + load_source(normal, source + ivec2(1, 1))) * 0.25;
		store_level(normal, 1, coord, value);
	}
	tile[local.y][local.x] = value;

	// The rest from the tile in shared memory, halving it each level.
	int width = 16;
	for (int level = 2; level <= level_count; ++level) {
		memoryBarrierShared();
		barrier();
		width >>= 1;
		size >>= 1;
		bool inside = all(lessThan(local, ivec2(width)));
		vec4 next = vec4(0.0);
		if (inside) {
			ivec2 t = local * 2;
			next = (tile[t.y][t.x] + tile[t.y][t.x + 1] + tile[t.y + 1][t.x] + tile[t.y + 1][t.x + 1]) * 0.25;
			ivec2 level_coord = group * width + local;
			if (all(lessThan(level_coord, ivec2(size)))) {
				store_level(normal, level, level_coord, next);
			}
		}
		memoryBarrierShared();
		barrier();
		if (inside) {
			tile[local.y][local.x] = next;
		}
	}
}
