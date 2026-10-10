@tool
class_name BuoyancyProbeVolume
extends Node3D
## Probe-based displacement source. It generates physical buoyancy probes inside
## the design waterline and separate FX/contact probes on the waterline edge.

## Emitted when probes are added, removed, enabled, disabled or edited, or the
## volume itself is toggled. BuoyantBody rebuilds its probe cache on it.
signal probes_changed

const GENERATED_PROBES_NAME := "GeneratedProbes"
const DEBUG_NODE_NAME := "DebugDraw"
const EPSILON := 0.0001
const PHYSICAL_PROBE_SCRIPT := preload("res://addons/buoyancy_system/buoyancy_probe_node.gd")
const FX_PROBE_SCRIPT := preload("res://addons/buoyancy_system/buoyancy_fx_probe_node.gd")

const PHYSICAL_COLOR := Color(0.1, 0.8, 1.0, 0.9)
const FX_COLOR := Color(1.0, 0.62, 0.14, 0.9)
const WATERLINE_COLOR := Color(0.2, 0.9, 1.0, 0.9)
const WATERLINE_HULL_COLOR := Color(1.0, 0.15, 0.95, 0.95)
const FORCE_COLOR := Color(0.1, 0.95, 0.35, 1.0)
const GRAVITY_COLOR := Color(1.0, 0.2, 0.05, 1.0)
const NET_FORCE_COLOR := Color(1.0, 0.9, 0.15, 1.0)
const CENTER_OF_MASS_COLOR := Color(1.0, 1.0, 1.0, 1.0)
const PHYSICAL_DEBUG_CROSS_SIZE := 0.16
const DEBUG_FORCE_SCALE := 0.015
const DEBUG_BODY_FORCE_SCALE := 0.004
const DEBUG_CENTER_OF_MASS_SIZE := 0.35
const DEBUG_SHOW_WATERLINE_INTERSECTION := true
const DEBUG_SHOW_WATERLINE_CONVEX_HULL := true

## Enables this probe volume for buoyancy sampling and contact events.
@export var enabled := true :
	set(value):
		enabled = value
		probes_changed.emit()

@export_group("Waterline Generation")
## Mesh roots used by the editor generator to find the design waterline outline.
@export var source_paths : Array[NodePath] = []
## Local-space height of the static design waterline used by probe generation.
@export var design_waterline_y := 0.0 :
	set(value):
		design_waterline_y = value
		_queue_debug_rebuild()
## Local X coordinate used as the mirror plane when symmetric generation is enabled.
@export var symmetry_plane_x := 0.0
## Mirrors physical probes across the local YZ plane for stable left/right balance.
@export var mirror_across_yz_plane := true
## Interprets the bow as local -Z when tagging generated FX/contact probes.
@export var bow_is_negative_z := true
## Target number of generated physical buoyancy probes.
@export_range(1, 256, 1) var physical_probe_count := 12
## Target number of generated FX/contact probes around the waterline edge.
@export_range(0, 256, 1) var fx_probe_count := 24
## Default fully-submerged volume assigned to each generated physical probe.
@export_range(0.001, 100000.0, 0.001, "or_greater") var generated_probe_volume_cubic_meters := 1.0
## Default vertical water column height assigned to each generated physical probe,
## generated_probe_freeboard included.
@export_range(0.01, 100.0, 0.01, "or_greater") var generated_probe_buoyancy_height := 1.2
## Height of each generated physical probe's column top above design_waterline_y.
## The hull above the waterline (up to the deck or gunwale) is reserve buoyancy: with
## the column ending at the waterline, waves above it cannot lift the hull.
@export_range(0.0, 100.0, 0.01, "or_greater") var generated_probe_freeboard := 0.0
## Fraction of hull length skipped near bow and stern when placing physical probes.
@export_range(0.0, 0.45, 0.01) var longitudinal_margin_fraction := 0.08
## Editor-only display radius assigned to generated FX/contact probes.
@export_range(0.01, 5.0, 0.01, "or_greater") var generated_fx_probe_display_radius := 0.12
## Automatically generates probes in the editor when this volume has no saved probes.
@export var editor_auto_generate_if_empty := true
## Regenerates physical probes from source_paths.
@export_tool_button("Generate Physical Probes", "Reload") var generate_physical_probes_action := generate_physical_probes_from_source
## Regenerates FX/contact probes from source_paths.
@export_tool_button("Generate FX Probes", "Reload") var generate_fx_probes_action := generate_fx_probes_from_source
## Regenerates both physical and FX/contact probes.
@export_tool_button("Generate All Probes", "Reload") var generate_all_probes_action := generate_all_probes_from_source

@export_group("Probe Defaults")
## Default forward/back water drag multiplier assigned to generated physical probes.
@export_range(0.0, 100.0, 0.01, "or_greater") var generated_probe_longitudinal_drag_multiplier := 1.0
## Default side-to-side water drag multiplier assigned to generated physical probes.
@export_range(0.0, 100.0, 0.01, "or_greater") var generated_probe_lateral_drag_multiplier := 1.0

