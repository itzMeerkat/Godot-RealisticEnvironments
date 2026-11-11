@tool
class_name GREBuoyantBody
extends Node
## Floats its parent RigidBody3D on the water (GREWaterSurface.find()). Made to look
## right, not to be exact: see addons/gre_buoyancy_system/README.md.
##
## Probes on the hull's waterline plane, spread over the outline of the body's
## collision shapes, sample the water every physics tick. Each lifts its share of
## the body's weight, more the deeper it is. The shares balance about the centre of
## mass, so in calm water the body rests level with the hull's lowest point draft
## below the surface, whatever its mass and centre of mass. The lift never acts
## below the centre of mass: a high centre of mass cannot capsize the body, while a
## low one (ballast) steadies it further. Damping and drag act relative to the
## moving water, so the body rides the waves and drifts with the surface drift. Bow
## along -Z.
##
## Every tick the body also reports its hull to the water (GREWaterSurface.submit_disturbance()):
## its footprint, how deep it sits and the water's motion under it, so the water draws
## the waves its motion makes (wake_strength). By default the body feels only the
## water simulation's waves, never the waves bodies stir up, so nothing it does can
## feed back into it; wave_response lets it ride those too (its own bow wave and wake,
## other hulls' wakes), all but the water its own hull displaces.

## A CollisionShape3D child in this group is left out of the hull: it collides but
## doesn't float the body (a seat, a mast, a cargo rack). Shapes the body gets other
## than as CollisionShape3D children (the shape-owner API) are never part of it.
const IGNORE_GROUP := &"buoyancy_ignore"
## Seconds the body is held frozen waiting for its first water sample; after that it
## is released anyway, with an error.
const FIRST_SAMPLE_TIMEOUT := 5.0
## Most probes per side, for probe_grid and the automatic grid.
const MAX_PROBES_PER_SIDE := 16
## Probes the automatic grid aims for over the hull's footprint.
const _AUTO_PROBE_COUNT := 16.0
## Largest natural frequency (rad/s) times the physics step that floats smoothly:
## stiffer floating (a tiny draft, a light and wide hull) jitters.
const _MAX_FREQUENCY_STEP := 0.5
## Smallest share of the weight (relative to an even share) a probe keeps when the
## shares balance about a centre of mass near the footprint's edge.
const _MIN_PROBE_SHARE := 0.05
const _DEBUG_DRY_COLOR := Color(0.6, 0.6, 0.6)
const _DEBUG_WET_COLOR := Color(0.2, 0.8, 1.0)
const _DEBUG_PROBE_SIZE := 0.1
## Test points per side for the footprint's area share (_build_hull()).
const _AREA_SAMPLES := 24
## Superellipse exponent n -> the share of its bounding box |u|^n + |v|^n <= 1 fills
## (Gamma(1 + 1/n)^2 / Gamma(1 + 2/n)): the footprint the water gets from the hull's.
const _FOOTPRINT_EXPONENTS := [1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0, 4.0, 6.0, 10.0, 16.0]
const _FOOTPRINT_AREA_SHARES := [0.5, 0.6068, 0.6845, 0.742, 0.7854, 0.8452, 0.8833, 0.927, 0.9638, 0.9857, 0.9941]

## What _build_hull() finds out about the body's collision shapes.
class Hull:
	## Probe positions (body space) on the waterline plane, over the shapes' outline.
	var probes := PackedVector3Array()
	## Lowest and highest point (body y) of the shapes.
	var bottom := INF
	var top := -INF
	## Corners (body x, z) of the shapes' footprint seen from above, and the share of
	## that rectangle the footprint fills.
	var low := Vector2(INF, INF)
	var high := Vector2(-INF, -INF)
	var area_share := 1.0
	## Shapes that cannot float ("name (class)").
	var unsupported := PackedStringArray()

## How deep (m) the hull's lowest point sits below calm water at rest, whatever the
## body's mass. It also sets the bobbing: about 2 pi sqrt(draft / g) seconds per
## bob (1.1 s for 0.3 m, 6 s for a battleship's 9 m).
@export_range(0.01, 20.0, 0.01, "or_greater", "suffix:m") var draft := 0.3 :
	set(value):
		draft = value
		update_configuration_warnings()
## Probes across the beam (x) and along the length (y). 0 picks a count from the
## hull's proportions (about 16 probes in all). More probes follow the waves under a
## long hull more closely.
@export var probe_grid := Vector2i.ZERO :
	set(value):
		probe_grid = value
		update_configuration_warnings()
