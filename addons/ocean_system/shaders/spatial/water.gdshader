shader_type spatial;
render_mode world_vertex_coords, cull_disabled, depth_draw_always;
/*
 * Lights (the sun) shade the water in light(): Lambert diffuse and a GGX
 * specular highlight whose roughness includes the wave slopes a pixel does not
 * resolve, so glints are sharp up close and merge into a broad sun path in the
 * distance. Sky and planar reflections are computed here and added as EMISSION;
 * SPECULAR = 0 turns off the engine's own sky reflection, which would double them.
 *
 * Light under the surface follows the water's optical properties (water_absorption,
 * water_scattering): the deep-water color (water_body_albedo()) and the light that
 * crosses thin wave crests and scatters toward the eye (crest_scatter(), in light()).
 *
 * The water is transparent: it reads the opaque scene (screen and depth textures), so
 * Godot draws it in the transparent pass. The scene behind the surface is seen along the
 * refracted view ray (find_refracted_scene()) and attenuated over the water it crosses
 * (underwater_transmittance()); the water body's color fills in what is not transmitted.
 *
 * The water is drawn on the earth's curve (earth_curvature_drop()), so it ends at a real
 * horizon. Everything else about the surface (waves, queries, hulls, planar reflections)
 * stays flat: water_world_position is the flat position, and only the drawn vertex and
 * the shading normal follow the curve.
 */

#define MAX_CASCADES 8
#define MAX_NEAR_HULLS 8
#define MAX_LOD_LEVELS 16
// Solid angle (sr) of the sun's (and the moon's) disk, about 0.53 degrees across.
#define LIGHT_DISK_SOLID_ANGLE 6.8e-5
// Radius (m) of the sphere the water is drawn on (OceanSystem.EARTH_RADIUS).
#define EARTH_RADIUS 6371000.0
#define WATER_IOR 1.333
// Scattering by water molecules (1/m; Morel: 0.00193 (550 nm / lambda)^4.32 at the sRGB
// primaries' wavelengths), and the share particles scatter backward (Petzold, about 1.8%).
#define WATER_MOLECULAR_SCATTERING vec3(0.0012, 0.0019, 0.0040)
#define WATER_PARTICLE_BACKSCATTER_RATIO 0.018
// Light paths through wave crests (crest_light_path()): march steps 0.25 * 2^k m, and the
// length assumed when the march does not leave the water.
#define CREST_MARCH_STEPS 7
#define CREST_PATH_MAX 32.0
// Foam lighting (light()): wrap of its diffuse term, and strength and sharpness of the
// light it lets through toward the viewer.
#define FOAM_WRAP 0.6
#define FOAM_TRANSMISSION 0.5
#define FOAM_TRANSMISSION_POWER 4.0
// Refinement steps of the planar reflection hit along a pixel's reflected ray.
#define PLANAR_REFLECTION_STEPS 3
// Refracted view ray's search for the opaque scene (find_refracted_scene()): march and
// bisection steps, how far (m) behind a surface the ray may end up and still pass through
// it, the nearest view depth (m) the ray is followed to, and the longest path (m) searched
// (light from farther is gone).
#define REFRACTION_MARCH_STEPS 32
#define REFRACTION_REFINE_STEPS 6
#define REFRACTION_THICKNESS 0.25
// Pixels between an object's silhouette and the scene that stands in for what it hides.
#define REFRACTION_SILHOUETTE_MARGIN 3.0
#define REFRACTION_NEAR 0.05
#define REFRACTION_MAX_DISTANCE 64.0
// Caustics (caustic_light()): angular diameter (rad) of the sun's disk, which blurs them
// by that times the light's path; the share of the direct sun in a clear sky's light on
// a level surface; and the softening of the focus singularity (peak about 1 / it).
#define SUN_ANGULAR_DIAMETER 0.0093
#define CAUSTIC_CLEAR_SKY_DIRECT_SHARE 0.8
#define CAUSTIC_SOFTENING 0.12
// Mean cosine of the downwelling light's directions below the surface (about 0.8 under a
// high sun): its diffuse attenuation is K_d = (a + bb) / mean cosine (Kirk 1984).
#define WATER_DOWNWELLING_MEAN_COSINE 0.8

uniform vec4 foam_color : source_color;
// Optical properties of the water, per sRGB channel (1/m): absorption, and scattering by
// particles (sediment, plankton). Pure seawater absorbs about (0.30, 0.056, 0.012); dissolved
// organic matter and algae add to it, turning clear blue water greener and darker. Particles
// make it brighter and more turbid.
uniform vec3 water_absorption = vec3(0.45, 0.07, 0.03);
uniform vec3 water_scattering = vec3(0.03, 0.035, 0.04);
uniform float water_scattering_anisotropy : hint_range(0.0, 0.99) = 0.85; // Henyey-Greenstein g of particle scattering (ocean particles: about 0.9)

uniform float clear_roughness : hint_range(0.0, 1.0) = 0.10;
uniform float foam_roughness : hint_range(0.0, 1.0) = 0.24;
uniform float normal_strength : hint_range(0.0, 1.0) = 1.0; // Global normal strength
uniform float foam_intensity : hint_range(0.0, 4.0) = 1.0; // multiplies the wave foam coverage
// Foam pattern with uniformly distributed values (textures/generate_foam_detail.py): foam
// shows where pattern > 1 - coverage, which covers exactly `coverage` of the area.
uniform sampler2D foam_detail : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform float foam_detail_tile_size = 3.0; // meters per pattern tile
uniform vec4 sky_top_color : source_color = vec4(0.12, 0.42, 0.78, 1.0);
uniform vec4 sky_horizon_color : source_color = vec4(0.58, 0.78, 0.94, 1.0);
uniform vec4 sky_ground_horizon_color : source_color = vec4(0.16, 0.24, 0.28, 1.0);
uniform vec4 sky_ground_bottom_color : source_color = vec4(0.01, 0.02, 0.03, 1.0);
uniform vec3 sky_sun_direction = vec3(0.0, 0.2, -1.0);
uniform float sky_sun_visibility : hint_range(0.0, 1.0) = 1.0;
// Clouds from the sky source (SkySystem.get_cloud_cubemap()): rgb premultiplied
// radiance, a opacity, with a mip chain for rough reflections. Set at runtime by OceanSystem.
uniform bool sky_clouds_enabled = false;
uniform samplerCube sky_cloud_cubemap : filter_linear_mipmap;
// The sky source's atmosphere seen from the sea (get_atmosphere_sky_volumes(): transmittance,
// in-scatter but the lobe, lobe in-scatter per unit phase, at the cloud base and at the ray's
// end; get_atmosphere_light(): xyz toward its light, w the lobe's g). With it the sky the
// water reflects is the atmosphere's, and the sky colours above are unused. Set at runtime
// by OceanSystem.
uniform bool sky_atmosphere_enabled = false;
uniform sampler3D sky_atmosphere_transmittance : filter_linear, repeat_disable;
uniform sampler3D sky_atmosphere_inscatter : filter_linear, repeat_disable;
uniform sampler3D sky_atmosphere_inscatter_lobe : filter_linear, repeat_disable;
uniform vec4 sky_atmosphere_light = vec4(0.0, 1.0, 0.0, 0.97);
// The sky source's atmosphere between the camera and the scene (get_atmosphere_view_volumes(),
// same three volumes for the observer aerial_observer: world position, w its altitude as the
// volumes use it; slices out to aerial_max_distance). The water is drawn after the sky's
// aerial perspective, so it hazes itself (FOG). Set at runtime by OceanSystem.
uniform bool aerial_perspective_enabled = false;
uniform sampler3D aerial_transmittance : filter_linear, repeat_disable;
uniform sampler3D aerial_inscatter : filter_linear, repeat_disable;
uniform sampler3D aerial_inscatter_lobe : filter_linear, repeat_disable;
uniform vec4 aerial_observer;
uniform float aerial_max_distance = 1.0;
uniform bool sky_reflection_enabled = true;
uniform float sky_reflection_strength : hint_range(0.0, 2.0) = 1.0;
uniform float sky_reflection_f0 : hint_range(0.0, 0.12) = 0.02;
uniform float sun_specular_strength : hint_range(0.0, 4.0) = 1.0;
// Stochastic glints (see glitter_scale()): facets per square meter of water, 0 = smooth highlight.
uniform float sun_glitter_density : hint_range(0.0, 10000000.0) = 1000000.0;
uniform float sun_glitter_rate : hint_range(0.0, 60.0) = 12.0; // glint patterns per second
uniform int water_debug_view : hint_range(0, 15) = 0;
// The camera's exposure (CameraAttributes.exposure_multiplier, or the world's), set
// every frame by OceanSystem. The reflections are summed pre-exposed, as the sky source's
// clouds and atmosphere and the planar reflection are stored, and EMISSION (which Godot
// exposes itself) divides by it.
uniform float scene_exposure = 1.0;
uniform bool planar_reflection_enabled = false;
// Linear HDR, rgb premultiplied by geometry coverage (a), with a mip chain (PlanarReflectionCaptureEffect).
uniform sampler2D planar_reflection_texture : filter_linear_mipmap, repeat_disable;
// Distance (m) from the mirrored camera to the surface each texel shows, 0 = no geometry.
uniform sampler2D planar_reflection_distance : filter_nearest, repeat_disable;
uniform mat4 planar_reflection_view_projection;
uniform vec3 planar_reflection_camera_position; // the mirrored camera
uniform float planar_reflection_texel_angle = 0.001; // radians per mip-0 texel at the image center
uniform float planar_reflection_strength : hint_range(0.0, 1.0) = 0.0; // how much reflected geometry covers the sky behind it
uniform float planar_reflection_plane_y = 0.0;
// The opaque scene behind the water (linear HDR, exposed like EMISSION after scene_exposure).
uniform sampler2D scene_color : hint_screen_texture, filter_linear_mipmap, repeat_disable;
uniform sampler2D scene_depth : hint_depth_texture, filter_nearest, repeat_disable;
// The opaque scene's view-space normals (rgb * 2 - 1), for which way what lies below faces.
uniform sampler2D scene_normal_roughness : hint_normal_roughness_texture, filter_nearest, repeat_disable;
uniform bool use_bicubic_normals = true;
uniform int fragment_cascade_limit : hint_range(1, 8) = 3;
// CDLOD mesh (OceanSystem._update_lod_grid). Off for the editor's preview plane.
uniform bool lod_grid_enabled = false;
uniform float lod_ranges[MAX_LOD_LEVELS];       // beyond range(L), level-L vertices sit on the level L + 1 lattice
uniform float lod_morph_starts[MAX_LOD_LEVELS]; // level-L vertices morph between this and range(L)
uniform int lod_top_level = 0;
// Hulls near the camera (see OceanSystem._update_hull_cutouts and HullProfile).
uniform int near_hull_count = 0;
uniform vec4 near_hull_world_to_local_x[MAX_NEAR_HULLS]; // rows of the world-to-hull affine transform: xyz basis row, w origin
uniform vec4 near_hull_world_to_local_y[MAX_NEAR_HULLS];
uniform vec4 near_hull_world_to_local_z[MAX_NEAR_HULLS];
uniform vec4 near_hull_spheres[MAX_NEAR_HULLS]; // world center xyz, (radius + feather)^2
uniform vec4 near_hull_rects[MAX_NEAR_HULLS];   // profile min z, min y, 1 / length, 1 / height
uniform vec4 near_hull_params[MAX_NEAR_HULLS];  // profile layer, center x, feather (m), edge foam
uniform float near_hull_top_offsets[MAX_NEAR_HULLS]; // cutout reach above the station top, in profile heights
uniform sampler2DArray hull_profiles : filter_linear, repeat_disable; // R = inner half-width over (z, y), B = station top

