@tool
class_name BuoyancyCellVolume
extends Node3D
## Cell-based displacement volume used as the source of truth for buoyancy,
## mass, center of mass, water cutout, and local water interaction.

const DEFAULT_CELL_COLOR := Color(0.1, 0.8, 1.0, 0.18)
const DISABLED_CELL_COLOR := Color(0.25, 0.25, 0.25, 0.08)
const WATERLINE_CELL_COLOR := Color(0.1, 0.7, 1.0, 0.9)
const BUOYANCY_FORCE_COLOR := Color(0.1, 0.95, 0.35, 1.0)
const TOTAL_FORCE_COLOR := Color(1.0, 0.25, 0.1, 1.0)
const BODY_GRAVITY_COLOR := Color(1.0, 0.2, 0.05, 1.0)
const BODY_NET_FORCE_COLOR := Color(1.0, 0.9, 0.15, 1.0)
const CENTER_OF_MASS_COLOR := Color(1.0, 1.0, 1.0, 1.0)
const INTERACTION_SOURCE_LIMIT := 6
const BUOYANCY_CELL := preload("res://addons/buoyancy_system/buoyancy_cell.gd")

@export var enabled := true

@export_group("Generation")
@export var source_model_path : NodePath
@export var voxel_size := Vector3(0.8, 0.45, 1.2) :
	set(value):
		voxel_size = value.max(Vector3(0.05, 0.05, 0.05))
@export var bounds_padding := Vector3.ZERO
@export_range(1, 4096, 1) var max_generated_cells := 768
@export_range(0.0, 20000.0, 1.0, "or_greater") var default_density := 450.0
@export var auto_generate_if_empty := true
@export var generate_cells_now := false :
	set(value):
		if not value:
			generate_cells_now = false
			return
		generate_cells_now = false
		generate_cells_from_source()

@export_group("Cells")
@export var cells : Array[Resource] = [] :
	set(value):
		cells = value
		_connect_cell_signals()
		_apply_mass_to_parent()
		_queue_debug_rebuild()

@export_group("Buoyancy Defaults")
@export_range(0.0, 1.0, 0.01) var default_buoyancy_efficiency := 1.0
@export_range(0.0, 1.0, 0.01) var default_flooding_fraction := 0.0
@export_range(0.0, 100.0, 0.01, "or_greater") var default_vertical_damping_multiplier := 1.0
@export_range(0.0, 100.0, 0.01, "or_greater") var default_longitudinal_water_drag_multiplier := 1.0
@export_range(0.0, 100.0, 0.01, "or_greater") var default_lateral_water_drag_multiplier := 1.0

@export_group("Mass")
@export var apply_mass_to_rigid_body := true :
	set(value):
		apply_mass_to_rigid_body = value
		_apply_mass_to_parent()
@export_range(0.001, 100.0, 0.001, "or_greater") var mass_scale := 1.0 :
	set(value):
		mass_scale = maxf(value, 0.001)
		_apply_mass_to_parent()
@export var center_of_mass_offset := Vector3.ZERO :
	set(value):
		center_of_mass_offset = value
		_apply_mass_to_parent()

@export_group("Water Cutout")
@export var water_exclusion_enabled := true
@export_range(0.0, 10.0, 0.01, "or_greater") var exclusion_margin := 0.25
@export_range(0.0, 10.0, 0.01, "or_greater") var exclusion_height_above_origin := 0.45
@export_range(0.0, 10.0, 0.01, "or_greater") var exclusion_height_below_origin := 2.0
@export_range(0.001, 10.0, 0.01, "or_greater") var exclusion_height_feather := 0.35
@export_range(0.0, 4.0, 0.01, "or_greater") var feather := 0.65
@export_range(0.0, 1.0, 0.01) var foam_amount := 0.75

@export_group("Water Interaction")
@export var water_interaction_enabled := true
@export_range(0.0, 100.0, 0.01, "or_greater") var interaction_velocity_threshold := 0.35
@export_range(0.0, 20.0, 0.01, "or_greater") var interaction_strength := 0.05
@export_range(0.0, 10.0, 0.01, "or_greater") var interaction_radius_scale := 1.35
@export_range(1, 12, 1) var max_interaction_sources := 6
@export var local_forward_axis := Vector3.FORWARD

