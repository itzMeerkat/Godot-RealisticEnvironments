#[compute]
#version 460
/**
 * Modulates the JONSWAP wave spectra texture in time and calculates
 * its gradients. Since the outputs are all real-valued, they are packed
 * in pairs.
 *
 * Sources: Jerry Tessendorf - Simulating Ocean Water
 *          Robert Matusiak - Implementing Fast Fourier Transform Algorithms of Real-Valued Sequences With the TMS320 DSP Platform
 */

#define PI          (3.141592653589793)
#define G           (9.81)
#define NUM_SPECTRA (4U)

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(rgba32f, set = 0, binding = 0) restrict readonly uniform image2DArray spectrum;

layout(std430, set = 1, binding = 0) restrict writeonly buffer FFTBuffer {
	vec2 data[]; // map_size x map_size x num_spectra x 2 * spectrum slots
};

layout(push_constant) restrict readonly uniform PushConstants {
	vec2 tile_length;
	float depth;
	float time;          // the wave clock modulo WAVE_REPEAT_SECONDS
	uint spectrum_layer; // layer of the spectrum texture
	uint buffer_slot;    // region of the FFT buffer (the spectrum slot)
};

/** Returns exp(j*x) assuming x >= 0. */
vec2 exp_complex(in float x) {
	return vec2(cos(x), sin(x));
}

/** Returns (a0 + j*a1)(b0 + j*b1) */
vec2 mul_complex(in vec2 a, in vec2 b) {
	return vec2(a.x*b.x - a.y*b.y, a.x*b.y + a.y*b.x);
}

/** Returns the complex conjugate of x */
vec2 conj_complex(in vec2 x) {
	x.y *= -1;
	return x;
}

// Wave phases repeat every WAVE_REPEAT_SECONDS (WaveGenerator.WAVE_REPEAT_SECONDS): each
// angular frequency is rounded to a multiple of 2 pi / WAVE_REPEAT_SECONDS (Tessendorf,
// "Simulating Ocean Water", 3.4), so the clock can be passed modulo that period and keeps
// its float precision however long the game runs. The rounding (< 0.0032 rad/s) does not show.
#define WAVE_REPEAT_SECONDS 1000.0

// Jerry Tessendorf - Source: Simulating Ocean Water
float dispersion_relation(in float k) {
	float omega = sqrt(max(G*k*tanh(k*depth), 0.f));
	float omega_step = 2.0*PI / WAVE_REPEAT_SECONDS;
	return round(omega / omega_step) * omega_step;
}

#define FFT_DATA(id, layer) (data[(id.z)*map_size*map_size*NUM_SPECTRA*2 + (layer)*map_size*map_size + (id.y)*map_size + (id.x)])
void main() {
	const uint map_size = gl_NumWorkGroups.x * gl_WorkGroupSize.x;
	const ivec2 dims = imageSize(spectrum).xy;
	const ivec3 id = ivec3(gl_GlobalInvocationID.xy, spectrum_layer);
	const ivec3 buffer_id = ivec3(gl_GlobalInvocationID.xy, buffer_slot);

	vec2 k_vec = (id.xy - dims*0.5)*2.0*PI / tile_length; // Wave direction
	float k = length(k_vec) + 1e-6;
	vec2 k_unit = k_vec / k;

	// --- WAVE SPECTRUM MODULATION ---
	vec4 h0 = imageLoad(spectrum, id); // xy=h0(k), zw=conj(h0(-k))
	float dispersion = dispersion_relation(k) * time;
	vec2 modulation = exp_complex(dispersion);
	// Note: h respects the complex conjugation property
	vec2 h = mul_complex(h0.xy, modulation) + mul_complex(h0.zw, conj_complex(modulation));
	vec2 h_inv = vec2(-h.y, h.x); // Used to simplify complex multiplication operations

	// --- WAVE DISPLACEMENT CALCULATION ---
	vec2 hx = h_inv * k_unit.y;            // Equivalent: mul_complex(vec2(0, -k_unit.x), h);
	vec2 hy = h;
	vec2 hz = h_inv * k_unit.x;            // Equivalent: mul_complex(vec2(0, -k_unit.z), h);

	// --- WAVE GRADIENT CALCULATION ---
	// The simulation maps world X/Z onto texture Y/X for the packed FFT layout.
	vec2 dhy_dx = h_inv * k_vec.y;         // Equivalent: mul_complex(vec2(0, k_vec.x), h);
	vec2 dhy_dz = h_inv * k_vec.x;         // Equivalent: mul_complex(vec2(0, k_vec.z), h);
	vec2 dhx_dx = -h * k_vec.y * k_unit.y; // Equivalent: mul_complex(vec2(k_vec.x * k_unit.x, 0), -h);
	vec2 dhz_dz = -h * k_vec.x * k_unit.x; // Equivalent: mul_complex(vec2(k_vec.y * k_unit.y, 0), -h);
	vec2 dhz_dx = -h * k_vec.y * k_unit.x; // Equivalent: mul_complex(vec2(k_vec.x * k_unit.y, 0), -h);

	// Because h respects the complex conjugation property (i.e., the output of IFFT will be a
	// real signal), we can pack two waves into one.
	FFT_DATA(buffer_id, 0) = vec2(    hx.x -     hy.y,     hx.y +     hy.x);
	FFT_DATA(buffer_id, 1) = vec2(    hz.x - dhy_dx.y,     hz.y + dhy_dx.x);
	FFT_DATA(buffer_id, 2) = vec2(dhy_dz.x - dhx_dx.y, dhy_dz.y + dhx_dx.x);
	FFT_DATA(buffer_id, 3) = vec2(dhz_dz.x - dhz_dx.y, dhz_dz.y + dhz_dx.x);
}