## Damping of bobbing and rocking relative to the water's own up-and-down motion:
## 0 bobs on and on, 1 settles without overshooting.
@export_range(0.0, 2.0, 0.01) var damping_ratio := 0.4

@export_group("Drag")
## How quickly (1/s) the water takes away speed along the hull (relative to the
## water) while the hull is in it. Low: a hull glides.
@export_range(0.0, 10.0, 0.01, "or_greater", "suffix:1/s") var forward_drag := 0.2
## How quickly (1/s) the water takes away sideways speed (relative to the water).
## Higher than forward_drag gives keel grip: the hull goes where it points.
@export_range(0.0, 10.0, 0.01, "or_greater", "suffix:1/s") var sideways_drag := 2.0

@export_group("Waves")
## Scales the waves and foam the body makes as it moves through the water: wake, bow
## wave, rings and the foam its speed churns up (drawn by the ocean's interactive waves,
## felt only through wave_response). 0 makes none.
@export_range(0.0, 4.0, 0.01, "or_greater") var wake_strength := 1.0
## How much the body feels the waves hulls make (GREWaterSurface.set_query_wave_response()):
## 0 not at all, 1 fully. It then pitches on its own bow wave, rocks crossing its own and
## other hulls' wakes and bobs in the rings of things dropped beside it. Inside its own
## footprint the water is taken from around the hull, so the water it displaces itself
## never lifts it. Only near the camera, where the ocean simulates those waves.
@export_range(0.0, 1.0, 0.01) var wave_response := 0.0 :
	set(value):
		wave_response = value
		if _water != null:
			_water.set_query_wave_response(self, wave_response)

@export_group("Debug")
## Draws the probes and the water above or below each.
@export var debug_enabled := false :
	set(value):
		debug_enabled = value
		if _debug_instance != null:
			_debug_instance.visible = debug_enabled

var _body : RigidBody3D
var _water : GREWaterSurface
## Probe positions in the body's space, on its waterline plane.
var _probes := PackedVector3Array()
## Each probe's share of the weight relative to an even share (mean 1), balanced
## about the centre of mass on the first tick (_balance_probes()).
var _probe_shares := PackedFloat32Array()
## Lowest and highest point (body y) of the collision shapes.
var _hull_bottom := 0.0
var _hull_top := 0.0
## World positions of the probes this tick (submitted as the query).
var _points := PackedVector3Array()
## Per probe this tick: the water height (world y) over it and the surface slope
## (dy/dx, dy/dz) there.
var _water_heights := PackedFloat32Array()
var _water_slopes := PackedVector2Array()
var _has_sample := false
var _wet_probe_count := 0
## True while the body is frozen waiting for its first sample.
var _holding := false
var _hold_time := 0.0
var _stability_checked := false
## The hull's footprint as the water gets it (body x, z centre; half length and half
## beam; superellipse exponent), and the report reused every tick.
var _footprint_center := Vector2.ZERO
var _footprint_half_extents := Vector2.ONE
var _footprint_exponent := 2.0
var _disturbance := GREWaterDisturbance.new()
var _debug_instance : MeshInstance3D
var _debug_mesh : ImmediateMesh


func _ready() -> void:
	if Engine.is_editor_hint():
		set_physics_process(false)
		return
	var parent := get_parent()
	if not parent is RigidBody3D:
		push_error("GREBuoyantBody %s: its parent must be a RigidBody3D; buoyancy is off." % get_path())
		set_physics_process(false)
		return
	_body = parent
	var hull := _build_hull(_body)
	if not hull.unsupported.is_empty():
		push_error("GREBuoyantBody %s: ignoring collision shapes that cannot float: %s." % [get_path(), ", ".join(hull.unsupported)])
	if hull.probes.is_empty():
		push_error("GREBuoyantBody %s: no collision shapes to float on; buoyancy is off." % get_path())
		set_physics_process(false)
		return
	_probes = hull.probes
	_hull_bottom = hull.bottom
	_hull_top = hull.top
	_footprint_center = (hull.low + hull.high) * 0.5
	# Bow along -Z: the length runs along z, the beam along x.
	var half_size := (hull.high - hull.low) * 0.5
	_footprint_half_extents = Vector2(half_size.y, half_size.x)
	_footprint_exponent = _exponent_for_area_share(hull.area_share)
	_water = GREWaterSurface.find(self)
	if _water == null:
		push_error("GREBuoyantBody %s: no water in this world (add an GREOceanSystem); buoyancy is off." % get_path())
		set_physics_process(false)
		return
	_water.set_query_wave_response(self, wave_response)
	_points.resize(_probes.size())
	_water_heights.resize(_probes.size())
	_water_slopes.resize(_probes.size())
	if not _body.freeze:
		_body.freeze = true
		_holding = true
	_create_debug_instance()