// Interaction simulation (WaterInteractionSim): rgba16f h, eta, foam, wrap-around addressed.
uniform bool interaction_enabled = false;
uniform sampler2D interaction_render : repeat_enable, filter_linear;
uniform vec4 interaction_window = vec4(0.0); // window center x, center z, fade start, fade end (Chebyshev distance from center, m)
uniform float interaction_inv_extent = 0.0;  // 1 / window size (m)
uniform float interaction_cell_size = 0.5;

group_uniforms cascade_data;
uniform vec4 map_scales[MAX_CASCADES];               // Scales for displacement/normal maps. Packed: [uv scale, displacement scale, normal scale]
uniform vec4 spectrum_blend_states[MAX_CASCADES];    // Packed: [active layer, pending layer, active weight, pending weight]; pending weight is 0 unless a spectrum crossfade is running
uniform int num_cascades = 0;
// Two maps of each kind, A and B, hold every cascade's two latest FFT frames in either order
// (WaveGenerator); wave_frame_blends[i].x is cascade i's weight of B for the current time.
// Displacement maps carry mip chains: coarse vertices read prefiltered waves.
uniform sampler2DArray displacements_a : filter_linear_mipmap, repeat_enable; // Each layer represents one wave cascade.
uniform sampler2DArray displacements_b : filter_linear_mipmap, repeat_enable;
// Normal maps: xy mean slope, z mean squared slope, w foam; full mip chain (mip_downsample.glsl).
uniform sampler2DArray normals_a : hint_normal, filter_linear_mipmap, repeat_enable;
uniform sampler2DArray normals_b : hint_normal, filter_linear_mipmap, repeat_enable;
uniform vec4 wave_frame_blends[MAX_CASCADES]; // x: weight of map B (OceanSystem._get_cascade_frame_blend())

varying float foam_factor;
// Flat (uncurved) world position of the displaced surface.
varying vec3 water_world_position;
// Fragment -> light(): multiplies the specular highlight (foam covers it).
varying float light_specular_scale;
// Fragment -> light(): view-ray transmission for crest_scatter() (Fresnel, foam covers it).
varying float crest_transmission;
// Fragment -> light(), for glitter_scale(): random numbers of the pixel's glint cells, for
// (fine level, coarse level) x (current pattern, next pattern).
varying vec4 glitter_random;
// Facets in a fine and in a coarse cell, fine-to-coarse blend, current-to-next pattern blend.
varying vec4 glitter_cells;

/*
 * How far the water at world XZ is drawn below the plane touching the sphere under
 * the camera (distance^2 / 2R, exact to well below a millimeter within 100 km).
 */
float earth_curvature_drop(vec2 xz, vec3 camera_position) {
	vec2 offset = xz - camera_position.xz;
	return dot(offset, offset) * (0.5 / EARTH_RADIUS);
}

/*
 * Turns a direction from the flat frame at world XZ into the world: the sphere's
 * surface there is tilted away from the camera by (distance / R) radians.
 */
vec3 earth_curvature_tilt(vec3 direction, vec2 xz, vec3 camera_position) {
	vec2 offset = xz - camera_position.xz;
	float distance_xz = length(offset);
	vec2 radial = distance_xz > 0.0 ? offset / distance_xz : vec2(0.0);
	float angle = distance_xz / EARTH_RADIUS;
	float s = sin(angle);
	float c = cos(angle);
	float along = dot(direction.xz, radial);
	// Rotation in the (radial, up) plane that takes up to (sin, cos).
	float tilted_along = along * c + direction.y * s;
	float tilted_up = direction.y * c - along * s;
	vec2 horizontal = direction.xz + radial * (tilted_along - along);
	return vec3(horizontal.x, tilted_up, horizontal.y);
}

/* View-volume x: azimuth from the atmosphere's light (atmosphere_view_x()). */
float atmosphere_light_azimuth_x(vec3 direction) {
	vec2 light_xz = sky_atmosphere_light.xz;
	float d = length(direction.xz);
	float l = length(light_xz);
	float cos_phi = d > 1e-5 && l > 1e-5 ? dot(direction.xz, light_xz) / (d * l) : 1.0;
	return acos(clamp(cos_phi, -1.0, 1.0)) / PI;
}

/* The haze lobe's Henyey-Greenstein phase toward direction (1/sr). */
float atmosphere_lobe_phase(vec3 direction) {
	float g = sky_atmosphere_light.w;
	float denominator = 1.0 + g * g - 2.0 * g * dot(direction, sky_atmosphere_light.xyz);
	return (1.0 - g * g) / (4.0 * PI * denominator * sqrt(denominator));
}

/*
 * The sky source's sea-level view volume (two slices: 0 at the cloud base, 1 at the
 * ray's end) along an upward direction: transmittance and in-scatter from the sea to
 * there, the lobe's phase applied. The mapping is the sky system's
 * atmosphere_view_uvw() (shaders/compute/atmosphere_common.glslinc and
 * atmosphere.gdshaderinc) for an observer at altitude 0, whose horizon is level.
 * Change them together.
 */
void atmosphere_sea_lookup(vec3 direction, float slice, out vec3 transmittance, out vec3 inscatter) {
	vec3 size = vec3(textureSize(sky_atmosphere_transmittance, 0));
	float x = atmosphere_light_azimuth_x(direction);
	// Zenith angle over the half-turn from the zenith to the level horizon, squeezed
	// toward the horizon; directions below it (none here: reflections point up) mirror it.
	float zenith = acos(clamp(direction.y, -1.0, 1.0)) / (0.5 * PI);
	float y = zenith < 1.0 ? 0.5 * (1.0 - sqrt(1.0 - zenith)) : 0.5 + 0.5 * sqrt(min(zenith - 1.0, 1.0));
	vec3 uvw = vec3(0.5 / size.x + x * (1.0 - 1.0 / size.x), clamp(y, 0.5 / size.y, 1.0 - 0.5 / size.y), (slice + 0.5) / size.z);
	transmittance = textureLod(sky_atmosphere_transmittance, uvw, 0.0).rgb;
	inscatter = textureLod(sky_atmosphere_inscatter, uvw, 0.0).rgb + textureLod(sky_atmosphere_inscatter_lobe, uvw, 0.0).rgb * atmosphere_lobe_phase(direction);
}

/*
 * The atmosphere between the camera and a drawn point of the water, as FOG: Godot blends
 * the lit color toward FOG.rgb by FOG.a, which is the mean transmittance (exact for grey
 * haze), as the sky system's atmosphere_fog() does for other transparent surfaces. The
 * camera view volume's mapping is the sky system's atmosphere_view_uvw() (zenith angle
 * squeezed toward the observer's horizon from both sides; slices by the square root of
 * the distance); change them together.
 */
vec4 aerial_perspective_fog(vec3 position) {
	vec3 offset = position - aerial_observer.xyz;
	float distance = length(offset);
	if (distance < 1e-3)
		return vec4(0.0);
	vec3 direction = offset / distance;
	vec3 size = vec3(textureSize(aerial_transmittance, 0));
	float h = max(aerial_observer.w, 0.0);
	float horizon_mu = -sqrt(h * (2.0 * EARTH_RADIUS + h)) / (EARTH_RADIUS + h);
	float beta = acos(clamp(-horizon_mu, -1.0, 1.0));
	float zenith_horizon = PI - beta;
	float zenith = acos(clamp(direction.y, -1.0, 1.0));
	float y = zenith < zenith_horizon
			? 0.5 * (1.0 - sqrt(max(1.0 - zenith / zenith_horizon, 0.0)))
			: 0.5 + 0.5 * sqrt(clamp((zenith - zenith_horizon) / max(beta, 1e-6), 0.0, 1.0));
	float slice = sqrt(clamp(distance / aerial_max_distance, 0.0, 1.0)) * (size.z - 2.0);
	vec3 uvw = vec3(0.5 / size.x + atmosphere_light_azimuth_x(direction) * (1.0 - 1.0 / size.x), clamp(y, 0.5 / size.y, 1.0 - 0.5 / size.y), (slice + 0.5) / size.z);
	vec3 transmittance = textureLod(aerial_transmittance, uvw, 0.0).rgb;
	vec3 inscatter = textureLod(aerial_inscatter, uvw, 0.0).rgb + textureLod(aerial_inscatter_lobe, uvw, 0.0).rgb * atmosphere_lobe_phase(direction);
	float opacity = 1.0 - dot(transmittance, vec3(1.0 / 3.0));
	return opacity > 1e-5 ? vec4(inscatter / opacity, opacity) : vec4(0.0);
}

/* 1 inside the interaction window, fading to 0 before its absorbing border. */
float interaction_fade(vec2 xz) {
	vec2 from_center = abs(xz - interaction_window.xy);
	return 1.0 - smoothstep(interaction_window.z, interaction_window.w, max(from_center.x, from_center.y));
}