@export_group("Contact Events")
## Depth above the sampled water surface required to emit an entered-water event.
@export_range(-10.0, 10.0, 0.001) var enter_depth_threshold := 0.03
## Depth below the sampled water surface required to emit an exited-water event.
@export_range(-10.0, 10.0, 0.001) var exit_depth_threshold := -0.03
## Minimum seconds between repeated enter/exit events for the same probe.
@export_range(0.0, 10.0, 0.001, "or_greater") var min_event_interval := 0.08

@export_group("Debug Draw")
## Shows generated probes, water contact lines, waterline helpers, and force vectors.
@export var debug_enabled := true :
	set(value):
		debug_enabled = value
		if not debug_enabled:
			_debug_mesh.clear_surfaces()
		elif is_inside_tree():
			_ensure_debug_nodes()
		_update_debug_visibility()
		_queue_debug_rebuild()

var _physical_cache : Array[Node3D] = []
var _fx_cache : Array[Node3D] = []
var _cache_dirty := true
var _warned_missing_runtime_probes := false
## Probe instance id -> BuoyancyProbeState, for the probes currently in this volume.
var _states_by_probe := {}
var _debug_body_state := {}
var _debug_mesh_instance : MeshInstance3D
var _debug_mesh := ImmediateMesh.new()
var _debug_line_vertices := PackedVector3Array()
var _debug_rebuild_queued := false
var _physical_material : StandardMaterial3D
var _fx_material : StandardMaterial3D
var _waterline_material : StandardMaterial3D
var _waterline_hull_material : StandardMaterial3D
var _force_material : StandardMaterial3D
var _gravity_material : StandardMaterial3D
var _net_force_material : StandardMaterial3D
var _center_of_mass_material : StandardMaterial3D


func _enter_tree() -> void:
	add_to_group(&"buoyancy_probe_volume")


func _exit_tree() -> void:
	remove_from_group(&"buoyancy_probe_volume")


func _notification(what: int) -> void:
	if what == NOTIFICATION_CHILD_ORDER_CHANGED:
		_invalidate_probe_cache()
		_queue_probe_refresh()


func _ready() -> void:
	if _get_physical_probes().is_empty() and _get_fx_probes().is_empty():
		if editor_auto_generate_if_empty and Engine.is_editor_hint():
			generate_physical_probes_from_source()
		elif not Engine.is_editor_hint():
			_warn_missing_runtime_probes_once()
	_connect_probe_signals()
	if debug_enabled:
		_ensure_debug_nodes()
	_queue_debug_rebuild()


## Editor only: replaces the generated physical and contact probes with new ones from the
## waterline outline of the meshes under source_paths. Save the scene to keep them.
func generate_all_probes_from_source() -> void:
	if not Engine.is_editor_hint():
		push_warning("Buoyancy probes can only be generated in the editor. Generate and save probes before running the scene.")
		return
	var start_usec := Time.get_ticks_usec()
	var context := _get_generation_context()
	var root := _get_or_create_generated_root()
	_clear_generated_physical_probes(root)
	_clear_generated_fx_probes(root)
	var physical_count := _generate_physical_probes(root, context)
	var fx_count := _generate_fx_probes(root, context)
	_finalize_generation()
	var elapsed_msec := float(Time.get_ticks_usec() - start_usec) / 1000.0
	print("BuoyancyProbeVolume generated %d physical probes and %d FX probes from %d waterline segments in %.2f ms: %s" % [physical_count, fx_count, int(context.get("segment_count", 0)), elapsed_msec, str(get_path())])


## Editor only: replaces only the generated physical (force) probes.
func generate_physical_probes_from_source() -> void:
	if not Engine.is_editor_hint():
		push_warning("Buoyancy probes can only be generated in the editor. Generate and save probes before running the scene.")
		return
	var start_usec := Time.get_ticks_usec()
	var context := _get_generation_context()
	var root := _get_or_create_generated_root()
	_clear_generated_physical_probes(root)
	var physical_count := _generate_physical_probes(root, context)
	_finalize_generation()
	var elapsed_msec := float(Time.get_ticks_usec() - start_usec) / 1000.0
	print("BuoyancyProbeVolume generated %d physical probes from %d waterline segments in %.2f ms: %s" % [physical_count, int(context.get("segment_count", 0)), elapsed_msec, str(get_path())])


## Editor only: replaces only the generated contact (FX) probes.
func generate_fx_probes_from_source() -> void:
	if not Engine.is_editor_hint():
		push_warning("FX probes can only be generated in the editor. Generate and save probes before running the scene.")
		return
	var start_usec := Time.get_ticks_usec()
	var context := _get_generation_context()
	var root := _get_or_create_generated_root()
	_clear_generated_fx_probes(root)
	var fx_count := _generate_fx_probes(root, context)
	_finalize_generation()
	var elapsed_msec := float(Time.get_ticks_usec() - start_usec) / 1000.0
	print("BuoyancyProbeVolume generated %d FX probes from %d waterline segments in %.2f ms: %s" % [fx_count, int(context.get("segment_count", 0)), elapsed_msec, str(get_path())])


