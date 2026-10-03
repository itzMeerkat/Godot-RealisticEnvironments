#[compute]
#version 460
/**
 * One iWave time step (Tessendorf, "Interactive Water Surfaces", 2004), with
 * the vertical-derivative operator applied exactly in frequency space (the
 * spectrum texture holds g * sqrt(-laplacian) applied to eta_n).
 *
 * The state is the wave deviation eta = h + p from the hull-conforming rest
 * state. With velocity damping alpha:
 *   eta_{n+1} = [ eta_n (2 + a dt) - eta_{n-1} - dt^2 L eta_n
 *                 + p_{n+1} (1 + a dt) - p_n (2 + a dt) + p_{n-1} ] / (1 + a dt)
 * which is the h-form equation h'' + a h' = -L (h + p) rewritten for eta, so a
 * hull at rest produces no waves and only changes of p radiate them.
 *
 * A viscous term nu * laplacian(eta_n - eta_{n-1}) * dt damps short waves much
 * more than long ones (rate ~ nu k^2), so grid-scale ripples from forcing noise
 * die out instead of piling up.
 */

#include "iwave_common.glslinc"

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(rgba32f, set = 0, binding = 0) restrict readonly uniform image2D state_in;
layout(rgba32f, set = 0, binding = 1) restrict writeonly uniform image2D state_out;
layout(rgba32f, set = 0, binding = 2) restrict readonly uniform image2D pressure; // p, hull coverage, bow rise outside hulls
layout(rg32f, set = 0, binding = 3) restrict readonly uniform image2D spectrum;
layout(rgba16f, set = 0, binding = 4) restrict uniform image2D render;

layout(push_constant) restrict readonly uniform PushConstants {
	ivec2 origin;
	int grid_size;
	float cell_size;
	float dt;
	float damping;           // alpha inside the window (1/s)
	float viscosity;         // nu (m^2/s)
	float sponge_cells;      // width of the absorbing border
	float sponge_damping;    // extra alpha at the window edge (1/s)
	float foam_grow;         // foam per second per unit of source
	float foam_decay;        // exponential decay rate (1/s)
	float foam_slope_threshold;
	float foam_bow_rate;     // foam source per meter of bow-wave rise outside hulls
};

void main() {
	ivec2 texel = ivec2(gl_GlobalInvocationID.xy);
	ivec2 mask = ivec2(grid_size - 1);
	vec4 state = imageLoad(state_in, texel);
	float eta = state.x;
	float eta_previous = state.y;
	vec3 pressure_data = imageLoad(pressure, texel).xyz;
	float pressure_next = pressure_data.x;
	// Fresh cells have no pressure history: treat it as unchanged (no forcing).
	float pressure_now = state.z <= IWAVE_NO_PRESSURE ? pressure_next : state.z;
	float pressure_previous = state.w <= IWAVE_NO_PRESSURE ? pressure_now : state.w;
	float operator_eta = imageLoad(spectrum, texel).x;

	// Absorbing border: damping ramps up toward the window edge so outgoing
	// waves are absorbed instead of wrapping around to the other side.
	ivec2 window_position = (texel - origin) & mask;
	int edge_distance = min(min(window_position.x, window_position.y), min(grid_size - 1 - window_position.x, grid_size - 1 - window_position.y));
	float sponge = clamp(1.0 - float(edge_distance) / sponge_cells, 0.0, 1.0);
	float alpha_dt = (damping + sponge_damping * sponge * sponge) * dt;

	vec2 left = imageLoad(state_in, (texel + ivec2(-1, 0)) & mask).xy;
	vec2 right = imageLoad(state_in, (texel + ivec2(1, 0)) & mask).xy;
	vec2 back = imageLoad(state_in, (texel + ivec2(0, -1)) & mask).xy;
	vec2 front = imageLoad(state_in, (texel + ivec2(0, 1)) & mask).xy;
	// Laplacian of the per-step change eta_n - eta_{n-1} (x - y of each texel).
	vec2 neighbors = left + right + back + front;
	float change_laplacian = ((neighbors.x - neighbors.y) - 4.0 * (eta - eta_previous)) / (cell_size * cell_size);

	float pressure_forcing = pressure_next * (1.0 + alpha_dt) - pressure_now * (2.0 + alpha_dt) + pressure_previous;
	float eta_next = (eta * (2.0 + alpha_dt) - eta_previous - dt * dt * operator_eta + viscosity * dt * change_laplacian + pressure_forcing) / (1.0 + alpha_dt);

	// Foam: steep simulated waves, plus the bow wave piling up against advancing hulls.
	float slope = length(vec2(right.x - left.x, front.x - back.x)) / (2.0 * cell_size);
	float foam = imageLoad(render, texel).z;
	foam = foam * exp(-foam_decay * dt) + foam_grow * dt * (max(slope - foam_slope_threshold, 0.0) + foam_bow_rate * pressure_data.z);
	foam = clamp(foam, 0.0, 1.0) * (1.0 - sponge);

	imageStore(state_out, texel, vec4(eta_next, eta, pressure_next, pressure_now));
	imageStore(render, texel, vec4(eta_next - pressure_next, eta_next, foam, pressure_data.y));
}