/* Interaction render texel at world XZ; repeat addressing matches the wrap-around grid. */
vec4 sample_interaction(vec2 xz) {
	return textureLod(interaction_render, xz * interaction_inv_extent, 0.0);
}

void vertex() {
	// Vertex spacing (m), for prefiltering the displacement; 0 on the editor's preview plane.
	float vertex_spacing = 0.0;
	if (lod_grid_enabled) {
		// One CDLOD node per multimesh instance (identity transform). The mesh is a
		// grid whose UVs are its lattice coordinates; INSTANCE_CUSTOM holds the
		// node's world origin x, z, its vertex spacing and its level.
		int level = int(INSTANCE_CUSTOM.w + 0.5);
		vertex_spacing = INSTANCE_CUSTOM.z;
		vec2 xz = INSTANCE_CUSTOM.xy + UV * vertex_spacing;
		float camera_distance = distance(CAMERA_POSITION_WORLD, vec3(xz.x, VERTEX.y, xz.y));
		// Geomorphing: with distance, odd lattice vertices slide onto their even
		// neighbours, i.e. onto the next level's lattice, and on through coarser
		// levels. Positions then depend only on the world position, so nodes of
		// different levels meet without cracks. Nodes never reach more than two
		// levels beyond their own (OceanSystem.LOD_RANGE_FACTOR).
		for (int k = level; k < min(level + 2, lod_top_level); ++k) {
			float morph = clamp((camera_distance - lod_morph_starts[k]) / (lod_ranges[k] - lod_morph_starts[k]), 0.0, 1.0);
			if (morph <= 0.0)
				break;
			vec2 lattice = round(xz / vertex_spacing);
			xz = (lattice - mod(lattice, 2.0) * morph) * vertex_spacing;
			vertex_spacing *= 1.0 + morph;
			if (morph < 1.0)
				break;
		}
		VERTEX.xz = xz;
	}
	UV = VERTEX.xz;

	// Read displacements from displacement maps, prefiltered to the vertex spacing
	// (a mip whose texels are as wide as the spacing): waves shorter than the
	// mesh can show are averaged away instead of aliasing.
	float map_size = float(textureSize(displacements_a, 0).x);
	vec3 displacement = vec3(0);
	for (uint i = 0U; i < uint(num_cascades); ++i) {
		vec4 scales = map_scales[i];
		if (scales.z == 0.0)
			continue;
		float lod = log2(max(vertex_spacing * map_size * max(scales.x, scales.y), 1.0));
		vec4 blend_state = spectrum_blend_states[i];
		vec3 active_coords = vec3(UV*scales.xy, blend_state.x);
		float b_weight = wave_frame_blends[i].x;
		vec3 cascade_displacement = mix(textureLod(displacements_a, active_coords, lod).xyz, textureLod(displacements_b, active_coords, lod).xyz, b_weight) * blend_state.z;
		// Uniform branch: the pending spectrum is only sampled during a crossfade.
		if (blend_state.w > 0.0) {
			vec3 pending_coords = vec3(UV*scales.xy, blend_state.y);
			cascade_displacement += mix(textureLod(displacements_a, pending_coords, lod).xyz, textureLod(displacements_b, pending_coords, lod).xyz, b_weight) * blend_state.w;
		}
		displacement += cascade_displacement * scales.z;
	}
	VERTEX += displacement;
	if (interaction_enabled) {
		// Sampled at the displaced position: the simulation lives at final surface positions.
		VERTEX.y += sample_interaction(VERTEX.xz).x * interaction_fade(VERTEX.xz);
	}
	water_world_position = VERTEX;
	VERTEX.y -= earth_curvature_drop(VERTEX.xz, CAMERA_POSITION_WORLD);
}

/* Filter weights for a cubic B-spline. */
vec4 cubic_weights(float a) {
	float a2 = a*a;
	float a3 = a2*a;
	
	float w0 =-a3     + a2*3.0 - a*3.0 + 1.0;
	float w1 = a3*3.0 - a2*6.0         + 4.0;
	float w2 =-a3*3.0 + a2*3.0 + a*3.0 + 1.0;
	float w3 = a3;
	return vec4(w0, w1, w2, w3) / 6.0;
}

/* Performs bicubic B-spline filtering on the provided sampler. */
// Source: https://developer.nvidia.com/gpugems/gpugems2/part-iii-high-quality-rendering/chapter-20-fast-third-order-texture-filtering
vec4 texture_bicubic(in sampler2DArray sampler, in vec3 uvw) {
	vec2 dims = vec2(textureSize(sampler, 0).xy);
	vec2 dims_inv = 1.0 / dims;
	uvw.xy = uvw.xy*dims + 0.5;
	
	vec2 fuv = fract(uvw.xy);
	vec4 wx = cubic_weights(fuv.x);
	vec4 wy = cubic_weights(fuv.y);

	vec4 g = vec4(wx.xz + wx.yw, wy.xz + wy.yw);
	vec4 h = (vec4(wx.yw, wy.yw) / g + vec2(-1.5, 0.5).xyxy + floor(uvw.xy).xxyy)*dims_inv.xxyy;
	vec2 w = g.xz / (g.xz + g.yw);
	// LOD 0: only used under magnification. Explicit, so this may run in divergent control flow.
	return mix(
		mix(textureLod(sampler, vec3(h.yw, uvw.z), 0.0), textureLod(sampler, vec3(h.xw, uvw.z), 0.0), w.x),
		mix(textureLod(sampler, vec3(h.yz, uvw.z), 0.0), textureLod(sampler, vec3(h.xz, uvw.z), 0.0), w.x), w.y);
}

/*
 * One spectrum layer's (mean slope xy, unresolved slope variance, foam), blended between its two
 * FFT frames in maps A and B by b_weight. Trilinear at mip lod (explicit, so it may run after the
 * hull discard). bilinear_weight 1 skips the bicubic filter (8 extra reads), which only helps
 * under magnification.
 */
vec4 sample_normal_layer(vec3 coords, float lod, float bilinear_weight, float b_weight) {
	vec4 sample_a = textureLod(normals_a, coords, lod);
	vec4 sample_b = textureLod(normals_b, coords, lod);
	if (use_bicubic_normals && bilinear_weight < 1.0) {
		sample_a = mix(texture_bicubic(normals_a, coords), sample_a, bilinear_weight);
		sample_b = mix(texture_bicubic(normals_b, coords), sample_b, bilinear_weight);
	}
	// Slopes the filter averaged away: E|g|^2 - |E g|^2 (mip_downsample.glsl), per frame, as
	// blending two frames' slopes is not roughness. Interpolating texels with different slopes
	// also raises it, but while a pixel covers less than a texel that spread is drawn (the
	// interpolated slope varies across pixels), not missed: count it from one texel up.
	float variance_a = max(sample_a.z - dot(sample_a.xy, sample_a.xy), 0.0);
	float variance_b = max(sample_b.z - dot(sample_b.xy, sample_b.xy), 0.0);
	vec4 blended = mix(sample_a, sample_b, b_weight);
	blended.z = mix(variance_a, variance_b, b_weight) * min(lod, 1.0);
	return blended;
}

float saturate(float value) {
	return clamp(value, 0.0, 1.0);
}

vec3 safe_normalize_vec3(vec3 value, vec3 fallback) {
	if (dot(value, value) < 0.000001) {
		return fallback;
	}
	return normalize(value);
}

float fresnel_schlick(float no_v, float f0) {
	return f0 + (1.0 - f0) * pow(1.0 - saturate(no_v), 5.0);
}

/*
 * Fresnel reflectance averaged over a rough surface (Bruneton, Neyret, Holzschuch,
 * "Real-time Realistic Ocean Lighting using Seamless Transitions from Geometry to
 * BRDF", 2010), for the mean normal and an isotropic slope deviation sigma per
 * axis. Unresolved facets seen at grazing angles tilt toward the viewer, so a
 * rough sea reflects much less than a mirror there.
 */
float rough_fresnel(float no_v, float sigma, float f0) {
	float mean = pow(1.0 - saturate(no_v), 5.0 * exp(-2.69 * sigma)) / (1.0 + 22.7 * pow(sigma, 1.5));
	return f0 + (1.0 - f0) * mean;
}

/* Sky gradient without clouds. */
vec3 sample_sky_gradient(vec3 direction) {
	float upper_blend = smoothstep(0.0, 0.55, direction.y);
	vec3 upper_sky = mix(sky_horizon_color.rgb, sky_top_color.rgb, upper_blend);

	float lower_blend = smoothstep(0.0, 0.55, -direction.y);
	vec3 lower_sky = mix(sky_ground_horizon_color.rgb, sky_ground_bottom_color.rgb, lower_blend);

	float horizon_blend = smoothstep(-0.035, 0.055, direction.y);
	return mix(lower_sky, upper_sky, horizon_blend);
}

/*
 * The sky source's clouds seen in direction (rgb premultiplied radiance, a opacity),
 * blurred over the reflection lobe of GGX roughness (perceptual); none without clouds.
 */
vec4 sample_clouds(vec3 direction, float roughness) {
	if (!sky_clouds_enabled) {
		return vec4(0.0);
	}
	// Reflected directions spread with an angular deviation of about sqrt(2) alpha
	// (twice the normal's, slope deviation alpha / sqrt(2)). A box-filtered mip of
	// texels 2^lod wide (about 2 / face size radians each at mip 0) has deviation
	// 2^lod * texel / sqrt(12); matching the two gives the level.
	float alpha = roughness * roughness;
	float lod = log2(max(alpha * float(textureSize(sky_cloud_cubemap, 0).x) * 2.45, 1.0));
	// Explicit LOD: called from divergent control flow.
	return textureLod(sky_cloud_cubemap, direction, lod);
}

/*
 * The sky without clouds in direction, from the sky source's atmosphere when it has one
 * (the in-scatter at the ray's end), else from the gradient.
 */
vec3 sample_clear_sky(vec3 direction) {
	if (sky_atmosphere_enabled) {
		vec3 transmittance;
		vec3 inscatter;
		atmosphere_sea_lookup(direction, 1.0, transmittance, inscatter);
		return inscatter;
	}
	return sample_sky_gradient(direction) * scene_exposure;
}