func _exit_tree() -> void:
	if _water != null:
		_water.release_query(self)
		_water.release_disturbance(self)


func _physics_process(delta : float) -> void:
	if _probe_shares.is_empty():
		_balance_probes()
	var body_transform := _body.global_transform
	for i in _probes.size():
		_points[i] = body_transform * _probes[i]
	_water.submit_query(self, _points)
	var result := _water.get_query_result(self)
	if result == null:
		if _holding:
			_hold_time += delta
			if _hold_time > FIRST_SAMPLE_TIMEOUT:
				push_error("GREBuoyantBody %s: no water sample after %d s (does the ocean run?); released without buoyancy." % [get_path(), FIRST_SAMPLE_TIMEOUT])
				_release()
		return
	if result.samples.size() != _probes.size():
		push_error("GREBuoyantBody %s: %d water samples for %d probes; tick skipped." % [get_path(), result.samples.size(), _probes.size()])
		return
	if _holding:
		_release()
	_read_water(result)
	_report_hull(result)
	if not _body.freeze:
		_apply_forces(result)
		if not _stability_checked:
			_check_stability()
			_stability_checked = true
	if debug_enabled:
		_draw_debug()


func _get_configuration_warnings() -> PackedStringArray:
	var warnings := PackedStringArray()
	var parent := get_parent()
	if not parent is RigidBody3D:
		warnings.push_back("GREBuoyantBody must be a child of the RigidBody3D it floats.")
		return warnings
	var body : RigidBody3D = parent
	if body.freeze:
		warnings.push_back("The RigidBody3D is frozen (freeze), so it does not float.")
	var hull := _build_hull(body)
	if not hull.unsupported.is_empty():
		warnings.push_back("These collision shapes cannot float and are ignored: %s." % ", ".join(hull.unsupported))
	if hull.probes.is_empty():
		warnings.push_back("The RigidBody3D has no collision shapes to float on (box, sphere, capsule, cylinder, convex or concave polygon).")
	else:
		if draft >= hull.top - hull.bottom:
			warnings.push_back("draft (%.2f m) is at least the hull's height (%.2f m): the body floats with its top under water." % [draft, hull.top - hull.bottom])
		var center := Vector2(body.center_of_mass.x, body.center_of_mass.z)
		if body.center_of_mass_mode == RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM and (center.clamp(hull.low, hull.high) != center):
			warnings.push_back("center_of_mass lies outside the hull's footprint seen from above: the body cannot float level.")
	var gravity : float = ProjectSettings.get_setting("physics/3d/default_gravity", 9.8)
	var max_frequency := _MAX_FREQUENCY_STEP * Engine.physics_ticks_per_second
	if sqrt(gravity / draft) > max_frequency:
		warnings.push_back("draft below %.3f m bobs faster than %d physics ticks per second can follow, and jitters: raise draft or the tick rate." % [gravity / (max_frequency * max_frequency), Engine.physics_ticks_per_second])
	return warnings


## Whether any probe is in the water this tick (false before the first sample).
func is_in_water() -> bool:
	return _wet_probe_count > 0


## Depth (m) of global_point below the water surface this tick, negative above it:
## from the nearest probe's sample and the surface slope there. -INF before the
## first sample.
func get_point_depth(global_point : Vector3) -> float:
	if not _has_sample:
		return -INF
	var nearest := 0
	var nearest_distance := INF
	for i in _points.size():
		var distance := Vector2(global_point.x - _points[i].x, global_point.z - _points[i].z).length_squared()
		if distance < nearest_distance:
			nearest_distance = distance
			nearest = i
	var offset := Vector2(global_point.x - _points[nearest].x, global_point.z - _points[nearest].z)
	return _water_heights[nearest] + _water_slopes[nearest].dot(offset) - global_point.y


func _release() -> void:
	_holding = false
	_body.freeze = false