@export_group("Debug Draw")
@export var debug_draw := true :
	set(value):
		debug_draw = value
		_update_debug_visibility()
@export_range(1, 4096, 1) var debug_max_cells := 512 :
	set(value):
		debug_max_cells = maxi(value, 1)
		_queue_debug_rebuild()
@export_range(0.001, 10.0, 0.001, "or_greater") var debug_force_scale := 0.015 :
	set(value):
		debug_force_scale = maxf(value, 0.001)
		_queue_debug_rebuild()
@export_range(0.001, 10.0, 0.001, "or_greater") var debug_body_force_scale := 0.004 :
	set(value):
		debug_body_force_scale = maxf(value, 0.001)
		_queue_debug_rebuild()
@export_range(0.01, 10.0, 0.01, "or_greater") var debug_center_of_mass_size := 0.35 :
	set(value):
		debug_center_of_mass_size = maxf(value, 0.01)
		_queue_debug_rebuild()

var _debug_mesh_instance : MeshInstance3D
var _debug_mesh := ImmediateMesh.new()
var _cell_material : StandardMaterial3D
var _waterline_material : StandardMaterial3D
var _buoyancy_force_material : StandardMaterial3D
var _total_force_material : StandardMaterial3D
var _body_gravity_material : StandardMaterial3D
var _body_net_force_material : StandardMaterial3D
var _center_of_mass_material : StandardMaterial3D
var _debug_sample_states : Array[Dictionary] = []
var _debug_body_state := {}
var _debug_line_vertices := PackedVector3Array()
var _debug_rebuild_queued := false


func _enter_tree() -> void:
	add_to_group(&"buoyancy_cell_volume")


func _exit_tree() -> void:
	remove_from_group(&"buoyancy_cell_volume")


func _ready() -> void:
	if cells.is_empty() and auto_generate_if_empty:
		generate_cells_from_source()
	_connect_cell_signals()
	_ensure_debug_nodes()
	_apply_mass_to_parent()
	call_deferred(&"_apply_mass_to_parent")
	_rebuild_debug_mesh()


func generate_cells_from_source() -> void:
	var bounds := _get_source_bounds_in_local_space()
	if bounds.size.length_squared() <= 0.0001:
		bounds = AABB(Vector3(-1.5, -0.5, -3.0), Vector3(3.0, 1.0, 6.0))
	bounds.position -= bounds_padding
	bounds.size += bounds_padding * 2.0

	var count_x := maxi(int(ceil(bounds.size.x / voxel_size.x)), 1)
	var count_y := maxi(int(ceil(bounds.size.y / voxel_size.y)), 1)
	var count_z := maxi(int(ceil(bounds.size.z / voxel_size.z)), 1)
	var total_count := count_x * count_y * count_z
	if total_count > max_generated_cells:
		var scale := pow(float(total_count) / float(max_generated_cells), 1.0 / 3.0)
		count_x = maxi(int(floor(float(count_x) / scale)), 1)
		count_y = maxi(int(floor(float(count_y) / scale)), 1)
		count_z = maxi(int(floor(float(count_z) / scale)), 1)

	var cell_size := Vector3(
		bounds.size.x / float(count_x),
		bounds.size.y / float(count_y),
		bounds.size.z / float(count_z)
	)
	var generated : Array[Resource] = []
	for z in count_z:
		for y in count_y:
			for x in count_x:
				var cell : Resource = BUOYANCY_CELL.new()
				cell.local_center = bounds.position + Vector3(
					(float(x) + 0.5) * cell_size.x,
					(float(y) + 0.5) * cell_size.y,
					(float(z) + 0.5) * cell_size.z
				)
				cell.size = cell_size
				cell.density = default_density
				cell.buoyancy_efficiency = default_buoyancy_efficiency
				cell.flooding_fraction = default_flooding_fraction
				cell.vertical_damping_multiplier = default_vertical_damping_multiplier
				cell.longitudinal_water_drag_multiplier = default_longitudinal_water_drag_multiplier
				cell.lateral_water_drag_multiplier = default_lateral_water_drag_multiplier
				generated.push_back(cell)
	cells = generated
	_connect_cell_signals()
	_apply_mass_to_parent()
	_queue_debug_rebuild()


