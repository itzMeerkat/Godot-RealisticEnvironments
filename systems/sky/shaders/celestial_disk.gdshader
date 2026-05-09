shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_add;

uniform vec4 body_color : source_color = vec4(1.0, 0.92, 0.72, 1.0);
uniform float visibility : hint_range(0.0, 1.0) = 1.0;
uniform float halo_strength : hint_range(0.0, 4.0) = 1.0;

void fragment() {
	vec2 centered_uv = UV * 2.0 - 1.0;
	float dist = length(centered_uv);
	float disk = smoothstep(0.52, 0.45, dist);
	float halo = smoothstep(1.0, 0.2, dist) * halo_strength * 0.35;
	float alpha = clamp((disk + halo) * visibility, 0.0, 1.0);
	ALBEDO = body_color.rgb * (disk + halo);
	ALPHA = alpha;
}
