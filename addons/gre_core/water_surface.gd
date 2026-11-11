@abstract
class_name GREWaterSurface
extends RefCounted
## The contract between a water simulation (GREOceanSystem) and what samples its
## surface. Consumers depend on this class only, never on the simulation's own types.
##
## A simulation registers its surface for the World3D it renders in; consumers
## look it up with [method find]. One surface per world.
##
## Queries are asynchronous: submit points every physics tick, read the latest
## completed result (null until the first one arrives, a few frames later) and
## extrapolate its heights by [method get_query_age]. Release the owner when it
## stops querying (e.g. in _exit_tree).
##
## Hulls report themselves with [method submit_disturbance] every physics tick, and
## the water draws the waves they make. Query results leave those waves out unless the
## owner opts in with [method set_query_wave_response].

## World3D instance id -> GREWaterSurface.
static var _surfaces := {}


## Makes surface the one find() returns for nodes in world.
static func register(world : World3D, surface : GREWaterSurface) -> void:
	var id := world.get_instance_id()
	if _surfaces.has(id) and _surfaces[id] != surface:
		push_error("A GREWaterSurface is already registered for this World3D; only one per world is supported.")
		return
	_surfaces[id] = surface


## Removes surface as world's water surface (only if it is the registered one). Call from
## the simulation's _exit_tree.
static func unregister(world : World3D, surface : GREWaterSurface) -> void:
	var id := world.get_instance_id()
	if _surfaces.get(id) == surface:
		_surfaces.erase(id)


## The surface of the world node is in, or null when there is none (or node is
## not inside the tree).
static func find(node : Node) -> GREWaterSurface:
	if not node.is_inside_tree():
		return null
	var world := node.get_viewport().find_world_3d()
	return _surfaces.get(world.get_instance_id()) if world != null else null


## Queues points for the next query dispatch; the latest submission per owner
## wins.
@abstract func submit_query(query_owner : Object, points : PackedVector3Array) -> void

## The latest completed query for query_owner, or null before the first one.
## Its points may differ from the most recent submission.
@abstract func get_query_result(query_owner : Object) -> GREWaterSurfaceQueryResult

## Seconds from result's dispatch to the caller's moment (in a physics tick: the
## moment of the bodies' state at its start), for
## GREWaterSurfaceSample.extrapolated_height().
@abstract func get_query_age(result : GREWaterSurfaceQueryResult) -> float

## How deep point is under the surface (negative above it), for what only needs one
## point: submits it for query_owner and reads the latest result, extrapolated to
## now. NAN until the first result arrives. Call it every physics tick while it
## matters, and release_query() the owner after.
func point_depth(query_owner : Object, point : Vector3) -> float:
	submit_query(query_owner, PackedVector3Array([point]))
	var result := get_query_result(query_owner)
	if result == null or result.samples.is_empty():
		return NAN
	return result.samples[0].extrapolated_height(get_query_age(result)) - point.y

## Forgets query_owner's submissions and results.
@abstract func release_query(query_owner : Object) -> void

## How much of the waves hulls make (submit_disturbance()) query_owner's results include:
## 0 none (the default), 1 all, in height, slope and rate. While query_owner also reports
## a hull, the waves inside its footprint are taken from around it, so the hull feels its
## bow wave, its wake and other hulls' waves but not the water it displaces itself.
## Water without such waves ignores it. Kept until release_query().
@abstract func set_query_wave_response(query_owner : Object, response : float) -> void

## The surface's clock, in the units of GREWaterSurfaceQueryResult.dispatch_time:
## a result dispatched at or before a moment read here predates it.
@abstract func get_clock() -> float

## Mean horizontal velocity (m/s, world space, y = 0) of the surface water on top of
## the waves' own motion: the wind and wave drift that carries foam and floating
## things downwind. Zero for still water.
@abstract func get_surface_drift() -> Vector3

## Reports disturbance_owner's hull for this physics tick; the latest report per owner
## wins. The water draws the waves the hull's motion relative to the water makes. The
## values are copied, so one GREWaterDisturbance can be reused every tick. Water without
## interactive waves ignores it.
@abstract func submit_disturbance(disturbance_owner : Object, disturbance : GREWaterDisturbance) -> void

## Forgets disturbance_owner's hull. Call from the owner's _exit_tree.
@abstract func release_disturbance(disturbance_owner : Object) -> void
