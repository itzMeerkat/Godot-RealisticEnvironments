@tool
class_name BuoyancyProbe
extends Marker3D
## A manually placed buoyancy sample point. Add these under a RigidBody3D and
## position them around the hull/bottom volume that should interact with water.

@export_range(0.0, 1000.0, 0.01, "or_greater") var volume_cubic_meters := 1.0
@export_range(0.0, 1.0, 0.01) var buoyancy_efficiency := 1.0
@export_range(0.0, 1.0, 0.01) var flooding_fraction := 0.0
@export_range(0.0, 100.0, 0.01, "or_greater") var buoyancy_weight := 1.0
@export_range(0.01, 100.0, 0.01, "or_greater") var submersion_depth := 1.0
@export_range(0.0, 100.0, 0.01, "or_greater") var vertical_damping := 2.0
@export_range(0.0, 100.0, 0.01, "or_greater") var water_drag := 1.0
@export_range(0.0, 100.0, 0.01, "or_greater") var current_drag := 1.0
@export var enabled := true

@export_group("Debug Draw")
@export var debug_draw := true :
	set(value):
		debug_draw = value
		_update_debug_visibility()
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
var _debug_water_material : StandardMaterial3D
var _debug_force_material : StandardMaterial3D
var _debug_water_position := Vector3.ZERO
var _debug_force := Vector3.ZERO
var _has_debug_sample := false


func _ready() -> void:
	_ensure_debug_nodes()
	_rebuild_debug_mesh()


func set_debug_state(water_position: Vector3, force: Vector3, has_sample: bool) -> void:
	_debug_water_position = water_position
	_debug_force = force
	_has_debug_sample = has_sample
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
	if _debug_mesh_instance == null:
		return
	_debug_mesh_instance.visible = debug_draw


func _update_debug_material() -> void:
	if _debug_water_material == null:
		_debug_water_material = _create_debug_material(debug_water_line_color)
	if _debug_force_material == null:
		_debug_force_material = _create_debug_material(debug_force_color)
	_debug_water_material.albedo_color = debug_water_line_color
	_debug_force_material.albedo_color = debug_force_color
	if _debug_mesh_instance != null:
		if _debug_mesh.get_surface_count() > 0:
			_debug_mesh_instance.set_surface_override_material(0, _debug_water_material)
		if _debug_mesh.get_surface_count() > 1:
			_debug_mesh_instance.set_surface_override_material(1, _debug_force_material)


func _create_debug_material(color: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = color
	material.no_depth_test = true
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	return material


func _rebuild_debug_mesh() -> void:
	if not is_inside_tree():
		return
	if not debug_draw:
		return
	_ensure_debug_nodes()
	_debug_mesh.clear_surfaces()
	if not _has_debug_sample:
		return

	var water_local := to_local(_debug_water_position)
	var force_local := to_local(global_position + _debug_force * debug_force_scale)

	_debug_mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	_debug_mesh.surface_add_vertex(Vector3.ZERO)
	_debug_mesh.surface_add_vertex(water_local)
	_debug_mesh.surface_end()

	_debug_mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	_debug_mesh.surface_add_vertex(Vector3.ZERO)
	_debug_mesh.surface_add_vertex(force_local)
	_add_arrowhead(force_local)
	_debug_mesh.surface_end()
	_update_debug_material()


func _add_arrowhead(force_local: Vector3) -> void:
	if force_local.length_squared() <= 0.0001:
		return
	var direction := force_local.normalized()
	var side := direction.cross(Vector3.UP)
	if side.length_squared() <= 0.0001:
		side = direction.cross(Vector3.RIGHT)
	side = side.normalized()
	var up := side.cross(direction).normalized()
	var length := minf(force_local.length() * 0.22, 0.45)
	var width := length * 0.45
	var base := force_local - direction * length
	_debug_mesh.surface_add_vertex(force_local)
	_debug_mesh.surface_add_vertex(base + side * width)
	_debug_mesh.surface_add_vertex(force_local)
	_debug_mesh.surface_add_vertex(base - side * width)
	_debug_mesh.surface_add_vertex(force_local)
	_debug_mesh.surface_add_vertex(base + up * width)
	_debug_mesh.surface_add_vertex(force_local)
	_debug_mesh.surface_add_vertex(base - up * width)
