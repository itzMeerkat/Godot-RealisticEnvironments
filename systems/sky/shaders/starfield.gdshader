shader_type spatial;
render_mode unshaded, cull_front, depth_draw_never, blend_add;

uniform float star_visibility : hint_range(0.0, 8.0) = 0.0;
uniform float star_brightness : hint_range(0.0, 8.0) = 1.0;
uniform float star_density : hint_range(16.0, 512.0) = 72.0;
uniform float star_twinkle_strength : hint_range(0.0, 1.0) = 0.12;
uniform float horizon_softness : hint_range(0.0, 0.5) = 0.08;
uniform float time = 0.0;

varying vec3 world_dir;

float hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

void vertex() {
	world_dir = normalize((MODEL_MATRIX * vec4(VERTEX, 0.0)).xyz);
}

void fragment() {
	vec3 dir = normalize(world_dir);
	vec3 abs_dir = abs(dir);
	vec2 projected_uv = dir.xz / max(abs_dir.y, 0.001);
	if (abs_dir.x > abs_dir.y && abs_dir.x > abs_dir.z) {
		projected_uv = dir.zy / max(abs_dir.x, 0.001);
	} else if (abs_dir.z > abs_dir.y) {
		projected_uv = dir.xy / max(abs_dir.z, 0.001);
	}
	projected_uv = projected_uv * 0.5 + 0.5;

	vec2 cell = floor(projected_uv * star_density);
	vec2 local_uv = fract(projected_uv * star_density) - 0.5;
	float seed = hash12(cell + floor(abs_dir * 7.0).xy * 113.7);
	float is_star = step(0.985, seed);
	float star_size = mix(0.012, 0.046, hash12(cell + 19.17));
	float star_shape = smoothstep(star_size, 0.0, length(local_uv));
	float twinkle = 1.0 + sin(time * mix(0.7, 2.1, seed) + seed * 31.0) * star_twinkle_strength;
	float horizon_fade = smoothstep(-horizon_softness, horizon_softness, dir.y);
	float intensity = is_star * star_shape * twinkle * horizon_fade * star_visibility * star_brightness;
	vec3 star_color = mix(vec3(0.62, 0.72, 1.0), vec3(1.0, 0.92, 0.72), hash12(cell + 7.31));
	ALBEDO = star_color * intensity;
	ALPHA = clamp(intensity, 0.0, 1.0);
}
