#[compute]
#version 450
/*
 * Night vision: the eye's rods take over from its cones in dim light. Each pixel's
 * absolute luminance (cd/m2) decides how much: above PHOTOPIC_LUMINANCE the cones see
 * colour as rendered; below SCOTOPIC_LUMINANCE only the rods see, colourless and
 * slightly blue; in between (the mesopic range) the two blend by log luminance. The
 * rods' luminance is the scotopic luminance of Larson et al. 1997 (from CIE XYZ),
 * normalized to the photopic one for white light; their colour is Jensen et al.'s 2000
 * blue shift. Runs on the HDR colour buffer before tonemapping.
 */

#define PHOTOPIC_LUMINANCE 3.0
#define SCOTOPIC_LUMINANCE 0.01
// Larson's V' of an equal-energy white over its Y.
#define SCOTOPIC_WHITE 2.31
// Rod vision's tint (luminance ~1).
#define ROD_TINT vec3(1.05, 0.97, 1.27)

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rgba16f, set = 0, binding = 0) uniform restrict image2D color_image;

layout(push_constant, std430) restrict readonly uniform PushConstants {
	vec2 size;
	// cd/m2 of a colour-buffer value of 1: the light meter's lux of the scene's
	// irradiance 1 over the exposure the buffer is rendered at.
	float luminance_scale;
	// 0-1: how much of the effect applies.
	float strength;
} pc;

void main() {
	ivec2 texel = ivec2(gl_GlobalInvocationID.xy);
	if (any(greaterThanEqual(texel, ivec2(pc.size)))) {
		return;
	}
	vec4 color = imageLoad(color_image, texel);
	vec3 rgb = max(color.rgb, vec3(0.0));
	// Linear Rec. 709 to CIE XYZ.
	float x = dot(rgb, vec3(0.4124, 0.3576, 0.1805));
	float y = dot(rgb, vec3(0.2126, 0.7152, 0.0722));
	float z = dot(rgb, vec3(0.0193, 0.1192, 0.9505));
	if (y <= 0.0) {
		return;
	}
	float scotopic = x > 1e-12 ? max(y * (1.33 * (1.0 + (y + z) / x) - 1.68), 0.0) / SCOTOPIC_WHITE : y;
	float luminance = y * pc.luminance_scale;
	float rods = 1.0 - smoothstep(log(SCOTOPIC_LUMINANCE), log(PHOTOPIC_LUMINANCE), log(luminance));
	rgb = mix(rgb, scotopic * ROD_TINT, rods * pc.strength);
	imageStore(color_image, texel, vec4(rgb, color.a));
}
