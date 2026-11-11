@tool
class_name GREWaveSpectrum extends Resource
## The sea state GREOceanSystem draws: one wind-driven JONSWAP/TMA spectrum, shared by
## every wave cascade. The cascades split it by wavelength (each draws its own band),
## so together they draw this one spectrum. Save one as a .tres to reuse a sea state.
##
## A change to the spectrum's inputs (or to the external wind) is generated into each
## cascade's inactive spectrum slot and crossfaded in over blend_duration, so the sea
## never jumps. displacement_scale applies at once.

@export_group("Wind")
## Wind speed in meters per second while GREOceanSystem has no wind_source_path.
## Higher values generate taller, steeper, more energetic waves.
@export_range(0.0, 60.0, 0.1, "or_greater", "suffix:m/s") var wind_speed := 6.0 :
	set(value): wind_speed = maxf(0.0001, value)
## Direction the wind blows toward while GREOceanSystem has no wind_source_path, in
## degrees: 0 along +Z, 90 along +X.
@export_range(-360.0, 360.0, 1.0, "degrees") var wind_direction := 20.0

@export_group("Spectrum")
## Distance the wind has blown over open water, in kilometers. Longer fetches give
## more developed, longer and more organized waves, up to the fully developed sea
## (about 175 km at 10 m/s, 700 km at 20 m/s), past which they stop growing. The
## largest cascade's tile should be at least 1.5 times the peak wavelength (GREOceanSystem
## warns otherwise).
@export_range(0.1, 1000.0, 0.1, "or_greater", "suffix:km") var fetch_length := 12.0 :
	set(value): fetch_length = maxf(0.0001, value)
## Mean water depth for the finite-depth (TMA) spectrum, in meters. Shallow water
## slows the waves and damps the long ones.
@export_range(0.1, 1000.0, 0.1, "or_greater", "suffix:m") var water_depth := 20.0 :
	set(value): water_depth = maxf(0.1, value)
## Swell: higher values make the waves longer-crested and more aligned with the wind.
@export_range(0.0, 2.0, 0.01) var swell := 0.55
## Directional spread: lower values align the waves with the wind, higher values
## spread their directions into a rougher, less organized sea.
@export_range(0.0, 1.0, 0.01) var spread := 0.35
## Short-wave detail: lower values damp the smallest ripples.
@export_range(0.0, 1.0, 0.01) var detail := 1.0
## Multiplies the waves' displacement (height and horizontal chop) everywhere: the
## drawn surface and its shading slopes and water queries. 1 is the height of the spectrum
## (JONSWAP). The cascades' whitecap thresholds include it: retune them together.
@export_range(0.0, 4.0, 0.01, "or_greater") var displacement_scale := 1.0

@export_group("Response")
## Turn each cascade's waves toward a new wind direction at a rate set by its tile
## length: long swell turns slowly, short chop follows the wind much faster. Off:
## every cascade turns at turn_rate.
@export var auto_turn_rate := true
## How fast the waves turn toward a new wind direction while auto_turn_rate is off,
## in degrees per second. Lower values keep the old travel direction longer.
@export_range(0.0, 180.0, 0.1, "or_greater", "suffix:°/s") var turn_rate := 5.0
## Wave direction change, in degrees, before a new spectrum is generated and
## crossfaded in. Lower values react sooner but regenerate spectra more often.
@export_range(0.0, 45.0, 0.1, "degrees") var direction_refresh_threshold := 2.0
## Wind speed change, in m/s, before a new spectrum is generated and crossfaded in.
## Smaller changes accumulate until they pass this threshold.
@export_range(0.0, 10.0, 0.01, "or_greater", "suffix:m/s") var speed_refresh_threshold := 0.25
## Seconds a newly generated spectrum takes to crossfade in. Longer blends hide
## changes but delay the full response.
@export_range(0.01, 60.0, 0.01, "or_greater", "suffix:s") var blend_duration := 4.0 :
	set(value):
		blend_duration = maxf(value, 0.01)
