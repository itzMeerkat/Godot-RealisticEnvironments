class_name WaterSurfaceSample
extends RefCounted
## Rendered ocean surface at one queried point.

## The queried world position.
var position := Vector3.ZERO
## World-space Y of the rendered surface above/below position.
var height := 0.0
var normal := Vector3.UP
## Wave displacement of the surface point that lies over position.
var displacement := Vector3.ZERO
## Change of that displacement per second.
var surface_velocity := Vector3.ZERO


## Linear extrapolation is only meaningful over a small fraction of a wave
## period, so longer gaps (e.g. after frame hitches) are capped at this.
const MAX_EXTRAPOLATION_SECONDS := 0.1

## Height predicted elapsed seconds after the query was dispatched, to hide
## the readback latency. The prediction is capped at MAX_EXTRAPOLATION_SECONDS.
func extrapolated_height(elapsed : float) -> float:
	return height + surface_velocity.y * minf(elapsed, MAX_EXTRAPOLATION_SECONDS)