## Shares the weight among the probes so that their lift centres under the centre of
## mass: probe i lifts 1 + g . d_i even shares, with d_i its offset (x, z) from the
## probes' centre and g chosen to move that centre onto the centre of mass.
func _balance_probes() -> void:
	var state := PhysicsServer3D.body_get_direct_state(_body.get_rid())
	var center_of_mass := Vector2(state.center_of_mass_local.x, state.center_of_mass_local.z)
	var count := _probes.size()
	var mean := Vector2.ZERO
	for probe in _probes:
		mean += Vector2(probe.x, probe.z)
	mean /= count
	# Second moments of the offsets, slightly regularised for probes in one row.
	var xx := 0.0
	var xz := 0.0
	var zz := 0.0
	for probe in _probes:
		var d := Vector2(probe.x, probe.z) - mean
		xx += d.x * d.x
		xz += d.x * d.y
		zz += d.y * d.y
	var epsilon := (xx + zz) * 1e-4 + 1e-9
	xx += epsilon
	zz += epsilon
	var target := (center_of_mass - mean) * count
	var determinant := xx * zz - xz * xz
	var gradient := Vector2(zz * target.x - xz * target.y, xx * target.y - xz * target.x) / determinant
	_probe_shares.resize(count)
	var total := 0.0
	var clamped := false
	for i in count:
		var share := 1.0 + gradient.dot(Vector2(_probes[i].x, _probes[i].z) - mean)
		if share < _MIN_PROBE_SHARE:
			share = _MIN_PROBE_SHARE
			clamped = true
		_probe_shares[i] = share
		total += share
	for i in count:
		_probe_shares[i] *= count / total
	if clamped:
		push_error("GREBuoyantBody %s: the centre of mass lies at or beyond the edge of the hull's footprint; the body floats tilted." % get_path())


## The water over each probe now: the sample extrapolated to this tick, and moved by
## the surface slope from where it was queried to where the probe is.
func _read_water(result : GREWaterSurfaceQueryResult) -> void:
	var age := _water.get_query_age(result)
	_wet_probe_count = 0
	for i in _probes.size():
		var sample := result.samples[i]
		var normal := sample.normal
		var slope := Vector2(-normal.x, -normal.z) / maxf(normal.y, 0.1)
		var moved := Vector2(_points[i].x - result.points[i].x, _points[i].z - result.points[i].z)
		_water_heights[i] = sample.extrapolated_height(age) + slope.dot(moved)
		_water_slopes[i] = slope
		if _water_heights[i] - _points[i].y > -draft:
			_wet_probe_count += 1
	_has_sample = true


## Tells the water where the hull is, how deep it sits below the surface around it
## (its waterline plane's mean depth plus draft) and how the water under it moves, so
## the water draws the waves its motion relative to the water makes.
func _report_hull(result : GREWaterSurfaceQueryResult) -> void:
	if wake_strength <= 0.0:
		_water.release_disturbance(self)
		return
	var body_transform := _body.global_transform
	var forward := -body_transform.basis.z
	forward.y = 0.0
	var depth := 0.0
	var water_velocity := Vector3.ZERO
	for i in _probes.size():
		depth += _probe_shares[i] * (_water_heights[i] - _points[i].y)
		water_velocity += _probe_shares[i] * result.samples[i].surface_velocity
	var count := float(_probes.size())
	water_velocity = water_velocity / count + _water.get_surface_drift()
	water_velocity.y = 0.0
	_disturbance.position = body_transform * Vector3(_footprint_center.x, _probes[0].y, _footprint_center.y)
	_disturbance.forward = forward.normalized() if forward.length_squared() > 1e-6 else Vector3.FORWARD
	_disturbance.half_extents = _footprint_half_extents
	_disturbance.shape_exponent = _footprint_exponent
	_disturbance.depth = clampf(draft + depth / count, 0.0, _hull_top - _hull_bottom)
	_disturbance.water_velocity = water_velocity
	_disturbance.wave_strength = wake_strength
	_water.submit_disturbance(self, _disturbance)


## The superellipse exponent whose shape fills share of its bounding box.
func _exponent_for_area_share(share : float) -> float:
	for i in range(1, _FOOTPRINT_AREA_SHARES.size()):
		if share <= _FOOTPRINT_AREA_SHARES[i]:
			var t := inverse_lerp(_FOOTPRINT_AREA_SHARES[i - 1], _FOOTPRINT_AREA_SHARES[i], share)
			return lerpf(_FOOTPRINT_EXPONENTS[i - 1], _FOOTPRINT_EXPONENTS[i], clampf(t, 0.0, 1.0))
	return _FOOTPRINT_EXPONENTS[-1]


