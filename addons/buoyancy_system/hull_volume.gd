@tool
class_name HullVolume
extends Node3D
## Editable hull displacement volume used for buoyancy samples and water masking.
##
## The volume is represented by editable cross-sections in local space. This is a
## ship-focused alternative to generic meshes: simple to author, stable to sample,
## and easy to split into compartments later.

@export var enabled := true

@export_group("Geometry")
@export var sections : Array[HullVolumeSection] = [] :
	set(value):
		sections = value
		_connect_section_signals()
		_sort_sections()
		_rebuild_debug_mesh()

@export_group("Buoyancy")
@export var generate_buoyancy_samples := true
## Generates one buoyancy sample at each editable section vertex.
## Add/remove section points to control buoyancy sampling density.
@export var sample_section_vertices := true
@export_range(0.01, 100.0, 0.01, "or_greater") var submersion_depth := 1.2
@export_range(0.0, 1.0, 0.01) var buoyancy_efficiency := 1.0
@export_range(0.0, 1.0, 0.01) var flooding_fraction := 0.0
@export_range(0.0, 100.0, 0.01, "or_greater") var vertical_damping := 1.4
@export_range(0.0, 100.0, 0.01, "or_greater") var water_drag := 0.45
@export_range(0.0, 100.0, 0.01, "or_greater") var current_drag := 0.65

@export_group("Water Exclusion")
@export var water_exclusion_enabled := true
@export_range(0.0, 10.0, 0.01, "or_greater") var exclusion_margin := 0.35
## How far above the hull volume origin water can still be clipped.
## Keep this near the authored waterline; high values can remove storm waves
## above a submerged bow and create visible holes.
@export_range(0.0, 10.0, 0.01, "or_greater") var exclusion_height_above_origin := 0.45
@export_range(0.0, 10.0, 0.01, "or_greater") var exclusion_height_below_origin := 3.0
@export_range(0.001, 10.0, 0.01, "or_greater") var exclusion_height_feather := 0.35
@export_range(0.0, 4.0, 0.01, "or_greater") var feather := 0.8
@export_range(0.0, 1.0, 0.01) var foam_amount := 0.85

@export_group("Debug Draw")
@export var debug_draw := true :
	set(value):
		debug_draw = value
		_update_debug_visibility()
@export var debug_color := Color(0.1, 0.8, 1.0, 0.55) :
	set(value):
		debug_color = value
		_update_debug_material()
@export var debug_water_line_color := Color(0.1, 0.7, 1.0, 1.0) :
	set(value):
		debug_water_line_color = value
		_update_debug_material()
@export var debug_force_color := Color(1.0, 0.25, 0.1, 1.0) :
	set(value):
		debug_force_color = value
		_update_debug_material()
@export_range(0.001, 10.0, 0.001, "or_greater") var debug_force_scale := 0.015 :
	set(value):
		debug_force_scale = maxf(value, 0.001)
		_rebuild_debug_mesh()

var _debug_mesh_instance : MeshInstance3D
var _debug_mesh := ImmediateMesh.new()
var _debug_hull_material : StandardMaterial3D
var _debug_water_material : StandardMaterial3D
var _debug_force_material : StandardMaterial3D
var _debug_sample_states : Array[Dictionary] = []
var _debug_rebuild_queued := false


func _enter_tree() -> void:
	add_to_group(&"water_hull_volume")


func _exit_tree() -> void:
	remove_from_group(&"water_hull_volume")


func _ready() -> void:
	if sections.is_empty():
		reset_to_default_boat_shape()
	_connect_section_signals()
	_ensure_debug_nodes()
	_rebuild_debug_mesh()


func reset_to_default_boat_shape() -> void:
	sections = [
		_create_section(-10.5, 0.7, -0.75, 0.15),
		_create_section(-6.0, 2.9, -1.35, 0.35),
		_create_section(3.5, 3.2, -1.45, 0.35),
		_create_section(9.5, 1.25, -0.85, 0.2),
	]
	_connect_section_signals()
	_sort_sections()
	_rebuild_debug_mesh()


func get_total_volume() -> float:
	var sorted := get_sorted_sections()
	if sorted.size() < 2:
		return 0.0
	var volume := 0.0
	for i in range(sorted.size() - 1):
		var a := sorted[i]
		var b := sorted[i + 1]
		var length := absf(b.z_position - a.z_position)
		volume += (a.get_area() + b.get_area()) * 0.5 * length
	return maxf(volume, 0.0)


