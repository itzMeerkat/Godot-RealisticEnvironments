shader_type spatial;
render_mode unshaded, cull_front, depth_draw_never, blend_add;

uniform float star_visibility : hint_range(0.0, 8.0) = 0.0;
uniform float star_brightness : hint_range(0.0, 8.0) = 1.0;
uniform float star_density : hint_range(16.0, 512.0) = 170.0;
uniform float star_twinkle_strength : hint_range(0.0, 1.0) = 0.12;
uniform float time = 0.0;

float hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

void fragment() {
	vec2 cell = floor(UV * star_density);
	vec2 local_uv = fract(UV * star_density) - 0.5;
	float seed = hash12(cell);
	float is_star = step(0.988, seed);
	float star_size = mix(0.018, 0.055, hash12(cell + 19.17));
	float star_shape = smoothstep(star_size, 0.0, length(local_uv));
	float twinkle = 1.0 + sin(time * mix(0.7, 2.1, seed) + seed * 31.0) * star_twinkle_strength;
	float intensity = is_star * star_shape * twinkle * star_visibility * star_brightness;
	vec3 star_color = mix(vec3(0.62, 0.72, 1.0), vec3(1.0, 0.92, 0.72), hash12(cell + 7.31));
	ALBEDO = star_color * intensity;
	ALPHA = clamp(intensity, 0.0, 1.0);
}
