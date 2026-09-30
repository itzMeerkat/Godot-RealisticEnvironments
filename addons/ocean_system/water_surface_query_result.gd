class_name WaterSurfaceQueryResult
extends RefCounted
## Latest completed surface query for one owner. samples[i] answers points[i].

## Points exactly as submitted for the dispatch that produced this result.
var points := PackedVector3Array()
var samples : Array[WaterSurfaceSample] = []
## OceanSystem.time when the query was dispatched. Results arrive a few frames
## later; use (ocean.time - dispatch_time) with WaterSurfaceSample.extrapolated_height().
var dispatch_time := 0.0
