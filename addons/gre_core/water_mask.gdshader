// GREWaterMask's lid (water_mask.gd): invisible, it marks the pixels where the lid is in
// view with GREWaterMask.STENCIL_REFERENCE, and the water does not draw there (its
// stencil_mode). Drawn in the transparent pass before the water (render priority
// below it), depth-tested so a hull's walls hide it, and only while the camera is
// above its plane: from below, an open boat shows its water rather than a hole in the
// sea beyond it. preview tints it in the editor.
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, shadows_disabled, fog_disabled;
stencil_mode write, compare_always, 128;

uniform bool preview = false;

void fragment() {
	vec3 up = normalize((MODEL_MATRIX * vec4(0.0, 1.0, 0.0, 0.0)).xyz);
	if (dot(CAMERA_POSITION_WORLD - NODE_POSITION_WORLD, up) < 0.0) {
		discard;
	}
	ALBEDO = vec3(0.2, 0.75, 1.0);
	ALPHA = preview ? 0.35 : 0.0;
}
