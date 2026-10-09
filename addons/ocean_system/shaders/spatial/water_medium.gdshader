shader_type spatial;
render_mode world_vertex_coords, cull_disabled, depth_draw_always;
// Water, quality Medium: shorter searches and marches (OceanSystem.shader_quality). The shader is water.gdshaderinc.
#define REFRACTION_MARCH_STEPS 16
#define REFRACTION_REFINE_STEPS 4
#define CREST_MARCH_STEPS 5
#define PLANAR_REFLECTION_STEPS 2
#include "res://addons/ocean_system/shaders/spatial/water.gdshaderinc"
