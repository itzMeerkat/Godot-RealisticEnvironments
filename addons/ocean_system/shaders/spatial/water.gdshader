shader_type spatial;
render_mode world_vertex_coords, cull_disabled, depth_draw_always;
// Water, quality High: every feature, full step counts (OceanSystem.shader_quality). The shader is water.gdshaderinc.
#include "res://addons/ocean_system/shaders/spatial/water.gdshaderinc"
