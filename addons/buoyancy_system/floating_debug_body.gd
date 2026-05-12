@tool
class_name FloatingDebugBody
extends RigidBody3D
## Debug helper for a floating rigid body. Enable auto_sync_debug_layout to
## drive collision, debug bounds, probes, and mass from one exported size.

@export var auto_sync_debug_layout := false :
	set(value):
		auto_sync_debug_layout = value
		if auto_sync_debug_layout:
			_apply_debug_size()

@export var box_size := Vector3(3.0, 1.0, 2.0) :
	set(value):
		box_size = Vector3(maxf(value.x, 0.05), maxf(value.y, 0.05), maxf(value.z, 0.05))
		if auto_sync_debug_layout:
			_apply_debug_size()

@export_range(0.0, 1.0, 0.01) var probe_inset_ratio := 0.18 :
	set(value):
		probe_inset_ratio = clampf(value, 0.0, 0.45)
		if auto_sync_debug_layout:
			_apply_debug_size()

@export_range(-2.0, 2.0, 0.01) var probe_height_above_center := 0.18 :
	set(value):
		probe_height_above_center = value
		if auto_sync_debug_layout:
			_apply_debug_size()

@export var auto_mass_from_size := true :
	set(value):
		auto_mass_from_size = value
		if auto_sync_debug_layout:
			_apply_debug_size()

@export_range(0.01, 1000.0, 0.01, "or_greater") var density := 4.0 :
	set(value):
		density = maxf(value, 0.01)
		if auto_sync_debug_layout:
			_apply_debug_size()

@export_group("Stability")
@export var use_custom_center_of_mass := true :
	set(value):
		use_custom_center_of_mass = value
		_apply_center_of_mass()
@export var custom_center_of_mass := Vector3(0.0, -1.0, -1.0) :
	set(value):
		custom_center_of_mass = value
		_apply_center_of_mass()

@export_group("Debug History")
@export var debug_draw_position_history := true :
	set(value):
		debug_draw_position_history = value
		_update_history_visibility()
@export_range(2, 2048, 1) var debug_history_max_points := 240 :
	set(value):
		debug_history_max_points = maxi(value, 2)
		_trim_history()
		_rebuild_history_mesh()
@export_range(0.01, 100.0, 0.01, "or_greater") var debug_history_min_distance := 0.2
@export var debug_history_color := Color(0.2, 1.0, 0.45, 1.0) :
	set(value):
		debug_history_color = value
		_update_history_material()

var _history_points := PackedVector3Array()
var _history_mesh_instance : MeshInstance3D
var _history_mesh := ImmediateMesh.new()
var _history_material : StandardMaterial3D


func _ready() -> void:
	_apply_center_of_mass()
	if auto_sync_debug_layout:
		_apply_debug_size()
	_ensure_history_nodes()


func _physics_process(_delta: float) -> void:
	if Engine.is_editor_hint() or not debug_draw_position_history:
		return
	_record_history_point()


func _notification(what: int) -> void:
	if auto_sync_debug_layout and what == NOTIFICATION_CHILD_ORDER_CHANGED:
		_apply_debug_size()


func _apply_debug_size() -> void:
	if not is_inside_tree():
		return

	var mesh_instance := get_node_or_null("Mesh") as MeshInstance3D
	if mesh_instance != null:
		var box_mesh := mesh_instance.mesh as BoxMesh
		if box_mesh == null:
			box_mesh = BoxMesh.new()
			mesh_instance.mesh = box_mesh
		box_mesh.size = box_size

	var collision := get_node_or_null("CollisionShape3D") as CollisionShape3D
	if collision != null:
		var box_shape := collision.shape as BoxShape3D
		if box_shape == null:
			box_shape = BoxShape3D.new()
			collision.shape = box_shape
		box_shape.size = box_size

	var bounds := get_node_or_null("DebugBounds") as BuoyancyDebugBounds
	if bounds != null:
		bounds.size = box_size + Vector3(0.08, 0.08, 0.08)

	_update_probe("ProbeFL", -1.0, -1.0)
	_update_probe("ProbeFR",  1.0, -1.0)
	_update_probe("ProbeBL", -1.0,  1.0)
	_update_probe("ProbeBR",  1.0,  1.0)

	if auto_mass_from_size:
		mass = maxf(box_size.x * box_size.y * box_size.z * density, 0.01)


func _apply_center_of_mass() -> void:
	if use_custom_center_of_mass:
		center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
		center_of_mass = custom_center_of_mass
	else:
		center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_AUTO


func _update_probe(name: StringName, x_sign: float, z_sign: float) -> void:
	var probe := get_node_or_null(NodePath(String(name))) as BuoyancyProbe
	if probe == null:
		return
	var half := box_size * 0.5
	var inset := Vector2(box_size.x, box_size.z) * probe_inset_ratio
	probe.position = Vector3(
		x_sign * maxf(half.x - inset.x, 0.0),
		probe_height_above_center,
		z_sign * maxf(half.z - inset.y, 0.0)
	)
	probe.submersion_depth = maxf(box_size.y * 1.4, 0.05)


func clear_position_history() -> void:
	_history_points.clear()
	_rebuild_history_mesh()


func _record_history_point() -> void:
	if _history_points.is_empty():
		_history_points.push_back(global_position)
		_rebuild_history_mesh()
		return
	if _history_points[_history_points.size() - 1].distance_to(global_position) < debug_history_min_distance:
		return
	_history_points.push_back(global_position)
	_trim_history()
	_rebuild_history_mesh()


func _trim_history() -> void:
	while _history_points.size() > debug_history_max_points:
		_history_points.remove_at(0)


func _ensure_history_nodes() -> void:
	if _history_mesh_instance != null and is_instance_valid(_history_mesh_instance):
		return
	_history_mesh_instance = get_node_or_null("PositionHistory") as MeshInstance3D
	if _history_mesh_instance == null:
		_history_mesh_instance = MeshInstance3D.new()
		_history_mesh_instance.name = "PositionHistory"
		add_child(_history_mesh_instance)
		_history_mesh_instance.owner = owner
	_history_mesh_instance.top_level = true
	_history_mesh_instance.global_transform = Transform3D.IDENTITY
	_history_mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_history_mesh_instance.extra_cull_margin = 10000.0
	_history_mesh_instance.mesh = _history_mesh
	_update_history_material()
	_update_history_visibility()


func _update_history_visibility() -> void:
	if _history_mesh_instance == null:
		return
	_history_mesh_instance.visible = debug_draw_position_history


func _update_history_material() -> void:
	if _history_material == null:
		_history_material = StandardMaterial3D.new()
		_history_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_history_material.no_depth_test = true
		_history_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_history_material.albedo_color = debug_history_color
	if _history_mesh_instance != null:
		_history_mesh_instance.material_override = _history_material


func _rebuild_history_mesh() -> void:
	if not is_inside_tree():
		return
	_ensure_history_nodes()
	_history_mesh.clear_surfaces()
	if _history_points.size() < 2:
		return
	_history_mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	for i in range(_history_points.size() - 1):
		_history_mesh.surface_add_vertex(_history_points[i])
		_history_mesh.surface_add_vertex(_history_points[i + 1])
	_history_mesh.surface_end()
	_update_history_material()