/*
 * The sky reflected over a rough surface: the clear sky averaged over the reflection
 * lobe, whose directions spread with an angular deviation of about sigma = sqrt(2) alpha
 * per axis (as for the clouds, sample_clouds()), by the 4-point Gaussian cubature
 * (+-sqrt(2) sigma along the elevation and the azimuth, weights 1/4: exact for skies that
 * vary up to cubically across the lobe). Directions below the horizon are mirrored up, as
 * the reflection is. The clouds are prefiltered (cubemap mips) and read once.
 */
vec3 sample_rough_procedural_environment(vec3 direction, float roughness) {
	float rough = saturate(roughness);
	float sigma = 1.41421356 * rough * rough;
	vec3 sky;
	if (sigma < 0.005) {
		sky = sample_clear_sky(direction);
	} else {
		vec3 elevation_axis = safe_normalize_vec3(vec3(0.0, 1.0, 0.0) - direction * direction.y, vec3(0.0, 0.0, 1.0));
		vec3 azimuth_axis = cross(direction, elevation_axis);
		float offset = tan(min(1.41421356 * sigma, 1.2));
		sky = vec3(0.0);
		for (int i = 0; i < 4; ++i) {
			vec3 axis = i < 2 ? elevation_axis : azimuth_axis;
			vec3 sample_direction = normalize(direction + axis * (i % 2 == 0 ? offset : -offset));
			sample_direction.y = abs(sample_direction.y);
			sky += sample_clear_sky(sample_direction) * 0.25;
		}
	}
	vec3 cloud_direction = direction;
	vec4 cloud = sample_clouds(cloud_direction, rough);
	if (!sky_atmosphere_enabled) {
		return sky * (1.0 - cloud.a) + cloud.rgb;
	}
	if (cloud.a <= 0.0) {
		return sky;
	}
	// The clouds sit inside the atmosphere: the air up to their base lies in front of
	// them, the rest of the sky (sky less that air's in-scatter) behind.
	vec3 transmittance_cloud;
	vec3 inscatter_cloud;
	atmosphere_sea_lookup(cloud_direction, 0.0, transmittance_cloud, inscatter_cloud);
	return inscatter_cloud + transmittance_cloud * cloud.rgb + (1.0 - cloud.a) * (sky - inscatter_cloud);
}

float ggx_distribution(float no_h, float roughness) {
	float alpha = max(roughness * roughness, 0.0009);
	float alpha2 = alpha * alpha;
	float denom = no_h * no_h * (alpha2 - 1.0) + 1.0;
	return alpha2 / max(3.14159265 * denom * denom, 0.00001);
}

/* Height-correlated Smith visibility, G / (4 N.L N.V). */
float smith_ggx_visibility(float no_v, float no_l, float roughness) {
	float alpha = max(roughness * roughness, 0.0009);
	float alpha2 = alpha * alpha;
	float lambda_v = no_l * sqrt(no_v * no_v * (1.0 - alpha2) + alpha2);
	float lambda_l = no_v * sqrt(no_l * no_l * (1.0 - alpha2) + alpha2);
	return 0.5 / max(lambda_v + lambda_l, 0.00001);
}

/* Specular BRDF of the water surface (GGX, Schlick Fresnel with the water's f0), without N.L. */
float water_specular_brdf(vec3 normal, vec3 view, vec3 light_direction, float roughness) {
	vec3 half_vector = safe_normalize_vec3(view + light_direction, normal);
	float no_v = max(dot(normal, view), 0.0001);
	float no_l = saturate(dot(normal, light_direction));
	float distribution = ggx_distribution(saturate(dot(normal, half_vector)), roughness);
	float visibility = smith_ggx_visibility(no_v, no_l, roughness);
	float fresnel = fresnel_schlick(saturate(dot(view, half_vector)), sky_reflection_f0);
	return distribution * visibility * fresnel;
}

/* Backscattering coefficient (1/m): half the molecular scattering, and the particles' share. */
vec3 water_backscattering() {
	return 0.5 * WATER_MOLECULAR_SCATTERING + WATER_PARTICLE_BACKSCATTER_RATIO * water_scattering;
}

/*
 * Transmittance of the water to a point behind the surface: the view ray's path through
 * the water (beam attenuation a + b: light scattered out of the ray no longer forms the
 * image), and the point's depth below the surface, which dims the light reaching it
 * (diffuse attenuation K_d; the scene's lights know nothing of the water).
 */
vec3 underwater_transmittance(float path_length, float depth) {
	vec3 beam_attenuation = water_absorption + water_scattering + WATER_MOLECULAR_SCATTERING;
	vec3 downwelling_attenuation = (water_absorption + water_backscattering()) / WATER_DOWNWELLING_MEAN_COSINE;
	return exp(-beam_attenuation * path_length - downwelling_attenuation * depth);
}

/* View depth (m, positive) of the opaque scene at a screen point; 0 where there is none (sky). */
float scene_view_depth(vec2 screen_uv, mat4 inv_projection) {
	float depth = textureLod(scene_depth, screen_uv, 0.0).r;
	if (depth <= 0.0)
		return 0.0; // Reversed Z: nothing was drawn in front of the far plane.
	vec4 view = inv_projection * vec4(screen_uv * 2.0 - 1.0, depth, 1.0);
	return -view.z / view.w;
}

/* View-space position of the opaque scene at a screen point; w = 0 where there is none (sky). */
vec4 scene_view_position(vec2 screen_uv, mat4 inv_projection) {
	float depth = textureLod(scene_depth, screen_uv, 0.0).r;
	if (depth <= 0.0)
		return vec4(0.0);
	vec4 view = inv_projection * vec4(screen_uv * 2.0 - 1.0, depth, 1.0);
	return vec4(view.xyz / view.w, 1.0);
}

/* Screen coordinates of a view-space point. */
vec2 screen_project(vec3 view_position, mat4 projection) {
	vec4 clip = projection * vec4(view_position, 1.0);
	return clip.xy / clip.w * 0.5 + 0.5;
}

/*
 * How far the ray's point at screen fraction u lies behind the scene seen there (m of view
 * depth; negative in front), and that scene point (view space). underwater is false where
 * the scene is nothing the ray can meet: none (sky), or above the water (higher than
 * origin, the surface point).
 */
float refraction_gap(float u, vec3 origin, vec3 end, float start_k, float end_k, vec2 start_uv, vec2 delta, vec3 up, mat4 inv_projection, out vec3 scene_point, out bool underwater) {
	float k = mix(start_k, end_k, u);
	vec3 position = mix(origin * start_k, end * end_k, u) / k;
	float scene = scene_view_depth(start_uv + delta * u, inv_projection);
	scene_point = position * (scene * k);
	underwater = scene > 0.0 && dot(scene_point - origin, up) <= 0.0;
	return 1.0 / k - scene;
}

/*
 * Where the view ray, refracted into the water at origin (view space), meets the opaque
 * scene. The march steps along the ray's image on the screen (depth interpolated
 * perspective-correctly; steps growing quadratically from the surface). Where the ray
 * goes from in front of the underwater scene to behind it, a bisection finds the
 * transition: if the ray ends up just behind the surface there (a screen point and its
 * depth are one point), it passes through it; if far behind, it went behind an object and
 * continues hidden. Scene above the water is nothing the ray can meet. A hidden ray that
 * finds nothing afterwards meets what is not on the screen, and the scene where it was
 * last seen stands in (the bottom next to the object, screen_pixel-sized steps back). Where the ray leaves the screen,
 * or finds nothing within max_distance, it is assumed to meet a level bottom at the depth
 * of the last underwater scene it passed over (at first the straight-through scene's,
 * bottom_depth m below the surface). Returns the screen point, which may be off the
 * screen.
 */
vec2 find_refracted_scene(vec3 origin, vec3 direction, vec3 up, float bottom_depth, float max_distance, vec2 screen_pixel, mat4 projection, mat4 inv_projection) {
	vec3 end = origin + direction * max_distance;
	if (end.z > -REFRACTION_NEAR) // Keep the end in front of the camera.
		end = origin + direction * ((-REFRACTION_NEAR - origin.z) / direction.z);
	vec2 start_uv = screen_project(origin, projection);
	vec2 delta = screen_project(end, projection) - start_uv;
	// 1 / depth is linear along the ray's image; so is position / depth.
	float start_k = 1.0 / -origin.z;
	float end_k = 1.0 / -end.z;
	// Only the part on the screen can be searched.
	float u_max = 1.0;
	for (int axis = 0; axis < 2; ++axis) {
		float end_uv = start_uv[axis] + delta[axis];
		if (end_uv < 0.0)
			u_max = min(u_max, -start_uv[axis] / delta[axis]);
		else if (end_uv > 1.0)
			u_max = min(u_max, (1.0 - start_uv[axis]) / delta[axis]);
	}
	float previous_u = 0.0;
	bool previous_behind = false;
	bool hidden = false;
	vec2 last_seen_uv = start_uv;
	vec3 scene_point;
	bool underwater;
	for (int i = 1; i <= REFRACTION_MARCH_STEPS; ++i) {
		float step_fraction = float(i) / float(REFRACTION_MARCH_STEPS);
		float u = u_max * step_fraction * step_fraction;
		float gap = refraction_gap(u, origin, end, start_k, end_k, start_uv, delta, up, inv_projection, scene_point, underwater);
		bool behind = underwater && gap >= 0.0;
		if (behind && !previous_behind) {
			float near_u = previous_u;
			float far_u = u;
			float far_gap = gap;
			vec3 mid_point;
			bool mid_underwater;
			for (int b = 0; b < REFRACTION_REFINE_STEPS; ++b) {
				float mid_u = 0.5 * (near_u + far_u);
				float mid_gap = refraction_gap(mid_u, origin, end, start_k, end_k, start_uv, delta, up, inv_projection, mid_point, mid_underwater);
				if (mid_underwater && mid_gap >= 0.0) {
					far_u = mid_u;
					far_gap = mid_gap;
				} else {
					near_u = mid_u;
				}
			}
			// The ray's own depth change over the final interval bounds the gap at a surface.
			// A ray that meets an object crosses its surface inside the object's silhouette, so
			// both ends of the interval see that surface; one that slips behind the object's edge
			// sees the background, much deeper, at the near end.
			float interval_depth = (1.0 / mix(start_k, end_k, far_u)) - (1.0 / mix(start_k, end_k, near_u));
			float near_scene = scene_view_depth(start_uv + delta * near_u, inv_projection);
			float far_scene = scene_view_depth(start_uv + delta * far_u, inv_projection);
			bool silhouette = near_scene > far_scene + interval_depth + REFRACTION_THICKNESS;
			if (far_gap <= interval_depth + REFRACTION_THICKNESS && !silhouette)
				return start_uv + delta * far_u;
			if (!hidden) // A few pixels back from the object's silhouette, so filtering does not pick it up.
				last_seen_uv = start_uv + delta * near_u - delta / max(length(delta), 1e-6) * REFRACTION_SILHOUETTE_MARGIN * screen_pixel;
			hidden = true;
		} else if (underwater && !behind) {
			bottom_depth = max(dot(origin - scene_point, up), 0.0); // The bottom it passes over.
		}
		previous_u = u;
		previous_behind = behind;
	}
	if (hidden)
		return last_seen_uv;
	float t = min(bottom_depth / max(-dot(direction, up), 0.05), max_distance);
	return screen_project(origin + direction * t, projection);
}

