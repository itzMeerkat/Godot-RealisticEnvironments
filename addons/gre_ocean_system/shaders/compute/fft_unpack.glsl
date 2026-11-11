#[compute]
#version 460
/** 
 * Unpacks the IFFT outputs from the modulation stage and creates
 * the output displacement and normal maps.
 */

#define TILE_SIZE   (16U)
#define NUM_SPECTRA (4U)

layout(local_size_x = TILE_SIZE, local_size_y = TILE_SIZE, local_size_z = 2) in;

// The output maps have mip chains: these are 2D views of this layer's mip 0.
layout(rgba16f, set = 0, binding = 0) restrict writeonly uniform image2D displacement_map;
layout(rgba16f, set = 0, binding = 1) restrict writeonly uniform image2D normal_map;
layout(rgba16f, set = 0, binding = 2) restrict readonly uniform image2D previous_normal_map;

layout(std430, set = 1, binding = 0) restrict buffer FFTBuffer {
	vec2 data[]; // map_size x map_size x num_spectra x 2 * spectrum slots
};

layout(push_constant) restrict readonly uniform PushConstants {
	uint buffer_slot;    // region of the FFT buffer (the spectrum slot)
	float whitecap;      // foam forms where the rendered surface's Jacobian is below this
	float foam_grow;     // coverage added this update per unit of Jacobian below whitecap
	float foam_decay;    // this update's share of the e-folding lifetime (update interval / lifetime)
	float displacement_scale; // GREWaveSpectrum.displacement_scale, as the vertex shader draws the waves
	int foam_shift_x;    // texels the foam drifts downwind this update (x along world x, y along world z)
	int foam_shift_y;
};

// Tiling doesn't provide much of a benefit here (but it does a *little*)
shared vec2 tile[NUM_SPECTRA][TILE_SIZE][TILE_SIZE];

// Note: There is an assumption that the FFT does not transpose a second time. Thus,
//       we access the FFT buffer at an offset of NUM_LAYERS*map_size*map_size
#define FFT_DATA(id, layer) (data[buffer_slot*map_size*map_size*NUM_SPECTRA*2 + NUM_SPECTRA*map_size*map_size + (layer)*map_size*map_size + (id).y*map_size + (id).x])
void main() {
	const uint map_size = gl_NumWorkGroups.x * gl_WorkGroupSize.x;
	const uvec3 id_local = gl_LocalInvocationID;
	const ivec2 id = ivec2(gl_GlobalInvocationID.xy);
	// Multiplying output of inverse FFT by below factor is equivalent to ifftshift()
	const float sign_shift = -2*((id.x & 1) ^ (id.y & 1)) + 1; // Equivalent: (-1^id.x)(-1^id.y)

	tile[id_local.z*2][id_local.y][id_local.x] = FFT_DATA(id, id_local.z*2);
	tile[id_local.z*2 + 1][id_local.y][id_local.x] = FFT_DATA(id, id_local.z*2 + 1);
	barrier();

	// Half of all threads writes to displacement map while other half writes to normal map.
	switch (id_local.z) {
		case 0:
			float hx = tile[0][id_local.y][id_local.x].x;
			float hy = tile[0][id_local.y][id_local.x].y;
			float hz = tile[1][id_local.y][id_local.x].x;
			imageStore(displacement_map, id, vec4(hx, hy, hz, 0) * sign_shift);
			break;
		case 1:
			float dhy_dx = tile[1][id_local.y][id_local.x].y * sign_shift;
			float dhy_dz = tile[2][id_local.y][id_local.x].x * sign_shift;
			float dhx_dx = tile[2][id_local.y][id_local.x].y * sign_shift;
			float dhz_dz = tile[3][id_local.y][id_local.x].x * sign_shift;
			float dhz_dx = tile[3][id_local.y][id_local.x].y * sign_shift;

			// Slope of the surface the vertex shader draws, P = (x + c*Dx, c*Dy, z + c*Dz),
			// c = displacement_scale: normal = dP/dz x dP/dx, gradient = -normal.xz / normal.y.
			// Crests (horizontal compression, Jacobian < 1) get steeper, troughs flatter.
			// The water shader applies normal_scale on top.
			// dDx/dz equals dDz/dx (the displacement field is irrotational).
			float chop_dx_dx = displacement_scale * dhx_dx;
			float chop_dz_dz = displacement_scale * dhz_dz;
			float chop_dz_dx = displacement_scale * dhz_dx;
			float chop_jacobian = (1.0 + chop_dx_dx) * (1.0 + chop_dz_dz) - chop_dz_dx*chop_dz_dx;
			// Folded surface (Jacobian <= 0) has no single normal; cap the steepening at 4x.
			vec2 gradient = displacement_scale * vec2((1.0 + chop_dz_dz) * dhy_dx - chop_dz_dx * dhy_dz,
			                                          (1.0 + chop_dx_dx) * dhy_dz - chop_dz_dx * dhy_dx) / max(chop_jacobian, 0.25);

			// Foam coverage (0-1). It forms where the rendered surface is compressed
			// (Jacobian below whitecap: the crests that look sharp), fades with the
			// cascade's lifetime, and stays with the water: the map is indexed by rest
			// position, so foam left by a passing crest stays behind it. The water's mean
			// drift (wind drift and Stokes drift) carries it downwind, whole texels at a time.
			ivec2 source = (id - ivec2(foam_shift_x, foam_shift_y)) & ivec2(int(map_size) - 1);
			float foam = imageLoad(previous_normal_map, source).a * exp(-foam_decay);
			foam += max(whitecap - chop_jacobian, 0.0) * foam_grow;
			foam = clamp(foam, 0.0, 1.0);
			// z: squared slope, the second moment the mip chain averages (mip_chain.glsl).
			imageStore(normal_map, id, vec4(gradient, dot(gradient, gradient), foam));
			break;
	}
}
