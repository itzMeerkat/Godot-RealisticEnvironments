shader_type spatial;
render_mode blend_mix, cull_disabled;
/*
 * Bow spray streaks (BowSpray): soft droplets tinted by the particles' colour, lit like
 * StandardMaterial3D. Transparent surfaces are drawn after the sky system's aerial
 * perspective, so the spray hazes itself for its own distance (atmosphere_fog()).
 */

#include "res://addons/sky_system/shaders/atmosphere.gdshaderinc"

// Radial droplet: white, alpha falling to 0 at the edge.
uniform sampler2D droplet : source_color, filter_linear_mipmap;
uniform float roughness : hint_range(0.0, 1.0) = 0.35;

void fragment() {
	vec4 droplet_sample = texture(droplet, UV);
	ALBEDO = COLOR.rgb * droplet_sample.rgb;
	ALPHA = COLOR.a * droplet_sample.a;
	ROUGHNESS = roughness;
	FOG = atmosphere_fog((INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz);
}