func _apply_forces(result : GREWaterSurfaceQueryResult) -> void:
	var state := PhysicsServer3D.body_get_direct_state(_body.get_rid())
	var gravity := state.total_gravity.length()
	var probe_count := float(_probes.size())
	var probe_mass := _body.mass / probe_count
	var probe_weight := probe_mass * gravity
	var max_lift := (_hull_top - _hull_bottom) / draft
	# Critical damping of a probe's share of the mass on its share of the stiffness
	# (weight / draft), times damping_ratio.
	var probe_damping := 2.0 * damping_ratio * probe_mass * sqrt(gravity / draft)
	var drift := _water.get_surface_drift()
	var center_of_mass := _body.global_position + state.center_of_mass
	var linear_velocity := state.linear_velocity
	var angular_velocity := state.angular_velocity
	var body_up := _body.global_transform.basis.y.normalized()
	var forward := -_body.global_transform.basis.z
	forward.y = 0.0
	forward = forward.normalized() if forward.length_squared() > 1e-6 else Vector3.FORWARD
	var right := forward.cross(Vector3.UP)
	var total_force := Vector3.ZERO
	var total_torque := Vector3.ZERO
	for i in _probes.size():
		var point := _points[i]
		var depth := _water_heights[i] - point.y
		var wet := clampf(1.0 + depth / draft, 0.0, 1.0)
		if wet <= 0.0:
			continue
		var sample := result.samples[i]
		var share := _probe_shares[i]
		var arm := point - center_of_mass
		var velocity := linear_velocity + angular_velocity.cross(arm)
		# How fast the surface rises past the probe as it moves over the slope.
		var surface_rate := sample.height_rate() + _water_slopes[i].dot(Vector2(velocity.x, velocity.z))
		var lift := Vector3.UP * (share * probe_weight * minf(1.0 + depth / draft, max_lift))
		# The lift acts no lower than the centre of mass: lift below it swings to
		# the raised side as the body heels and would capsize a tall hull.
		var lift_arm := arm - body_up * minf(arm.dot(body_up), 0.0)
		var force := Vector3.UP * (-share * probe_damping * wet * (velocity.y - surface_rate))
		var relative := velocity - sample.surface_velocity - drift
		force -= (forward * (forward_drag * relative.dot(forward)) + right * (sideways_drag * relative.dot(right))) * (share * probe_mass * wet)
		total_force += force + lift
		total_torque += arm.cross(force) + lift_arm.cross(lift)
	_body.apply_central_force(total_force)
	_body.apply_torque(total_torque)


## Reports a body that bobs, rolls or pitches faster than the physics step follows
## (it then jitters): its draft is tiny or it is light and wide for its inertia.
func _check_stability() -> void:
	var state := PhysicsServer3D.body_get_direct_state(_body.get_rid())
	var gravity := state.total_gravity.length()
	var max_frequency := _MAX_FREQUENCY_STEP / get_physics_process_delta_time()
	var heave := sqrt(gravity / draft)
	if heave > max_frequency:
		push_error("GREBuoyantBody %s: a draft of %.3f m bobs too fast for the physics tick rate and jitters; raise draft." % [get_path(), draft])
	# Rocking stiffness about each horizontal axis: every probe resists with
	# (weight share / draft) times the square of its vertical lever.
	var stiffness_per_probe := _body.mass * gravity / (_probes.size() * draft)
	var center_of_mass := _body.global_position + state.center_of_mass
	for axis : Vector3 in [_body.global_transform.basis.x.normalized(), _body.global_transform.basis.z.normalized()]:
		var stiffness := 0.0
		for i in _points.size():
			var lever := axis.cross(_points[i] - center_of_mass).y
			stiffness += stiffness_per_probe * _probe_shares[i] * lever * lever
		var inverse_inertia := axis.dot(state.inverse_inertia_tensor * axis)
		if sqrt(stiffness * inverse_inertia) > max_frequency:
			push_error("GREBuoyantBody %s: the body rocks too fast for the physics tick rate and jitters; give it more inertia or a larger draft." % get_path())
			return