func get_buoyancy_sample_points() -> Array[Dictionary]:
	var samples : Array[Dictionary] = []
	if not enabled or not generate_buoyancy_samples:
		return samples
	var sorted := get_sorted_sections()
	if sorted.size() < 2:
		return samples

	var total_volume := get_total_volume()
	if total_volume <= 0.0001:
		return samples

	var local_points := _generate_local_sample_points(sorted)
	if local_points.is_empty():
		return samples

	var sample_volume := total_volume / float(local_points.size())
	_debug_sample_states.clear()
	_debug_sample_states.resize(local_points.size())
	for i in local_points.size():
		var local_point := local_points[i]
		samples.push_back({
			"world_position": global_transform * local_point,
			"volume_cubic_meters": sample_volume,
			"buoyancy_efficiency": buoyancy_efficiency,
			"flooding_fraction": flooding_fraction,
			"submersion_depth": submersion_depth,
			"vertical_damping": vertical_damping,
			"water_drag": water_drag,
			"current_drag": current_drag,
			"source": self,
			"source_sample_index": i,
		})
	return samples


func get_exclusion_segments() -> Array[Dictionary]:
	var segments : Array[Dictionary] = []
	if not enabled or not water_exclusion_enabled:
		return segments
	var sorted := get_sorted_sections()
	if sorted.size() < 2:
		return segments

	for i in range(sorted.size() - 1):
		var a := sorted[i]
		var b := sorted[i + 1]
		var z0 := a.z_position
		var z1 := b.z_position
		var length := absf(z1 - z0)
		if length <= 0.001:
			continue
		var center_z := (z0 + z1) * 0.5
		var half_width_start := a.get_half_width() + exclusion_margin
		var half_width_end := b.get_half_width() + exclusion_margin
		var half_width := maxf(half_width_start, half_width_end)
		var half_length := length * 0.5 + exclusion_margin
		var center_world := global_transform * Vector3(0.0, 0.0, center_z)
		segments.push_back({
			"center": center_world,
			"right": global_transform.basis.x.normalized(),
			"forward": global_transform.basis.z.normalized(),
			"half_extents": Vector2(half_width, half_length),
			"half_widths": Vector2(half_width_start, half_width_end),
			"min_y": center_world.y - exclusion_height_below_origin,
			"max_y": center_world.y + exclusion_height_above_origin,
			"height_feather": exclusion_height_feather,
			"feather": feather,
			"foam_amount": foam_amount,
		})
	return segments


func get_sorted_sections() -> Array[HullVolumeSection]:
	var sorted : Array[HullVolumeSection] = []
	for section in sections:
		if section != null:
			sorted.push_back(section)
	sorted.sort_custom(func(a: HullVolumeSection, b: HullVolumeSection) -> bool:
		return a.z_position < b.z_position
	)
	return sorted


func set_debug_sample_state(sample_index: int, sample_position: Vector3, water_position: Vector3, force: Vector3, has_sample: bool) -> void:
	if sample_index < 0:
		return
	while _debug_sample_states.size() <= sample_index:
		_debug_sample_states.push_back({})
	_debug_sample_states[sample_index] = {
		"sample_position": sample_position,
		"water_position": water_position,
		"force": force,
		"has_sample": has_sample,
	}
	_queue_debug_rebuild()


func _queue_debug_rebuild() -> void:
	if _debug_rebuild_queued:
		return
	_debug_rebuild_queued = true
	call_deferred(&"_rebuild_queued_debug_mesh")


func _rebuild_queued_debug_mesh() -> void:
	_debug_rebuild_queued = false
	_rebuild_debug_mesh()


func _generate_local_sample_points(sorted: Array[HullVolumeSection]) -> Array[Vector3]:
	var points : Array[Vector3] = []
	if sample_section_vertices:
		for section in sorted:
			for point in section.points:
				points.push_back(Vector3(point.x, point.y, section.z_position))
	return points


func _create_section(z: float, half_width: float, bottom_y: float, top_y: float) -> HullVolumeSection:
	var section := HullVolumeSection.new()
	section.z_position = z
	section.points = PackedVector2Array([
		Vector2(-half_width, top_y),
		Vector2(-half_width * 0.7, bottom_y),
		Vector2(half_width * 0.7, bottom_y),
		Vector2(half_width, top_y),
	])
	return section


func _sort_sections() -> void:
	sections.sort_custom(func(a, b) -> bool:
		if a == null:
			return false
		if b == null:
			return true
		return a.z_position < b.z_position
	)


func _connect_section_signals() -> void:
	for section in sections:
		if section == null:
			continue
		if not section.changed.is_connected(_on_section_changed):
			section.changed.connect(_on_section_changed)


func _on_section_changed() -> void:
	_sort_sections()
	_rebuild_debug_mesh()


func _ensure_debug_nodes() -> void:
	if _debug_mesh_instance != null and is_instance_valid(_debug_mesh_instance):
		return
	_debug_mesh_instance = get_node_or_null("DebugDraw") as MeshInstance3D
	if _debug_mesh_instance == null:
		_debug_mesh_instance = MeshInstance3D.new()
		_debug_mesh_instance.name = "DebugDraw"
		add_child(_debug_mesh_instance)
		_debug_mesh_instance.owner = owner
	_debug_mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_debug_mesh_instance.extra_cull_margin = 10000.0
	_debug_mesh_instance.mesh = _debug_mesh
	_update_debug_material()
	_update_debug_visibility()


