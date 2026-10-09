@abstract
class_name WaterSurface
extends RefCounted
## The contract between a water simulation (OceanSystem) and what floats on it or
## disturbs it (buoyancy, spray, splashes). Consumers depend on this class only,
## never on the simulation's own types.
##
## A simulation registers its surface for the World3D it renders in; consumers
## look it up with [method find]. One surface per world.
##
## Queries are asynchronous: submit points every physics tick, read the latest
## completed result (null until the first one arrives, a few frames later) and
## extrapolate its heights by [method get_query_age]. Release the owner when it
## stops querying (e.g. in _exit_tree).

## World3D instance id -> WaterSurface.
static var _surfaces := {}


## Makes surface the one find() returns for nodes in world.
static func register(world : World3D, surface : WaterSurface) -> void:
	var id := world.get_instance_id()
	if _surfaces.has(id) and _surfaces[id] != surface:
		push_error("A WaterSurface is already registered for this World3D; only one per world is supported.")
		return
	_surfaces[id] = surface


static func unregister(world : World3D, surface : WaterSurface) -> void:
	var id := world.get_instance_id()
	if _surfaces.get(id) == surface:
		_surfaces.erase(id)


## The surface of the world node is in, or null when there is none (or node is
## not inside the tree).
static func find(node : Node) -> WaterSurface:
	if not node.is_inside_tree():
		return null
	var world := node.get_viewport().find_world_3d()
	return _surfaces.get(world.get_instance_id()) if world != null else null


## Queues points for the next query dispatch; the latest submission per owner
## wins. body is the physics body the points belong to; it defaults to
## query_owner's nearest PhysicsBody3D (itself or an ancestor). Surfaces may
## leave out waves a body makes itself, which would otherwise drive it.
@abstract func submit_query(query_owner : Object, points : PackedVector3Array, body : PhysicsBody3D = null) -> void

## The latest completed query for query_owner, or null before the first one.
## Its points may differ from the most recent submission.
@abstract func get_query_result(query_owner : Object) -> WaterSurfaceQueryResult

## Seconds from result's dispatch to the caller's moment (in a physics tick: the
## moment of the bodies' state at its start), for
## WaterSurfaceSample.extrapolated_height().
@abstract func get_query_age(result : WaterSurfaceQueryResult) -> float

## Forgets query_owner's submissions and results.
@abstract func release_query(query_owner : Object) -> void

## The surface's clock, in the units of WaterSurfaceQueryResult.dispatch_time:
## a result dispatched at or before a moment read here predates it.
@abstract func get_clock() -> float

## Whether add_impulse() has an effect (e.g. the simulation of waves around the
## camera is running).
@abstract func can_add_impulses() -> bool

## Queues a splash: raises the surface at world_position by a Gaussian of radius
## meters and amplitude meters (negative lowers it), at rest; it then spreads as
## a ring of waves. Independent of the simulation's step length. Ignored when
## can_add_impulses() is false.
@abstract func add_impulse(world_position : Vector3, radius : float, amplitude : float) -> void
