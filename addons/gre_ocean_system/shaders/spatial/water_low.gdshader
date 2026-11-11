shader_type spatial;
render_mode world_vertex_coords, cull_disabled, depth_draw_always;
// No water where a GREWaterMask's lid is in view (GREWaterMask.STENCIL_REFERENCE).
stencil_mode read, compare_not_equal, 128;
// Water, quality Low: short searches, no caustics or planet glints (GREOceanSystem.shader_quality). The shader is water.gdshaderinc.
#define REFRACTION_MARCH_STEPS 8
#define REFRACTION_REFINE_STEPS 3
#define CREST_MARCH_STEPS 4
#define NORMAL_ANISOTROPY_TAPS 2
#define PLANAR_REFLECTION_STEPS 1
#define WATER_NO_CAUSTICS
#define WATER_NO_SKY_POINTS
#include "res://addons/gre_ocean_system/shaders/spatial/water.gdshaderinc"
