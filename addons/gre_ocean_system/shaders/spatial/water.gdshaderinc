// The water shader's body, included by the quality variants (water.gdshader: High,
// water_medium.gdshader, water_low.gdshader; GREOceanSystem.shader_quality picks one).
// A variant may define, before including it:
//   REFRACTION_MARCH_STEPS, REFRACTION_REFINE_STEPS, CREST_MARCH_STEPS,
//   PLANAR_REFLECTION_STEPS: fewer steps for the searches and marches below;
//   NORMAL_ANISOTROPY_TAPS: fewer normal map reads along stretched pixel footprints;
//   WATER_NO_CAUSTICS, WATER_NO_SKY_POINTS: compile those features out.
// Every variant declares the same uniforms, so GREOceanSystem drives them alike.
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
 * Seen from below (a camera under the surface, the mesh's back faces), the surface is
 * Snell's window (underwater_view(), and the sun's transmission in light()).
 *
 * The water is drawn on the earth's curve (earth_curvature_drop()), so it ends at a real
 * horizon. Everything else about the surface (waves, queries, planar reflections)
 * stays flat: water_world_position is the flat position, and only the drawn vertex and
 * the shading normal follow the curve.
 */

#define MAX_CASCADES 8
#define MAX_LOD_LEVELS 16
// Radius (m) of the sphere the water is drawn on (GREOceanSystem.EARTH_RADIUS).
#define EARTH_RADIUS 6371000.0
// Light paths through wave crests (crest_light_path()): march steps 0.25 * 2^k m, and the
// length assumed when the march does not leave the water.
#ifndef CREST_MARCH_STEPS
#define CREST_MARCH_STEPS 7
#endif
#define CREST_PATH_MAX 32.0
// Most normal map reads per cascade along a pixel footprint's long axis (anisotropic
// filtering in the fragment shader); footprints stretched further are blurred across.
#ifndef NORMAL_ANISOTROPY_TAPS
#define NORMAL_ANISOTROPY_TAPS 8
#endif
// Foam lighting (light()): wrap of its diffuse term, and strength and sharpness of the
// light it lets through toward the viewer.
#define FOAM_WRAP 0.6
#define FOAM_TRANSMISSION 0.5
#define FOAM_TRANSMISSION_POWER 4.0
// Refinement steps of the planar reflection hit along a pixel's reflected ray.
#ifndef PLANAR_REFLECTION_STEPS
#define PLANAR_REFLECTION_STEPS 3
#endif
// Most reads along a reflection footprint's long axis (the clouds, the stars, the planar
// and screen-space reflections): seen at a low angle, a rough reflection spreads far more
// along the plane of incidence than across it (reflection_footprint()).
#ifndef REFLECTION_FOOTPRINT_TAPS
#define REFLECTION_FOOTPRINT_TAPS 4
#endif
// Refracted view ray's search for the opaque scene (find_refracted_scene()): march and
// bisection steps, how far (m) behind a surface the ray may end up and still pass through
// it, the nearest view depth (m) the ray is followed to, and the longest path (m) searched
// (light from farther is gone).
#ifndef REFRACTION_MARCH_STEPS
#define REFRACTION_MARCH_STEPS 32
#endif
// Screen-space reflections (find_reflected_scene()): march steps along the reflected ray,
// the longest path (m) searched, and the share of the screen's edge over which hits fade.
#ifndef SCREEN_REFLECTION_STEPS
#define SCREEN_REFLECTION_STEPS 24
#endif
#define SCREEN_REFLECTION_MAX_DISTANCE 400.0
#define SCREEN_REFLECTION_EDGE_FADE 0.1
#ifndef REFRACTION_REFINE_STEPS
#define REFRACTION_REFINE_STEPS 6
#endif
#define REFRACTION_THICKNESS 0.25
// Pixels between an object's silhouette and the scene that stands in for what it hides.
#define REFRACTION_SILHOUETTE_MARGIN 3.0
#define REFRACTION_NEAR 0.05
#define REFRACTION_MAX_DISTANCE 64.0

uniform vec4 foam_color : source_color;
// Optical properties of the water, per sRGB channel (1/m): absorption, and scattering by
// particles (sediment, plankton). Pure seawater absorbs about (0.30, 0.056, 0.012); dissolved
// organic matter and algae add to it, turning clear blue water greener and darker. Particles
// make it brighter and more turbid.
uniform vec3 water_absorption = vec3(0.45, 0.07, 0.03);
uniform vec3 water_scattering = vec3(0.03, 0.035, 0.04);
uniform float water_scattering_anisotropy : hint_range(0.0, 0.99) = 0.85; // Henyey-Greenstein g of particle scattering (ocean particles: about 0.9)

