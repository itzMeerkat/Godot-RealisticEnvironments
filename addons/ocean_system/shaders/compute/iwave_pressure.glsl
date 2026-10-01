#[compute]
#version 460
/**
 * Hull forcing for the iWave step. Each hull acts as a surface-pressure
 * disturbance: its pressure head p is the hull's draft below the incident
 * (FFT) wave surface, read from the baked HullProfile keel channel and tapered
 * to zero at the waterline, bow and stern so the hull edge does not ring (a hard
 * edge switches cells on and off as the hull crosses the grid).
 *
 * A pressure patch alone cannot make a bow wave: it depresses the water under
 * itself and radiates its first crest behind it. So p also carries the bow
 * wave's stagnation head: where the waterline wall moves into the water at
 * normal speed v_n, water piles up by C * v_n^2 / 2g (capped). It enters p with
 * a negative sign (a lifted surface) in a band around the wall, and the step
 * turns its motion into the bow crest and divergent waves.
 *
 * Also writes hull coverage (1 inside a hull's waterline and up to one edge
 * softness beyond it, fading out by two) and packs eta_n into the complex
 * spectrum texture for the FFT that follows.
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
	vec4 wake;    // pressure scale, edge softness (m), bow wave strength C, bow wave max rise (m)
	vec4 velocity;         // world velocity of the bounds center, unused
	vec4 angular_velocity; // world angular velocity (rad/s), unused
};

// x = pressure head p (m), y = hull coverage, z = bow-wave rise outside hulls (m, foam source).
layout(rgba32f, set = 0, binding = 0) restrict writeonly uniform image2D pressure;
layout(rg32f, set = 0, binding = 1) restrict writeonly uniform image2D spectrum;
layout(rgba32f, set = 0, binding = 2) restrict readonly uniform image2D state;

layout(std430, set = 0, binding = 3) restrict readonly buffer HullBuffer {
	SimHull hulls[];
};

// R = inner half-width over (z, y); G = keel height over (z, |x - center x|).
layout(set = 0, binding = 4) uniform sampler2DArray hull_profiles;

#define GRAVITY 9.81

void main() {
	ivec2 texel = ivec2(gl_GlobalInvocationID.xy);
	vec2 position = iwave_cell_center(iwave_texel_to_cell(texel, origin, grid_size), cell_size);

	float pressure_head = 0.0;
	float coverage = 0.0;
	float bow_rise_outside = 0.0;
	bool has_surface = false;
	float surface_y = 0.0;
	for (uint i = 0U; i < hull_count; ++i) {
		SimHull hull = hulls[i];
		float edge_softness = max(hull.wake.y, 0.001);
		// Coverage reaches up to two edge softnesses beyond the waterline.
		float reach = hull.bounds.z + 2.0 * edge_softness;
		vec2 to_center = position - hull.bounds.xy;
		if (dot(to_center, to_center) > reach * reach) {
			continue; // Outside this hull's footprint circle.
		}
		// The incident surface is shared by every hull covering this cell.
		if (!has_surface) {
			surface_y = ocean_sample_surface_height(position);
			has_surface = true;
		}
		vec4 surface_point = vec4(position.x, surface_y, position.y, 1.0);
		vec3 local = vec3(dot(hull.world_to_local_x, surface_point), dot(hull.world_to_local_y, surface_point), dot(hull.world_to_local_z, surface_point));
		float length_m = 1.0 / hull.rect.z;
		float along = local.z - hull.rect.x;
		float end_distance = min(along, length_m - along); // meters inside the bow or stern end; < 0 beyond it
		float u = clamp(along * hull.rect.z, 0.0, 1.0);
		float lateral = abs(local.x - hull.profile.y);
		float layer = hull.profile.x;
		// Waterline half-width: the hull's width at the surface height, or at the
		// station's top when the surface is above it.
		float station_top = textureLod(hull_profiles, vec3(u, 0.5, layer), 0.0).b;
		float v = clamp((local.y - hull.rect.y) * hull.rect.w, 0.0, station_top);
		float half_width = textureLod(hull_profiles, vec3(u, v, layer), 0.0).r;
		float inside_distance = min(half_width - lateral, end_distance); // < 0 outside the waterline
		// Coverage marks where eta is this hull's own water (surface queries skip
		// it there). It includes a band outside the waterline, where buoyancy
		// probes on the hull edge sit and the hull's own bow wave is strongest.
		coverage = max(coverage, 1.0 - smoothstep(edge_softness, 2.0 * edge_softness, -inside_distance));

		// Bow wave: stagnation rise where the waterline wall moves into the water.
		float bow_strength = hull.wake.z;
		float band = 1.0 - smoothstep(0.0, 2.0 * edge_softness, abs(inside_distance));
		if (bow_strength > 0.0 && band > 0.0) {
			vec3 offset = vec3(position.x, surface_y, position.y) - vec3(hull.bounds.x, hull.bounds.w, hull.bounds.y);
			vec3 velocity = hull.velocity.xyz + cross(hull.angular_velocity.xyz, offset);
			vec2 local_velocity = vec2(dot(hull.world_to_local_x.xyz, velocity), dot(hull.world_to_local_z.xyz, velocity));
			// Outward waterline normal in hull space (x, z): the side wall
			// |x - center| = half_width(z), or the bow/stern end, whichever is nearer.
			vec2 wall_normal;
			if (half_width - lateral < end_distance) {
				float du = 1.0 / float(textureSize(hull_profiles, 0).x);
				float width_ahead = textureLod(hull_profiles, vec3(min(u + du, 1.0), v, layer), 0.0).r;
				float width_behind = textureLod(hull_profiles, vec3(max(u - du, 0.0), v, layer), 0.0).r;
				float width_slope = (width_ahead - width_behind) / ((min(u + du, 1.0) - max(u - du, 0.0)) * length_m);
				wall_normal = normalize(vec2(local.x >= hull.profile.y ? 1.0 : -1.0, -width_slope));
			} else {
				wall_normal = vec2(0.0, along < 0.5 * length_m ? -1.0 : 1.0);
			}
			float normal_speed = max(dot(local_velocity, wall_normal), 0.0);
			float rise = min(bow_strength * normal_speed * normal_speed / (2.0 * GRAVITY), hull.wake.w) * band;
			pressure_head -= rise;
			// Outside the wall the rise shows (the cutout hides the inside): foam source.
			bow_rise_outside = max(bow_rise_outside, rise * (1.0 - smoothstep(-0.5 * edge_softness, 0.5 * edge_softness, inside_distance)));
		}
		if (end_distance <= 0.0) {
			continue; // Beyond the bow or stern.
		}
		float keel = textureLod(hull_profiles, vec3(u, lateral * hull.profile.z, layer), 0.0).g;
		float draft = local.y - keel;
		if (draft <= 0.0) {
			continue; // The hull bottom is above the surface here.
		}
		float taper = smoothstep(0.0, edge_softness, half_width - lateral) * smoothstep(0.0, edge_softness, end_distance);
		pressure_head += hull.wake.x * draft * taper;
	}

	imageStore(pressure, texel, vec4(pressure_head, coverage, bow_rise_outside, 0.0));
	imageStore(spectrum, texel, vec4(imageLoad(state, texel).x, 0.0, 0.0, 0.0));
}
