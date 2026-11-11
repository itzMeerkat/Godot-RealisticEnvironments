#[compute]
#version 460
/**
 * Interactive waves, step 3 (GREOceanInteraction): moves every Fourier mode of the height
 * h and its rate dh/dt exactly one step on, at its own frequency
 * omega = sqrt(g k tanh(k depth)). With that dispersion long waves outrun short ones,
 * which is what draws a Kelvin wake (a fixed V of about 19.5 degrees at any speed). The
 * shortest waves lose energy to viscosity, all of them a little to damping.
 *
 * The forward FFT transformed z = h + i dh/dt, two real fields in one complex one, so
 * the spectra of h and dh/dt are separated by Hermitian symmetry, evolved and joined
 * again as H + i V for the inverse FFT, scaled by 1 / map_size^2 (the transforms are
 * unnormalized). Reads the output half (the spectrum, transposed: only |k| matters),
 * writes the input half.
 */

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(std430, set = 0, binding = 0) restrict buffer FFTBuffer {
	vec2 data[]; // input half, then output half: map_size^2 each
};

layout(push_constant) restrict readonly uniform PushConstants {
	float cell_size;   // m
	float water_depth; // m
	float viscosity;   // m^2/s: damps each mode at viscosity k^2
	float damping;     // 1/s: damps every mode
	float delta;       // s
};

#define GRAVITY 9.81
#define TAU 6.283185307179586

void main() {
	int map_size = int(gl_NumWorkGroups.x * gl_WorkGroupSize.x);
	ivec2 id = ivec2(gl_GlobalInvocationID.xy);
	ivec2 mirror = (map_size - id) & (map_size - 1);
	uint count = uint(map_size * map_size);
	vec2 z = data[count + uint(id.y * map_size + id.x)];
	vec2 z_mirror = data[count + uint(mirror.y * map_size + mirror.x)];

	// H(k) = (Z(k) + conj Z(-k)) / 2, V(k) = (Z(k) - conj Z(-k)) / 2i.
	vec2 z_mirror_conjugate = vec2(z_mirror.x, -z_mirror.y);
	vec2 h = 0.5 * (z + z_mirror_conjugate);
	vec2 i_v = 0.5 * (z - z_mirror_conjugate);
	vec2 v = vec2(i_v.y, -i_v.x);

	ivec2 signed_id = id - map_size * ivec2(greaterThanEqual(id, ivec2(map_size / 2)));
	float k = length(vec2(signed_id)) * TAU / (float(map_size) * cell_size);
	float omega = sqrt(GRAVITY * k * tanh(min(k * water_depth, 20.0)));
	vec2 next_h = h + v * delta;
	vec2 next_v = v;
	if (omega > 1e-6) {
		float c = cos(omega * delta);
		float s = sin(omega * delta);
		next_h = h * c + v * (s / omega);
		next_v = v * c - h * (omega * s);
	}
	float decay = exp(-(viscosity * k * k + damping) * delta);
	vec2 next = (next_h + vec2(-next_v.y, next_v.x)) * (decay / float(count));
	data[uint(id.y * map_size + id.x)] = next;
}
