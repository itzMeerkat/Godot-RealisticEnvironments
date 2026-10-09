class_name AtmosphereGlobals
extends RefCounted
## The global shader uniforms SkySystem's atmosphere publishes, read through
## shaders/atmosphere.gdshaderinc and declared in project.godot [shader_globals]
## (by the Sky System plugin, from DECLARATIONS). Change all three together.
##
## Kept apart from SkySystem so the plugin can read the list without loading the
## sky's shaders, which do not compile before the uniforms exist.

const ENABLED := &"atmosphere_enabled"
const VIEW_TEXTURES : Array[StringName] = [&"atmosphere_view_transmittance", &"atmosphere_view_inscatter", &"atmosphere_view_inscatter_lobe"]
const OBSERVER := &"atmosphere_observer"
const LIGHT := &"atmosphere_light"
const MAX_DISTANCE := &"atmosphere_max_distance"
const EXPOSURE := &"atmosphere_exposure"
## [name, project.godot type, default value] of every uniform above.
const DECLARATIONS := [
	[ENABLED, "bool", false],
	[&"atmosphere_view_transmittance", "sampler3D", null],
	[&"atmosphere_view_inscatter", "sampler3D", null],
	[&"atmosphere_view_inscatter_lobe", "sampler3D", null],
	[OBSERVER, "vec4", Vector4(0, 0, 0, 0)],
	[LIGHT, "vec4", Vector4(0, 1, 0, 0.97)],
	[MAX_DISTANCE, "float", 100000.0],
	[EXPOSURE, "float", 1.0],
]