func get_buoyancy_sample_points() -> Array[Dictionary]:
	var samples : Array[Dictionary] = []
	if not enabled:
		return samples
	_debug_sample_states.clear()
	_debug_sample_states.resize(cells.size())
	for i in cells.size():
		var cell := cells[i] as BuoyancyCell
		if cell == null or not cell.enabled:
			continue
		var vertical_half_extent := _get_cell_vertical_half_extent(cell)
		samples.push_back({
			"world_position": global_transform * cell.local_center,
			"local_position": cell.local_center,
			"volume_cubic_meters": cell.get_volume(),
			"mass_kg": cell.get_mass(),
			"buoyancy_efficiency": cell.buoyancy_efficiency,
			"flooding_fraction": cell.flooding_fraction,
			"submersion_depth": maxf(vertical_half_extent * 2.0, 0.001),
			"cell_vertical_half_extent": vertical_half_extent,
			"vertical_damping_multiplier": cell.vertical_damping_multiplier,
			"longitudinal_water_drag_multiplier": cell.longitudinal_water_drag_multiplier,
			"lateral_water_drag_multiplier": cell.lateral_water_drag_multiplier,
			"source": self,
			"source_sample_index": i,
		})
	return samples


func get_total_volume() -> float:
	var volume := 0.0
	for i in cells.size():
		var cell := cells[i] as BuoyancyCell
		if cell != null and cell.enabled:
			volume += cell.get_volume()
	return volume


func get_total_mass() -> float:
	var mass := 0.0
	for i in cells.size():
		var cell := cells[i] as BuoyancyCell
		if cell != null and cell.enabled:
			mass += cell.get_mass()
	return mass * mass_scale


func get_center_of_mass() -> Vector3:
	var weighted_center := Vector3.ZERO
	var total_mass := 0.0
	for i in cells.size():
		var cell := cells[i] as BuoyancyCell
		if cell == null or not cell.enabled:
			continue
		var mass := cell.get_mass()
		weighted_center += cell.local_center * mass
		total_mass += mass
	if total_mass <= 0.0001:
		return center_of_mass_offset
	return weighted_center / total_mass + center_of_mass_offset


func get_exclusion_segments() -> Array[Dictionary]:
	var segments : Array[Dictionary] = []
	if not enabled or not water_exclusion_enabled:
		return segments
	var bounds := _get_enabled_cell_bounds()
	if bounds.size.length_squared() <= 0.0001:
		return segments
	var center := bounds.get_center()
	var half_extents := Vector2(bounds.size.x * 0.5 + exclusion_margin, bounds.size.z * 0.5 + exclusion_margin)
	var center_world := global_transform * center
	segments.push_back({
		"center": center_world,
		"right": global_transform.basis.x.normalized(),
		"forward": global_transform.basis.z.normalized(),
		"half_extents": half_extents,
		"half_widths": Vector2(half_extents.x, half_extents.x),
		"min_y": center_world.y - exclusion_height_below_origin,
		"max_y": center_world.y + exclusion_height_above_origin,
		"height_feather": exclusion_height_feather,
		"feather": feather,
		"foam_amount": foam_amount,
	})
	return segments


