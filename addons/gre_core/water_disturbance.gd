class_name GREWaterDisturbance
extends RefCounted
## A hull in the water, as GREWaterSurface.submit_disturbance() takes it: the water draws
## the waves its motion relative to the water makes (wakes, bow waves, rings). Seen
## from above, the hull's footprint is a superellipse in its own frame
## (|u|^n + |v|^n <= 1), and its depth tapers smoothly to the footprint's edge.

## Centre of the footprint on the water (world space; y is ignored).
var position := Vector3.ZERO
## Direction of the hull's length on the water (world space, horizontal).
var forward := Vector3.FORWARD
## Half the footprint's length (along forward) and half its beam, in meters.
var half_extents := Vector2.ONE
## The footprint's shape: 2 is an oval, higher is boxier (a rectangle as it grows), 1 a
## diamond.
var shape_exponent := 2.0
## How deep (m) the hull reaches below the water surface around it; 0 out of the water.
var depth := 0.0
## Horizontal velocity (m/s, world space) of the surface water under the hull: the
## waves' own motion and the surface drift. A hull moving with the water makes no waves.
var water_velocity := Vector3.ZERO
## Scales the waves and foam the hull makes: 1 as its motion makes them, 0 none.
var wave_strength := 1.0