func _get_generation_context() -> Dictionary:
	var source_mesh_instances := _get_source_mesh_instances()
	if source_mesh_instances.is_empty():
		push_warning("%s found no MeshInstance3D sources for buoyancy probe generation." % str(get_path()))
	var segments := _build_waterline_segments(source_mesh_instances)
	var bounds := _get_segments_bounds(segments)
	if bounds.size.length_squared() <= EPSILON:
		bounds = _get_source_bounds_in_local_space(source_mesh_instances)
	if bounds.size.length_squared() <= EPSILON:
		bounds = AABB(Vector3(-1.5, design_waterline_y, -3.0), Vector3(3.0, 0.01, 6.0))
	var hull_points := _build_waterline_hull_points(segments, bounds)
	return {
		"segments": segments,
		"hull_points": hull_points,
		"bounds": bounds,
		"segment_count": segments.size(),
		"owner": _get_generated_node_owner(),
	}


func _generate_physical_probes(root: Node, context: Dictionary) -> int:
	var hull_points : Array = context.get("hull_points", [])
	var bounds : AABB = context.get("bounds", AABB())
	var physical_specs := _build_physical_probe_specs(hull_points, bounds)
	var generated_owner : Node = context.get("owner", _get_generated_node_owner())
	var physical_count := 0
	for spec in physical_specs:
		var probe : Node3D = PHYSICAL_PROBE_SCRIPT.new()
		probe.name = "Probe_%03d" % physical_count
		probe.position = Vector3(float(spec["x"]), design_waterline_y + generated_probe_freeboard, float(spec["z"]))
		probe.set(&"max_submerged_volume_cubic_meters", generated_probe_volume_cubic_meters)
		probe.set(&"buoyancy_height", generated_probe_buoyancy_height)
		probe.set(&"longitudinal_water_drag_multiplier", generated_probe_longitudinal_drag_multiplier)
		probe.set(&"lateral_water_drag_multiplier", generated_probe_lateral_drag_multiplier)
		root.add_child(probe)
		probe.owner = generated_owner
		physical_count += 1
	return physical_count


func _generate_fx_probes(root: Node, context: Dictionary) -> int:
	var hull_points : Array = context.get("hull_points", [])
	var bounds : AABB = context.get("bounds", AABB())
	var fx_specs := _build_fx_probe_specs(hull_points, bounds)
	var generated_owner : Node = context.get("owner", _get_generated_node_owner())
	var fx_count := 0
	for spec in fx_specs:
		var probe : Node3D = FX_PROBE_SCRIPT.new()
		probe.name = "FxProbe_%03d_%s" % [fx_count, str(spec.get("tag", "side")).capitalize()]
		probe.position = Vector3(float(spec["x"]), design_waterline_y, float(spec["z"]))
		probe.set(&"display_radius", generated_fx_probe_display_radius)
		probe.set(&"tag", str(spec.get("tag", "side")))
		probe.set(&"enter_depth_threshold", enter_depth_threshold)
		probe.set(&"exit_depth_threshold", exit_depth_threshold)
		root.add_child(probe)
		probe.owner = generated_owner
		fx_count += 1
	return fx_count


func _finalize_generation() -> void:
	_invalidate_probe_cache()
	_connect_probe_signals()
	_queue_debug_rebuild()
	update_configuration_warnings()


func _get_configuration_warnings() -> PackedStringArray:
	if _get_physical_probes().is_empty():
		return PackedStringArray(["No buoyancy probes: the body does not float. Set source_paths to the hull meshes, press Generate All Probes, and save the scene."])
	return PackedStringArray()


## States of the enabled physical probes, created once per probe and reused.
## Empty while the volume is disabled.
func get_physical_probe_states() -> Array[BuoyancyProbeState]:
	var states : Array[BuoyancyProbeState] = []
	if not enabled:
		return states
	var probes := _get_physical_probes()
	if probes.is_empty():
		_warn_missing_runtime_probes_once()
	for probe in probes:
		if (probe as BuoyancyProbeNode).enabled:
			states.push_back(_get_or_create_state(probe, false, "", enter_depth_threshold, exit_depth_threshold))
	return states


## States of the enabled contact (FX) probes. Empty while the volume is disabled.
func get_contact_probe_states() -> Array[BuoyancyProbeState]:
	var states : Array[BuoyancyProbeState] = []
	if not enabled:
		return states
	for probe in _get_fx_probes():
		var fx_probe := probe as BuoyancyFxProbeNode
		if fx_probe.enabled:
			states.push_back(_get_or_create_state(probe, true, fx_probe.tag, fx_probe.enter_depth_threshold, fx_probe.exit_depth_threshold))
	return states


