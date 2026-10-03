#[compute]
#version 450
/**
 * Writes the cloud weather map: a square of world XZ centred on the camera
 * that tells the raymarcher what kind of cloud exists where.
 *
 *   r  coverage  0 = clear, 1 = fully covered
 *   g  type      0 = stratus, 0.5 = cumulus, 1 = cumulonimbus
 *   b  density   extinction multiplier
 *   a  unused (reserved for precipitation)
 *
 * This pass is the only producer of the map, and the raymarcher only reads it,
 * so a future cloud simulation (advection, growth, dissipation) can replace
 * this shader without touching the raymarcher. Today the map is procedural:
 * noise in world space, carried by the wind offset and slowly reshaped by the
 * evolution time (the noise's third axis), so cloud fields form and fade.
 */

#include "cloud_noise.glslinc"

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rgba16f, set = 0, binding = 0) uniform restrict writeonly image2D weather_image;

layout(push_constant, std430) restrict readonly uniform PushConstants {
	vec2 center;              // world XZ of the map centre
	float extent;             // world size of the map edge (m)
	float evolution_time;     // noise units; advanced by CloudPreset.evolution_speed
	vec2 wind_offset;         // world XZ distance the wind has carried the clouds (m)
	float weather_scale;      // size of a weather region (m)
	float coverage;
	float coverage_variation;
	float cloud_type;
	float type_variation;
	float density_variation;
} pc;

void main() {
	ivec2 id = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size = imageSize(weather_image);
	if (any(greaterThanEqual(id, size))) {
		return;
	}
	vec2 uv = (vec2(id) + 0.5) / vec2(size);
	vec2 world = pc.center + (uv - 0.5) * pc.extent;
	vec2 p = (world - pc.wind_offset) / pc.weather_scale;
	float t = pc.evolution_time;

	float coverage_noise = cloud_gradient_fbm(vec3(p, t), 0.0, 4) * 1.6;
	float type_noise = cloud_gradient_fbm(vec3(p * 0.7 + 17.3, t * 0.7 + 5.1), 0.0, 3) * 1.6;
	float density_noise = cloud_gradient_fbm(vec3(p * 1.3 - 9.1, t + 11.7), 0.0, 3) * 1.6;

	float coverage = clamp(pc.coverage + coverage_noise * pc.coverage_variation, 0.0, 1.0);
	float cloud_type = clamp(pc.cloud_type + type_noise * pc.type_variation, 0.0, 1.0);
	float density = max(1.0 + density_noise * pc.density_variation, 0.0);
	imageStore(weather_image, id, vec4(coverage, cloud_type, density, 0.0));
}
