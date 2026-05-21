@tool
class_name FloatingDebugBody
extends RigidBody3D
## Demo helper for a floating rigid body. It keeps stability settings and draws
## a simple world-space position trail.

@export_group("Control")
@export var player_controlled := false :
	set(value):
		player_controlled = value
		_apply_player_controlled_state()

@export_group("Debug History")
@export var debug_draw_position_history := true :
	set(value):
		debug_draw_position_history = value
		_update_history_visibility()
@export var sync_child_buoyancy_debug_with_player_control := false :
	set(value):
		sync_child_buoyancy_debug_with_player_control = value
		_apply_player_controlled_state()
@export var sync_child_water_cutout_with_player_control := false :
	set(value):
		sync_child_water_cutout_with_player_control = value
		_apply_player_controlled_state()
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


func _enter_tree() -> void:
	_apply_player_controlled_state()


func _ready() -> void:
	_ensure_history_nodes()
	_apply_player_controlled_state()


func _physics_process(_delta: float) -> void:
	if Engine.is_editor_hint() or not player_controlled or not debug_draw_position_history:
		return
	_record_history_point()


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
	_history_mesh_instance.visible = player_controlled and debug_draw_position_history


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


func _apply_player_controlled_state() -> void:
	_update_history_visibility()

	if not is_inside_tree():
		return

	for child in _find_descendants():
		var cell_volume := child as Node
		if cell_volume == null or not cell_volume.has_method(&"get_buoyancy_sample_points"):
			continue
		if sync_child_buoyancy_debug_with_player_control:
			cell_volume.set(&"debug_draw", player_controlled)

	for child in _find_descendants():
		var cutout := child as WaterHullCutout
		if cutout == null:
			continue
		if sync_child_water_cutout_with_player_control:
			cutout.enabled = player_controlled

	for child in _find_descendants():
		if not child.is_in_group(&"water_cutout_provider"):
			continue
		if sync_child_water_cutout_with_player_control:
			child.set(&"enabled", player_controlled)

	for child in _find_descendants():
		if child.is_in_group(&"boat_controller"):
			child.set(&"enabled", player_controlled)
		if child.is_in_group(&"boat_water_interactor"):
			child.set(&"enabled", player_controlled)
		if child.is_in_group(&"boat_wake_trail"):
			child.set(&"enabled", player_controlled)


func _find_descendants() -> Array[Node]:
	var descendants : Array[Node] = []
	for child in get_children():
		var child_node := child as Node
		if child_node == null:
			continue
		descendants.push_back(child_node)
		descendants.append_array(_find_descendants_for(child_node))
	return descendants


func _find_descendants_for(root: Node) -> Array[Node]:
	var descendants : Array[Node] = []
	for child in root.get_children():
		var child_node := child as Node
		if child_node == null:
			continue
		descendants.push_back(child_node)
		descendants.append_array(_find_descendants_for(child_node))
	return descendants