func _get_or_create_state(probe : Node3D, is_fx_probe : bool, tag : String, enter_threshold : float, exit_threshold : float) -> BuoyancyProbeState:
	var key := probe.get_instance_id()
	if not _states_by_probe.has(key):
		_states_by_probe[key] = BuoyancyProbeState.new(probe, is_fx_probe, tag, enter_threshold, exit_threshold, min_event_interval)
	return _states_by_probe[key]


## Called by BuoyantBody each tick with the body's centre of mass and forces, for the debug draw.
func set_debug_body_state(center_of_mass_world: Vector3, gravity_force: Vector3, external_force: Vector3, has_state: bool) -> void:
	if not debug_enabled:
		return
	_debug_body_state = {
		"center_of_mass_world": center_of_mass_world,
		"gravity_force": gravity_force,
		"external_force": external_force,
		"has_state": has_state,
	}
	_queue_debug_rebuild()


func _build_waterline_segments(mesh_instances: Array[MeshInstance3D]) -> Array[Dictionary]:
	var triangles := HullSlicer.collect_triangles(mesh_instances, global_transform.affine_inverse())
	var points := HullSlicer.slice(triangles, design_waterline_y)
	var segments : Array[Dictionary] = []
	for i in range(0, points.size(), 2):
		segments.push_back({"a": points[i], "b": points[i + 1]})
	return segments


func _build_waterline_hull_points(segments: Array, bounds: AABB) -> Array:
	var points : Array = []
	for segment in segments:
		points.push_back(segment["a"])
		points.push_back(segment["b"])
	points = _deduplicate_vector2_points(points)
	if points.size() < 3:
		points = _get_bounds_footprint_points(bounds)
	return _build_convex_hull_2d(points)


func _get_bounds_footprint_points(bounds: AABB) -> Array:
	var min_x := bounds.position.x
	var max_x := bounds.position.x + bounds.size.x
	var min_z := bounds.position.z
	var max_z := bounds.position.z + bounds.size.z
	return [
		Vector2(min_x, min_z),
		Vector2(max_x, min_z),
		Vector2(max_x, max_z),
		Vector2(min_x, max_z),
	]


func _deduplicate_vector2_points(points: Array) -> Array:
	var result : Array = []
	for point in points:
		var p : Vector2 = point
		var is_duplicate := false
		for existing in result:
			if p.distance_squared_to(existing) <= EPSILON * EPSILON:
				is_duplicate = true
				break
		if not is_duplicate:
			result.push_back(p)
	return result


func _build_convex_hull_2d(points: Array) -> Array:
	points = _deduplicate_vector2_points(points)
	if points.size() < 3:
		return points
	points.sort_custom(func(a: Vector2, b: Vector2) -> bool:
		if absf(a.x - b.x) > EPSILON:
			return a.x < b.x
		return a.y < b.y
	)
	var lower : Array = []
	for point in points:
		var p : Vector2 = point
		while lower.size() >= 2 and _cross_2d(lower[lower.size() - 2], lower[lower.size() - 1], p) <= EPSILON:
			lower.remove_at(lower.size() - 1)
		lower.push_back(p)
	var upper : Array = []
	for reverse_index in points.size():
		var p : Vector2 = points[points.size() - 1 - reverse_index]
		while upper.size() >= 2 and _cross_2d(upper[upper.size() - 2], upper[upper.size() - 1], p) <= EPSILON:
			upper.remove_at(upper.size() - 1)
		upper.push_back(p)
	lower.remove_at(lower.size() - 1)
	upper.remove_at(upper.size() - 1)
	var hull : Array = []
	hull.append_array(lower)
	hull.append_array(upper)
	return hull if hull.size() >= 3 else points


func _cross_2d(a: Vector2, b: Vector2, c: Vector2) -> float:
	return (b - a).cross(c - a)


func _build_physical_probe_specs(hull_points: Array, bounds: AABB) -> Array[Dictionary]:
	var specs : Array[Dictionary] = []
	var target_count := maxi(physical_probe_count, 1)
	if mirror_across_yz_plane:
		@warning_ignore("integer_division")
		var pair_count := target_count / 2
		var station_count := maxi(pair_count, 1)
		for station_index in station_count:
			var z := _get_station_z(station_index, station_count, bounds)
			var interval := _get_hull_interval_at_z(hull_points, bounds, z)
			var half_width := _get_symmetric_half_width(interval)
			if half_width <= EPSILON:
				continue
			var x_offset := half_width
			if pair_count > 0:
				specs.push_back({"x": symmetry_plane_x - x_offset, "z": z})
				specs.push_back({"x": symmetry_plane_x + x_offset, "z": z})
		if target_count % 2 != 0:
			@warning_ignore("integer_division")
			var z := _get_station_z(station_count / 2, station_count, bounds)
			specs.push_back({"x": symmetry_plane_x, "z": z})
	else:
		for station_index in target_count:
			var z := _get_station_z(station_index, target_count, bounds)
			var interval := _get_hull_interval_at_z(hull_points, bounds, z)
			specs.push_back({"x": (interval.x + interval.y) * 0.5, "z": z})
	while specs.size() > target_count:
		specs.remove_at(specs.size() - 1)
	return specs