func get_water_interaction_sources(sample_points: Array, surface_samples: Array, rigid_body: RigidBody3D) -> Array[Dictionary]:
	var sources : Array[Dictionary] = []
	if not enabled or not water_interaction_enabled or rigid_body == null:
		return sources
	var zone_count := mini(maxi(max_interaction_sources, 1), INTERACTION_SOURCE_LIMIT)
	var zones : Array[Dictionary] = []
	zones.resize(zone_count)
	for i in zone_count:
		zones[i] = {
			"weight": 0.0,
			"position": Vector3.ZERO,
			"velocity": Vector3.ZERO,
			"radius": 0.0,
			"strength": 0.0,
		}

	var bounds := _get_enabled_cell_bounds()
	if bounds.size.length_squared() <= 0.0001:
		return sources
	var max_speed := 0.0
	var sample_count := mini(sample_points.size(), surface_samples.size())
	for i in sample_count:
		var sample_point : Dictionary = sample_points[i]
		if sample_point.get("source") != self:
			continue
		var water_sample : WaterSurfaceSample = surface_samples[i]
		var world_position : Vector3 = sample_point["world_position"]
		var local_position : Vector3 = sample_point.get("local_position", to_local(world_position))
		var cell_height := maxf(float(sample_point.get("submersion_depth", voxel_size.y)), 0.001)
		var cell_half_height := maxf(float(sample_point.get("cell_vertical_half_extent", cell_height * 0.5)), 0.0005)
		var cell_bottom_y := world_position.y - cell_half_height
		var submersion := clampf((water_sample.height - cell_bottom_y) / cell_height, 0.0, 1.0)
		if submersion <= 0.02:
			continue
		var offset := world_position - rigid_body.global_position
		var point_velocity := rigid_body.linear_velocity + rigid_body.angular_velocity.cross(offset)
		var water_velocity := water_sample.surface_velocity
		var relative_velocity := point_velocity - water_velocity
		var speed := relative_velocity.length()
		if speed < interaction_velocity_threshold:
			continue
		var zone_index := _get_interaction_zone_index(local_position, bounds, zone_count)
		var zone := zones[zone_index]
		var volume := float(sample_point.get("volume_cubic_meters", 0.0))
		var weight := submersion * volume * speed
		zone["weight"] = float(zone["weight"]) + weight
		zone["position"] = Vector3(zone["position"]) + world_position * weight
		zone["velocity"] = Vector3(zone["velocity"]) + relative_velocity * weight
		zone["radius"] = maxf(float(zone["radius"]), pow(maxf(volume, 0.001), 1.0 / 3.0) * interaction_radius_scale)
		zone["strength"] = float(zone["strength"]) + weight * interaction_strength
		zones[zone_index] = zone
		max_speed = maxf(max_speed, speed)

	for zone in zones:
		var weight := float(zone["weight"])
		if weight <= 0.0001:
			continue
		var velocity := Vector3(zone["velocity"]) / weight
		sources.push_back({
			"position": Vector3(zone["position"]) / weight,
			"radius": maxf(float(zone["radius"]), 0.4),
			"strength": clampf(float(zone["strength"]), -1.0, 1.0),
			"foam": clampf(velocity.length() / 6.0, 0.0, 1.0),
			"velocity": velocity,
		})

	if sources.size() < zone_count:
		var body_speed := rigid_body.linear_velocity.length()
		if body_speed > interaction_velocity_threshold:
			var forward := _get_forward_direction()
			var stern_local := bounds.get_center() - forward * bounds.size.length() * 0.25
			var stern_world := global_transform * stern_local
			sources.push_back({
				"position": stern_world,
				"radius": maxf(minf(bounds.size.x, bounds.size.z) * 0.18, 0.6),
				"strength": clampf(body_speed * interaction_strength * 0.75, 0.0, 1.0),
				"foam": clampf(body_speed / 8.0, 0.0, 1.0),
				"velocity": rigid_body.linear_velocity,
			})
	return sources


func set_debug_sample_state(
	sample_index: int,
	sample_position: Vector3,
	water_position: Vector3,
	force: Vector3,
	has_sample: bool,
	buoyancy_force := Vector3.ZERO,
	submersion := 0.0
) -> void:
	if sample_index < 0:
		return
	while _debug_sample_states.size() <= sample_index:
		_debug_sample_states.push_back({})
	_debug_sample_states[sample_index] = {
		"sample_position": sample_position,
		"water_position": water_position,
		"force": force,
		"has_sample": has_sample,
		"buoyancy_force": buoyancy_force,
		"submersion": submersion,
	}
	_queue_debug_rebuild()