/* Cascade i's wave slope (gradient of the height) at a rest position, from mip lod. */
vec2 cascade_slope(uint i, vec2 rest_xz, float lod) {
	vec4 scales = map_scales[i];
	vec4 blend_state = spectrum_blend_states[i];
	float b_weight = wave_frame_blends[i].x;
	vec3 coords = vec3(rest_xz * scales.xy, blend_state.x);
	vec2 slope = mix(textureLod(normals_a, coords, lod).xy, textureLod(normals_b, coords, lod).xy, b_weight) * blend_state.z;
	// Uniform branch: the pending spectrum is only sampled during a crossfade.
	if (blend_state.w > 0.0) {
		coords.z = blend_state.y;
		slope += mix(textureLod(normals_a, coords, lod).xy, textureLod(normals_b, coords, lod).xy, b_weight) * blend_state.w;
	}
	return slope * scales.w;
}

/*
 * Variance of the wave slopes within a footprint of width meters around a rest position,
 * summed over the cascades: what the mips average away there (E|g|^2 - |E g|^2).
 */
float slope_variance_within(vec2 rest_xz, float width) {
	float map_size = float(textureSize(normals_a, 0).x);
	float variance = 0.0;
	uint cascade_count = min(uint(num_cascades), uint(fragment_cascade_limit));
	for (uint i = 0U; i < cascade_count; ++i) {
		vec4 scales = map_scales[i];
		vec4 blend_state = spectrum_blend_states[i];
		float texel = 1.0 / (map_size * max(scales.x, scales.y));
		float lod = log2(max(width / texel, 1.0));
		vec4 a = textureLod(normals_a, vec3(rest_xz * scales.xy, blend_state.x), lod);
		vec4 b = textureLod(normals_b, vec3(rest_xz * scales.xy, blend_state.x), lod);
		vec4 m = mix(a, b, wave_frame_blends[i].x);
		variance += max(m.z - dot(m.xy, m.xy), 0.0) * blend_state.z * blend_state.z * scales.w * scales.w;
	}
	return variance * normal_strength * normal_strength;
}

/*
 * Caustics: the waves focus and spread the sunlight that reaches what lies below.
 * Refraction turns a slope s into a deviation k s of the refracted ray (k = 1 - cos i /
 * (n cos t) in the plane of incidence; 1 - 1/n under a high sun), so after a path D the
 * light that entered at rest position x lands at x + D (t0 - k s(x)), and the irradiance
 * there is scaled by 1 / det(I - D k H), H the height's Hessian (the slopes' gradient).
 * Light reaching one point below comes from a patch of the surface about r = D k sigma
 * wide, sigma the deviation of the slopes of waves shorter than r: those focus far above
 * the point and their light arrives evenly mixed. So H is differenced over r (found by
 * iterating from the patch of all slopes), the blur the sun's disk gives over the path,
 * or the pixel's footprint there, whichever is widest, from the mips that average the
 * waves finer than it. Only the direct sun is redistributed, so the result is
 * 1 + share (focus - 1), whose mean over the bottom stays 1: share is the direct sun's
 * part of the light on that surface (sun visibility, the part of the beam not scattered
 * on the way down, and how much the surface faces the light).
 * hit: world position below the surface; hit_normal: its world normal; surface: the
 * (flat) world position of a nearby surface point, rest_xz its rest position; other
 * surface points' rest positions are taken at the same offset (the waves' horizontal
 * displacement changes little over the distance).
 */
float caustic_light(vec3 hit, vec3 hit_normal, vec3 to_sun, vec3 surface, vec2 rest_xz, float pixel_size) {
	float depth = surface.y - hit.y;
	if (to_sun.y <= 0.0 || depth <= 0.0 || num_cascades == 0)
		return 1.0;
	vec3 down = refract(-to_sun, vec3(0.0, 1.0, 0.0), 1.0 / WATER_IOR);
	float cos_t = -down.y;
	float path = depth / cos_t;
	float facing = dot(hit_normal, -down);
	vec3 beam_scattering = water_scattering + WATER_MOLECULAR_SCATTERING;
	float survival = exp(-dot(beam_scattering, vec3(1.0 / 3.0)) * path);
	float direct = CAUSTIC_CLEAR_SKY_DIRECT_SHARE * sky_sun_visibility * survival;
	// Light on a surface turned by facing / cos_t relative to a level one: the direct part
	// scales with it, the diffuse rest does not.
	float lit = direct * max(facing, 0.0) / cos_t;
	float share = lit / (lit + 1.0 - direct);
	if (share <= 0.001)
		return 1.0;
	// Where that light entered: back along the refracted ray, at the matching rest position.
	vec2 entry_rest = rest_xz + (hit.xz - down.xz * path - surface.xz);
	float k = 1.0 - to_sun.y / (WATER_IOR * cos_t);
	float blur = max(SUN_ANGULAR_DIAMETER * path, pixel_size);
	float mixing = path * k * sqrt(slope_variance_within(entry_rest, 1.0e6));
	for (int iteration = 0; iteration < 2; ++iteration)
		mixing = path * k * sqrt(slope_variance_within(entry_rest, max(mixing, blur)));
	blur = max(blur, mixing);
	float map_size = float(textureSize(normals_a, 0).x);
	mat2 hessian = mat2(0.0);
	uint cascade_count = min(uint(num_cascades), uint(fragment_cascade_limit));
	for (uint i = 0U; i < cascade_count; ++i) {
		vec4 scales = map_scales[i];
		float texel = 1.0 / (map_size * max(scales.x, scales.y));
		float e = max(blur, texel);
		float lod = log2(e / texel);
		vec2 dx = vec2(e, 0.0);
		vec2 dz = vec2(0.0, e);
		hessian[0] += (cascade_slope(i, entry_rest + dx, lod) - cascade_slope(i, entry_rest - dx, lod)) / (2.0 * e);
		hessian[1] += (cascade_slope(i, entry_rest + dz, lod) - cascade_slope(i, entry_rest - dz, lod)) / (2.0 * e);
	}
	mat2 jacobian = mat2(1.0) - path * k * normal_strength * hessian;
	float focus = inversesqrt(determinant(jacobian) * determinant(jacobian) + CAUSTIC_SOFTENING * CAUSTIC_SOFTENING);
	return 1.0 + share * (focus - 1.0);
}

/*
 * Albedo of optically deep water (radiance = albedo * irradiance / PI), from its optical
 * properties: the remote-sensing reflectance just below the surface, rrs = 0.0949 u + 0.0794 u^2
 * with u = bb / (a + bb) (Gordon et al. 1988), above it Rrs = 0.52 rrs / (1 - 1.7 rrs) (Lee et
 * al. 1998, for a view from above, surface transmission included); the albedo is PI Rrs.
 */
vec3 water_body_albedo() {
	vec3 backscattering = water_backscattering();
	vec3 u = backscattering / (water_absorption + backscattering);
	vec3 subsurface = (0.0949 + 0.0794 * u) * u;
	return PI * 0.52 * subsurface / (1.0 - 1.7 * subsurface);
}

/* Henyey-Greenstein phase function (1/sr). */
float henyey_greenstein(float cos_theta, float g) {
	float g2 = g * g;
	return (1.0 - g2) / (4.0 * PI * pow(max(1.0 + g2 - 2.0 * g * cos_theta, 1e-6), 1.5));
}

/*
 * Height of the FFT waves at rest position rest_xz, blended like the vertex shader and
 * prefiltered to `spacing` meters (wakes left out).
 */
float wave_height_at(vec2 rest_xz, float spacing) {
	float map_size = float(textureSize(displacements_a, 0).x);
	float height = 0.0;
	for (int i = 0; i < min(num_cascades, MAX_CASCADES); ++i) {
		vec4 scales = map_scales[i];
		if (scales.z == 0.0)
			continue;
		float lod = log2(max(spacing * map_size * max(scales.x, scales.y), 1.0));
		vec4 blend_state = spectrum_blend_states[i];
		float b_weight = wave_frame_blends[i].x;
		vec3 coords = vec3(rest_xz * scales.xy, blend_state.x);
		float cascade_height = mix(textureLod(displacements_a, coords, lod).y, textureLod(displacements_b, coords, lod).y, b_weight) * blend_state.z;
		if (blend_state.w > 0.0) {
			coords.z = blend_state.y;
			cascade_height += mix(textureLod(displacements_a, coords, lod).y, textureLod(displacements_b, coords, lod).y, b_weight) * blend_state.w;
		}
		height += cascade_height * scales.z;
	}
	return height;
}

/*
 * Length (m) of water a ray toward the light crosses from the surface point at rest position
 * rest_xz (world height surface_y) before it leaves the water: marched along the heightfield
 * in steps doubling from 0.25 m. Short behind thin wave crests; CREST_PATH_MAX when the ray
 * stays in the water (it is not refracted: the march only measures how thick the water is).
 */
float crest_light_path(vec2 rest_xz, float surface_y, vec3 to_light) {
	// The heightfield through this point (the mesh's own height may differ by wakes and filtering).
	float base = surface_y - wave_height_at(rest_xz, 0.25);
	float previous_t = 0.0;
	float previous_depth = 0.0;
	for (int k = 0; k < CREST_MARCH_STEPS; ++k) {
		float t = 0.25 * exp2(float(k));
		float depth = base + wave_height_at(rest_xz + to_light.xz * t, t * 0.5) - (surface_y + to_light.y * t);
		if (depth <= 0.0) {
			return mix(previous_t, t, previous_depth / (previous_depth - depth));
		}
		previous_t = t;
		previous_depth = depth;
	}
	return CREST_PATH_MAX;
}

