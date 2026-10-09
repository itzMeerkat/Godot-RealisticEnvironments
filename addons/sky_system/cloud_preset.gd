@tool
class_name CloudPreset
extends Resource
## One weather state (clear, overcast, storm, sea fog, ...) for SkySystem: the
## clouds and the haze over the sea.
## SkySystem crossfades between presets by interpolating every field, so all of
## them must stay plain numbers.

## Fields interpolated by blend(). Add new fields here.
const BLENDED_PROPERTIES : Array[StringName] = [
	&"coverage", &"coverage_variation", &"weather_scale",
	&"cloud_type", &"type_variation", &"base_altitude", &"thickness",
	&"shape_scale", &"detail_scale", &"detail_erosion",
	&"density", &"density_variation", &"scattering_albedo",
	&"evolution_speed", &"sun_light_scale",
	&"haze_visibility", &"haze_scale_height", &"haze_anisotropy",
	&"star_scintillation",
]
## Blended fields interpolated geometrically: haze_visibility, so that the haze
## thickens evenly through a transition from clear air to fog.
const GEOMETRIC_BLENDED_PROPERTIES : Array[StringName] = [&"haze_visibility"]

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
## Share of light the cloud scatters instead of absorbing. Cloud droplets absorb
## almost no visible light (1); light scatters dozens to hundreds of times inside a
## cloud, so lower values darken thick clouds strongly (a stylistic choice). Thick
## clouds are dark underneath because of their depth, not their albedo.
@export_range(0.1, 1.0, 0.001) var scattering_albedo := 1.0

@export_group("Motion")
## How fast clouds form, dissipate and change shape, on top of drifting with
## the wind. In noise units per second.
@export_range(0.0, 0.05, 0.0001) var evolution_speed := 0.004

@export_group("Scene Lighting")
## Multiplies the sun light reaching the scene under this cloud cover.
@export_range(0.0, 1.0, 0.01) var sun_light_scale := 1.0

@export_group("Haze")
## Visibility at sea level in meters: how far a dark object stays visible (2 %
## contrast; the haze's extinction there is 3.912 / visibility). Clear marine air
## 50-70 km, haze 5-20 km, mist 1-5 km, fog below 1 km. It also sets how bright
## the glow around the sun is.
@export_range(100.0, 100000.0, 10.0, "or_greater", "exp") var haze_visibility := 50000.0
## Height (m) over which the haze thins to 1/e: about 1 km for the haze of the
## marine boundary layer, 100-200 m for sea fog.
@export_range(10.0, 5000.0, 1.0, "or_greater") var haze_scale_height := 1000.0
## How sharply the haze scatters light forward: Henyey-Greenstein g of the
## forward lobe that holds 75 % of its scattering (the rest is isotropic), so the
## mean g is 0.75 times this; about 0.97 for marine haze (coarse sea salt), 0.98
## for fog droplets. Higher makes the glow around the sun smaller.
@export_range(0.0, 0.99, 0.01) var haze_anisotropy := 0.97

@export_group("Stars")
## How much the stars twinkle (the air's turbulence): the spread of the log of a
## star's brightness at the zenith. It grows toward the horizon with the air
## mass to the power 1.5, where stars also flash in colour. About 0.1 in calm air,
## 0.3 in turbulent air (a strong jet stream, a cold front passing).
@export_range(0.0, 1.0, 0.01) var star_scintillation := 0.15


## Sets every blended field to the interpolation between two presets.
func blend(from : CloudPreset, to : CloudPreset, weight : float) -> void:
	for property in BLENDED_PROPERTIES:
		var from_value : float = from.get(property)
		var to_value : float = to.get(property)
		if property in GEOMETRIC_BLENDED_PROPERTIES:
			set(property, exp(lerpf(log(from_value), log(to_value), weight)))
		else:
			set(property, lerpf(from_value, to_value, weight))
