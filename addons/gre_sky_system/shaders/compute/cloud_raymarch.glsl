#[compute]
#version 450
/**
 * Raymarches the cloud layer (cloud_common.glslinc) into a cubemap seen from an
 * observer, for the consumers that need the clouds in every direction rather than on
 * screen (GRECloudRenderer):
 *   face_mode 0, the sea cubemap: an observer on the sea below the layer; every face
 *     but -Y, side faces only above the horizon. The water's sky reflection, the
 *     atmosphere's cloud shadows and the mirrored camera's starfield.
 *   face_mode 1, the camera cubemap: the camera wherever it is, every face. The sky's
 *     radiance map (ambient light and reflections) and the camera's light meter.
 *
 * Each dispatch refreshes one texel of every stride x stride block
 * (pattern_offset picks which), so the whole cube is refreshed every stride^2
 * frames. A refreshed texel is blended with its previous value; together with
 * the per-frame jitter this averages several sub-texel rays.
 *
 * Output texel: rgb = in-scattered radiance (premultiplied), a = opacity, as seen at
 * the cloud.
 */

#define CLOUD_TRANSMITTANCE_BINDING 6
#include "atmosphere_common.glslinc"
#include "cloud_common.glslinc"

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rgba16f, set = 0, binding = 0) uniform restrict imageCube cloud_image;

layout(push_constant, std430) restrict readonly uniform PushConstants {
	ivec2 pattern_offset;
	int stride;
	int face_size;
	vec2 jitter;          // sub-texel ray offset, in texels
	float history_weight; // 0 replaces the texel
	float frame_seed;
	vec3 observer;        // world x, altitude above the sea (m), world z
	int face_mode;        // 0: every face but -Y, above the horizon; 1: every face
} pc;

const int SEA_FACES[5] = int[](0, 1, 2, 4, 5); // every face but -Y

// Inverse of the cube face selection in the Vulkan spec; st in [-1, 1], t grows downward.
vec3 cube_direction(int face, vec2 st) {
	switch (face) {
		case 0: return vec3(1.0, -st.y, -st.x);
		case 1: return vec3(-1.0, -st.y, st.x);
		case 2: return vec3(st.x, 1.0, st.y);
		case 3: return vec3(st.x, -1.0, -st.y);
		case 4: return vec3(st.x, -st.y, 1.0);
		default: return vec3(-st.x, -st.y, -1.0);
	}
}

void main() {
	int face = pc.face_mode == 0 ? SEA_FACES[gl_GlobalInvocationID.z] : int(gl_GlobalInvocationID.z);
	ivec2 texel = ivec2(gl_GlobalInvocationID.xy) * pc.stride + pc.pattern_offset;
	if (any(greaterThanEqual(texel, ivec2(pc.face_size)))) {
		return;
	}
	// The sea's side faces: only the rows above the horizon, plus one for filtering.
	if (pc.face_mode == 0 && face != 2 && texel.y > pc.face_size / 2 + 1) {
		return;
	}
	vec2 st = (vec2(texel) + 0.5 + pc.jitter) / float(pc.face_size) * 2.0 - 1.0;
	vec3 direction = normalize(cube_direction(face, st));
	float jitter = cloud_hash12(vec2(texel) + vec2(float(face) * 1031.0, 0.0) + pc.frame_seed);
	float cloud_distance;
	vec4 cloud = cloud_march(pc.observer.xz, pc.observer.y, direction, 1.0e9, jitter, cloud_distance);
	ivec3 coordinate = ivec3(texel, face);
	vec4 history = imageLoad(cloud_image, coordinate);
	imageStore(cloud_image, coordinate, mix(cloud, history, pc.history_weight));
}