/*
 * Light from direction to_light that enters the water, scatters once just under this surface
 * point and leaves toward the eye, per unit of the light's irradiance, before the view ray's own
 * Fresnel transmission. It is the glow of backlit wave crests: forward scattering is strong, so
 * it shows where light that crossed a thin crest heads for the eye.
 *
 * The view ray refracts through this face. Light enters through this face when it faces the
 * light, else through the crest's far face, taken as this face mirrored about the vertical (a
 * symmetric crest). Scattering: particles (Henyey-Greenstein) and water molecules (Rayleigh).
 * Along the view ray the light's path through the water grows about as fast as the view ray
 * goes in, so the in-scattering integrates to sigma_s p / (2 sigma_t), attenuated over the
 * light's path to this point (crest_light_path()).
 */
vec3 crest_scatter(vec3 normal, vec3 view, vec3 to_light, vec2 rest_xz, float surface_y, out float light_path, out float phase) {
	light_path = 0.0;
	phase = 0.0;
	vec3 view_in_water = refract(-view, normal, 1.0 / WATER_IOR);
	vec3 entry_normal = dot(normal, to_light) > 0.0 ? normal : vec3(-normal.x, normal.y, -normal.z);
	if (dot(entry_normal, to_light) <= 0.0 || dot(view_in_water, view_in_water) == 0.0)
		return vec3(0.0);
	vec3 light_in_water = refract(-to_light, entry_normal, 1.0 / WATER_IOR);
	float cos_theta = dot(light_in_water, -view_in_water);
	phase = henyey_greenstein(cos_theta, water_scattering_anisotropy);
	vec3 scattering = water_scattering * phase + WATER_MOLECULAR_SCATTERING * (3.0 / (16.0 * PI)) * (1.0 + cos_theta * cos_theta);
	vec3 extinction = water_absorption + water_scattering + WATER_MOLECULAR_SCATTERING;
	vec3 unshadowed = scattering / (2.0 * extinction);
	// Skip the march where even an unobstructed path would scatter almost nothing.
	if (max(unshadowed.r, max(unshadowed.g, unshadowed.b)) < 0.002)
		return vec3(0.0);
	light_path = crest_light_path(rest_xz, surface_y, to_light);
	float transmission_in = 1.0 - fresnel_schlick(dot(entry_normal, to_light), sky_reflection_f0);
	return unshadowed * transmission_in * exp(-extinction * light_path);
}

/* Uniform random number in [0, 1) for integer coordinates (PCG3D hash). */
float hash_uniform(ivec3 key) {
	uvec3 v = uvec3(key) * 1664525u + 1013904223u;
	v.x += v.y * v.z; v.y += v.z * v.x; v.z += v.x * v.y;
	v ^= v >> 16u;
	v.x += v.y * v.z; v.y += v.z * v.x; v.z += v.x * v.y;
	return float(v.x >> 8u) / 16777216.0;
}

/*
 * Glint multiplier of one cell with `facets` facets, of which a share `aligned_fraction` reflects
 * the light into the eye: the aligned count is Poisson distributed (drawn with uniform u), and
 * its ratio to the mean is the multiplier, so the mean highlight stays the GGX one.
 */
float glint_cell(float facets, float aligned_fraction, float u) {
	float mean = facets * aligned_fraction;
	if (mean <= 0.0) {
		return 1.0;
	}
	float count = 0.0;
	if (mean < 8.0) {
		// Inverse of the Poisson CDF.
		float probability = exp(-mean);
		float cumulative = probability;
		for (int k = 1; k < 24 && u > cumulative; ++k) {
			count += 1.0;
			probability *= mean / count;
			cumulative += probability;
		}
	} else {
		// Nearly normal: logistic approximation of the normal quantile (std 1).
		float z = log(max(u, 1e-6) / max(1.0 - u, 1e-6)) * 0.5513;
		count = max(mean + sqrt(mean) * z, 0.0);
	}
	return count / mean;
}

/*
 * Stochastic sun glitter (after Zirr & Kaplanyan 2016 and Deliot & Belcour 2023). The GGX
 * highlight is the mean over many tiny facets; a pixel holds a finite number of them, and the
 * few that point the light's disk at the eye flash as glints. World cells about a pixel wide
 * (two levels, blended) draw their aligned facet count; patterns change sun_glitter_rate times a
 * second and crossfade.
 */
float glitter_scale(vec3 normal, vec3 view, vec3 light_direction, float roughness) {
	vec3 half_vector = safe_normalize_vec3(view + light_direction, normal);
	float no_h = saturate(dot(normal, half_vector));
	float vo_h = max(dot(view, half_vector), 0.0001);
	// Share of facet normals inside the half-vector cone of the light's disk.
	float aligned_fraction = min(ggx_distribution(no_h, roughness) * no_h * LIGHT_DISK_SOLID_ANGLE / (4.0 * vo_h), 1.0);
	float fine = mix(glint_cell(glitter_cells.x, aligned_fraction, glitter_random.x), glint_cell(glitter_cells.x, aligned_fraction, glitter_random.y), glitter_cells.w);
	float coarse = mix(glint_cell(glitter_cells.y, aligned_fraction, glitter_random.z), glint_cell(glitter_cells.y, aligned_fraction, glitter_random.w), glitter_cells.w);
	return mix(fine, coarse, glitter_cells.z);
}

/*
 * Planar reflection texture coordinates of a world point (w = 1) or of a direction at
 * infinity (w = 0); z is 1 inside the image, else 0.
 */
vec3 planar_reflection_project(vec4 point) {
	vec4 clip = planar_reflection_view_projection * point;
	if (clip.w <= 0.0001) {
		return vec3(0.0);
	}
	vec2 uv = clip.xy / clip.w * 0.5 + 0.5;
	uv.y = 1.0 - uv.y;
	float inside = all(greaterThanEqual(uv, vec2(0.0))) && all(lessThanEqual(uv, vec2(1.0))) ? 1.0 : 0.0;
	return vec3(uv, inside);
}