func _get_symmetric_half_width(interval: Vector2) -> float:
	return maxf(maxf(absf(interval.x - symmetry_plane_x), absf(interval.y - symmetry_plane_x)), EPSILON)


func _build_fx_probe_specs(hull_points: Array, bounds: AABB) -> Array[Dictionary]:
	var specs : Array[Dictionary] = []
	if fx_probe_count <= 0:
		return specs
	@warning_ignore("integer_division")
	var pair_count := maxi(fx_probe_count / 2, 1)
	for station_index in pair_count:
		var z := _get_station_z(station_index, pair_count, bounds)
		var interval := _get_hull_interval_at_z(hull_points, bounds, z)
		var left_point := Vector2(interval.x, z)
		var right_point := Vector2(interval.y, z)
		specs.push_back({"x": left_point.x, "z": left_point.y, "tag": _get_fx_tag(left_point, bounds)})
		if specs.size() >= fx_probe_count:
			break
		specs.push_back({"x": right_point.x, "z": right_point.y, "tag": _get_fx_tag(right_point, bounds)})
	if fx_probe_count % 2 != 0 and specs.size() < fx_probe_count:
		var z := bounds.position.z if bow_is_negative_z else bounds.position.z + bounds.size.z
		specs.push_back({"x": symmetry_plane_x, "z": z, "tag": "bow"})
	return specs


func _get_station_z(index: int, count: int, bounds: AABB) -> float:
	var margin := bounds.size.z * clampf(longitudinal_margin_fraction, 0.0, 0.45)
	var start_z := bounds.position.z + margin
	var end_z := bounds.position.z + bounds.size.z - margin
	if count <= 1:
		return (start_z + end_z) * 0.5
	return lerpf(start_z, end_z, (float(index) + 0.5) / float(count))


func _get_hull_interval_at_z(hull_points: Array, bounds: AABB, z: float) -> Vector2:
	if hull_points.size() < 3:
		return Vector2(bounds.position.x, bounds.position.x + bounds.size.x)
	var intersections : Array[float] = []
	for i in hull_points.size():
		var a : Vector2 = hull_points[i]
		var b : Vector2 = hull_points[(i + 1) % hull_points.size()]
		var min_z := minf(a.y, b.y)
		var max_z := maxf(a.y, b.y)
		if z < min_z - EPSILON or z > max_z + EPSILON:
			continue
		if absf(a.y - b.y) <= EPSILON:
			if absf(z - a.y) <= EPSILON:
				intersections.push_back(a.x)
				intersections.push_back(b.x)
			continue
		var t := (z - a.y) / (b.y - a.y)
		if t < -EPSILON or t > 1.0 + EPSILON:
			continue
		intersections.push_back(lerpf(a.x, b.x, clampf(t, 0.0, 1.0)))
	if intersections.size() < 2:
		return Vector2(bounds.position.x, bounds.position.x + bounds.size.x)
	intersections.sort()
	intersections = _deduplicate_floats(intersections)
	if intersections.size() < 2:
		return Vector2(bounds.position.x, bounds.position.x + bounds.size.x)
	return Vector2(intersections[0], intersections[intersections.size() - 1])


func _deduplicate_floats(values: Array[float]) -> Array[float]:
	var result : Array[float] = []
	for value in values:
		if result.is_empty() or absf(value - result[result.size() - 1]) > EPSILON:
			result.push_back(value)
	return result


func _get_fx_tag(point: Vector2, bounds: AABB) -> String:
	var length := maxf(bounds.size.z, EPSILON)
	var bow_t := (point.y - bounds.position.z) / length
	if not bow_is_negative_z:
		bow_t = 1.0 - bow_t
	if bow_t <= 0.22:
		return "bow"
	if bow_t >= 0.82:
		return "stern"
	return "side"


func _get_source_roots() -> Array[Node3D]:
	var roots : Array[Node3D] = []
	if source_paths.is_empty():
		var parent_node := get_parent() as Node3D
		if parent_node != null:
			roots.push_back(parent_node)
		return roots
	for source_path in source_paths:
		var source := get_node_or_null(source_path) as Node3D
		if source != null and not roots.has(source):
			roots.push_back(source)
	return roots


func _get_source_mesh_instances() -> Array[MeshInstance3D]:
	var mesh_instances : Array[MeshInstance3D] = []
	var seen := {}
	for source_root in _get_source_roots():
		for mesh_instance in _find_mesh_instances(source_root):
			var instance_id := mesh_instance.get_instance_id()
			if seen.has(instance_id):
				continue
			seen[instance_id] = true
			mesh_instances.push_back(mesh_instance)
	return mesh_instances


func _find_mesh_instances(root: Node) -> Array[MeshInstance3D]:
	var results : Array[MeshInstance3D] = []
	if root == self:
		return results
	if root is MeshInstance3D and not _is_physical_probe(root) and not _is_fx_probe(root) and root.name != DEBUG_NODE_NAME:
		results.push_back(root)
	for child in root.get_children():
		results.append_array(_find_mesh_instances(child))
	return results