uniform float clear_roughness : hint_range(0.0, 1.0) = 0.10; // calm water's micro-roughness (perceptual)
// Slope variance of the short waves the wind raises, which the cascades do not draw
// (GREOceanSystem.short_wave_slope_scale): x along the wind, y across it. Cox and Munk found
// them steeper along the wind, so glints stretch along it.
uniform vec2 short_wave_slope_variance = vec2(0.0);
// Unit world (x, z) direction the wind blows toward.
uniform vec2 wind_direction = vec2(0.0, 1.0);
uniform float foam_roughness : hint_range(0.0, 1.0) = 0.24;
uniform float normal_scale : hint_range(0.0, 2.0) = 1.0; // multiplies every wave slope (GREOceanSystem.normal_scale; 1 = physical)
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
// Clouds from the sky source (GRESkySystem.get_cloud_cubemap()): rgb premultiplied
// radiance, a opacity, with a mip chain for rough reflections. Set at runtime by GREOceanSystem.
uniform bool sky_clouds_enabled = false;
uniform samplerCube sky_cloud_cubemap : filter_linear_mipmap;
// Stars from the sky source (get_star_cubemap()): rgb radiance (cd/m2) above the
// atmosphere with a mip chain, in the frame sky_star_basis turns world directions into;
// sky_star_radiance_scale turns it into scene radiance. Set at runtime by GREOceanSystem.
// Where the planar reflection covers the reflected ray it brings the stars itself (the
// mirrored camera draws the starfield sharp), so the cubemap fills in only the rest.
uniform bool sky_stars_enabled = false;
uniform samplerCube sky_star_cubemap : filter_linear_mipmap;
uniform mat3 sky_star_basis = mat3(1.0);
uniform float sky_star_radiance_scale = 0.0;
// Point lights of the night sky from the sky source (get_planet_directions(),
// get_planet_irradiance()): world directions and irradiance (rgb, scene units,
// unexposed) above the atmosphere. The water reflects them as glints, like the sun's
// highlight. Set at runtime by GREOceanSystem.
const int MAX_SKY_POINTS = 8;
uniform int sky_point_count = 0;
uniform vec3 sky_point_directions[MAX_SKY_POINTS];
uniform vec3 sky_point_irradiance[MAX_SKY_POINTS];
// The sky source's atmosphere seen from the sea (get_atmosphere_sky_volumes(): transmittance,
// in-scatter but the lobe, lobe in-scatter per unit phase, at the cloud base and at the ray's
// end; get_atmosphere_light(): xyz toward its light, w the lobe's g). With it the sky the
// water reflects is the atmosphere's, and the sky colours above are unused. Set at runtime
// by GREOceanSystem.
uniform bool sky_atmosphere_enabled = false;
uniform sampler3D sky_atmosphere_transmittance : filter_linear, repeat_disable;
uniform sampler3D sky_atmosphere_inscatter : filter_linear, repeat_disable;
uniform sampler3D sky_atmosphere_inscatter_lobe : filter_linear, repeat_disable;
uniform vec4 sky_atmosphere_light = vec4(0.0, 1.0, 0.0, 0.97);
// The sky source's atmosphere between the camera and the scene (get_atmosphere_view_volumes(),
// same three volumes for the observer aerial_observer: world position, w its altitude as the
// volumes use it; slices out to aerial_max_distance). The water is drawn after the sky's
// aerial perspective, so it hazes itself (FOG). Set at runtime by GREOceanSystem.
uniform bool aerial_perspective_enabled = false;
uniform sampler3D aerial_transmittance : filter_linear, repeat_disable;
uniform sampler3D aerial_inscatter : filter_linear, repeat_disable;
uniform sampler3D aerial_inscatter_lobe : filter_linear, repeat_disable;
uniform vec4 aerial_observer;
uniform float aerial_max_distance = 1.0;
uniform float sky_reflection_strength : hint_range(0.0, 2.0) = 1.0;
uniform float sky_reflection_f0 : hint_range(0.0, 0.12) = 0.02;
uniform float sun_specular_strength : hint_range(0.0, 4.0) = 1.0;
uniform int water_debug_view : hint_range(0, 18) = 0;
// The camera's exposure (CameraAttributes.exposure_multiplier, or the world's), set
// every frame by GREOceanSystem. The reflections are summed pre-exposed, as the sky source's
// clouds and atmosphere and the planar reflection are stored, and EMISSION (which Godot
// exposes itself) divides by it.
uniform float scene_exposure = 1.0;
// Irradiance on a level surface just above the water (scene units, unexposed), for the
// water's own light seen from below (underwater_path_light()). Set by GREOceanSystem.
uniform vec3 underwater_irradiance = vec3(3.14159);
// The rough sea's bubbles and stirred-up matter (1/m, GREOceanSystem.underwater_storm_churn).
uniform float underwater_churn = 0.0;
// Steps of the underwater light-shaft march (GREOceanSystem.shader_quality; 0: no shafts).
uniform int underwater_shaft_steps = 6;
uniform bool planar_reflection_enabled = false;
// Screen-space reflections (GREOceanSystem.reflection_mode): the reflected ray is marched
// against the opaque scene the camera already drew (scene_color, scene_depth).
uniform bool screen_space_reflections_enabled = false;
// Linear HDR, rgb premultiplied by geometry coverage (a), with a mip chain (GREPlanarReflectionCaptureEffect).
uniform sampler2D planar_reflection_texture : filter_linear_mipmap, repeat_disable;
// Distance (m) from the mirrored camera to the surface each texel shows, 0 = no geometry.
uniform sampler2D planar_reflection_distance : filter_nearest, repeat_disable;
uniform mat4 planar_reflection_view_projection;
uniform vec3 planar_reflection_camera_position; // the mirrored camera
uniform float planar_reflection_strength : hint_range(0.0, 1.0) = 0.0; // how much reflected geometry covers the sky behind it
// The opaque scene behind the water (linear HDR, exposed like EMISSION after scene_exposure).
uniform sampler2D scene_color : hint_screen_texture, filter_linear_mipmap, repeat_disable;
uniform sampler2D scene_depth : hint_depth_texture, filter_nearest, repeat_disable;
// The opaque scene's view-space normals (rgb * 2 - 1), for which way what lies below faces.
uniform sampler2D scene_normal_roughness : hint_normal_roughness_texture, filter_nearest, repeat_disable;
uniform bool use_bicubic_normals = true;
uniform int fragment_cascade_limit : hint_range(1, 8) = 3;
// CDLOD mesh (GREOceanLodGrid). Off for the editor's preview plane.
uniform bool lod_grid_enabled = false;
uniform float lod_ranges[MAX_LOD_LEVELS];       // beyond range(L), level-L vertices sit on the level L + 1 lattice
uniform float lod_morph_starts[MAX_LOD_LEVELS]; // level-L vertices morph between this and range(L)
uniform int lod_top_level = 0;

// Height of the still water (GREOceanSystem.water_level): the surface is drawn here, as
// queries and reflections see it.
uniform float water_level = 0.0;

group_uniforms cascade_data;
uniform vec4 map_scales[MAX_CASCADES];               // Packed: [uv scale xy (1 / tile length), displacement scale, unused]
uniform vec4 spectrum_blend_states[MAX_CASCADES];    // Packed: [active layer, pending layer, active weight, pending weight]; pending weight is 0 unless a spectrum crossfade is running
uniform int num_cascades = 0;
// Two maps of each kind, A and B, hold every cascade's two latest FFT frames in either order
// (GREWaveGenerator); wave_frame_blends[i].x is cascade i's weight of B for the current time.
// Displacement maps carry mip chains: coarse vertices read prefiltered waves.
uniform sampler2DArray displacements_a : filter_linear_mipmap, repeat_enable; // Each layer represents one wave cascade.
uniform sampler2DArray displacements_b : filter_linear_mipmap, repeat_enable;
// Normal maps: xy mean slope, z mean squared slope, w foam; full mip chain (mip_chain.glsl).
uniform sampler2DArray normals_a : hint_normal, filter_linear_mipmap, repeat_enable;
uniform sampler2DArray normals_b : hint_normal, filter_linear_mipmap, repeat_enable;
uniform vec4 wave_frame_blends[MAX_CASCADES]; // x: weight of map B (GREOceanSystem._get_cascade_frame_blend())
// The interactive waves (GREOceanInteraction): the waves hulls make, on a world-locked map
// around the camera that repeats every window (sampled with repeat wrapping):
// (height, slope x, slope z, squared slope) at rest positions, full mips.
uniform bool interaction_enabled = false;
uniform sampler2D interaction_map : filter_linear_mipmap_anisotropic, repeat_enable;
// The foam hulls churn up, on the same window: x = coverage, full mips; its foam lies
// interaction_foam_offset (m) past the cells (the drift within a cell), so it moves
// smoothly (GREOceanInteraction.get_foam_offset()).
uniform sampler2D interaction_foam_map : filter_linear_mipmap_anisotropic, repeat_enable;
uniform vec2 interaction_foam_offset = vec2(0.0);
uniform vec4 interaction_window = vec4(0.0, 0.0, 1.0, 1.0); // centre x, z, half size (m), 1 / size (1/m)

varying float foam_factor;
// Flat (uncurved) world position of the displaced surface.
varying vec3 water_world_position;
// Fragment -> light(): multiplies the specular highlight (foam covers it).
varying float light_specular_scale;
// Fragment -> light(): view-ray transmission for crest_scatter() (Fresnel, foam covers it).
varying float crest_transmission;
// Fragment -> light(): GGX alpha of the specular highlight along the wind (x) and across it (y).
varying vec2 specular_alpha;
// Fragment -> light(), for a surface seen from below (0 from above): rgb the transmittance
// of the water between it and the camera, a the share of the surface's light from above
// that reaches the camera through the surface (1 - Fresnel, foam covers it).
varying vec4 underwater_view_transmission;
// Fragment -> light(): 1 for a surface seen from below.
varying float seen_from_below;

#include "res://addons/gre_ocean_system/shaders/spatial/ocean_common.gdshaderinc"

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

/* The haze lobe's Henyey-Greenstein phase (1/sr) at cosine cos_theta from its light. */
float atmosphere_lobe_hg(float cos_theta) {
	float g = sky_atmosphere_light.w;
	float denominator = 1.0 + g * g - 2.0 * g * cos_theta;
	return (1.0 - g * g) / (4.0 * PI * denominator * sqrt(denominator));
}

/*
 * The haze lobe's phase toward direction (1/sr), capped at its value cap_angle (rad) from
 * the light. A rough reflection averages the sky over a lobe far wider than the haze's
 * peak, which a few samples cannot resolve (each would reflect its own copy of the glow
 * around a low sun, strips beside the real sun path); the capped phase is smooth at that
 * scale, and the peak above the cap is reflected like a light (atmosphere_lobe_core()).
 * cap_angle 0: the whole phase.
 */
float atmosphere_lobe_phase(vec3 direction, float cap_angle) {
	return atmosphere_lobe_hg(min(dot(direction, sky_atmosphere_light.xyz), cos(cap_angle)));
}

/*
 * The part of the haze lobe's phase integral (1 over the sphere) above its cap at cap_angle
 * (atmosphere_lobe_phase()): its integral within cap_angle of the light,
 * (1 - g^2) / 2g (1 / (1 - g) - 1 / sqrt(1 + g^2 - 2g cos)), less the cap's level over
 * that cone. In-scatter per unit phase times it is the irradiance the peak brings.
 */
