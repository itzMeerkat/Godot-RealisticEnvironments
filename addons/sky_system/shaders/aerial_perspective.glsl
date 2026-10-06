#[versions]

single = "";
msaa = "#define USE_MSAA";

#[vertex]
#version 450
/*
 * Aerial perspective over the opaque scene (AerialPerspectiveEffect): one fullscreen
 * triangle drawn into the scene's colour buffer before the transparent pass. Dual-source
 * blending multiplies the colour by the transmittance to each pixel's surface (second
 * output) and adds the in-scattered light (first output), both read from the camera's
 * view volume (AtmosphereRenderer).
 * With MSAA it runs per sample on the multisampled buffer, so edges resolve correctly
 * and transparent surfaces drawn afterwards are not hazed by what lies behind them.
 */

VERSION_DEFINES

void main() {
	vec2 corner = vec2((gl_VertexIndex << 1) & 2, gl_VertexIndex & 2);
	gl_Position = vec4(corner * 2.0 - 1.0, 0.0, 1.0);
}

#[fragment]
#version 450

VERSION_DEFINES

#include "compute/atmosphere_common.glslinc"

#ifdef USE_MSAA
layout(set = 0, binding = 0) uniform sampler2DMS depth_texture;
#else
layout(set = 0, binding = 0) uniform sampler2D depth_texture;
#endif
layout(set = 0, binding = 1) uniform sampler3D view_transmittance;
layout(set = 0, binding = 2) uniform sampler3D view_inscatter;
layout(set = 0, binding = 3) uniform sampler3D view_inscatter_lobe;

layout(push_constant, std430) restrict readonly uniform Params {
	mat4 inv_view_projection; // clip space to camera-relative world offsets
	vec3 camera_offset;       // camera position minus the view volume's observer
	float observer_altitude;  // m, as the view volume was built for
	vec3 light_direction;     // toward the key light
	float phase_g;            // Henyey-Greenstein g of the haze's forward lobe
	vec2 raster_size;
	float max_distance;       // m, the view volume's last regular slice
	float pad;
} params;

layout(location = 0, index = 0) out vec4 inscatter;
layout(location = 0, index = 1) out vec4 transmittance;

void main() {
	ivec2 pixel = ivec2(gl_FragCoord.xy);
#ifdef USE_MSAA
	float depth = texelFetch(depth_texture, pixel, gl_SampleID).r;
#else
	float depth = texelFetch(depth_texture, pixel, 0).r;
#endif
	// Reverse Z: the background (sky) is at 0 and has its atmosphere already.
	if (depth <= 0.0) {
		discard;
	}
	vec2 uv = gl_FragCoord.xy / params.raster_size;
	vec4 clip_position = params.inv_view_projection * vec4(uv * 2.0 - 1.0, depth, 1.0);
	vec3 offset = params.camera_offset + clip_position.xyz / clip_position.w;
	float distance = length(offset);
	vec3 direction = offset / max(distance, 1e-6);
	vec3 uvw = atmosphere_view_uvw(direction, distance, params.light_direction, params.observer_altitude, params.max_distance, vec3(textureSize(view_transmittance, 0)));
	float phase = atmosphere_henyey_greenstein(dot(direction, params.light_direction), params.phase_g);
	inscatter = vec4(textureLod(view_inscatter, uvw, 0.0).rgb + textureLod(view_inscatter_lobe, uvw, 0.0).rgb * phase, 0.0);
	transmittance = vec4(textureLod(view_transmittance, uvw, 0.0).rgb, 1.0);
}