func set_debug_body_state(center_of_mass_world: Vector3, gravity_force: Vector3, external_force: Vector3, has_state: bool) -> void:
	_debug_body_state = {
		"center_of_mass_world": center_of_mass_world,
		"gravity_force": gravity_force,
		"external_force": external_force,
		"has_state": has_state,
	}
	_queue_debug_rebuild()


func _get_source_bounds_in_local_space() -> AABB:
	var source := get_node_or_null(source_model_path) as Node3D
	if source == null:
		source = get_parent() as Node3D
	if source == null:
		return AABB()
	var bounds := AABB()
	var has_bounds := false
	for mesh_instance in _find_mesh_instances(source):
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


func _find_mesh_instances(root: Node) -> Array[MeshInstance3D]:
	var results : Array[MeshInstance3D] = []
	if root is MeshInstance3D:
		results.push_back(root)
	for child in root.get_children():
		results.append_array(_find_mesh_instances(child))
	return results


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


func _connect_cell_signals() -> void:
	for i in cells.size():
		var cell := cells[i] as BuoyancyCell
		if cell == null:
			continue
		if not cell.changed.is_connected(_on_cell_changed):
			cell.changed.connect(_on_cell_changed)


func _on_cell_changed() -> void:
	_apply_mass_to_parent()
	_queue_debug_rebuild()


func _apply_mass_to_parent() -> void:
	if not apply_mass_to_rigid_body or not is_inside_tree():
		return
	var body := get_parent() as RigidBody3D
	if body == null:
		return
	var total_mass := get_total_mass()
	if total_mass <= 0.0001:
		return
	body.mass = total_mass
	body.center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	body.center_of_mass = transform * get_center_of_mass()


func _get_enabled_cell_bounds() -> AABB:
	var bounds := AABB()
	var has_bounds := false
	for i in cells.size():
		var cell := cells[i] as BuoyancyCell
		if cell == null or not cell.enabled:
			continue
		var half_size : Vector3 = cell.size * 0.5
		var cell_bounds := AABB(cell.local_center - half_size, cell.size)
		if not has_bounds:
			bounds = cell_bounds
			has_bounds = true
		else:
			bounds = bounds.merge(cell_bounds)
	return bounds if has_bounds else AABB()


func _get_cell_vertical_half_extent(cell: Resource) -> float:
	var half_size : Vector3 = cell.size * 0.5
	var basis := global_transform.basis
	return maxf(
		absf(basis.x.y) * half_size.x
		+ absf(basis.y.y) * half_size.y
		+ absf(basis.z.y) * half_size.z,
		0.0005
	)


func _get_interaction_zone_index(local_position: Vector3, bounds: AABB, zone_count: int) -> int:
	if zone_count <= 1:
		return 0
	var center := bounds.get_center()
	if zone_count <= 3:
		var z_t := inverse_lerp(bounds.position.z, bounds.position.z + bounds.size.z, local_position.z)
		return clampi(int(floor(z_t * float(zone_count))), 0, zone_count - 1)
	if zone_count <= 5:
		if local_position.z > center.z + bounds.size.z * 0.2:
			return 0
		if local_position.z < center.z - bounds.size.z * 0.2:
			return 1
		if local_position.x < center.x:
			return 2
		return 3
	var z_t_full := inverse_lerp(bounds.position.z, bounds.position.z + bounds.size.z, local_position.z)
	var z_band := clampi(int(floor(z_t_full * 3.0)), 0, 2)
	var side := 0 if local_position.x < center.x else 1
	return clampi(z_band * 2 + side, 0, zone_count - 1)


func _get_forward_direction() -> Vector3:
	var forward := local_forward_axis
	if forward.length_squared() <= 0.0001:
		forward = Vector3.FORWARD
	return forward.normalized()


func _queue_debug_rebuild() -> void:
	if _debug_rebuild_queued:
		return
	_debug_rebuild_queued = true
	call_deferred(&"_rebuild_queued_debug_mesh")


func _rebuild_queued_debug_mesh() -> void:
	_debug_rebuild_queued = false
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
	_update_debug_materials()
	_update_debug_visibility()