float atmosphere_lobe_core(float cap_angle) {
	float g = sky_atmosphere_light.w;
	if (g <= 1e-4 || cap_angle <= 0.0) {
		return 0.0;
	}
	float cap_cos = cos(cap_angle);
	float inside = (1.0 - g * g) / (2.0 * g) * (1.0 / (1.0 - g) - inversesqrt(1.0 + g * g - 2.0 * g * cap_cos));
	// 1 - cos, without cancellation for small angles.
	float s = sin(0.5 * cap_angle);
	return max(inside - atmosphere_lobe_hg(cap_cos) * 4.0 * PI * s * s, 0.0);
}

/*
 * The sky source's sea-level view volume (two slices: 0 at the cloud base, 1 at the
 * ray's end) along an upward direction: transmittance and in-scatter from the sea to
 * there, the lobe's phase applied. The mapping is the sky system's
 * atmosphere_view_uvw() (shaders/compute/atmosphere_common.glslinc and
 * atmosphere.gdshaderinc) for an observer at altitude 0, whose horizon is level.
 * Change them together.
 */
void atmosphere_sea_volumes(vec3 direction, float slice, out vec3 transmittance, out vec3 inscatter, out vec3 lobe) {
	vec3 size = vec3(textureSize(sky_atmosphere_transmittance, 0));
	float x = atmosphere_light_azimuth_x(direction);
	// Zenith angle over the half-turn from the zenith to the level horizon, squeezed
	// toward the horizon; directions below it (none here: reflections point up) mirror it.
	float zenith = acos(clamp(direction.y, -1.0, 1.0)) / (0.5 * PI);
	float y = zenith < 1.0 ? 0.5 * (1.0 - sqrt(1.0 - zenith)) : 0.5 + 0.5 * sqrt(min(zenith - 1.0, 1.0));
	// On its own side of the horizon (the sky system's atmosphere_view_v()).
	y = y < 0.5 ? clamp(y, 0.5 / size.y, 0.5 - 0.5 / size.y) : clamp(y, 0.5 + 0.5 / size.y, 1.0 - 0.5 / size.y);
	vec3 uvw = vec3(0.5 / size.x + x * (1.0 - 1.0 / size.x), y, (slice + 0.5) / size.z);
	transmittance = textureLod(sky_atmosphere_transmittance, uvw, 0.0).rgb;
	inscatter = textureLod(sky_atmosphere_inscatter, uvw, 0.0).rgb;
	lobe = textureLod(sky_atmosphere_inscatter_lobe, uvw, 0.0).rgb;
}

/* atmosphere_sea_volumes() with the lobe's phase applied, capped at cap_angle (atmosphere_lobe_phase()). */
void atmosphere_sea_lookup(vec3 direction, float slice, float cap_angle, out vec3 transmittance, out vec3 inscatter) {
	vec3 lobe;
	atmosphere_sea_volumes(direction, slice, transmittance, inscatter, lobe);
	inscatter += lobe * atmosphere_lobe_phase(direction, cap_angle);
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
	y = y < 0.5 ? clamp(y, 0.5 / size.y, 0.5 - 0.5 / size.y) : clamp(y, 0.5 + 0.5 / size.y, 1.0 - 0.5 / size.y);
	vec3 uvw = vec3(0.5 / size.x + atmosphere_light_azimuth_x(direction) * (1.0 - 1.0 / size.x), y, (slice + 0.5) / size.z);
	vec3 transmittance = textureLod(aerial_transmittance, uvw, 0.0).rgb;
	vec3 inscatter = textureLod(aerial_inscatter, uvw, 0.0).rgb + textureLod(aerial_inscatter_lobe, uvw, 0.0).rgb * atmosphere_lobe_phase(direction, 0.0);
	float opacity = 1.0 - dot(transmittance, vec3(1.0 / 3.0));
	return opacity > 1e-5 ? vec4(inscatter / opacity, opacity) : vec4(0.0);
}

