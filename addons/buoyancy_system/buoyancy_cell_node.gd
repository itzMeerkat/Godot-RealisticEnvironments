@tool
class_name BuoyancyCellNode
extends MeshInstance3D
## Editable buoyancy voxel. The node position is the cell's local center.

signal cell_changed

const CELL_COLOR := Color(0.1, 0.8, 1.0, 0.22)
const DISABLED_CELL_COLOR := Color(0.25, 0.25, 0.25, 0.12)

@export var enabled := true :
	set(value):
		enabled = value
		_update_material()
		_emit_cell_changed()

@export var size := Vector3.ONE :
	set(value):
		size = value.max(Vector3(0.001, 0.001, 0.001))
		_rebuild_mesh()
		_emit_cell_changed()

@export_range(0.0, 20000.0, 1.0, "or_greater") var density := 450.0 :
	set(value):
		density = maxf(value, 0.0)
		_emit_cell_changed()

@export_range(0.0, 1.0, 0.01) var buoyancy_efficiency := 1.0 :
	set(value):
		buoyancy_efficiency = clampf(value, 0.0, 1.0)
		_emit_cell_changed()

@export_range(0.0, 1.0, 0.01) var flooding_fraction := 0.0 :
	set(value):
		flooding_fraction = clampf(value, 0.0, 1.0)
		_emit_cell_changed()

@export_range(0.0, 100.0, 0.01, "or_greater") var vertical_damping_multiplier := 1.0 :
	set(value):
		vertical_damping_multiplier = maxf(value, 0.0)
		_emit_cell_changed()

@export_range(0.0, 100.0, 0.01, "or_greater") var longitudinal_water_drag_multiplier := 1.0 :
	set(value):
		longitudinal_water_drag_multiplier = maxf(value, 0.0)
		_emit_cell_changed()

@export_range(0.0, 100.0, 0.01, "or_greater") var lateral_water_drag_multiplier := 1.0 :
	set(value):
		lateral_water_drag_multiplier = maxf(value, 0.0)
		_emit_cell_changed()

var _material : StandardMaterial3D


func _ready() -> void:
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	extra_cull_margin = 10000.0
	set_notify_transform(true)
	_rebuild_mesh()
	_update_material()
	if not Engine.is_editor_hint():
		visible = false


func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSFORM_CHANGED:
		_emit_cell_changed()


func get_volume() -> float:
	return maxf(size.x, 0.0) * maxf(size.y, 0.0) * maxf(size.z, 0.0)


func get_mass() -> float:
	return density * get_volume() if enabled else 0.0


func _rebuild_mesh() -> void:
	var half := size * 0.5
	var corners := [
		Vector3(-half.x, -half.y, -half.z),
		Vector3( half.x, -half.y, -half.z),
		Vector3( half.x,  half.y, -half.z),
		Vector3(-half.x,  half.y, -half.z),
		Vector3(-half.x, -half.y,  half.z),
		Vector3( half.x, -half.y,  half.z),
		Vector3( half.x,  half.y,  half.z),
		Vector3(-half.x,  half.y,  half.z),
	]
	var edges := [
		0, 1, 1, 2, 2, 3, 3, 0,
		4, 5, 5, 6, 6, 7, 7, 4,
		0, 4, 1, 5, 2, 6, 3, 7,
	]
	var immediate := ImmediateMesh.new()
	immediate.surface_begin(Mesh.PRIMITIVE_LINES)
	for i in range(0, edges.size(), 2):
		immediate.surface_add_vertex(corners[edges[i]])
		immediate.surface_add_vertex(corners[edges[i + 1]])
	immediate.surface_end()
	mesh = immediate


func _update_material() -> void:
	if _material == null:
		_material = StandardMaterial3D.new()
		_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_material.no_depth_test = true
		_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_material.albedo_color = CELL_COLOR if enabled else DISABLED_CELL_COLOR
	material_override = _material


func _emit_cell_changed() -> void:
	if is_inside_tree():
		cell_changed.emit()