func _get_source_bounds_in_local_space(mesh_instances: Array[MeshInstance3D]) -> AABB:
	var bounds := AABB()
	var has_bounds := false
	for mesh_instance in mesh_instances:
		if mesh_instance.mesh == null:
			continue
		var mesh_bounds := mesh_instance.mesh.get_aabb()
		for corner in _get_aabb_corners(mesh_bounds):
			var local_corner := to_local(mesh_instance.global_transform * corner)
			if not has_bounds:
				bounds = AABB(local_corner, Vector3.ZERO)
				has_bounds = true
			else:
				bounds = bounds.expand(local_corner)
	return bounds if has_bounds else AABB()


func _get_segments_bounds(segments: Array[Dictionary]) -> AABB:
	var bounds := AABB()
	var has_bounds := false
	for segment in segments:
		var a : Vector2 = segment["a"]
		var b : Vector2 = segment["b"]
		for point in [Vector3(a.x, design_waterline_y, a.y), Vector3(b.x, design_waterline_y, b.y)]:
			if not has_bounds:
				bounds = AABB(point, Vector3.ZERO)
				has_bounds = true
			else:
				bounds = bounds.expand(point)
	return bounds if has_bounds else AABB()


func _get_aabb_corners(bounds: AABB) -> Array[Vector3]:
	var p := bounds.position
	var s := bounds.size
	return [
		p,
		p + Vector3(s.x, 0.0, 0.0),
		p + Vector3(0.0, s.y, 0.0),
		p + Vector3(0.0, 0.0, s.z),
		p + Vector3(s.x, s.y, 0.0),
		p + Vector3(s.x, 0.0, s.z),
		p + Vector3(0.0, s.y, s.z),
		p + s,
	]


func _get_or_create_generated_root() -> Node3D:
	var root := get_node_or_null(GENERATED_PROBES_NAME) as Node3D
	if root == null:
		root = Node3D.new()
		root.name = GENERATED_PROBES_NAME
		add_child(root)
	root.owner = _get_generated_node_owner()
	return root


func _clear_generated_physical_probes(root: Node) -> void:
	for child in root.get_children():
		if _is_physical_probe(child):
			root.remove_child(child)
			child.queue_free()


func _clear_generated_fx_probes(root: Node) -> void:
	for child in root.get_children():
		if child is Node3D and child.get_script() == FX_PROBE_SCRIPT:
			root.remove_child(child)
			child.queue_free()


func _get_generated_node_owner() -> Node:
	if Engine.is_editor_hint() and is_inside_tree():
		var edited_scene_root := get_tree().edited_scene_root
		if edited_scene_root != null:
			return edited_scene_root
	return owner


func _get_physical_probes() -> Array[Node3D]:
	if _cache_dirty:
		_rebuild_probe_cache()
	return _physical_cache


func _get_fx_probes() -> Array[Node3D]:
	if _cache_dirty:
		_rebuild_probe_cache()
	return _fx_cache


func _is_physical_probe(node: Node) -> bool:
	return node is Node3D and node.get_script() == PHYSICAL_PROBE_SCRIPT


func _is_fx_probe(node: Node) -> bool:
	return node is Node3D and node.get_script() == FX_PROBE_SCRIPT


func _rebuild_probe_cache() -> void:
	_physical_cache.clear()
	_fx_cache.clear()
	_collect_probes(self)
	_cache_dirty = false
	var kept := {}
	for probe in _physical_cache + _fx_cache:
		var key := probe.get_instance_id()
		if _states_by_probe.has(key):
			kept[key] = _states_by_probe[key]
	_states_by_probe = kept


func _collect_probes(root: Node) -> void:
	for child in root.get_children():
		if _is_physical_probe(child):
			_physical_cache.push_back(child)
		elif _is_fx_probe(child):
			_fx_cache.push_back(child)
		else:
			_collect_probes(child)


func _invalidate_probe_cache() -> void:
	_cache_dirty = true


func _queue_probe_refresh() -> void:
	if not is_inside_tree():
		return
	call_deferred(&"_refresh_probes_deferred")


func _refresh_probes_deferred() -> void:
	if not is_inside_tree():
		return
	_connect_probe_signals()
	_queue_debug_rebuild()
	probes_changed.emit()


func _connect_probe_signals() -> void:
	for probe in _get_physical_probes():
		if probe != null and probe.has_signal(&"probe_changed") and not probe.is_connected(&"probe_changed", Callable(self, "_on_probe_changed")):
			probe.connect(&"probe_changed", Callable(self, "_on_probe_changed"))
	for probe in _get_fx_probes():
		if probe != null and probe.has_signal(&"probe_changed") and not probe.is_connected(&"probe_changed", Callable(self, "_on_probe_changed")):
			probe.connect(&"probe_changed", Callable(self, "_on_probe_changed"))