func _update_debug_visibility() -> void:
	if _debug_mesh_instance != null:
		_debug_mesh_instance.visible = debug_draw


func _update_debug_materials() -> void:
	if _cell_material == null:
		_cell_material = _create_debug_material(DEFAULT_CELL_COLOR)
	if _waterline_material == null:
		_waterline_material = _create_debug_material(WATERLINE_CELL_COLOR)
	if _buoyancy_force_material == null:
		_buoyancy_force_material = _create_debug_material(BUOYANCY_FORCE_COLOR)
	if _total_force_material == null:
		_total_force_material = _create_debug_material(TOTAL_FORCE_COLOR)
	if _body_gravity_material == null:
		_body_gravity_material = _create_debug_material(BODY_GRAVITY_COLOR)
	if _body_net_force_material == null:
		_body_net_force_material = _create_debug_material(BODY_NET_FORCE_COLOR)
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
	_ensure_debug_nodes()
	_debug_mesh.clear_surfaces()
	if not debug_draw:
		return
	_update_debug_materials()

	if _has_debug_cells():
		var drawn := 0
		_begin_debug_lines()
		for i in cells.size():
			var cell := cells[i] as BuoyancyCell
			if cell == null:
				continue
			if drawn >= debug_max_cells:
				break
			_add_cell_box(cell)
			drawn += 1
		_commit_debug_lines(_cell_material)

	if _has_debug_sample_lines():
		_begin_debug_lines()
		_add_debug_water_lines()
		_commit_debug_lines(_waterline_material)

	if _has_debug_sample_lines() and _has_debug_buoyancy_forces():
		_begin_debug_lines()
		_add_debug_buoyancy_force_lines()
		_commit_debug_lines(_buoyancy_force_material)

	if _has_debug_sample_lines() and _has_debug_total_forces():
		_begin_debug_lines()
		_add_debug_total_force_lines()
		_commit_debug_lines(_total_force_material)

	if _has_debug_body_state():
		_begin_debug_lines()
		_add_debug_center_of_mass()
		_commit_debug_lines(_center_of_mass_material)

	if _has_debug_body_state():
		_begin_debug_lines()
		_add_debug_body_gravity()
		_commit_debug_lines(_body_gravity_material)

	if _has_debug_body_state():
		_begin_debug_lines()
		_add_debug_body_net_force()
		_commit_debug_lines(_body_net_force_material)


func _begin_debug_lines() -> void:
	_debug_line_vertices.clear()


func _add_debug_vertex(vertex: Vector3) -> void:
	_debug_line_vertices.push_back(vertex)


func _commit_debug_lines(material: Material) -> void:
	if _debug_line_vertices.is_empty():
		return
	if _debug_line_vertices.size() % 2 != 0:
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


func _has_debug_cells() -> bool:
	for i in cells.size():
		var cell := cells[i] as BuoyancyCell
		if cell != null:
			return true
	return false


func _add_cell_box(cell: Resource) -> void:
	var half : Vector3 = cell.size * 0.5
	var p : Vector3 = cell.local_center
	var corners := [
		p + Vector3(-half.x, -half.y, -half.z),
		p + Vector3( half.x, -half.y, -half.z),
		p + Vector3( half.x,  half.y, -half.z),
		p + Vector3(-half.x,  half.y, -half.z),
		p + Vector3(-half.x, -half.y,  half.z),
		p + Vector3( half.x, -half.y,  half.z),
		p + Vector3( half.x,  half.y,  half.z),
		p + Vector3(-half.x,  half.y,  half.z),
	]
	var edges := [
		0, 1, 1, 2, 2, 3, 3, 0,
		4, 5, 5, 6, 6, 7, 7, 4,
		0, 4, 1, 5, 2, 6, 3, 7,
	]
	for i in range(0, edges.size(), 2):
		_add_debug_vertex(corners[edges[i]])
		_add_debug_vertex(corners[edges[i + 1]])


func _has_debug_sample_lines() -> bool:
	for sample_state in _debug_sample_states:
		if sample_state is Dictionary and not sample_state.is_empty() and bool(sample_state.get("has_sample", false)):
			return true
	return false


