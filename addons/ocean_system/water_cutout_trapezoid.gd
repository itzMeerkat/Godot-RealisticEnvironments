@tool
class_name WaterCutoutTrapezoid
extends MeshInstance3D
## Editable top-view trapezoid water cutout segment.

signal cutout_changed

const DEBUG_COLOR := Color(0.2, 0.7, 1.0, 0.9)

@export var enabled := true :
	set(value):
		enabled = value
		_emit_cutout_changed()

@export_range(0.01, 100.0, 0.01, "or_greater") var half_length := 1.0 :
	set(value):
		half_length = maxf(value, 0.01)
		_rebuild_mesh()
		_emit_cutout_changed()

@export_range(0.01, 100.0, 0.01, "or_greater") var start_half_width := 1.0 :
	set(value):
		start_half_width = maxf(value, 0.01)
		_rebuild_mesh()
		_emit_cutout_changed()

@export_range(0.01, 100.0, 0.01, "or_greater") var end_half_width := 1.0 :
	set(value):
		end_half_width = maxf(value, 0.01)
		_rebuild_mesh()
		_emit_cutout_changed()

@export_range(-20.0, 20.0, 0.01) var vertical_min_offset := -1.0 :
	set(value):
		vertical_min_offset = value
		_rebuild_mesh()
		_emit_cutout_changed()

@export_range(-20.0, 20.0, 0.01) var vertical_max_offset := 0.35 :
	set(value):
		vertical_max_offset = value
		_rebuild_mesh()
		_emit_cutout_changed()

@export_range(0.001, 10.0, 0.01, "or_greater") var height_feather := 0.35 :
	set(value):
		height_feather = maxf(value, 0.001)
		_emit_cutout_changed()

@export_range(0.0, 4.0, 0.01, "or_greater") var feather := 0.85 :
	set(value):
		feather = maxf(value, 0.0)
		_emit_cutout_changed()

@export_range(0.0, 1.0, 0.01) var foam_amount := 0.75 :
	set(value):
		foam_amount = clampf(value, 0.0, 1.0)
		_emit_cutout_changed()

@export var debug_draw := true :
	set(value):
		debug_draw = value
		_update_debug_visibility()

@export var debug_draw_in_game := false :
	set(value):
		debug_draw_in_game = value
		_update_debug_visibility()

var _debug_mesh := ImmediateMesh.new()
var _debug_material : StandardMaterial3D


func _ready() -> void:
	set_notify_transform(true)
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	extra_cull_margin = 10000.0
	mesh = _debug_mesh
	_rebuild_mesh()
	_update_material()
	_update_debug_visibility()


func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSFORM_CHANGED:
		_emit_cutout_changed()


func get_exclusion_segment() -> Dictionary:
	return {
		"center": global_position,
		"right": global_transform.basis.x.normalized(),
		"forward": global_transform.basis.z.normalized(),
		"half_extents": Vector2(maxf(start_half_width, end_half_width), half_length),
		"half_widths": Vector2(start_half_width, end_half_width),
		"min_y": global_position.y + vertical_min_offset,
		"max_y": global_position.y + vertical_max_offset,
		"height_feather": height_feather,
		"feather": feather,
		"foam_amount": foam_amount,
	}


func _rebuild_mesh() -> void:
	_debug_mesh.clear_surfaces()
	_debug_mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	var corners := [
		Vector3(-start_half_width, vertical_min_offset, -half_length),
		Vector3( start_half_width, vertical_min_offset, -half_length),
		Vector3(-end_half_width, vertical_min_offset, half_length),
		Vector3( end_half_width, vertical_min_offset, half_length),
		Vector3(-start_half_width, vertical_max_offset, -half_length),
		Vector3( start_half_width, vertical_max_offset, -half_length),
		Vector3(-end_half_width, vertical_max_offset, half_length),
		Vector3( end_half_width, vertical_max_offset, half_length),
	]
	var edges := [
		0, 1, 1, 3, 3, 2, 2, 0,
		4, 5, 5, 7, 7, 6, 6, 4,
		0, 4, 1, 5, 2, 6, 3, 7,
	]
	for i in range(0, edges.size(), 2):
		_debug_mesh.surface_add_vertex(corners[edges[i]])
		_debug_mesh.surface_add_vertex(corners[edges[i + 1]])
	_debug_mesh.surface_end()
	_update_material()


func _update_material() -> void:
	if _debug_material == null:
		_debug_material = StandardMaterial3D.new()
		_debug_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_debug_material.no_depth_test = true
		_debug_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_debug_material.albedo_color = DEBUG_COLOR
	material_override = _debug_material


func _update_debug_visibility() -> void:
	visible = debug_draw and (Engine.is_editor_hint() or debug_draw_in_game)


func _emit_cutout_changed() -> void:
	if is_inside_tree():
		cutout_changed.emit()