## The probes (body space, on the waterline plane draft above the hull's lowest
## point) over the outline of body's collision shapes, seen from above.
func _build_hull(body : RigidBody3D) -> Hull:
	var hull := Hull.new()
	var outlines : Array[PackedVector2Array] = []
	var triangles := PackedVector2Array()
	for child in body.get_children():
		if not child is CollisionShape3D:
			continue
		var shape_node : CollisionShape3D = child
		if shape_node.disabled or shape_node.shape == null or shape_node.is_in_group(IGNORE_GROUP):
			continue
		var shape := shape_node.shape
		var vertices := PackedVector3Array()
		var concave := shape is ConcavePolygonShape3D
		if concave:
			var polygon : ConcavePolygonShape3D = shape
			vertices = polygon.get_faces()
		elif shape is BoxShape3D or shape is SphereShape3D or shape is CapsuleShape3D or shape is CylinderShape3D or shape is ConvexPolygonShape3D:
			# Each is convex, so its outline from above is the convex hull of its
			# points; the debug mesh's vertices lie on its surface and include them.
			var mesh := shape.get_debug_mesh()
			for surface in mesh.get_surface_count():
				vertices.append_array(mesh.surface_get_arrays(surface)[Mesh.ARRAY_VERTEX])
		else:
			hull.unsupported.push_back("%s (%s)" % [shape_node.name, shape.get_class()])
			continue
		var footprint := PackedVector2Array()
		for vertex in vertices:
			var point := shape_node.transform * vertex
			hull.bottom = minf(hull.bottom, point.y)
			hull.top = maxf(hull.top, point.y)
			var flat := Vector2(point.x, point.z)
			hull.low = hull.low.min(flat)
			hull.high = hull.high.max(flat)
			footprint.push_back(flat)
		if concave:
			triangles.append_array(footprint)
		else:
			var outline := Geometry2D.convex_hull(footprint)
			if outline.size() >= 4:
				outlines.push_back(outline)
	if hull.bottom < hull.top:
		var size := hull.high - hull.low
		var grid := probe_grid
		var spacing := sqrt(maxf(size.x * size.y, 1e-6) / _AUTO_PROBE_COUNT)
		if grid.x <= 0:
			grid.x = roundi(size.x / spacing)
		if grid.y <= 0:
			grid.y = roundi(size.y / spacing)
		grid = grid.clamp(Vector2i(2, 2), Vector2i(MAX_PROBES_PER_SIDE, MAX_PROBES_PER_SIDE))
		var waterline := hull.bottom + draft
		for j in grid.y:
			for i in grid.x:
				var flat := hull.low + size * Vector2((i + 0.5) / grid.x, (j + 0.5) / grid.y)
				if _is_inside(flat, outlines, triangles):
					hull.probes.push_back(Vector3(flat.x, waterline, flat.y))
		var inside := 0
		for j in _AREA_SAMPLES:
			for i in _AREA_SAMPLES:
				if _is_inside(hull.low + size * Vector2((i + 0.5) / _AREA_SAMPLES, (j + 0.5) / _AREA_SAMPLES), outlines, triangles):
					inside += 1
		hull.area_share = float(inside) / (_AREA_SAMPLES * _AREA_SAMPLES)
	return hull


func _is_inside(point : Vector2, outlines : Array[PackedVector2Array], triangles : PackedVector2Array) -> bool:
	for outline in outlines:
		if Geometry2D.is_point_in_polygon(point, outline):
			return true
	for i in range(0, triangles.size(), 3):
		if Geometry2D.point_is_inside_triangle(point, triangles[i], triangles[i + 1], triangles[i + 2]):
			return true
	return false


func _create_debug_instance() -> void:
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.no_depth_test = true
	material.vertex_color_use_as_albedo = true
	_debug_mesh = ImmediateMesh.new()
	_debug_instance = MeshInstance3D.new()
	_debug_instance.name = "BuoyancyDebug"
	_debug_instance.mesh = _debug_mesh
	_debug_instance.material_override = material
	_debug_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_debug_instance.extra_cull_margin = 10000.0
	_debug_instance.visible = debug_enabled
	# A Node parent gives no transform: the lines are drawn in world space.
	add_child(_debug_instance, false, INTERNAL_MODE_BACK)


## Each probe as a cross, and a line from it to the water over it (blue when wet).
func _draw_debug() -> void:
	_debug_mesh.clear_surfaces()
	_debug_mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	for i in _points.size():
		var point := _points[i]
		var water := Vector3(point.x, _water_heights[i], point.z)
		_debug_mesh.surface_set_color(_DEBUG_WET_COLOR if water.y - point.y > -draft else _DEBUG_DRY_COLOR)
		for axis : Vector3 in [Vector3.RIGHT, Vector3.FORWARD]:
			_debug_mesh.surface_add_vertex(point - axis * _DEBUG_PROBE_SIZE)
			_debug_mesh.surface_add_vertex(point + axis * _DEBUG_PROBE_SIZE)
		_debug_mesh.surface_add_vertex(point)
		_debug_mesh.surface_add_vertex(water)
	_debug_mesh.surface_end()
