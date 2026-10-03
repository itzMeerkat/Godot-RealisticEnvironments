#[compute]
#version 460
/**
 * In-place 1D FFT of every row (or column) of the complex spectrum texture.
 * One workgroup transforms one line in shared memory (radix-2, bit-reversed
 * load, iterative Cooley-Tukey). Unnormalized in both directions; the operator
 * pass divides by grid_size^2.
 */

#define THREADS 128U
#define MAX_SIZE 1024U
#define TAU 6.283185307179586

layout(local_size_x = THREADS, local_size_y = 1, local_size_z = 1) in;

layout(rg32f, set = 0, binding = 0) restrict uniform image2D spectrum;

layout(push_constant) restrict readonly uniform PushConstants {
	uint grid_size;
	uint log2_size;
	uint along_columns; // 0: transform rows, 1: transform columns
	float direction;    // -1: forward, +1: inverse
};

shared vec2 line_data[MAX_SIZE];

vec2 complex_multiply(vec2 a, vec2 b) {
	return vec2(a.x * b.x - a.y * b.y, a.x * b.y + a.y * b.x);
}

ivec2 line_texel(uint line, uint index) {
	return along_columns != 0U ? ivec2(line, index) : ivec2(index, line);
}

void main() {
	uint line = gl_WorkGroupID.x;
	uint thread = gl_LocalInvocationID.x;

	for (uint i = thread; i < grid_size; i += THREADS) {
		uint reversed = bitfieldReverse(i) >> (32U - log2_size);
		line_data[reversed] = imageLoad(spectrum, line_texel(line, i)).xy;
	}
	barrier();

	for (uint stage = 1U; stage <= log2_size; ++stage) {
		uint half_span = 1U << (stage - 1U);
		for (uint butterfly = thread; butterfly < grid_size / 2U; butterfly += THREADS) {
			uint k = butterfly & (half_span - 1U);
			uint i0 = ((butterfly >> (stage - 1U)) << stage) + k;
			uint i1 = i0 + half_span;
			float angle = direction * TAU * float(k) / float(half_span << 1U);
			vec2 twiddled = complex_multiply(vec2(cos(angle), sin(angle)), line_data[i1]);
			vec2 value = line_data[i0];
			line_data[i0] = value + twiddled;
			line_data[i1] = value - twiddled;
		}
		barrier();
	}

	for (uint i = thread; i < grid_size; i += THREADS) {
		imageStore(spectrum, line_texel(line, i), vec4(line_data[i], 0.0, 0.0));
	}
}
