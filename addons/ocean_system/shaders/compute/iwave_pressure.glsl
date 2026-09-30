#[compute]
#version 460
/**
 * Hull forcing for the iWave step. Each hull acts as a surface-pressure
 * disturbance: its pressure head p is the hull's draft below the incident
 * (FFT) wave surface, read from the baked HullProfile keel channel and tapered
 * to zero at the waterline so the hull edge does not ring.
 *
 * Also packs eta_n into the complex spectrum texture for the FFT that follows.
 */

#include "iwave_common.glslinc"

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(push_constant) restrict readonly uniform PushConstants {
	ivec2 origin;
	int grid_size;
	float cell_size;
	uint hull_count;
	uint cascade_count;
	float water_level;
	float wave_blend_alpha;
};

#define OCEAN_SAMPLING_SET 0
#define OCEAN_CASCADE_BUFFER_BINDING 5
#define OCEAN_CURRENT_DISPLACEMENT_BINDING 6
#define OCEAN_PREVIOUS_DISPLACEMENT_BINDING 7
#include "ocean_sampling.glslinc"

struct SimHull {
	vec4 world_to_local_x; // rows of the world-to-hull affine transform
	vec4 world_to_local_y;
	vec4 world_to_local_z;
	vec4 bounds;  // world center x, world center z, radius, unused
	vec4 rect;    // profile min z, min y, 1 / length, 1 / height
	vec4 profile; // texture layer, center x, 1 / max half width, unused
	vec4 wake;    // pressure scale, edge softness (m), unused, unused
};

layout(r32f, set = 0, binding = 0) restrict writeonly uniform image2D pressure;
layout(rg32f, set = 0, binding = 1) restrict writeonly uniform image2D spectrum;
layout(rgba32f, set = 0, binding = 2) restrict readonly uniform image2D state;

layout(std430, set = 0, binding = 3) restrict readonly buffer HullBuffer {
	SimHull hulls[];
};

// R = inner half-width over (z, y); G = keel height over (z, |x - center x|).
layout(set = 0, binding = 4) uniform sampler2DArray hull_profiles;

void main() {
	ivec2 texel = ivec2(gl_GlobalInvocationID.xy);
	vec2 position = iwave_cell_center(iwave_texel_to_cell(texel, origin, grid_size), cell_size);

	float pressure_head = 0.0;
	bool has_surface = false;
	float surface_y = 0.0;
	for (uint i = 0U; i < hull_count; ++i) {
		SimHull hull = hulls[i];
		vec2 to_center = position - hull.bounds.xy;
		if (dot(to_center, to_center) > hull.bounds.z * hull.bounds.z) {
			continue; // Outside this hull's footprint circle.
		}
		// The incident surface is shared by every hull covering this cell.
		if (!has_surface) {
			surface_y = ocean_sample_surface_height(position);
			has_surface = true;
		}
		vec4 surface_point = vec4(position.x, surface_y, position.y, 1.0);
		vec3 local = vec3(dot(hull.world_to_local_x, surface_point), dot(hull.world_to_local_y, surface_point), dot(hull.world_to_local_z, surface_point));
		float u = (local.z - hull.rect.x) * hull.rect.z;
		if (u < 0.0 || u > 1.0) {
			continue; // Beyond the bow or stern.
		}
		float lateral = abs(local.x - hull.profile.y);
		float layer = hull.profile.x;
		float keel = textureLod(hull_profiles, vec3(u, lateral * hull.profile.z, layer), 0.0).g;
		float draft = local.y - keel;
		if (draft <= 0.0) {
			continue; // The hull bottom is above the surface here.
		}
		float v = clamp((local.y - hull.rect.y) * hull.rect.w, 0.0, 1.0);
		float half_width = textureLod(hull_profiles, vec3(u, v, layer), 0.0).r;
		float taper = smoothstep(0.0, max(hull.wake.y, 0.001), half_width - lateral);
		pressure_head += hull.wake.x * draft * taper;
	}

	imageStore(pressure, texel, vec4(pressure_head));
	imageStore(spectrum, texel, vec4(imageLoad(state, texel).x, 0.0, 0.0, 0.0));
}
