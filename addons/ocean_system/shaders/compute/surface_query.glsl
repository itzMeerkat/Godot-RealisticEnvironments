#[compute]
#version 460
/**
 * Samples OceanSystem displacement maps at arbitrary world-space points.
 * This is intended for buoyancy/gameplay queries where reading back full
 * displacement textures would be far too expensive.
 */

#define MAX_CASCADES 8U
#define WORKGROUP_SIZE 64U

layout(local_size_x = WORKGROUP_SIZE, local_size_y = 1, local_size_z = 1) in;

struct CascadeData {
	vec4 map_scales;     // [uv scale, displacement scale, normal scale]
	vec4 blend_state;    // [active layer, pending layer, spectrum blend alpha, unused]
};

struct SurfaceSample {
	vec4 displacement_height; // xyz = visual displacement, w = height
	vec4 normal_valid;        // xyz = normal, w = valid
	vec4 surface_velocity;    // xyz = displacement velocity, w = unused
};

layout(std430, set = 0, binding = 0) restrict readonly buffer PointBuffer {
	vec4 points[];
};

layout(std430, set = 0, binding = 1) restrict readonly buffer CascadeBuffer {
	CascadeData cascades[];
};

layout(std430, set = 0, binding = 2) restrict writeonly buffer SampleBuffer {
	SurfaceSample samples[];
};

layout(rgba16f, set = 0, binding = 3) restrict readonly uniform image2DArray current_displacements;
layout(rgba16f, set = 0, binding = 4) restrict readonly uniform image2DArray previous_displacements;

layout(push_constant) restrict readonly uniform PushConstants {
	uint point_count;
	uint cascade_count;
	uint map_size;
	float water_level;
	float wave_blend_alpha;
	float wave_blend_duration;
	float normal_sample_distance;
	float _pad0;
};

vec4 sample_current_layer_bilinear(int layer, vec2 uv) {
	vec2 dims = vec2(imageSize(current_displacements).xy);
	vec2 p = fract(uv) * dims;
	ivec2 p0 = ivec2(floor(p)) % ivec2(dims);
	ivec2 p1 = (p0 + ivec2(1)) % ivec2(dims);
	vec2 f = fract(p);

	vec4 c00 = imageLoad(current_displacements, ivec3(p0.x, p0.y, layer));
	vec4 c10 = imageLoad(current_displacements, ivec3(p1.x, p0.y, layer));
	vec4 c01 = imageLoad(current_displacements, ivec3(p0.x, p1.y, layer));
	vec4 c11 = imageLoad(current_displacements, ivec3(p1.x, p1.y, layer));
	return mix(mix(c00, c10, f.x), mix(c01, c11, f.x), f.y);
}

vec4 sample_previous_layer_bilinear(int layer, vec2 uv) {
	vec2 dims = vec2(imageSize(previous_displacements).xy);
	vec2 p = fract(uv) * dims;
	ivec2 p0 = ivec2(floor(p)) % ivec2(dims);
	ivec2 p1 = (p0 + ivec2(1)) % ivec2(dims);
	vec2 f = fract(p);

	vec4 c00 = imageLoad(previous_displacements, ivec3(p0.x, p0.y, layer));
	vec4 c10 = imageLoad(previous_displacements, ivec3(p1.x, p0.y, layer));
	vec4 c01 = imageLoad(previous_displacements, ivec3(p0.x, p1.y, layer));
	vec4 c11 = imageLoad(previous_displacements, ivec3(p1.x, p1.y, layer));
	return mix(mix(c00, c10, f.x), mix(c01, c11, f.x), f.y);
}

vec3 sample_current_cascade_displacement(CascadeData cascade, vec3 world_position) {
	vec2 uv = world_position.xz * cascade.map_scales.xy;
	int active_layer = int(cascade.blend_state.x + 0.5);
	int pending_layer = int(cascade.blend_state.y + 0.5);
	vec3 active_displacement = sample_current_layer_bilinear(active_layer, uv).xyz;
	vec3 pending_displacement = sample_current_layer_bilinear(pending_layer, uv).xyz;
	return mix(active_displacement, pending_displacement, cascade.blend_state.z) * cascade.map_scales.z;
}

vec3 sample_previous_cascade_displacement(CascadeData cascade, vec3 world_position) {
	vec2 uv = world_position.xz * cascade.map_scales.xy;
	int active_layer = int(cascade.blend_state.x + 0.5);
	int pending_layer = int(cascade.blend_state.y + 0.5);
	vec3 active_displacement = sample_previous_layer_bilinear(active_layer, uv).xyz;
	vec3 pending_displacement = sample_previous_layer_bilinear(pending_layer, uv).xyz;
	return mix(active_displacement, pending_displacement, cascade.blend_state.z) * cascade.map_scales.z;
}

vec3 sample_current_total_displacement(vec3 world_position) {
	vec3 displacement = vec3(0.0);
	uint count = min(cascade_count, MAX_CASCADES);
	for (uint i = 0U; i < count; ++i) {
		displacement += sample_current_cascade_displacement(cascades[i], world_position);
	}
	return displacement;
}

vec3 sample_previous_total_displacement(vec3 world_position) {
	vec3 displacement = vec3(0.0);
	uint count = min(cascade_count, MAX_CASCADES);
	for (uint i = 0U; i < count; ++i) {
		displacement += sample_previous_cascade_displacement(cascades[i], world_position);
	}
	return displacement;
}

float sample_height(vec3 world_position) {
	vec3 previous_displacement = sample_previous_total_displacement(world_position);
	vec3 current_displacement = sample_current_total_displacement(world_position);
	return water_level + mix(previous_displacement, current_displacement, wave_blend_alpha).y;
}

void main() {
	uint index = gl_GlobalInvocationID.x;
	if (index >= point_count) {
		return;
	}

	vec3 world_position = points[index].xyz;
	vec3 previous_displacement = sample_previous_total_displacement(world_position);
	vec3 current_displacement = sample_current_total_displacement(world_position);
	vec3 visual_displacement = mix(previous_displacement, current_displacement, wave_blend_alpha);

	float e = max(normal_sample_distance, 0.001);
	float h_l = sample_height(world_position + vec3(-e, 0.0, 0.0));
	float h_r = sample_height(world_position + vec3( e, 0.0, 0.0));
	float h_b = sample_height(world_position + vec3(0.0, 0.0, -e));
	float h_f = sample_height(world_position + vec3(0.0, 0.0,  e));
	vec3 normal = normalize(vec3(h_l - h_r, 2.0 * e, h_b - h_f));
	vec3 velocity = (current_displacement - previous_displacement) / max(wave_blend_duration, 1.0 / 60.0);

	samples[index].displacement_height = vec4(visual_displacement, water_level + visual_displacement.y);
	samples[index].normal_valid = vec4(normal, 1.0);
	samples[index].surface_velocity = vec4(velocity, 0.0);
}
