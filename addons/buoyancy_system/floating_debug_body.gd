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

@export_group("Angular Damping")
@export var local_angular_damping_enabled := false
## Per-mass torque damping in local axes: X = pitch, Y = yaw, Z = roll.
@export var local_angular_damping := Vector3.ZERO

@export_group("Righting Torque")
@export var roll_righting_torque_enabled := false
## Per-mass torque spring that rotates the body's local up axis back toward world up around its roll axis.
@export_range(0.0, 1000.0, 0.01, "or_greater") var roll_righting_torque_per_kg := 0.0
@export_range(0.0, 10000000.0, 1.0, "or_greater") var max_roll_righting_torque := 0.0
@export_range(0.0, 30.0, 0.1, "degrees") var roll_righting_dead_zone_degrees := 0.0

@export_group("Debug History")
@export var debug_draw_position_history := false :
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
	if Engine.is_editor_hint():
		return
	_apply_roll_righting_torque()
	_apply_local_angular_damping()
	if player_controlled and debug_draw_position_history:
		_record_history_point()


func _apply_local_angular_damping() -> void:
	if not local_angular_damping_enabled:
		return
	if local_angular_damping.length_squared() <= 0.0 or angular_velocity.length_squared() <= 0.0:
		return
	var basis := global_transform.basis.orthonormalized()
	var local_angular_velocity := basis.inverse() * angular_velocity
	var local_torque := Vector3(
		-local_angular_velocity.x * maxf(local_angular_damping.x, 0.0),
		-local_angular_velocity.y * maxf(local_angular_damping.y, 0.0),
		-local_angular_velocity.z * maxf(local_angular_damping.z, 0.0)
	) * mass
	apply_torque(basis * local_torque)


func _apply_roll_righting_torque() -> void:
	if not roll_righting_torque_enabled:
		return
	if roll_righting_torque_per_kg <= 0.0:
		return
	var basis := global_transform.basis.orthonormalized()
	var roll_axis := basis.z.normalized()
	var body_up := basis.y.normalized()
	if roll_axis.length_squared() <= 0.0001 or body_up.length_squared() <= 0.0001:
		return

	var target_up := Vector3.UP - roll_axis * Vector3.UP.dot(roll_axis)
	if target_up.length_squared() <= 0.0001:
		return
	target_up = target_up.normalized()

	var roll_error := body_up.signed_angle_to(target_up, roll_axis)
	var dead_zone := deg_to_rad(roll_righting_dead_zone_degrees)
	if absf(roll_error) <= dead_zone:
		return
	roll_error -= signf(roll_error) * dead_zone

	var torque := roll_axis * roll_error * roll_righting_torque_per_kg * mass
	if max_roll_righting_torque > 0.0 and torque.length_squared() > max_roll_righting_torque * max_roll_righting_torque:
		torque = torque.normalized() * max_roll_righting_torque
	apply_torque(torque)


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
		var probe_volume := child as Node
		if probe_volume == null or not probe_volume.has_method(&"get_buoyancy_sample_points"):
			continue
		if sync_child_buoyancy_debug_with_player_control:
			probe_volume.set(&"debug_draw", player_controlled)

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
