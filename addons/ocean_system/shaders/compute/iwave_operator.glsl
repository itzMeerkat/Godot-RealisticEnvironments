#[compute]
#version 460
/**
 * Applies iWave's vertical-derivative operator in the frequency domain:
 * multiplies each wavenumber by g * |k|, the exact deep-water dispersion
 * (omega^2 = g |k|), and by 1 / grid_size^2 to normalize the round trip.
 * The operator is real and even, so the inverse transform stays real.
 */

#define TAU 6.283185307179586

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(rg32f, set = 0, binding = 0) restrict uniform image2D spectrum;

layout(push_constant) restrict readonly uniform PushConstants {
	uint grid_size;
	float cell_size;
	float gravity;
};

void main() {
	ivec2 texel = ivec2(gl_GlobalInvocationID.xy);
	int size = int(grid_size);
	// FFT bin index to signed frequency in [-size/2, size/2).
	ivec2 frequency = texel - size * ivec2(greaterThanEqual(texel, ivec2(size / 2)));
	vec2 wavenumber = TAU * vec2(frequency) / (float(size) * cell_size);
	float scale = gravity * length(wavenumber) / float(size * size);
	imageStore(spectrum, texel, vec4(imageLoad(spectrum, texel).xy * scale, 0.0, 0.0));
}
