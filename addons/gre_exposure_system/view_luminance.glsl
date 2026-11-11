#[compute]
#version 450
/*
 * What the eye adapts to in the view: the log-average luminance (Krawczyk et al. 2005's
 * adaptation luminance) of a GRID_X x GRID_Y grid of texels spread across the HDR colour
 * buffer, each at least floor_luminance, plus the glare of the view's bright parts. A log
 * average hardly sees a small bright area (a sunset's glow low in a dark sky), though the
 * eye adapts to it: so the mean of what the texels have above GLARE_KNEE times the log
 * average is added, each counted up to GLARE_CEILING times it (a sun or moon disk on one
 * texel would make the exposure flicker). It fades out from GLARE_FULL_LUMINANCE to
 * GLARE_NONE_LUMINANCE: in daylight the log average serves, a sun in view included. One
 * workgroup does it and writes the natural log of the result into the result buffer. Units
 * are the colour buffer's (GREViewLuminanceEffect turns them into cd/m2).
 */

#define GRID_X 96
#define GRID_Y 54
#define THREADS 256
// Below this share of the log average a texel is the view's ordinary contrast (the sky
// against the sea), not glare.
#define GLARE_KNEE 4.0
#define GLARE_CEILING 100.0
// Log-average luminance (cd/m2): the cones' range begins, and well inside it.
#define GLARE_FULL_LUMINANCE 3.0
#define GLARE_NONE_LUMINANCE 100.0

layout(local_size_x = THREADS, local_size_y = 1, local_size_z = 1) in;

layout(rgba16f, set = 0, binding = 0) uniform restrict readonly image2D color_image;

layout(set = 0, binding = 1, std430) restrict writeonly buffer Result {
	float log_luminance;
} result;

layout(push_constant, std430) restrict readonly uniform PushConstants {
	vec2 size;
	// The darkest luminance counted, in colour-buffer units (black pixels would make the
	// log average 0).
	float floor_luminance;
	// cd/m2 of a colour-buffer value of 1.
	float luminance_scale;
} pc;

shared float partial_sums[THREADS];
shared float shared_log_average;

float grid_luminance(uint i) {
	vec2 cell = vec2(float(i % GRID_X), float(i / GRID_X)) + 0.5;
	ivec2 texel = ivec2(cell / vec2(GRID_X, GRID_Y) * pc.size);
	vec3 rgb = max(imageLoad(color_image, texel).rgb, vec3(0.0));
	float luminance = dot(rgb, vec3(0.2126, 0.7152, 0.0722));
	// NaN pixels count as the floor; overflowed ones as the brightest half float.
	luminance = isnan(luminance) ? pc.floor_luminance : min(luminance, 65504.0);
	return max(luminance, pc.floor_luminance);
}

void main() {
	uint thread = gl_LocalInvocationID.x;
	// First the log average, handed to every thread, then the glare above it.
	float log_average = 0.0;
	for (int pass = 0; pass < 2; ++pass) {
		float sum = 0.0;
		float average = exp(log_average);
		for (uint i = thread; i < GRID_X * GRID_Y; i += THREADS) {
			float luminance = grid_luminance(i);
			sum += pass == 0 ? log(luminance) : max(min(luminance, GLARE_CEILING * average) - GLARE_KNEE * average, 0.0);
		}
		partial_sums[thread] = sum;
		barrier();
		for (uint stride = THREADS / 2; stride > 0; stride /= 2) {
			if (thread < stride) {
				partial_sums[thread] += partial_sums[thread + stride];
			}
			barrier();
		}
		if (pass == 0) {
			if (thread == 0) {
				shared_log_average = partial_sums[0] / float(GRID_X * GRID_Y);
			}
			barrier();
			log_average = shared_log_average;
		}
	}
	if (thread == 0) {
		float average = exp(log_average);
		float share = 1.0 - smoothstep(log(GLARE_FULL_LUMINANCE), log(GLARE_NONE_LUMINANCE), log(average * pc.luminance_scale));
		result.log_luminance = log(average + share * partial_sums[0] / float(GRID_X * GRID_Y));
	}
}
