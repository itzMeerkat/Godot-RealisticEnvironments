@tool
class_name WaterCutoutHullLOD
extends Node3D
## Generates and provides editable top-view trapezoid water cutout segments.

const GENERATED_CUTOUTS_NAME := "GeneratedCutouts"
const POINT_DEDUP_SCALE := 1000.0
const WATER_CUTOUT_TRAPEZOID := preload("res://addons/ocean_system/water_cutout_trapezoid.gd")

@export var enabled := true

@export_group("Generation")
@export var source_model_path : NodePath
@export_range(1, 16, 1) var segments_count := 3 :
	set(value):
		segments_count = maxi(value, 1)
@export var bow_is_positive_z := true
@export var bounds_padding := Vector3.ZERO :
	set(value):
		bounds_padding = value.max(Vector3.ZERO)
@export_range(0.0, 10.0, 0.01, "or_greater") var inset_margin := 0.25 :
	set(value):
		inset_margin = maxf(value, 0.0)
@export_range(0.0, 1.5, 0.01, "or_greater") var bow_width_scale := 0.55 :
	set(value):
		bow_width_scale = maxf(value, 0.0)
@export_range(0.0, 1.5, 0.01, "or_greater") var stern_width_scale := 0.8 :
	set(value):
		stern_width_scale = maxf(value, 0.0)
@export_range(0.0, 1.0, 0.01) var bow_length_scale := 0.75 :
	set(value):
		bow_length_scale = clampf(value, 0.0, 1.0)
@export var generate_cutouts_now := false :
	set(value):
		if not value:
			generate_cutouts_now = false
			return
		generate_cutouts_now = false
		generate_cutouts_from_source()

@export_group("Defaults")
@export_range(-20.0, 20.0, 0.01) var default_vertical_min_offset := -1.0
@export_range(-20.0, 20.0, 0.01) var default_vertical_max_offset := 0.35
@export_range(0.001, 10.0, 0.01, "or_greater") var default_height_feather := 0.35
@export_range(0.0, 4.0, 0.01, "or_greater") var default_feather := 0.85
@export_range(0.0, 1.0, 0.01) var default_foam_amount := 0.75
@export_range(1.0, 4.0, 0.01, "or_greater") var bow_feather_multiplier := 1.5

@export_group("Debug")
@export var debug_draw := true :
	set(value):
		debug_draw = value
		_apply_debug_settings()
@export var debug_draw_in_game := false :
	set(value):
		debug_draw_in_game = value
		_apply_debug_settings()


func _enter_tree() -> void:
	add_to_group(&"water_cutout_provider")


func _exit_tree() -> void:
	remove_from_group(&"water_cutout_provider")


func _ready() -> void:
	_connect_cutout_signals()
	_apply_debug_settings()


func generate_cutouts_from_source() -> void:
	var root := _get_or_create_generated_cutouts_root()
	_clear_generated_cutouts(root)
	var points := _get_source_points_in_local_space()
	if points.is_empty():
		return
	var bounds := _get_points_bounds(points)
	if bounds.size.length_squared() <= 0.0001:
		return
	bounds.position -= bounds_padding
	bounds.size += bounds_padding * 2.0
	var count := maxi(segments_count, 1)
	var segment_length := bounds.size.z / float(count)
	for segment_index in count:
		var segment_min_z := bounds.position.z + segment_length * float(segment_index)
		var segment_max_z := segment_min_z + segment_length
		var segment_points := _get_points_in_z_range(points, segment_min_z, segment_max_z)
		if segment_points.is_empty():
			continue
		var local_center_z := (segment_min_z + segment_max_z) * 0.5
		var half_length := segment_length * 0.5
		var segment_kind := _get_segment_kind(segment_index, count)
		if segment_kind == &"bow":
			half_length *= bow_length_scale
		var width_scale := _get_width_scale(segment_kind)
		var start_width := _get_half_width_for_range(segment_points, segment_min_z, local_center_z) * width_scale
		var end_width := _get_half_width_for_range(segment_points, local_center_z, segment_max_z) * width_scale
		start_width = maxf(start_width - inset_margin, 0.01)
		end_width = maxf(end_width - inset_margin, 0.01)
		var segment_bounds := _get_points_bounds(segment_points)
		var cutout : WaterCutoutTrapezoid = WATER_CUTOUT_TRAPEZOID.new()
		cutout.name = _get_segment_name(segment_kind, segment_index)
		cutout.position = Vector3(segment_bounds.get_center().x, segment_bounds.get_center().y, local_center_z)
		cutout.half_length = half_length
		cutout.start_half_width = start_width
		cutout.end_half_width = end_width
		cutout.vertical_min_offset = default_vertical_min_offset
		cutout.vertical_max_offset = default_vertical_max_offset
		cutout.height_feather = default_height_feather
		cutout.feather = default_feather * (bow_feather_multiplier if segment_kind == &"bow" else 1.0)
		cutout.foam_amount = default_foam_amount
		cutout.debug_draw = debug_draw
		cutout.debug_draw_in_game = debug_draw_in_game
		root.add_child(cutout)
		cutout.owner = owner
	_connect_cutout_signals()


