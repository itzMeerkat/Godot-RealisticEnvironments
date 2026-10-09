shader_type spatial;
render_mode world_vertex_coords, cull_disabled, depth_draw_always;
// Water, quality Low: short searches, no caustics, glitter or planet glints (OceanSystem.shader_quality). The shader is water.gdshaderinc.
#define REFRACTION_MARCH_STEPS 8
#define REFRACTION_REFINE_STEPS 3
#define CREST_MARCH_STEPS 4
#define PLANAR_REFLECTION_STEPS 1
#define WATER_NO_CAUSTICS
#define WATER_NO_GLITTER
#define WATER_NO_SKY_POINTS
#include "res://addons/ocean_system/shaders/spatial/water.gdshaderinc"