func _has_debug_buoyancy_forces() -> bool:
	for sample_state in _debug_sample_states:
		if not (sample_state is Dictionary):
			continue
		if sample_state.is_empty() or not bool(sample_state.get("has_sample", false)):
			continue
		if float(sample_state.get("submersion", 0.0)) > 0.0 and Vector3(sample_state.get("buoyancy_force", Vector3.ZERO)).length_squared() > 0.0001:
			return true
	return false


func _has_debug_total_forces() -> bool:
	for sample_state in _debug_sample_states:
		if not (sample_state is Dictionary):
			continue
		if sample_state.is_empty() or not bool(sample_state.get("has_sample", false)):
			continue
		if float(sample_state.get("submersion", 0.0)) > 0.0 and Vector3(sample_state.get("force", Vector3.ZERO)).length_squared() > 0.0001:
			return true
	return false


func _add_debug_water_lines() -> void:
	for sample_state in _debug_sample_states:
		if not (sample_state is Dictionary):
			continue
		if sample_state.is_empty() or not bool(sample_state.get("has_sample", false)):
			continue
		var sample_position : Vector3 = sample_state["sample_position"]
		var water_position : Vector3 = sample_state["water_position"]
		_add_debug_vertex(to_local(sample_position))
		_add_debug_vertex(to_local(water_position))


func _add_debug_buoyancy_force_lines() -> void:
	for sample_state in _debug_sample_states:
		if not (sample_state is Dictionary):
			continue
		if sample_state.is_empty() or not bool(sample_state.get("has_sample", false)):
			continue
		var submersion := float(sample_state.get("submersion", 0.0))
		if submersion <= 0.0:
			continue
		var sample_position : Vector3 = sample_state["sample_position"]
		var buoyancy_force : Vector3 = sample_state.get("buoyancy_force", Vector3.ZERO)
		_add_debug_arrow(sample_position, buoyancy_force, debug_force_scale)


func _add_debug_total_force_lines() -> void:
	for sample_state in _debug_sample_states:
		if not (sample_state is Dictionary):
			continue
		if sample_state.is_empty() or not bool(sample_state.get("has_sample", false)):
			continue
		var submersion := float(sample_state.get("submersion", 0.0))
		if submersion <= 0.0:
			continue
		var sample_position : Vector3 = sample_state["sample_position"]
		var force : Vector3 = sample_state["force"]
		_add_debug_arrow(sample_position, force, debug_force_scale)


func _has_debug_body_state() -> bool:
	return _debug_body_state is Dictionary and not _debug_body_state.is_empty() and bool(_debug_body_state.get("has_state", false))


func _add_debug_center_of_mass() -> void:
	var center_world : Vector3 = _debug_body_state["center_of_mass_world"]
	var center := to_local(center_world)
	var size := debug_center_of_mass_size
	_add_debug_vertex(center + Vector3.LEFT * size)
	_add_debug_vertex(center + Vector3.RIGHT * size)
	_add_debug_vertex(center + Vector3.DOWN * size)
	_add_debug_vertex(center + Vector3.UP * size)
	_add_debug_vertex(center + Vector3.FORWARD * size)
	_add_debug_vertex(center + Vector3.BACK * size)


func _add_debug_body_gravity() -> void:
	var center_world : Vector3 = _debug_body_state["center_of_mass_world"]
	var gravity_force : Vector3 = _debug_body_state["gravity_force"]
	_add_debug_arrow(center_world, gravity_force, debug_body_force_scale)


func _add_debug_body_net_force() -> void:
	var center_world : Vector3 = _debug_body_state["center_of_mass_world"]
	var external_force : Vector3 = _debug_body_state["external_force"]
	_add_debug_arrow(center_world, external_force, debug_body_force_scale)


func _add_debug_arrow(start_world: Vector3, force: Vector3, scale: float) -> void:
	if force.length_squared() <= 0.0001:
		return
	var start_local := to_local(start_world)
	var end_local := to_local(start_world + force * scale)
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