func _update_debug_visibility() -> void:
	if _debug_mesh_instance != null:
		_debug_mesh_instance.visible = debug_draw


func _update_debug_material() -> void:
	if _debug_hull_material == null:
		_debug_hull_material = _create_debug_material(debug_color)
	if _debug_water_material == null:
		_debug_water_material = _create_debug_material(debug_water_line_color)
	if _debug_force_material == null:
		_debug_force_material = _create_debug_material(debug_force_color)
	_debug_hull_material.albedo_color = debug_color
	_debug_water_material.albedo_color = debug_water_line_color
	_debug_force_material.albedo_color = debug_force_color
	if _debug_mesh_instance != null:
		if _debug_mesh.get_surface_count() > 0:
			_debug_mesh_instance.set_surface_override_material(0, _debug_hull_material)
		if _debug_mesh.get_surface_count() > 1:
			_debug_mesh_instance.set_surface_override_material(1, _debug_water_material)
		if _debug_mesh.get_surface_count() > 2:
			_debug_mesh_instance.set_surface_override_material(2, _debug_force_material)


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
	_ensure_debug_nodes()
	_debug_mesh.clear_surfaces()
	var sorted := get_sorted_sections()
	if sorted.is_empty():
		return

	if _has_hull_debug_lines(sorted):
		_debug_mesh.surface_begin(Mesh.PRIMITIVE_LINES)
		for section in sorted:
			_add_section_outline(section)
		for i in range(sorted.size() - 1):
			_add_section_connectors(sorted[i], sorted[i + 1])
		_debug_mesh.surface_end()

	if _has_debug_sample_lines():
		_debug_mesh.surface_begin(Mesh.PRIMITIVE_LINES)
		_add_debug_water_lines()
		_debug_mesh.surface_end()

		_debug_mesh.surface_begin(Mesh.PRIMITIVE_LINES)
		_add_debug_force_lines()
		_debug_mesh.surface_end()
	_update_debug_material()


func _has_hull_debug_lines(sorted: Array[HullVolumeSection]) -> bool:
	for section in sorted:
		if section != null and section.points.size() >= 2:
			return true
	for i in range(sorted.size() - 1):
		var a := sorted[i]
		var b := sorted[i + 1]
		if a != null and b != null and mini(a.points.size(), b.points.size()) > 0:
			return true
	return false


func _has_debug_sample_lines() -> bool:
	for sample_state in _debug_sample_states:
		if sample_state is Dictionary and not sample_state.is_empty() and bool(sample_state.get("has_sample", false)):
			return true
	return false


func _add_section_outline(section: HullVolumeSection) -> void:
	if section.points.size() < 2:
		return
	for i in section.points.size():
		var a := section.points[i]
		var b := section.points[(i + 1) % section.points.size()]
		_debug_mesh.surface_add_vertex(Vector3(a.x, a.y, section.z_position))
		_debug_mesh.surface_add_vertex(Vector3(b.x, b.y, section.z_position))


func _add_section_connectors(a: HullVolumeSection, b: HullVolumeSection) -> void:
	var count := mini(a.points.size(), b.points.size())
	for i in count:
		var point_a := a.points[i]
		var point_b := b.points[i]
		_debug_mesh.surface_add_vertex(Vector3(point_a.x, point_a.y, a.z_position))
		_debug_mesh.surface_add_vertex(Vector3(point_b.x, point_b.y, b.z_position))


func _add_debug_water_lines() -> void:
	for sample_state in _debug_sample_states:
		if not (sample_state is Dictionary):
			continue
		if sample_state.is_empty() or not bool(sample_state.get("has_sample", false)):
			continue
		var sample_position : Vector3 = sample_state["sample_position"]
		var water_position : Vector3 = sample_state["water_position"]
		var water_local := to_local(water_position)
		var sample_local := to_local(sample_position)
		_debug_mesh.surface_add_vertex(sample_local)
		_debug_mesh.surface_add_vertex(water_local)


func _add_debug_force_lines() -> void:
	for sample_state in _debug_sample_states:
		if not (sample_state is Dictionary):
			continue
		if sample_state.is_empty() or not bool(sample_state.get("has_sample", false)):
			continue
		var water_position : Vector3 = sample_state["water_position"]
		var force : Vector3 = sample_state["force"]
		var start_local := to_local(water_position)
		var end_local := to_local(water_position + force * debug_force_scale)
		_debug_mesh.surface_add_vertex(start_local)
		_debug_mesh.surface_add_vertex(end_local)
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
	_debug_mesh.surface_add_vertex(end_local)
	_debug_mesh.surface_add_vertex(base + side * width)
	_debug_mesh.surface_add_vertex(end_local)
	_debug_mesh.surface_add_vertex(base - side * width)
	_debug_mesh.surface_add_vertex(end_local)
	_debug_mesh.surface_add_vertex(base + up * width)
	_debug_mesh.surface_add_vertex(end_local)
	_debug_mesh.surface_add_vertex(base - up * width)
