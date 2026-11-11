shader_type spatial;
render_mode unshaded, depth_test_disabled, depth_draw_never, cull_disabled, shadows_disabled, fog_disabled;
/*
 * The view from a camera under the water (GREOceanSystem shows it while the camera is below
 * the waves): a full-screen pass drawn before the water's surface. Everything the camera
 * sees lies behind water: the opaque scene is dimmed by the water between (beam
 * attenuation a + b) and the water adds its own light along the way. The surface itself,
 * drawn afterwards, shades its own path (water.gdshaderinc, seen from below).
 *
 * The water's light: the light at the surface (underwater_irradiance), dimmed with depth
 * by the downwelling attenuation K_d, scattered toward the camera. Its diffuse part makes
 * the deep water's radiance (water_subsurface_reflectance(): rrs looking down, brighter
 * looking up, where the path climbs toward the light); the sun's direct part scatters
 * once with the particles' forward lobe (the glow around the sun's refracted direction)
 * and is focused and spread by the waves above (caustic_focus()): the light shafts.
 */

#define MAX_CASCADES 8

// Set by GREOceanSystem with the water material's names and values.
uniform vec3 water_absorption = vec3(0.45, 0.07, 0.03);
uniform vec3 water_scattering = vec3(0.03, 0.035, 0.04);
uniform float water_scattering_anisotropy = 0.85;
uniform float normal_scale = 1.0;
uniform int fragment_cascade_limit = 3;
uniform float water_level = 0.0;
uniform float scene_exposure = 1.0;
uniform vec3 sky_sun_direction = vec3(0.0, 0.2, -1.0);
uniform float sky_sun_visibility = 1.0;
uniform vec4 map_scales[MAX_CASCADES];
uniform vec4 spectrum_blend_states[MAX_CASCADES];
uniform int num_cascades = 0;
uniform sampler2DArray normals_a : hint_normal, filter_linear_mipmap, repeat_enable;
uniform sampler2DArray normals_b : hint_normal, filter_linear_mipmap, repeat_enable;
uniform vec4 wave_frame_blends[MAX_CASCADES];
// Irradiance on a level surface just above the water (scene units, unexposed): the sky
// source's light meter, or GREOceanSystem's stand-in without one.
uniform vec3 underwater_irradiance = vec3(3.14159);
// The rough sea's bubbles and stirred-up matter (1/m, GREOceanSystem.underwater_storm_churn).
uniform float underwater_churn = 0.0;
// Steps of the light-shaft march (GREOceanSystem.shader_quality; 0: no shafts).
uniform int underwater_shaft_steps = 6;

uniform sampler2D screen_texture : hint_screen_texture, filter_nearest, repeat_disable;
uniform sampler2D depth_texture : hint_depth_texture, filter_nearest, repeat_disable;

#include "res://addons/gre_ocean_system/shaders/spatial/ocean_common.gdshaderinc"

void vertex() {
	// A quad over the whole screen (QuadMesh of size 2), whatever the transform.
	POSITION = vec4(VERTEX.xy, 1.0, 1.0);
}

void fragment() {
	vec2 ndc = SCREEN_UV * 2.0 - 1.0;
	float depth = textureLod(depth_texture, SCREEN_UV, 0.0).r;
	vec4 near = INV_PROJECTION_MATRIX * vec4(ndc, 1.0, 1.0);
	vec3 view_direction = normalize(near.xyz / near.w);
	vec3 direction = normalize((INV_VIEW_MATRIX * vec4(view_direction, 0.0)).xyz);
	// The scene's distance; where nothing was drawn the water goes on.
	float scene_distance = 1.0e6;
	if (depth > 0.0) {
		vec4 point = INV_PROJECTION_MATRIX * vec4(ndc, depth, 1.0);
		scene_distance = length(point.xyz / point.w);
	}
	float camera_depth = max(water_level - CAMERA_POSITION_WORLD.y, 0.0);
	// Rays climbing to the surface leave the water there (the surface covers the rest).
	float path = direction.y > 1e-4 ? min(scene_distance, camera_depth / direction.y) : scene_distance;

	vec3 attenuation = underwater_attenuation();
	vec3 transmittance = exp(-attenuation * path);
	vec3 to_sun = normalize(sky_sun_direction);
	vec3 inscatter = underwater_path_light(direction, camera_depth, path, underwater_irradiance, to_sun, sky_sun_visibility);

	// Light shafts: the waves above focus the sun's light unevenly. Rays that climb to the
	// surface are drawn over by it (its own pass adds their shafts).
	if (direction.y <= 0.0 || path < camera_depth / max(direction.y, 1e-4))
		inscatter += underwater_shafts(CAMERA_POSITION_WORLD, direction, path, underwater_irradiance, to_sun, sky_sun_visibility,
			2.0 / (abs(PROJECTION_MATRIX[1][1]) * VIEWPORT_SIZE.y), interleaved_gradient_noise(FRAGCOORD.xy));

	// Unshaded ALBEDO is not exposed by Godot: the scene behind is (it was lit exposed).
	vec3 scene = textureLod(screen_texture, SCREEN_UV, 0.0).rgb;
	ALBEDO = scene * transmittance + inscatter * scene_exposure;
}
