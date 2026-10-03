#[compute]
#version 450
/**
 * Bakes the tiling 3D noise textures the cloud raymarcher samples. Runs once
 * when a CloudRenderer is created. Both are single-channel and stretched to
 * a roughly uniform [0, 1] distribution, so a coverage threshold c covers
 * about c of the sky.
 *
 * mode 0, shape (128^3): Perlin-Worley (Perlin dilated by Worley: connected
 * blobs with billowy edges), eroded by a Worley fbm.
 * mode 1, detail (64^3): Worley fbm that carves wisps into cloud edges.
 *
 * The stretch constants are the 2nd/98th percentiles of the raw values,
 * measured offline; recompute them when the noise changes.
 */

#include "cloud_noise.glslinc"

layout(local_size_x = 4, local_size_y = 4, local_size_z = 4) in;

layout(r8, set = 0, binding = 0) uniform restrict writeonly image3D noise_image;

layout(push_constant, std430) restrict readonly uniform PushConstants {
	int mode;
} pc;

void main() {
	ivec3 id = ivec3(gl_GlobalInvocationID);
	ivec3 size = imageSize(noise_image);
	if (any(greaterThanEqual(id, size))) {
		return;
	}
	vec3 uvw = (vec3(id) + 0.5) / vec3(size);
	float value;
	if (pc.mode == 0) {
		float perlin = clamp(cloud_gradient_fbm(uvw * 4.0, 4.0, 5) * 2.1 + 0.5, 0.0, 1.0);
		float worley = cloud_worley_fbm(uvw, 4.0);
		float perlin_worley = worley + perlin * (1.0 - worley);
		float erosion = worley * 0.625 + cloud_worley_fbm(uvw, 8.0) * 0.25 + cloud_worley_fbm(uvw, 16.0) * 0.125;
		float shape = (perlin_worley - (erosion - 1.0)) / (2.0 - erosion);
		value = (shape - 0.649) / (0.993 - 0.649);
	} else {
		float detail = cloud_worley_fbm(uvw, 2.0) * 0.625 + cloud_worley_fbm(uvw, 4.0) * 0.25 + cloud_worley_fbm(uvw, 8.0) * 0.125;
		value = (detail - 0.30) / (0.66 - 0.30);
	}
	imageStore(noise_image, id, vec4(clamp(value, 0.0, 1.0)));
}