func get_exclusion_segments() -> Array[Dictionary]:
	var segments : Array[Dictionary] = []
	if not enabled:
		return segments
	for cutout in _get_cutouts():
		if cutout.enabled:
			segments.push_back(cutout.get_exclusion_segment())
	return segments


func _get_segment_kind(segment_index: int, count: int) -> StringName:
	if count <= 1:
		return &"mid"
	var bow_index := count - 1 if bow_is_positive_z else 0
	var stern_index := 0 if bow_is_positive_z else count - 1
	if segment_index == bow_index:
		return &"bow"
	if segment_index == stern_index:
		return &"stern"
	return &"mid"


func _get_segment_name(segment_kind: StringName, segment_index: int) -> String:
	if segment_kind == &"bow":
		return "BowCutout"
	if segment_kind == &"stern":
		return "SternCutout"
	return "MidCutout_%02d" % segment_index


func _get_width_scale(segment_kind: StringName) -> float:
	if segment_kind == &"bow":
		return bow_width_scale
	if segment_kind == &"stern":
		return stern_width_scale
	return 1.0


func _get_or_create_generated_cutouts_root() -> Node3D:
	var root := get_node_or_null(GENERATED_CUTOUTS_NAME) as Node3D
	if root != null:
		return root
	root = Node3D.new()
	root.name = GENERATED_CUTOUTS_NAME
	add_child(root)
	root.owner = owner
	return root


func _clear_generated_cutouts(root: Node) -> void:
	for child in root.get_children():
		root.remove_child(child)
		child.queue_free()


func _get_cutouts() -> Array[WaterCutoutTrapezoid]:
	var cutouts : Array[WaterCutoutTrapezoid] = []
	_collect_cutouts(self, cutouts)
	return cutouts


func _collect_cutouts(root: Node, cutouts: Array[WaterCutoutTrapezoid]) -> void:
	for child in root.get_children():
		if child is WaterCutoutTrapezoid:
			cutouts.push_back(child)
		else:
			_collect_cutouts(child, cutouts)


func _connect_cutout_signals() -> void:
	for cutout in _get_cutouts():
		if not cutout.cutout_changed.is_connected(_on_cutout_changed):
			cutout.cutout_changed.connect(_on_cutout_changed)


func _on_cutout_changed() -> void:
	pass


func _apply_debug_settings() -> void:
	for cutout in _get_cutouts():
		cutout.debug_draw = debug_draw
		cutout.debug_draw_in_game = debug_draw_in_game


func _get_source_points_in_local_space() -> PackedVector3Array:
	var points := PackedVector3Array()
	var seen := {}
	var source := get_node_or_null(source_model_path) as Node3D
	if source == null:
		source = get_parent() as Node3D
	if source == null:
		return points
	for mesh_instance in _find_mesh_instances(source):
		if mesh_instance.mesh == null:
			continue
		var mesh := mesh_instance.mesh
		for surface_index in mesh.get_surface_count():
			var arrays := mesh.surface_get_arrays(surface_index)
			if arrays.is_empty() or arrays.size() <= Mesh.ARRAY_VERTEX:
				continue
			if not (arrays[Mesh.ARRAY_VERTEX] is PackedVector3Array):
				continue
			var vertices : PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			for vertex in vertices:
				var local_vertex := to_local(mesh_instance.global_transform * vertex)
				var key := _get_point_dedup_key(local_vertex)
				if seen.has(key):
					continue
				seen[key] = true
				points.push_back(local_vertex)
	return points


func _find_mesh_instances(root: Node) -> Array[MeshInstance3D]:
	var results : Array[MeshInstance3D] = []
	if root == self:
		return results
	if root is MeshInstance3D and not (root is WaterCutoutTrapezoid):
		results.push_back(root)
	for child in root.get_children():
		results.append_array(_find_mesh_instances(child))
	return results


func _get_point_dedup_key(point: Vector3) -> String:
	return "%d:%d:%d" % [
		int(round(point.x * POINT_DEDUP_SCALE)),
		int(round(point.y * POINT_DEDUP_SCALE)),
		int(round(point.z * POINT_DEDUP_SCALE)),
	]


func _get_points_bounds(points: PackedVector3Array) -> AABB:
	var bounds := AABB()
	var has_bounds := false
	for point in points:
		if not has_bounds:
			bounds = AABB(point, Vector3.ZERO)
			has_bounds = true
		else:
			bounds = bounds.expand(point)
	return bounds if has_bounds else AABB()


func _get_points_in_z_range(points: PackedVector3Array, min_z: float, max_z: float) -> PackedVector3Array:
	var results := PackedVector3Array()
	for point in points:
		if point.z >= min_z and point.z <= max_z:
			results.push_back(point)
	return results


func _get_half_width_for_range(points: PackedVector3Array, min_z: float, max_z: float) -> float:
	var min_x := 1.0e20
	var max_x := -1.0e20
	var found := false
	for point in points:
		if point.z < min_z or point.z > max_z:
			continue
		min_x = minf(min_x, point.x)
		max_x = maxf(max_x, point.x)
		found = true
	if not found:
		var bounds := _get_points_bounds(points)
		return bounds.size.x * 0.5
	return maxf((max_x - min_x) * 0.5, 0.01)