// Weight of the interactive waves at rest position xz: 1 inside their window, fading to
// 0 over its outer fifth (surface_query.glsl does the same for the camera's height).
float interaction_fade(vec2 xz) {
	vec2 offset = abs(xz - interaction_window.xy) / interaction_window.z;
	return 1.0 - smoothstep(0.8, 1.0, max(offset.x, offset.y));
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
		float camera_distance = distance(CAMERA_POSITION_WORLD, vec3(xz.x, water_level, xz.y));
		// Geomorphing: with distance, odd lattice vertices slide onto their even
		// neighbours, i.e. onto the next level's lattice, and on through coarser
		// levels. Positions then depend only on the world position, so nodes of
		// different levels meet without cracks. Nodes never reach more than two
		// levels beyond their own (GREOceanLodGrid.LOD_RANGE_FACTOR).
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
	// The sea's height is water_level, wherever the node is (GREOceanSystem warns when moved).
	VERTEX.y = water_level;
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
	// The interactive waves' height, prefiltered to the vertex spacing like the cascades.
	if (interaction_enabled) {
		float interaction_lod = log2(max(vertex_spacing * float(textureSize(interaction_map, 0).x) * interaction_window.w, 1.0));
		displacement.y += textureLod(interaction_map, UV * interaction_window.w, interaction_lod).x * interaction_fade(UV);
	}
	VERTEX += displacement;
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
 * One spectrum layer's (mean slope xy, unresolved slope variance, foam) over a pixel's
 * footprint, blended between its two FFT frames in maps A and B by b_weight. The footprint
 * (tile coordinates) is centered on uv and read as `taps` trilinear reads at mip lod spread
 * along its long axis `axis` (anisotropic filtering); explicit LOD. variance_weight scales the slope variance the reads average away.
 * bilinear_weight 1 skips the bicubic filter of a single read (8 extra reads), which only
 * helps under magnification.
 */
vec4 sample_normal_layer(vec2 uv, float layer, vec2 axis, int taps, float lod, float variance_weight, float bilinear_weight, float b_weight) {
	vec4 sample_a = vec4(0.0);
	vec4 sample_b = vec4(0.0);
	for (int t = 0; t < taps; ++t) {
		vec3 coords = vec3(uv + axis * ((float(t) + 0.5) / float(taps) - 0.5), layer);
		sample_a += textureLod(normals_a, coords, lod);
		sample_b += textureLod(normals_b, coords, lod);
	}
	sample_a /= float(taps);
	sample_b /= float(taps);
	if (taps == 1 && use_bicubic_normals && bilinear_weight < 1.0) {
		sample_a = mix(texture_bicubic(normals_a, vec3(uv, layer)), sample_a, bilinear_weight);
		sample_b = mix(texture_bicubic(normals_b, vec3(uv, layer)), sample_b, bilinear_weight);
	}
	// Slopes the reads averaged away: E|g|^2 - |E g|^2 (mip_chain.glsl), per frame, as
	// blending two frames' slopes is not roughness. Every channel averages linearly, so the
	// mean over the taps is the mean over the footprint and the spread between taps counts.
	float variance_a = max(sample_a.z - dot(sample_a.xy, sample_a.xy), 0.0);
	float variance_b = max(sample_b.z - dot(sample_b.xy, sample_b.xy), 0.0);
	vec4 blended = mix(sample_a, sample_b, b_weight);
	blended.z = mix(variance_a, variance_b, b_weight) * variance_weight;
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

/*
 * Unpolarized Fresnel reflectance for light arriving at cosine cos_i to the normal in a
 * medium of eta times the other side's index; 1 past the critical angle (total internal
 * reflection).
 */
float fresnel_dielectric(float cos_i, float eta) {
	float sin2_t = eta * eta * (1.0 - cos_i * cos_i);
	if (sin2_t >= 1.0) {
		return 1.0;
	}
	float cos_t = sqrt(1.0 - sin2_t);
	float rs = (eta * cos_i - cos_t) / (eta * cos_i + cos_t);
	float rp = (cos_i - eta * cos_t) / (cos_i + eta * cos_t);
	return 0.5 * (rs * rs + rp * rp);
}

/*
 * Share of a ray reflected below the horizon (direction_y < 0) that reflects again off the
 * next wave, taken as level: it meets it at a glancing angle, so most of it does; a ray
 * reflected steeply down mostly enters the water. 1 above the horizon.
 */
float second_bounce_reflectance(float direction_y) {
	return direction_y < 0.0 ? fresnel_dielectric(-direction_y, 1.0 / WATER_IOR) : 1.0;
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
 * Footprint of a rough reflection's lobe around a reflected direction, in radians:
 * x its length along the plane of incidence (the elevation, for the water), y across it.
 * Reflected directions spread with an angular deviation of about sigma = sqrt(2) alpha
 * (twice the normal's, slope deviation alpha / sqrt(2)) in the plane of incidence, but a
 * normal tilted across that plane turns the reflection by only twice the tilt times
 * no_v: seen at a low angle, reflections stretch into long vertical streaks. A box filter
 * as wide as sqrt(12) sigma (4.9 alpha) has the same deviation, so a mip of texels that
 * wide matches it.
 */
vec2 reflection_footprint(float roughness, float no_v) {
	float length_along = 4.9 * roughness * roughness;
	return vec2(length_along, length_along * max(no_v, 0.02));
}

/*
 * A cubemap's directions world_basis * d averaged over a reflection footprint around
 * direction (reflection_footprint(); along: unit vector of its long axis): reads spread
 * along the long axis, each at the mip of the wider of the short axis and the read
 * spacing (a texel at mip 0 is about 2 / face size radians). Directions below the horizon
 * are mirrored up, as the reflection is. Explicit LOD: called from divergent control flow.
 */
vec4 sample_cubemap_footprint(samplerCube cubemap, mat3 world_basis, vec3 direction, vec3 along, vec2 footprint) {
	float texel = 2.0 / float(textureSize(cubemap, 0).x);
	int taps = footprint.x > texel ? clamp(int(ceil(footprint.x / max(footprint.y, 1e-6) - 0.5)), 1, REFLECTION_FOOTPRINT_TAPS) : 1;
	float lod = log2(max(max(footprint.y, footprint.x / float(taps)) / texel, 1.0));
	vec4 sum = vec4(0.0);
	for (int t = 0; t < taps; ++t) {
		vec3 tap = normalize(direction + along * (footprint.x * ((float(t) + 0.5) / float(taps) - 0.5)));
		tap.y = abs(tap.y);
		sum += textureLod(cubemap, world_basis * tap, lod);
	}
	return sum / float(taps);
}

/*
 * The sky source's clouds seen in direction (rgb premultiplied radiance, a opacity),
 * averaged over a reflection footprint (sample_cubemap_footprint()); none without clouds.
 */
vec4 sample_clouds(vec3 direction, vec3 along, vec2 footprint) {
	if (!sky_clouds_enabled) {
		return vec4(0.0);
	}
	return sample_cubemap_footprint(sky_cloud_cubemap, mat3(1.0), direction, along, footprint);
}

/*
 * The sky source's stars seen in direction (pre-exposed radiance above the atmosphere),
 * averaged over a reflection footprint like the clouds; none below the horizon, by day
 * (too faint for the exposure to show) or without stars.
 */
vec3 sample_stars(vec3 direction, vec3 along, vec2 footprint) {
	float scale = sky_star_radiance_scale * scene_exposure;
	// The brightest star spread over a texel is well under 1 cd/m2.
	if (!sky_stars_enabled || scale < 1e-4 || direction.y <= 0.0) {
		return vec3(0.0);
	}
	return sample_cubemap_footprint(sky_star_cubemap, sky_star_basis, direction, along, footprint).rgb * scale;
}

/* Unit vector along the elevation at direction: the long axis of its reflection footprint. */
vec3 elevation_axis(vec3 direction) {
	return safe_normalize_vec3(vec3(0.0, 1.0, 0.0) - direction * direction.y, vec3(0.0, 0.0, 1.0));
}

/*
 * The cap of the haze lobe's phase for a reflection of this roughness: the reach of the
 * sky samples along the elevation (sample_rough_procedural_environment()), so the capped
 * phase is smooth between them; 0 for a mirror, which reads the whole phase.
 */
float reflection_lobe_cap(float roughness) {
	float sigma = 1.41421356 * roughness * roughness;
	return sigma < 0.005 ? 0.0 : 1.41421356 * sigma;
}

/*
 * The sky without clouds in direction, from the sky source's atmosphere when it has one
 * (sky: the in-scatter at the ray's end but the haze lobe; lobe: the lobe's per unit
 * phase), else from the gradient (no lobe).
 */
void sample_clear_sky(vec3 direction, out vec3 sky, out vec3 lobe) {
	lobe = vec3(0.0);
	if (sky_atmosphere_enabled) {
		vec3 transmittance;
		atmosphere_sea_volumes(direction, 1.0, transmittance, sky, lobe);
		return;
	}
	sky = sample_sky_gradient(direction) * scene_exposure;
}

/*
 * The sky reflected over a rough surface: the clear sky averaged over the reflection
 * lobe, whose directions spread with an angular deviation of about sigma = sqrt(2) alpha
 * along the elevation and no_v times that across it (reflection_footprint()), by the
 * 4-point Gaussian cubature (+-sqrt(2) deviations along each axis, weights 1/4: exact for
 * skies that vary up to cubically across the lobe). Directions below the horizon are
 * mirrored up, as the reflection is. The haze lobe's phase is capped at the cubature's
 * reach (reflection_lobe_cap()); fragment() reflects the peak above it like a light. The
 * clouds and the stars are prefiltered (cubemap mips) and read over the footprint;
 * star_weight scales the stars (the share the planar reflection does not bring). Samples
 * below the horizon reflect again off the next wave (second_bounce_reflectance()); what
 * enters the water there brings back body_radiance (water_body_radiance()).
 */
vec3 sample_rough_procedural_environment(vec3 direction, float roughness, float no_v, float star_weight, vec3 body_radiance) {
	float rough = saturate(roughness);
	float sigma = 1.41421356 * rough * rough;
	float lobe_cap = reflection_lobe_cap(rough);
	vec3 along = elevation_axis(direction);
	vec2 footprint = reflection_footprint(rough, no_v);
	vec3 sky = vec3(0.0);
	if (sigma < 0.005) {
		vec3 lobe;
		sample_clear_sky(direction, sky, lobe);
		sky += lobe * atmosphere_lobe_phase(direction, lobe_cap);
	} else {
		vec3 azimuth_axis = cross(direction, along);
		float offset_along = tan(min(1.41421356 * sigma, 1.2));
		float offset_across = tan(min(1.41421356 * sigma * max(no_v, 0.02), 1.2));
		for (int i = 0; i < 4; ++i) {
			vec3 offset = i < 2 ? along * offset_along : azimuth_axis * offset_across;
			vec3 sample_direction = normalize(direction + (i % 2 == 0 ? offset : -offset));
			float bounce = second_bounce_reflectance(sample_direction.y);
			sample_direction.y = abs(sample_direction.y);
			vec3 sample_sky;
			vec3 sample_lobe;
			sample_clear_sky(sample_direction, sample_sky, sample_lobe);
			vec3 sample_radiance = sample_sky + sample_lobe * atmosphere_lobe_phase(sample_direction, lobe_cap);
			sky += (bounce < 1.0 ? mix(body_radiance, sample_radiance, bounce) : sample_radiance) * 0.25;
		}
	}
	// The stars lie beyond the atmosphere, dimmed by it along the whole ray.
	vec3 stars = star_weight > 0.0 ? sample_stars(direction, along, footprint) * star_weight : vec3(0.0);
	if (sky_atmosphere_enabled && stars != vec3(0.0)) {
		vec3 transmittance_end;
		vec3 inscatter_end;
		atmosphere_sea_lookup(direction, 1.0, 0.0, transmittance_end, inscatter_end);
		stars *= transmittance_end;
	}
	sky += stars;
	vec3 cloud_direction = direction;
	vec4 cloud = sample_clouds(cloud_direction, along, footprint);
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
	atmosphere_sea_lookup(cloud_direction, 0.0, lobe_cap, transmittance_cloud, inscatter_cloud);
	return inscatter_cloud + transmittance_cloud * cloud.rgb + (1.0 - cloud.a) * (sky - inscatter_cloud);
}

/*
 * The peak of the haze's glow around the atmosphere's light above the cap of a reflection
 * of this roughness (atmosphere_lobe_core()), as a light: its irradiance on a surface
 * facing it (pre-exposed) and its direction, lifted onto the horizon while the light is
 * below it. The clouds toward the light hide what lies behind them; the air in front of
 * them still glows. None without an atmosphere.
 */
vec3 sky_glow_core(float roughness, out vec3 direction) {
	vec3 light = sky_atmosphere_light.xyz;
	direction = normalize(vec3(light.x, max(light.y, 0.0), light.z));
	float core = sky_atmosphere_enabled ? atmosphere_lobe_core(reflection_lobe_cap(saturate(roughness))) : 0.0;
	if (core <= 0.0) {
		return vec3(0.0);
	}
	vec3 transmittance;
	vec3 inscatter;
	vec3 lobe_end;
	vec3 lobe_cloud;
	atmosphere_sea_volumes(direction, 1.0, transmittance, inscatter, lobe_end);
	atmosphere_sea_volumes(direction, 0.0, transmittance, inscatter, lobe_cloud);
	float cloud = sky_clouds_enabled ? textureLod(sky_cloud_cubemap, direction, 0.0).a : 0.0;
	return mix(lobe_end, lobe_cloud, cloud) * core;
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

/*
 * Specular BRDF of the water surface with anisotropic GGX (Burley 2012) and height-
 * correlated Smith visibility, Schlick Fresnel with the water's f0, without N.L: alpha.x
 * along tangent (projected onto the surface), alpha.y across it.
 */
float water_specular_brdf_anisotropic(vec3 normal, vec3 view, vec3 light_direction, vec3 tangent, vec2 alpha) {
	vec3 t = safe_normalize_vec3(tangent - normal * dot(normal, tangent), safe_normalize_vec3(cross(normal, vec3(0.0, 0.0, 1.0)), vec3(1.0, 0.0, 0.0)));
	vec3 b = cross(normal, t);
	vec2 a = max(alpha, vec2(0.0009));
	vec3 half_vector = safe_normalize_vec3(view + light_direction, normal);
	float no_v = max(dot(normal, view), 0.0001);
	float no_l = saturate(dot(normal, light_direction));
	vec3 stretched = vec3(dot(t, half_vector) / a.x, dot(b, half_vector) / a.y, dot(normal, half_vector));
	float stretched_length2 = dot(stretched, stretched);
	float distribution = 1.0 / max(PI * a.x * a.y * stretched_length2 * stretched_length2, 0.00001);
	float lambda_v = no_l * length(vec3(a.x * dot(t, view), a.y * dot(b, view), no_v));
	float lambda_l = no_v * length(vec3(a.x * dot(t, light_direction), a.y * dot(b, light_direction), no_l));
	float visibility = 0.5 / max(lambda_v + lambda_l, 0.00001);
	float fresnel = fresnel_schlick(saturate(dot(view, half_vector)), sky_reflection_f0);
	return distribution * visibility * fresnel;
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

/*
 * Where the ray reflected at origin (view space) along direction meets the opaque scene
 * the camera drew: xy the screen point, z the coverage (0: no hit, the sky shows). The
 * march steps along the ray's image on the screen (depth interpolated perspective-
 * correctly, steps growing quadratically); a hit is where the ray goes behind a surface
 * by less than its own depth change over the step plus REFRACTION_THICKNESS (farther
 * behind, it passed behind an object). Hits fade near the screen's edge, and rays toward
 * the camera find what faces it only (the screen holds no back sides): they fade too.
 */
vec3 find_reflected_scene(vec3 origin, vec3 direction, mat4 projection, mat4 inv_projection) {
	vec3 end = origin + direction * SCREEN_REFLECTION_MAX_DISTANCE;
	if (end.z > -REFRACTION_NEAR) // Keep the end in front of the camera.
		end = origin + direction * ((-REFRACTION_NEAR - origin.z) / min(direction.z, -1e-4));
	vec2 start_uv = screen_project(origin, projection);
	vec2 delta = screen_project(end, projection) - start_uv;
	float start_k = 1.0 / -origin.z;
	float end_k = 1.0 / -end.z;
	float u_max = 1.0;
	for (int axis = 0; axis < 2; ++axis) {
		float end_uv = start_uv[axis] + delta[axis];
		if (end_uv < 0.0)
			u_max = min(u_max, -start_uv[axis] / delta[axis]);
		else if (end_uv > 1.0)
			u_max = min(u_max, (1.0 - start_uv[axis]) / delta[axis]);
	}
	float previous_depth = -origin.z;
	for (int i = 1; i <= SCREEN_REFLECTION_STEPS; ++i) {
		float step_fraction = float(i) / float(SCREEN_REFLECTION_STEPS);
		float u = u_max * step_fraction * step_fraction;
		vec2 uv = start_uv + delta * u;
		float ray_depth = 1.0 / mix(start_k, end_k, u);
		float scene = scene_view_depth(uv, inv_projection);
		if (scene > 0.0 && ray_depth >= scene) {
			if (ray_depth - scene <= abs(ray_depth - previous_depth) + REFRACTION_THICKNESS) {
				vec2 edge = min(uv, 1.0 - uv);
				float coverage = smoothstep(0.0, SCREEN_REFLECTION_EDGE_FADE, min(edge.x, edge.y));
				coverage *= smoothstep(0.6, 0.0, direction.z);
				return vec3(uv, coverage);
			}
			return vec3(0.0); // Behind an object: what it meets is hidden.
		}
		previous_depth = ray_depth;
	}
	return vec3(0.0);
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
	float focus = caustic_focus(entry_rest, path, k, max(SUN_ANGULAR_DIAMETER * path, pixel_size));
	return 1.0 + share * (focus - 1.0);
}


/*
 * Albedo of optically deep water (radiance = albedo * irradiance / PI), from its optical
 * properties: the remote-sensing reflectance just below the surface, rrs = 0.0949 u + 0.0794 u^2
 * with u = bb / (a + bb) (Gordon et al. 1988), above it Rrs = 0.52 rrs / (1 - 1.7 rrs) (Lee et
 * al. 1998, for a view from above, surface transmission included); the albedo is PI Rrs.
 */
vec3 water_body_albedo() {
	vec3 subsurface = water_subsurface_reflectance();
	return PI * 0.52 * subsurface / (1.0 - 1.7 * subsurface);
}

/*
 * The deep water's own light toward the sky (pre-exposed): its albedo under the clear sky's
 * light, about pi times the zenith's radiance. What a ray that enters the water at the
 * second bounce brings back.
 */
vec3 water_body_radiance() {
	vec3 zenith;
	vec3 lobe;
	sample_clear_sky(vec3(0.0, 1.0, 0.0), zenith, lobe);
	return water_body_albedo() * zenith;
}

/*
 * Microfacet transmission of the water surface (Walter et al. 2007, GGX), without N.L: light
 * from to_light above the surface (normal points up into the air) refracted toward to_view
 * below it, including the n^2 rise in radiance as the light enters the denser water.
 */
float water_transmission_btdf(vec3 normal, vec3 to_view, vec3 to_light, float roughness) {
	float i_n = dot(to_light, normal);
	float o_n = dot(to_view, normal);
	if (i_n <= 0.0 || o_n >= 0.0) {
		return 0.0;
	}
	vec3 half_vector = -normalize(to_light + WATER_IOR * to_view);
	if (dot(half_vector, normal) < 0.0) {
		half_vector = -half_vector;
	}
	float i_h = dot(to_light, half_vector);
	float o_h = dot(to_view, half_vector);
	if (i_h <= 0.0 || o_h >= 0.0) {
		return 0.0;
	}
	float denominator = i_h + WATER_IOR * o_h;
	float distribution = ggx_distribution(saturate(dot(normal, half_vector)), roughness);
	// smith_ggx_visibility() is G / (4 |i.n| |o.n|).
	float visibility = smith_ggx_visibility(-o_n, i_n, roughness);
	float transmission = 1.0 - fresnel_schlick(i_h, sky_reflection_f0);
	return i_h * -o_h * WATER_IOR * WATER_IOR * transmission * distribution * 4.0 * visibility / max(denominator * denominator, 1e-6);
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

/*
 * Glints of the sky's point lights (the planets): each one's irradiance through the
 * sea-level atmosphere and the clouds, reflected by the specular BRDF, pre-exposed.
 * Skipped while too faint for the exposure (by day).
 */
vec3 sky_point_glints(vec3 normal, vec3 view, vec2 alpha) {
	vec3 glints = vec3(0.0);
	for (int i = 0; i < min(sky_point_count, MAX_SKY_POINTS); ++i) {
		vec3 direction = sky_point_directions[i];
		vec3 irradiance = sky_point_irradiance[i] * scene_exposure;
		// The GGX peak at the smoothest roughness is ~3.5e5 per unit irradiance.
		if (direction.y <= 0.0 || max(irradiance.r, max(irradiance.g, irradiance.b)) < 1e-8) {
			continue;
		}
		if (sky_atmosphere_enabled) {
			vec3 transmittance;
			vec3 inscatter;
			atmosphere_sea_lookup(direction, 1.0, 0.0, transmittance, inscatter);
			irradiance *= transmittance;
		}
		irradiance *= 1.0 - sample_clouds(direction, vec3(0.0, 1.0, 0.0), vec2(0.0)).a;
		float no_l = saturate(dot(normal, direction));
		glints += irradiance * (water_specular_brdf_anisotropic(normal, view, direction, vec3(wind_direction.x, 0.0, wind_direction.y), alpha) * no_l);
	}
	return glints;
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

/*
 * Reads of a 2D image over a footprint whose long axis is major_texels long and whose
 * short width is minor_texels (mip-0 texels): x the number of reads spread along the long
 * axis, y the mip each is read at (the wider of the short width and the read spacing).
 * Read t lies at ((t + 0.5) / x - 0.5) of the long axis from the centre.
 */
vec2 image_footprint_reads(float major_texels, float minor_texels) {
	int taps = major_texels > 1.0 ? clamp(int(ceil(major_texels / max(minor_texels, 1e-6) - 0.5)), 1, REFLECTION_FOOTPRINT_TAPS) : 1;
	return vec2(float(taps), log2(max(max(minor_texels, major_texels / float(taps)), 1.0)));
}

void fragment() {
	// Screen-space derivatives of the world XZ position, taken before any discard:
	// the pixel footprint for normal map and foam pattern filtering.
	vec2 uv_dx = dFdx(UV);
	vec2 uv_dy = dFdy(UV);
	// The pixel footprint on the water (m): grazing views stretch it along the view
	// direction, many times longer than wide. The normal maps are read with taps along
	// its long axis, each at the mip of the wider of its short axis and the tap
	// spacing, so slopes are averaged over the footprint's real shape and what they
	// average away becomes roughness. An isotropic mip of the footprint's area leaves
	// the long axis under-filtered (waves alias into crawling, squeezed bands); one of
	// its long axis blurs the short axis too (milky water).
	float dx_length = length(uv_dx);
	float dy_length = length(uv_dy);
	vec2 footprint_axis = dx_length > dy_length ? uv_dx : uv_dy;
	float footprint_major = max(dx_length, dy_length);
	float footprint_minor = min(dx_length, dy_length);
	int footprint_taps = clamp(int(ceil(footprint_major / max(footprint_minor, 1e-6) - 0.5)), 1, NORMAL_ANISOTROPY_TAPS);
	float footprint_width = max(footprint_minor, footprint_major / float(footprint_taps));

	vec2 gradient = vec2(0.0);
	float foam_signal = 0.0;
	// Total variance of the slopes inside the pixel footprint, over all cascades.
	float slope_variance = 0.0;
	foam_factor = 0.0;
	vec3 world_normal = vec3(0.0, 1.0, 0.0);
	// The interactive waves over the pixel footprint (height, slopes, squared slope), and
	// the foam hulls churned up there.
	vec4 interaction = vec4(0.0);
	float interaction_foam = 0.0;
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
			float texels_per_meter = map_size * max(scales.x, scales.y);
			// A single read (round footprint) of a coarse tile (under 10 texels per meter)
			// mixes in the bicubic filter under magnification; where the footprint covers
			// two or more texels it adds nothing.
			float bilinear_weight = footprint_taps > 1 ? 1.0 : max(min(1.0, texels_per_meter * 0.1), smoothstep(1.0, 2.0, footprint_major * texels_per_meter));
			float lod = log2(max(footprint_width * texels_per_meter, 1.0));
			// Interpolating texels with different slopes also raises the variance, but while
			// the footprint is shorter than a texel that spread is drawn (the interpolated
			// slope varies across pixels), not missed: count it from one texel up.
			float variance_weight = min(log2(max(footprint_major * texels_per_meter, 1.0)), 1.0);
			vec2 tile_uv = UV * scales.xy;
			vec2 tile_axis = footprint_axis * scales.xy;
			float b_weight = wave_frame_blends[i].x;
			vec4 active_sample = sample_normal_layer(tile_uv, blend_state.x, tile_axis, footprint_taps, lod, variance_weight, bilinear_weight, b_weight);
			vec2 cascade_gradient = active_sample.xy * blend_state.z;
			float cascade_variance = active_sample.z * blend_state.z * blend_state.z;
			float cascade_foam = active_sample.w;
			// Uniform branch: the pending spectrum is only sampled during a crossfade.
			if (blend_state.w > 0.0) {
				vec4 pending_sample = sample_normal_layer(tile_uv, blend_state.y, tile_axis, footprint_taps, lod, variance_weight, bilinear_weight, b_weight);
				cascade_gradient += pending_sample.xy * blend_state.w;
				// The two spectra are independent, so their variances add with squared weights.
				cascade_variance += pending_sample.z * blend_state.w * blend_state.w;
				// Foam is a non-negative mask, so it crossfades linearly rather than by equal power.
				cascade_foam = mix(active_sample.w, pending_sample.w, blend_state.w / (blend_state.z + blend_state.w));
			}
			gradient += cascade_gradient;
			slope_variance += cascade_variance;
			foam_signal += cascade_foam;
		}

	}
	if (interaction_enabled) {
		// Filtered over the pixel footprint (anisotropic), so the mean slope and the
		// slope variance it hides come out as for the cascades.
		float scale = interaction_window.w;
		interaction = textureGrad(interaction_map, UV * scale, uv_dx * scale, uv_dy * scale);
		float fade = interaction_fade(UV);
		gradient += interaction.yz * fade;
		slope_variance += max(interaction.w - dot(interaction.yz, interaction.yz), 0.0) * fade;
		interaction *= fade;
		interaction_foam = textureGrad(interaction_foam_map, (UV - interaction_foam_offset) * scale, uv_dx * scale, uv_dy * scale).x * fade;
		foam_signal += interaction_foam;
	}
	// Foam is coverage (fft_unpack.glsl, interaction_foam.glsl), so its mips hold the
	// covered share of each texel: right at every distance, with no fade.
	foam_factor = saturate(foam_signal * foam_intensity);
	if (num_cascades > 0 || interaction_enabled) {
		gradient *= normal_scale;
		slope_variance *= normal_scale * normal_scale;
		world_normal = normalize(vec3(-gradient.x, 1.0, -gradient.y));
	}
	world_normal = earth_curvature_tilt(world_normal, water_world_position.xz, CAMERA_POSITION_WORLD);
	NORMAL = (VIEW_MATRIX * vec4(world_normal, 0.0)).xyz;
	float foam_coverage = foam_factor;
	// Reveal the coverage as foam lace: white where the pattern exceeds 1 - coverage,
	// with a narrow edge. On the rest-position grid (UV), so the lace rides with the
	// water. Once the pattern's texels shrink below a pixel its mips flatten toward
	// 0.5 and the threshold no longer keeps the area; there plain coverage takes over.
	float detail_texels = footprint_major / foam_detail_tile_size * float(textureSize(foam_detail, 0).x);
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
	// The camera is under the surface (the mesh's back face): Snell's window, underwater_view.
	bool from_below = !FRONT_FACING;
	vec3 reflection_direction = reflect(-view_direction_world, world_normal);
	// A ray reflected below the horizon meets the next wave and reflects again, mirrored
	// up (second_bounce_reflectance()); the rest enters the water.
	float second_bounce = second_bounce_reflectance(reflection_direction.y);
	reflection_direction.y = abs(reflection_direction.y);
	float clear_water_mask = 1.0 - foam_factor * 0.85;
	float no_v = saturate(dot(world_normal, view_direction_world));
	// GGX alpha (perceptual roughness squared) widened by the unresolved slope variance
	// (Toksvig / LEAN: alpha^2 += variance, the variance of both axes together).
	// clear_roughness is the micro-roughness of calm water, shared by both axes; the
	// wind's short waves add their own variance along and across it. The highlight is
	// anisotropic (specular_alpha: alpha^2 = 2 sigma^2 per axis); the reflections use the
	// total.
	float base_alpha = clear_roughness * clear_roughness;
	float shared_variance = 0.5 * (base_alpha * base_alpha + slope_variance);
	vec2 axis_variance = vec2(shared_variance) + short_wave_slope_variance;
	float total_variance = axis_variance.x + axis_variance.y;
	effective_reflection_roughness = saturate(sqrt(sqrt(total_variance)));
	vec2 clear_alpha = sqrt(2.0 * axis_variance);
	vec3 wind_tangent = vec3(wind_direction.x, 0.0, wind_direction.y);

	// One Fresnel reflectance for everything the water reflects: the sky, and the
	// scene geometry of the planar reflection in front of it. Averaged over the
	// same slopes as the roughness: alpha^2 = 2 sigma^2 per axis.
	float slope_sigma = sqrt(total_variance) * 0.70710678;
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
	if (straight_point.w > 0.0 && !from_below) {
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
#ifndef WATER_NO_CAUSTICS
			caustics = caustic_light(hit_world, normalize(hit_normal), sun_dir, water_world_position, UV, meters_per_pixel);
#endif
					vec3 behind = textureLod(scene_color, refracted_uv, refraction_lod).rgb * caustics;
			transmitted_radiance = behind * water_transmittance * (1.0 - sky_fresnel) * (1.0 - foam_factor);
		}
	}
	body_albedo *= vec3(1.0) - water_transmittance;
	// Bubble cells (low pattern values) are a little darker than the lace between them.
	vec3 base_albedo = mix(body_albedo, foam_color.rgb * mix(0.75, 1.0, detail), foam_factor);
	sky_reflection_amount = saturate(sky_reflection_strength * sky_fresnel * clear_water_mask);
	// The highlight itself is lit in light(); this copy (per unit of sun irradiance) is for the debug view.
	sun_specular_amount = water_specular_brdf_anisotropic(world_normal, view_direction_world, sun_dir, wind_tangent, clear_alpha) * saturate(dot(world_normal, sun_dir));

	// The planar (or screen-space) reflection: rgb premultiplied by geometry coverage (a),
	// and the share of the reflection it covers (0 off screen of the mirrored camera, where
	// the screen-space ray finds nothing, or when disabled).
	vec4 planar_sample = vec4(0.0);
	float planar_coverage = 0.0;
	if (!from_below && planar_reflection_enabled && planar_reflection_strength > 0.0) {
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
					float surface_distance = textureLod(planar_reflection_distance, reflection_uv.xy, 0.0).r;
			if (surface_distance <= 0.0)
				break;
			vec3 texel_ray = ray_end.w > 0.0 ? normalize(ray_end.xyz - planar_reflection_camera_position) : reflection_direction;
			vec3 surface = planar_reflection_camera_position + texel_ray * surface_distance;
			hit_distance = max(dot(surface - water_world_position, reflection_direction), 0.0);
			ray_end = vec4(water_world_position + reflection_direction * hit_distance, 1.0);
			reflection_uv = planar_reflection_project(ray_end);
		}
		// Averaged over the reflection's footprint (reflection_footprint()), as the
		// mirrored camera sees it: where rays turned along and across the plane of
		// incidence by a small angle meet the same distance.
		const float FOOTPRINT_PROBE = 0.01;
		vec3 along = elevation_axis(reflection_direction);
		vec3 across = cross(reflection_direction, along);
		vec4 probe_along = ray_end.w > 0.0 ? vec4(water_world_position + normalize(reflection_direction + along * FOOTPRINT_PROBE) * hit_distance, 1.0) : vec4(normalize(reflection_direction + along * FOOTPRINT_PROBE), 0.0);
		vec4 probe_across = ray_end.w > 0.0 ? vec4(water_world_position + normalize(reflection_direction + across * FOOTPRINT_PROBE) * hit_distance, 1.0) : vec4(normalize(reflection_direction + across * FOOTPRINT_PROBE), 0.0);
		vec2 footprint = reflection_footprint(effective_reflection_roughness, no_v);
		vec2 major_uv = (planar_reflection_project(probe_along).xy - reflection_uv.xy) / FOOTPRINT_PROBE * footprint.x;
		float minor_texels = length((planar_reflection_project(probe_across).xy - reflection_uv.xy) / FOOTPRINT_PROBE * footprint.y * vec2(textureSize(planar_reflection_texture, 0)));
		vec2 reads = image_footprint_reads(length(major_uv * vec2(textureSize(planar_reflection_texture, 0))), minor_texels);
		for (int t = 0; t < int(reads.x); ++t) {
					planar_sample += textureLod(planar_reflection_texture, reflection_uv.xy + major_uv * ((float(t) + 0.5) / reads.x - 0.5), reads.y);
		}
		planar_sample /= reads.x;
		planar_coverage = planar_reflection_strength * reflection_uv.z;
	} else if (!from_below && screen_space_reflections_enabled) {
		vec3 reflection_view = (VIEW_MATRIX * vec4(reflection_direction, 0.0)).xyz;
		vec3 hit = find_reflected_scene(VERTEX, reflection_view, PROJECTION_MATRIX, INV_PROJECTION_MATRIX);
		if (hit.z > 0.0) {
			// Averaged over the reflection's footprint like the planar reflection: rays
			// turned along and across the plane of incidence, at the hit's distance.
			const float FOOTPRINT_PROBE = 0.01;
			vec4 hit_position = scene_view_position(hit.xy, INV_PROJECTION_MATRIX);
			float hit_distance = distance(hit_position.xyz, VERTEX);
			vec3 along = (VIEW_MATRIX * vec4(elevation_axis(reflection_direction), 0.0)).xyz;
			vec3 across = cross(reflection_view, along);
			vec2 footprint = reflection_footprint(effective_reflection_roughness, no_v);
			vec2 major_uv = (screen_project(VERTEX + normalize(reflection_view + along * FOOTPRINT_PROBE) * hit_distance, PROJECTION_MATRIX) - hit.xy) / FOOTPRINT_PROBE * footprint.x;
			float minor_texels = length((screen_project(VERTEX + normalize(reflection_view + across * FOOTPRINT_PROBE) * hit_distance, PROJECTION_MATRIX) - hit.xy) / FOOTPRINT_PROBE * footprint.y * VIEWPORT_SIZE);
			vec2 reads = image_footprint_reads(length(major_uv * VIEWPORT_SIZE), minor_texels);
			vec3 reflected_scene = vec3(0.0);
			for (int t = 0; t < int(reads.x); ++t) {
							reflected_scene += textureLod(scene_color, hit.xy + major_uv * ((float(t) + 0.5) / reads.x - 0.5), reads.y).rgb;
			}
			// Opaque: coverage is the hit's.
			planar_sample = vec4(reflected_scene / reads.x, 1.0);
			planar_coverage = hit.z;
		}
	}
	// Seen from the bottom of the atmosphere; the camera's own path to the water is
	// hazed afterwards, with the rest of the scene (the sky source's aerial perspective).
	vec3 body_radiance = water_body_radiance();
	reflected_sky_color = sample_rough_procedural_environment(reflection_direction, effective_reflection_roughness, no_v, 1.0 - planar_coverage, body_radiance);
	// Reflected scene geometry hides the sky behind it (alpha: geometry coverage).
	float sky_visible = 1.0 - planar_coverage * planar_sample.a;
	vec3 reflected_color = reflected_sky_color * sky_visible + planar_sample.rgb * planar_coverage;
	if (second_bounce < 1.0) {
		reflected_color = mix(body_radiance, reflected_color, second_bounce);
	}
	vec3 reflection_radiance = reflected_color * sky_reflection_amount;
	// The peak of the haze's glow, reflected like a light (sky_glow_core()): the specular
	// BRDF gives its reflection the shape the sun's own has.
	vec3 glow_direction;
	vec3 glow_irradiance = sky_glow_core(effective_reflection_roughness, glow_direction);
	if (glow_irradiance != vec3(0.0)) {
		float glow_no_l = saturate(dot(world_normal, glow_direction));
		reflection_radiance += glow_irradiance * (water_specular_brdf_anisotropic(world_normal, view_direction_world, glow_direction, wind_tangent, clear_alpha) * glow_no_l
				* sky_reflection_strength * clear_water_mask * sky_visible);
	}

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
		} else if (water_debug_view == 16) {
			debug_color = vec3(max(interaction.x, 0.0), max(-interaction.x, 0.0), 0.0) * 4.0; // interactive waves' height: red up, green down, full at 0.25 m
		} else if (water_debug_view == 17) {
			debug_color = vec3(abs(interaction.yz) * 4.0, 0.0); // interactive waves' slopes along x (red) and z (green)
		} else if (water_debug_view == 18) {
			debug_color = vec3(interaction_foam); // the foam hulls churned up (coverage)
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
		specular_alpha = vec2(1.0);
		underwater_view_transmission = vec4(0.0);
		seen_from_below = 0.0;
	} else if (from_below) {
		// Snell's window: the sky's light crosses the surface within the critical angle
		// (48.6 degrees) of the normal, squeezed from the whole sky into that cone, so its
		// radiance rises by n^2; past it the surface reflects the water below totally.
		// The water between the camera and the surface dims all of it and scatters its
		// own light toward the camera, and the total reflection shows the water's light
		// looking down from the surface (underwater_path_light(), as the underwater view).
		vec3 toward_surface = -view_direction_world;
		float inside_fresnel = fresnel_dielectric(saturate(dot(toward_surface, world_normal)), WATER_IOR);
		vec3 sky_through = vec3(0.0);
		if (inside_fresnel < 1.0) {
			vec3 to_sky = normalize(refract(toward_surface, -world_normal, WATER_IOR));
			sky_through = sample_rough_procedural_environment(vec3(to_sky.x, abs(to_sky.y), to_sky.z), effective_reflection_roughness, 1.0, 1.0, water_body_radiance());
			// What stands above the water in the window (a hull, a mast): the refracted ray
			// marched against the opaque scene on screen, like the screen-space reflections.
			// The screen holds it as drawn in air, before the underwater view dimmed it.
			vec3 hit = find_reflected_scene(VERTEX, (VIEW_MATRIX * vec4(to_sky, 0.0)).xyz, PROJECTION_MATRIX, INV_PROJECTION_MATRIX);
			if (hit.z > 0.0) {
							sky_through = mix(sky_through, textureLod(scene_color, hit.xy, 0.0).rgb, hit.z);
			}
			sky_through *= WATER_IOR * WATER_IOR;
		}
		float path = distance(CAMERA_POSITION_WORLD, drawn_position);
		vec3 path_transmittance = exp(-underwater_attenuation() * path);
		float through = (1.0 - inside_fresnel) * (1.0 - foam_factor);
		vec3 sun = normalize(sky_sun_direction);
		vec3 inscatter = underwater_path_light(toward_surface, max(water_level - CAMERA_POSITION_WORLD.y, 0.0), path, underwater_irradiance, sun, sky_sun_visibility)
				+ underwater_shafts(CAMERA_POSITION_WORLD, toward_surface, path, underwater_irradiance, sun, sky_sun_visibility,
					2.0 / (abs(PROJECTION_MATRIX[1][1]) * VIEWPORT_SIZE.y), interleaved_gradient_noise(FRAGCOORD.xy));
		vec3 reflected_water = underwater_path_light(reflect(toward_surface, -world_normal), 0.0, 1.0e6, underwater_irradiance, sun, sky_sun_visibility);
		vec3 water_light = (inside_fresnel * (1.0 - foam_factor) * reflected_water * path_transmittance + inscatter) * scene_exposure;
		ALBEDO = foam_color.rgb * mix(0.75, 1.0, detail) * foam_factor * path_transmittance;
		METALLIC = 0.0;
		ROUGHNESS = mix(effective_reflection_roughness, foam_roughness, foam_factor);
		SPECULAR = 0.0;
		EMISSION = (sky_through * through * path_transmittance + water_light) / scene_exposure;
		// Underwater the air's haze does not apply.
		FOG = vec4(0.0);
		light_specular_scale = 0.0;
		crest_transmission = 0.0;
		specular_alpha = clear_alpha;
		underwater_view_transmission = vec4(path_transmittance, through * sun_specular_strength);
		seen_from_below = 1.0;
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
		specular_alpha = mix(clear_alpha, vec2(foam_roughness * foam_roughness), foam_factor);
		underwater_view_transmission = vec4(0.0);
		seen_from_below = 0.0;
#ifndef WATER_NO_SKY_POINTS
		if (sky_point_count > 0) {
			EMISSION += sky_point_glints(world_normal, view_direction_world, clear_alpha) * light_specular_scale / scene_exposure;
		}
#endif
	}
}

/*
 * Replaces Godot's per-light shading. LIGHT_COLOR includes PI, so these match the
 * engine's Lambert diffuse and specular conventions.
 */
void light() {
	float no_l = dot(NORMAL, LIGHT);
	vec3 up = (VIEW_MATRIX * vec4(0.0, 1.0, 0.0, 0.0)).xyz;
	if (seen_from_below > 0.5) {
		// Seen from below (fragment()): foam lit through from above, and the light seen
		// through the surface, dimmed by the water between (its own light is EMISSION).
		float foam_light = max(no_l + FOAM_WRAP, 0.0) / (1.0 + FOAM_WRAP)
			+ FOAM_TRANSMISSION * pow(max(dot(-VIEW, LIGHT), 0.0), FOAM_TRANSMISSION_POWER);
		DIFFUSE_LIGHT += LIGHT_COLOR * ATTENUATION * foam_light / PI;
		if (no_l > 0.0) {
			SPECULAR_LIGHT += LIGHT_COLOR * ATTENUATION * (no_l / PI) * water_transmission_btdf(NORMAL, VIEW, LIGHT, ROUGHNESS)
					* underwater_view_transmission.rgb * underwater_view_transmission.a;
		}
	} else {
		// Water body: light refracted into the water and scattered back up. It depends
		// on how high the light is, not on the wave facet; Lambert on the facets made
		// the water look like shaded plastic.
		// Only the share the surface lets in (exact Fresnel at the light's height; the
		// body's albedo holds a high light's).
		float light_height = max(dot(up, LIGHT), 0.0);
		float body_light = light_height * (1.0 - fresnel_dielectric(light_height, 1.0 / WATER_IOR)) / (1.0 - sky_reflection_f0);
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
			vec3 tangent = (VIEW_MATRIX * vec4(wind_direction.x, 0.0, wind_direction.y, 0.0)).xyz;
			SPECULAR_LIGHT += LIGHT_COLOR * ATTENUATION * (no_l / PI) * water_specular_brdf_anisotropic(NORMAL, VIEW, LIGHT, tangent, specular_alpha) * light_specular_scale;
		}
	}
}