func _on_probe_changed() -> void:
	# Threshold edits must reach the probe's state, so drop it; the next
	# get_*_probe_states() call recreates it.
	_states_by_probe.clear()
	_queue_debug_rebuild()
	probes_changed.emit()


func _warn_missing_runtime_probes_once() -> void:
	if _warned_missing_runtime_probes:
		return
	_warned_missing_runtime_probes = true
	push_warning("%s has no buoyancy probes. Generate probes in the editor and save the scene before running." % str(get_path()))


func _queue_debug_rebuild() -> void:
	if not debug_enabled or not is_inside_tree():
		return
	if _debug_rebuild_queued:
		return
	_debug_rebuild_queued = true
	call_deferred(&"_rebuild_queued_debug_mesh")


func _rebuild_queued_debug_mesh() -> void:
	_debug_rebuild_queued = false
	_rebuild_debug_mesh()


func _ensure_debug_nodes() -> void:
	if _debug_mesh_instance != null:
		return
	# Internal and unowned: debug geometry is never saved into the scene.
	_debug_mesh_instance = MeshInstance3D.new()
	_debug_mesh_instance.name = DEBUG_NODE_NAME
	add_child(_debug_mesh_instance, false, INTERNAL_MODE_BACK)
	_debug_mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_debug_mesh_instance.extra_cull_margin = 10000.0
	_debug_mesh_instance.mesh = _debug_mesh
	_update_debug_materials()
	_update_debug_visibility()


func _update_debug_visibility() -> void:
	if _debug_mesh_instance != null:
		_debug_mesh_instance.visible = debug_enabled


func _update_debug_materials() -> void:
	if _physical_material == null:
		_physical_material = _create_debug_material(PHYSICAL_COLOR)
	if _fx_material == null:
		_fx_material = _create_debug_material(FX_COLOR)
	if _waterline_material == null:
		_waterline_material = _create_debug_material(WATERLINE_COLOR)
	if _waterline_hull_material == null:
		_waterline_hull_material = _create_debug_material(WATERLINE_HULL_COLOR)
	if _force_material == null:
		_force_material = _create_debug_material(FORCE_COLOR)
	if _gravity_material == null:
		_gravity_material = _create_debug_material(GRAVITY_COLOR)
	if _net_force_material == null:
		_net_force_material = _create_debug_material(NET_FORCE_COLOR)
	if _center_of_mass_material == null:
		_center_of_mass_material = _create_debug_material(CENTER_OF_MASS_COLOR)