void fragment() {
	// Screen-space derivatives of the world XZ position, taken before any discard:
	// the pixel footprint for normal map filtering.
	vec2 uv_dx = dFdx(UV);
	vec2 uv_dy = dFdy(UV);
	float meters_per_screen_pixel = max(abs(uv_dx.x) + abs(uv_dy.x), abs(uv_dx.y) + abs(uv_dy.y));

	// Hide water inside nearby hulls. The test runs on the water-surface point
	// itself, so it is view-independent; pitch and roll come from the transform.
	float hull_edge_foam = 0.0;
	for (int i = 0; i < min(near_hull_count, MAX_NEAR_HULLS); ++i) {
		vec3 to_center = water_world_position - near_hull_spheres[i].xyz;
		if (dot(to_center, to_center) > near_hull_spheres[i].w)
			continue; // Far from this hull.
		vec4 world_position = vec4(water_world_position, 1.0);
		vec3 local = vec3(dot(near_hull_world_to_local_x[i], world_position), dot(near_hull_world_to_local_y[i], world_position), dot(near_hull_world_to_local_z[i], world_position));
		vec2 profile_uv = (local.zy - near_hull_rects[i].xy) * near_hull_rects[i].zw;
		if (profile_uv.x < 0.0 || profile_uv.x > 1.0 || profile_uv.y < 0.0)
			continue; // Beyond the bow/stern or below the keel.
		vec4 params = near_hull_params[i];
		// Explicit LOD: these lookups sit in divergent control flow, where implicit derivatives are undefined.
		// Above this station's top (plus the offset) there is no hull; up to there,
		// heights above the top use the width at the top.
		float station_top = textureLod(hull_profiles, vec3(profile_uv.x, 0.5, params.x), 0.0).b;
		if (profile_uv.y > station_top + 0.5 / float(textureSize(hull_profiles, 0).y) + near_hull_top_offsets[i])
			continue;
		float half_width = textureLod(hull_profiles, vec3(profile_uv.x, min(profile_uv.y, station_top), params.x), 0.0).r;
		float hull_sdf = abs(local.x - params.y) - half_width; // < 0 inside the hull
		if (hull_sdf < 0.0) {
			discard;
		}
		hull_edge_foam = max(hull_edge_foam, (1.0 - smoothstep(0.0, max(params.z, 0.001), hull_sdf)) * params.w);
	}

	// Interaction simulation slope and foam (wakes, bow waves, splashes).
	vec2 interaction_gradient = vec2(0.0);
	float interaction_foam = 0.0;
	if (interaction_enabled) {
		vec2 xz = water_world_position.xz;
		float fade = interaction_fade(xz);
		if (fade > 0.0) {
			float e = interaction_cell_size;
			float h_left = sample_interaction(xz - vec2(e, 0.0)).x;
			float h_right = sample_interaction(xz + vec2(e, 0.0)).x;
			float h_back = sample_interaction(xz - vec2(0.0, e)).x;
			float h_front = sample_interaction(xz + vec2(0.0, e)).x;
			interaction_gradient = vec2(h_right - h_left, h_front - h_back) / (2.0 * e) * fade;
			interaction_foam = sample_interaction(xz).z * fade;
		}
	}

	vec2 gradient = vec2(0.0);
	float foam_signal = 0.0;
	// Total variance of the slopes inside the pixel footprint, over all cascades.
	float slope_variance = 0.0;
	foam_factor = 0.0;
	vec3 world_normal = vec3(0.0, 1.0, 0.0);
	float sky_reflection_amount = 0.0;
	vec3 reflected_sky_color = vec3(0.0);
	float sun_specular_amount = 0.0;
	float effective_reflection_roughness = 0.0;

	if (num_cascades > 0) {
		float map_size = float(textureSize(normals_a, 0).x);
		// Read foam and normal information from normal maps.
		uint cascade_count = min(uint(num_cascades), uint(fragment_cascade_limit));
		for (uint i = 0U; i < cascade_count; ++i) {
			vec4 scales = map_scales[i];
			vec4 blend_state = spectrum_blend_states[i];
			// Mix between bicubic and bilinear filtering depending on the world space pixels per meter.
			// This is dependent on the tile size as well as displacement/normal map resolution.
			// Where one screen pixel covers two or more texels (minification) bicubic adds nothing.
			float pixels_per_meter = map_size * min(scales.x, scales.y);
			float bilinear_weight = max(min(1.0, pixels_per_meter * 0.1), smoothstep(1.0, 2.0, meters_per_screen_pixel * pixels_per_meter));
			// Isotropic mip covering the pixel footprint's area. The slopes it averages
			// away become roughness (slope variance) instead of aliasing into sparkle.
			// Sizing it by the footprint's longer axis instead counts every slope along
			// a grazing footprint as round blur, which turns the water milky.
			float footprint = sqrt(length(uv_dx * scales.xy) * length(uv_dy * scales.xy)) * map_size;
			float lod = log2(max(footprint, 1.0));
			float b_weight = wave_frame_blends[i].x;
			vec4 active_sample = sample_normal_layer(vec3(UV*scales.xy, blend_state.x), lod, bilinear_weight, b_weight);
			vec2 cascade_gradient = active_sample.xy * blend_state.z;
			float cascade_variance = active_sample.z * blend_state.z * blend_state.z;
			float cascade_foam = active_sample.w;
			// Uniform branch: the pending spectrum is only sampled during a crossfade.
			if (blend_state.w > 0.0) {
				vec4 pending_sample = sample_normal_layer(vec3(UV*scales.xy, blend_state.y), lod, bilinear_weight, b_weight);
				cascade_gradient += pending_sample.xy * blend_state.w;
				// The two spectra are independent, so their variances add with squared weights.
				cascade_variance += pending_sample.z * blend_state.w * blend_state.w;
				// Foam is a non-negative mask, so it crossfades linearly rather than by equal power.
				cascade_foam = mix(active_sample.w, pending_sample.w, blend_state.w / (blend_state.z + blend_state.w));
			}
			gradient += cascade_gradient * scales.w;
			slope_variance += cascade_variance * scales.w * scales.w;
			foam_signal += cascade_foam;
		}

		// Foam is coverage (fft_unpack.glsl), so its mips hold the covered share of
		// each texel: right at every distance, with no fade.
		foam_factor = saturate(foam_signal * foam_intensity);

		gradient = (gradient + interaction_gradient) * normal_strength;
		slope_variance *= normal_strength * normal_strength;
		world_normal = normalize(vec3(-gradient.x, 1.0, -gradient.y));
	}
	world_normal = earth_curvature_tilt(world_normal, water_world_position.xz, CAMERA_POSITION_WORLD);
	NORMAL = (VIEW_MATRIX * vec4(world_normal, 0.0)).xyz;
	float foam_coverage = max(max(foam_factor, hull_edge_foam), interaction_foam);
	// Reveal the coverage as foam lace: white where the pattern exceeds 1 - coverage,
	// with a narrow edge. On the rest-position grid (UV), so the lace rides with the
	// water. Once the pattern's texels shrink below a pixel its mips flatten toward
	// 0.5 and the threshold no longer keeps the area; there plain coverage takes over.
	// Explicit LOD: this follows the hull discard.
	float detail_texels = max(length(uv_dx), length(uv_dy)) / foam_detail_tile_size * float(textureSize(foam_detail, 0).x);
	float detail_lod = log2(max(detail_texels, 1.0));
	float detail = textureLod(foam_detail, UV / foam_detail_tile_size, detail_lod).r;
	const float FOAM_EDGE = 0.12;
	float foam_threshold = (1.0 - foam_coverage) * (1.0 + FOAM_EDGE) - FOAM_EDGE;
	float revealed_foam = smoothstep(foam_threshold, foam_threshold + FOAM_EDGE, detail);
	// Thin foam (low coverage: old or barely formed) is translucent, dense foam opaque.
	float foam_opacity = mix(0.35, 1.0, foam_coverage);
	foam_factor = mix(revealed_foam, foam_coverage, saturate(detail_lod * 0.25)) * foam_opacity;

	vec3 drawn_position = water_world_position - vec3(0.0, earth_curvature_drop(water_world_position.xz, CAMERA_POSITION_WORLD), 0.0);
	vec3 view_direction_world = safe_normalize_vec3(CAMERA_POSITION_WORLD - drawn_position, vec3(0.0, 0.0, 1.0));
	vec3 sun_dir = safe_normalize_vec3(sky_sun_direction, vec3(0.0, 0.2, -1.0));
	vec3 reflection_direction = reflect(-view_direction_world, world_normal);
	// A ray reflected below the horizon hits the next wave and goes on upward;
	// mirroring it up stands in for that second bounce (the sky gradient's
	// ground colors are for looking down, not for reflections).
	reflection_direction.y = abs(reflection_direction.y);
	float clear_water_mask = 1.0 - foam_factor * 0.85;
	float no_v = saturate(dot(world_normal, view_direction_world));
	// GGX alpha (perceptual roughness squared) widened by the unresolved slope variance
	// (Toksvig / LEAN: alpha^2 += variance). clear_roughness is the micro-roughness of
	// ripples shorter than the smallest cascade.
	float base_alpha = clear_roughness * clear_roughness;
	effective_reflection_roughness = saturate(sqrt(sqrt(base_alpha * base_alpha + slope_variance)));

	// One Fresnel reflectance for everything the water reflects: the sky, and the
	// scene geometry of the planar reflection in front of it. Averaged over the
	// same slopes as the roughness: alpha^2 = 2 sigma^2 per axis.
	float slope_sigma = sqrt(base_alpha * base_alpha + slope_variance) * 0.70710678;
	float sky_fresnel = rough_fresnel(no_v, slope_sigma, sky_reflection_f0);
	// The water body's color is light that entered the water and scattered back
	// out: only the share the surface does not reflect leaves toward the eye
	// (water_body_albedo() holds it for a view from above). Foam lies on top, so it
	// is not dimmed.
	vec3 body_albedo = water_body_albedo() * (1.0 - sky_fresnel) / (1.0 - sky_reflection_f0);

	// The scene behind the surface, seen along the refracted view ray. The water
	// between attenuates it and adds its own color: the body's deep-water albedo
	// fills in what the transmittance takes away. Foam lies on top and hides it.
	vec3 water_transmittance = vec3(0.0);
	vec3 transmitted_radiance = vec3(0.0);
	float underwater_path = 0.0;
	vec2 refracted_uv = SCREEN_UV;
	float caustics = 1.0;
	vec3 up_view = (VIEW_MATRIX * vec4(0.0, 1.0, 0.0, 0.0)).xyz;
	vec4 straight_point = scene_view_position(SCREEN_UV, INV_PROJECTION_MATRIX);
	if (straight_point.w > 0.0) {
		float straight_below = max(dot(VERTEX - straight_point.xyz, up_view), 0.0);
		// Skip the search where even the straight-through scene's depth alone leaves no light.
		vec3 best_transmittance = underwater_transmittance(straight_below, straight_below);
		if (max(best_transmittance.r, max(best_transmittance.g, best_transmittance.b)) > 0.001) {
			vec3 refracted_direction = (VIEW_MATRIX * vec4(refract(-view_direction_world, world_normal, 1.0 / WATER_IOR), 0.0)).xyz;
			// Search as far as any light comes back from (transmittance 0.001 in the clearest channel).
			vec3 beam_attenuation = water_absorption + water_scattering + WATER_MOLECULAR_SCATTERING;
			float clearest = min(beam_attenuation.r, min(beam_attenuation.g, beam_attenuation.b));
			float max_distance = min(6.9 / clearest, REFRACTION_MAX_DISTANCE);
			vec2 found_uv = find_refracted_scene(VERTEX, refracted_direction, up_view, straight_below, max_distance, 1.0 / VIEWPORT_SIZE, PROJECTION_MATRIX, INV_PROJECTION_MATRIX);
			// Keep the read on the screen without folding: the offset may use at most half
			// the room toward the edge, so pixels nearing the edge squeeze what lies beyond
			// it rather than all reading the edge.
			vec2 offset = found_uv - SCREEN_UV;
			vec2 room = mix(SCREEN_UV, vec2(1.0) - SCREEN_UV, step(vec2(0.0), offset));
			refracted_uv = SCREEN_UV + sign(offset) * min(abs(offset), 0.5 * room);
			vec4 hit = scene_view_position(refracted_uv, INV_PROJECTION_MATRIX);
			if (hit.w == 0.0 || dot(hit.xyz - VERTEX, up_view) > 0.0) {
				// Sky, or scene above the water there: read straight through instead.
				refracted_uv = SCREEN_UV;
				hit = straight_point;
			}
			underwater_path = distance(hit.xyz, VERTEX);
			water_transmittance = underwater_transmittance(underwater_path, max(dot(VERTEX - hit.xyz, up_view), 0.0));
			// Blurred by the unresolved slopes: refraction turns a slope tilt t by about
			// t (1 - 1/n), spreading the rays over sqrt(2) sigma (1 - 1/n) radians.
			float spread = 1.41421356 * slope_sigma * (1.0 - 1.0 / WATER_IOR) * underwater_path;
			float meters_per_pixel = 2.0 * max(-hit.z, 0.001) / (PROJECTION_MATRIX[1][1] * VIEWPORT_SIZE.y);
			float refraction_lod = log2(max(2.0 * spread / meters_per_pixel, 1.0));
			vec3 hit_world = (INV_VIEW_MATRIX * vec4(hit.xyz, 1.0)).xyz;
			vec3 hit_normal = (INV_VIEW_MATRIX * vec4(textureLod(scene_normal_roughness, refracted_uv, 0.0).xyz * 2.0 - 1.0, 0.0)).xyz;
			caustics = caustic_light(hit_world, normalize(hit_normal), sun_dir, water_world_position, UV, meters_per_pixel);
			// Explicit LOD: this follows the hull discard.
			vec3 behind = textureLod(scene_color, refracted_uv, refraction_lod).rgb * caustics;
			transmitted_radiance = behind * water_transmittance * (1.0 - sky_fresnel) * (1.0 - foam_factor);
		}
	}
	body_albedo *= vec3(1.0) - water_transmittance;
	// Bubble cells (low pattern values) are a little darker than the lace between them.
	vec3 base_albedo = mix(body_albedo, foam_color.rgb * mix(0.75, 1.0, detail), foam_factor);
	sky_reflection_amount = saturate(sky_reflection_strength * sky_fresnel * clear_water_mask);
	if (sky_reflection_enabled) {
		// Seen from the bottom of the atmosphere; the camera's own path to the water is
		// hazed afterwards, with the rest of the scene (the sky source's aerial perspective).
		reflected_sky_color = sample_rough_procedural_environment(reflection_direction, effective_reflection_roughness);
	}
	vec3 reflected_color = reflected_sky_color;

	// The highlight itself is lit in light(); this copy (per unit of sun irradiance) is for the debug view.
	sun_specular_amount = water_specular_brdf(world_normal, view_direction_world, sun_dir, effective_reflection_roughness) * saturate(dot(world_normal, sun_dir));

	// Reflected scene geometry hides the sky behind it (alpha: geometry coverage).
	if (planar_reflection_enabled && planar_reflection_strength > 0.0) {
		// Find what this pixel's reflected ray (about its own wave normal) hits. The
		// mirrored camera sees every surface a ray from the water plane can reach,
		// and the capture stores each texel's surface distance. Start with the ray's
		// end at infinity; then repeatedly project the end, read the surface seen
		// there, and move the end to that surface's distance along the ray. A texel
		// with no geometry means the ray goes on to the sky.
		vec4 ray_end = vec4(reflection_direction, 0.0);
		float hit_distance = 0.0;
		vec3 reflection_uv = planar_reflection_project(ray_end);
		for (int i = 0; i < PLANAR_REFLECTION_STEPS && reflection_uv.z > 0.0; ++i) {
			// Explicit LOD: this follows the hull discard.
			float surface_distance = textureLod(planar_reflection_distance, reflection_uv.xy, 0.0).r;
			if (surface_distance <= 0.0)
				break;
			vec3 texel_ray = ray_end.w > 0.0 ? normalize(ray_end.xyz - planar_reflection_camera_position) : reflection_direction;
			vec3 surface = planar_reflection_camera_position + texel_ray * surface_distance;
			hit_distance = max(dot(surface - water_world_position, reflection_direction), 0.0);
			ray_end = vec4(water_world_position + reflection_direction * hit_distance, 1.0);
			reflection_uv = planar_reflection_project(ray_end);
		}
		// Blurred over the reflection lobe like the clouds (sample_clouds): the
		// reflected rays spread by about sqrt(2) alpha, which the mirrored camera sees
		// scaled by (distance from the water) / (distance from the mirrored camera).
		float lobe_scale = ray_end.w > 0.0 ? hit_distance / max(distance(ray_end.xyz, planar_reflection_camera_position), 0.001) : 1.0;
		float alpha = effective_reflection_roughness * effective_reflection_roughness;
		float reflection_lod = log2(max(alpha * 4.9 * lobe_scale / planar_reflection_texel_angle, 1.0));
		vec4 reflected_sample = textureLod(planar_reflection_texture, reflection_uv.xy, reflection_lod);
		float geometry_coverage = planar_reflection_strength * reflection_uv.z;
		reflected_color = reflected_color * (1.0 - geometry_coverage * reflected_sample.a) + reflected_sample.rgb * geometry_coverage;
	}
	vec3 reflection_radiance = reflected_color * sky_reflection_amount;

	if (water_debug_view > 0) {
		vec3 debug_color = vec3(0.0);
		// For the crest views: the sun's crest scattering, as light() computes it.
		float crest_path = 0.0;
		float crest_phase = 0.0;
		vec3 sun_crest = vec3(0.0);
		if (water_debug_view >= 4 && water_debug_view <= 6) {
			sun_crest = crest_scatter(world_normal, view_direction_world, sun_dir, UV, water_world_position.y, crest_path, crest_phase) * (1.0 - sky_fresnel);
		}
		if (water_debug_view == 1) {
			debug_color = vec3(sky_reflection_amount);
		} else if (water_debug_view == 2) {
			debug_color = reflected_sky_color;
		} else if (water_debug_view == 3) {
			debug_color = vec3(1.0) - exp(-vec3(sun_specular_amount)); // tonemapped
		} else if (water_debug_view == 4) {
			debug_color = vec3(crest_path / CREST_PATH_MAX); // light path through the water toward the sun
		} else if (water_debug_view == 5) {
			debug_color = vec3(crest_phase / (crest_phase + 1.0)); // scattering phase (1/sr), mapped to 0-1
		} else if (water_debug_view == 6) {
			debug_color = vec3(1.0) - exp(-sun_crest * 20.0); // crest scattering per unit sun irradiance, tonemapped
		} else if (water_debug_view == 7) {
			debug_color = water_body_albedo() * 20.0;
		} else if (water_debug_view == 8) {
			debug_color = vec3(reflection_direction.y * 0.5 + 0.5);
		} else if (water_debug_view == 9) {
			debug_color = vec3(effective_reflection_roughness);
		} else if (water_debug_view == 10) {
			debug_color = vec3(sqrt(slope_variance));
		} else if (water_debug_view == 11) {
			debug_color = vec3(foam_factor);
		} else if (water_debug_view == 12) {
			debug_color = water_transmittance; // to the scene behind the surface
		} else if (water_debug_view == 13) {
			debug_color = vec3(underwater_path / CREST_PATH_MAX); // refracted ray's path through the water
		} else if (water_debug_view == 15) {
			debug_color = vec3(caustics * 0.25); // caustic light factor on what lies below (1 = none)
		} else if (water_debug_view == 14) {
			debug_color = vec3(abs(refracted_uv - SCREEN_UV) * 20.0, 0.0); // refraction offset on screen
		}
		// Shown unlit, so the scene's lighting does not scale the values.
		ALBEDO = vec3(0.0);
		METALLIC = 0.0;
		ROUGHNESS = 1.0;
		SPECULAR = 0.0;
		EMISSION = debug_color / scene_exposure;
		FOG = vec4(0.0);
		light_specular_scale = 0.0;
		crest_transmission = 0.0;
		glitter_cells = vec4(0.0);
	} else {
		ALBEDO = base_albedo;
		METALLIC = 0.0;
		ROUGHNESS = mix(effective_reflection_roughness, foam_roughness, foam_factor);
		SPECULAR = 0.0; // No engine sky reflection: it is in EMISSION (see the header).
		EMISSION = (reflection_radiance + transmitted_radiance) / scene_exposure;
		// The camera's own path through the air (the sky's aerial perspective ran before
		// the transparent pass). In-scatter is stored pre-exposed; Godot does not expose FOG.
		FOG = aerial_perspective_enabled ? aerial_perspective_fog(drawn_position) : vec4(0.0);
		light_specular_scale = sun_specular_strength * clear_water_mask;
		crest_transmission = (1.0 - sky_fresnel) * (1.0 - foam_factor);

		// Glint cells on the rest-position grid (UV), so patterns ride with the water.
		// Cell sides are powers of two around the pixel footprint's size.
		float footprint_area = max(abs(uv_dx.x * uv_dy.y - uv_dx.y * uv_dy.x), 1e-8);
		float cell_level = 0.5 * log2(footprint_area);
		float fine_level = floor(cell_level);
		float fine_size = exp2(fine_level);
		ivec2 fine_cell = ivec2(floor(UV / fine_size));
		ivec2 coarse_cell = ivec2(floor(UV / (2.0 * fine_size)));
		float pattern_time = TIME * sun_glitter_rate;
		int pattern = int(floor(pattern_time));
		int level_key = int(fine_level) * 65536;
		glitter_random = vec4(
			hash_uniform(ivec3(fine_cell, level_key + pattern)),
			hash_uniform(ivec3(fine_cell, level_key + pattern + 1)),
			hash_uniform(ivec3(coarse_cell, level_key + 65536 + pattern)),
			hash_uniform(ivec3(coarse_cell, level_key + 65536 + pattern + 1)));
		float fine_facets = sun_glitter_density * fine_size * fine_size;
		glitter_cells = vec4(fine_facets, fine_facets * 4.0, cell_level - fine_level, fract(pattern_time));
	}
}

