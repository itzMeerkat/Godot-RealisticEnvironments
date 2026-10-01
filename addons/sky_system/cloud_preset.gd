@tool
class_name CloudPreset
extends Resource
## One cloud weather state (clear, overcast, storm, ...) for SkySystem.
## SkySystem crossfades between presets by interpolating every field, so all of
## them must stay plain numbers.

## Fields interpolated by blend(). Add new fields here.
const BLENDED_PROPERTIES : Array[StringName] = [
	&"coverage", &"coverage_variation", &"weather_scale",
	&"cloud_type", &"type_variation", &"base_altitude", &"thickness",
	&"shape_scale", &"detail_scale", &"detail_erosion",
	&"density", &"density_variation", &"scattering_albedo",
	&"evolution_speed", &"sun_light_scale", &"ambient_light_scale",
]

@export_group("Coverage")
## Average share of the sky covered by cloud. 1 is overcast.
@export_range(0.0, 1.0, 0.01) var coverage := 0.4
## How much coverage varies between weather regions. 0 is uniform; higher
## values leave clear gaps between cloud fields.
@export_range(0.0, 1.0, 0.01) var coverage_variation := 0.3
## Size of a weather region in metres.
@export_range(1000.0, 100000.0, 100.0, "or_greater") var weather_scale := 20000.0

@export_group("Shape")
## 0 is flat stratus, 0.5 cumulus, 1 towering cumulonimbus. Taller types fill
## more of the layer thickness.
@export_range(0.0, 1.0, 0.01) var cloud_type := 0.5
## How much the cloud type varies between weather regions.
@export_range(0.0, 1.0, 0.01) var type_variation := 0.15
## Altitude of the cloud base in metres.
@export_range(100.0, 8000.0, 10.0, "or_greater") var base_altitude := 1500.0
## Thickness of the cloud layer in metres.
@export_range(100.0, 12000.0, 10.0, "or_greater") var thickness := 3000.0
## World size of one tile of the noise that forms cloud bodies, in metres.
## Larger values make larger clouds.
@export_range(1000.0, 50000.0, 100.0, "or_greater") var shape_scale := 9000.0
## World size of one tile of the noise that erodes cloud edges, in metres.
@export_range(100.0, 10000.0, 10.0, "or_greater") var detail_scale := 1500.0
## How strongly the detail noise erodes edges into wisps.
@export_range(0.0, 1.0, 0.01) var detail_erosion := 0.35

@export_group("Optics")
## Extinction multiplier. Higher values make clouds more opaque.
@export_range(0.0, 8.0, 0.01) var density := 1.0
## How much density varies between weather regions.
@export_range(0.0, 1.0, 0.01) var density_variation := 0.2
## Share of light the cloud scatters instead of absorbing. Lower values give
## the dark bases of rain clouds.
@export_range(0.1, 1.0, 0.01) var scattering_albedo := 0.95

@export_group("Motion")
## How fast clouds form, dissipate and change shape, on top of drifting with
## the wind. In noise units per second.
@export_range(0.0, 0.05, 0.0001) var evolution_speed := 0.004

@export_group("Scene Lighting")
## Multiplies the sun light reaching the scene under this cloud cover.
@export_range(0.0, 1.0, 0.01) var sun_light_scale := 1.0
## Multiplies the environment ambient light under this cloud cover.
@export_range(0.0, 2.0, 0.01) var ambient_light_scale := 1.0


## Sets every blended field to the interpolation between two presets.
func blend(from : CloudPreset, to : CloudPreset, weight : float) -> void:
	for property in BLENDED_PROPERTIES:
		set(property, lerpf(from.get(property), to.get(property), weight))
