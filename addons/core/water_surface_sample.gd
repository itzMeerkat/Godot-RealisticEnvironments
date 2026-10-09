class_name WaterSurfaceSample
extends RefCounted
## The rendered water surface at one queried point.

## The queried world position.
var position := Vector3.ZERO
## World-space Y of the rendered surface above/below position.
var height := 0.0
var normal := Vector3.UP
## Wave displacement of the surface point that lies over position.
var displacement := Vector3.ZERO
## Change of that displacement per second: the velocity of the water at the
## surface over position (the particle there moves with it).
var surface_velocity := Vector3.ZERO


## Linear extrapolation is only meaningful over a small fraction of a wave
## period, so longer gaps (e.g. after frame hitches) are capped at this.
const MAX_EXTRAPOLATION_SECONDS := 0.1

## Height predicted elapsed seconds after the query was dispatched (see
## WaterSurface.get_query_age()), to hide the readback latency. The prediction is
## capped at MAX_EXTRAPOLATION_SECONDS.
func extrapolated_height(elapsed : float) -> float:
	return height + height_rate() * minf(elapsed, MAX_EXTRAPOLATION_SECONDS)


## Rate of change (m/s) of the height over the fixed point position. The water
## there rises at surface_velocity.y but also flows sideways along the slope:
## dh/dt = w - u . grad h, with grad h = -normal.xz / normal.y.
func height_rate() -> float:
	return surface_velocity.y + (surface_velocity.x * normal.x + surface_velocity.z * normal.z) / normal.y