/*
 * Replaces Godot's per-light shading. LIGHT_COLOR includes PI, so these match the
 * engine's Lambert diffuse and specular conventions.
 */
void light() {
	float no_l = dot(NORMAL, LIGHT);
	// Water body: light refracted into the water and scattered back up. It depends
	// on how high the light is, not on the wave facet; Lambert on the facets made
	// the water look like shaded plastic.
	vec3 up = (VIEW_MATRIX * vec4(0.0, 1.0, 0.0, 0.0)).xyz;
	float body_light = max(dot(up, LIGHT), 0.0);
	// Foam: a layer of bubbles that scatters light through its volume, so facets
	// turned away from the light still get some (wrapped diffuse), and light from
	// behind shines through toward the viewer.
	float foam_light = max(no_l + FOAM_WRAP, 0.0) / (1.0 + FOAM_WRAP)
		+ FOAM_TRANSMISSION * pow(max(dot(-VIEW, LIGHT), 0.0), FOAM_TRANSMISSION_POWER);
	DIFFUSE_LIGHT += LIGHT_COLOR * ATTENUATION * mix(body_light, foam_light, foam_factor) / PI;
	// Light that crossed a wave crest and scatters toward the eye. Not scaled by albedo.
	if (crest_transmission > 0.0) {
		vec3 world_normal = (INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz;
		vec3 world_view = (INV_VIEW_MATRIX * vec4(VIEW, 0.0)).xyz;
		vec3 world_light = (INV_VIEW_MATRIX * vec4(LIGHT, 0.0)).xyz;
		float light_path;
		float phase;
		vec3 crest = crest_scatter(world_normal, world_view, world_light, UV, water_world_position.y, light_path, phase);
		SPECULAR_LIGHT += LIGHT_COLOR * ATTENUATION / PI * crest * crest_transmission;
	}
	if (no_l > 0.0) {
		float glitter = glitter_cells.x > 0.0 ? glitter_scale(NORMAL, VIEW, LIGHT, ROUGHNESS) : 1.0;
		SPECULAR_LIGHT += LIGHT_COLOR * ATTENUATION * (no_l / PI) * water_specular_brdf(NORMAL, VIEW, LIGHT, ROUGHNESS) * light_specular_scale * glitter;
	}
}