func _create_debug_material(color: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.no_depth_test = true
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.albedo_color = color
	return material


func _rebuild_debug_mesh() -> void:
	if not is_inside_tree():
		return
	if not debug_enabled:
		if _debug_mesh_instance != null:
			_debug_mesh.clear_surfaces()
		return
	_ensure_debug_nodes()
	_update_debug_materials()
	_debug_mesh.clear_surfaces()

	if Engine.is_editor_hint() and DEBUG_SHOW_WATERLINE_INTERSECTION:
		_begin_debug_lines()
		_add_debug_waterline_intersection()
		_commit_debug_lines(_waterline_material)
	if Engine.is_editor_hint() and DEBUG_SHOW_WATERLINE_CONVEX_HULL:
		_begin_debug_lines()
		_add_debug_waterline_convex_hull()
		_commit_debug_lines(_waterline_hull_material)

	_begin_debug_lines()
	for probe in _get_physical_probes():
		if probe != null:
			_add_debug_cross(probe.position, PHYSICAL_DEBUG_CROSS_SIZE)
	_commit_debug_lines(_physical_material)

	_begin_debug_lines()
	for probe in _get_fx_probes():
		if probe != null:
			_add_debug_cross(probe.position, maxf(float(probe.get(&"display_radius")), 0.04))
	_commit_debug_lines(_fx_material)

	_begin_debug_lines()
	_add_debug_water_lines()
	_commit_debug_lines(_waterline_material)

	_begin_debug_lines()
	_add_debug_force_lines()
	_commit_debug_lines(_force_material)

	if _has_debug_body_state():
		_begin_debug_lines()
		_add_debug_center_of_mass()
		_commit_debug_lines(_center_of_mass_material)

	if _has_debug_body_state():
		_begin_debug_lines()
		_add_debug_body_gravity()
		_commit_debug_lines(_gravity_material)

	if _has_debug_body_state():
		_begin_debug_lines()
		_add_debug_body_net_force()
		_commit_debug_lines(_net_force_material)


func _begin_debug_lines() -> void:
	_debug_line_vertices.clear()


func _add_debug_vertex(vertex: Vector3) -> void:
	_debug_line_vertices.push_back(vertex)


func _commit_debug_lines(material: Material) -> void:
	if _debug_line_vertices.is_empty() or _debug_line_vertices.size() % 2 != 0:
		return
	_debug_mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	for vertex in _debug_line_vertices:
		_debug_mesh.surface_add_vertex(vertex)
	_debug_mesh.surface_end()
	_set_last_surface_material(material)


func _set_last_surface_material(material: Material) -> void:
	if _debug_mesh_instance == null:
		return
	var surface_index := _debug_mesh.get_surface_count() - 1
	if surface_index >= 0:
		_debug_mesh_instance.set_surface_override_material(surface_index, material)


func _add_debug_cross(center: Vector3, radius: float) -> void:
	_add_debug_vertex(center + Vector3.LEFT * radius)
	_add_debug_vertex(center + Vector3.RIGHT * radius)
	_add_debug_vertex(center + Vector3.DOWN * radius)
	_add_debug_vertex(center + Vector3.UP * radius)
	_add_debug_vertex(center + Vector3.FORWARD * radius)
	_add_debug_vertex(center + Vector3.BACK * radius)


func _add_debug_waterline_intersection() -> void:
	for segment in _build_waterline_segments(_get_source_mesh_instances()):
		var a : Vector2 = segment["a"]
		var b : Vector2 = segment["b"]
		_add_debug_vertex(Vector3(a.x, design_waterline_y, a.y))
		_add_debug_vertex(Vector3(b.x, design_waterline_y, b.y))


func _add_debug_waterline_convex_hull() -> void:
	var source_mesh_instances := _get_source_mesh_instances()
	var segments := _build_waterline_segments(source_mesh_instances)
	var bounds := _get_segments_bounds(segments)
	if bounds.size.length_squared() <= EPSILON:
		bounds = _get_source_bounds_in_local_space(source_mesh_instances)
	if bounds.size.length_squared() <= EPSILON:
		bounds = AABB(Vector3(-1.5, design_waterline_y, -3.0), Vector3(3.0, 0.01, 6.0))
	var hull_points := _build_waterline_hull_points(segments, bounds)
	if hull_points.size() < 2:
		return
	var hull_y := design_waterline_y + 0.03
	for i in hull_points.size():
		var a : Vector2 = hull_points[i]
		var b : Vector2 = hull_points[(i + 1) % hull_points.size()]
		_add_debug_vertex(Vector3(a.x, hull_y, a.y))
		_add_debug_vertex(Vector3(b.x, hull_y, b.y))


func _add_debug_water_lines() -> void:
	for state : BuoyancyProbeState in _states_by_probe.values():
		if state.has_sample:
			_add_debug_vertex(to_local(state.world_position))
			_add_debug_vertex(to_local(state.water_position))


func _add_debug_force_lines() -> void:
	for state : BuoyancyProbeState in _states_by_probe.values():
		if not state.is_fx_probe and state.has_sample:
			_add_debug_arrow(state.world_position, state.force, DEBUG_FORCE_SCALE)


func _has_debug_body_state() -> bool:
	return _debug_body_state is Dictionary and not _debug_body_state.is_empty() and bool(_debug_body_state.get("has_state", false))


func _add_debug_center_of_mass() -> void:
	var center_world : Vector3 = _debug_body_state["center_of_mass_world"]
	_add_debug_cross(to_local(center_world), DEBUG_CENTER_OF_MASS_SIZE)


func _add_debug_body_gravity() -> void:
	var center_world : Vector3 = _debug_body_state["center_of_mass_world"]
	var gravity_force : Vector3 = _debug_body_state["gravity_force"]
	_add_debug_arrow(center_world, gravity_force, DEBUG_BODY_FORCE_SCALE)


func _add_debug_body_net_force() -> void:
	var center_world : Vector3 = _debug_body_state["center_of_mass_world"]
	var external_force : Vector3 = _debug_body_state["external_force"]
	_add_debug_arrow(center_world, external_force, DEBUG_BODY_FORCE_SCALE)


func _add_debug_arrow(start_world: Vector3, force: Vector3, force_scale: float) -> void:
	if force.length_squared() <= 0.0001:
		return
	var start_local := to_local(start_world)
	var end_local := to_local(start_world + force * force_scale)
	_add_debug_vertex(start_local)
	_add_debug_vertex(end_local)
	_add_arrowhead(end_local, start_local)


func _add_arrowhead(end_local: Vector3, start_local: Vector3) -> void:
	var direction := end_local - start_local
	if direction.length_squared() <= 0.0001:
		return
	direction = direction.normalized()
	var side := direction.cross(Vector3.UP)
	if side.length_squared() <= 0.0001:
		side = direction.cross(Vector3.RIGHT)
	side = side.normalized()
	var up := side.cross(direction).normalized()
	var length := minf(end_local.distance_to(start_local) * 0.22, 0.45)
	var width := length * 0.45
	var base := end_local - direction * length
	_add_debug_vertex(end_local)
	_add_debug_vertex(base + side * width)
	_add_debug_vertex(end_local)
	_add_debug_vertex(base - side * width)
	_add_debug_vertex(end_local)
	_add_debug_vertex(base + up * width)
	_add_debug_vertex(end_local)
	_add_debug_vertex(base - up * width)
