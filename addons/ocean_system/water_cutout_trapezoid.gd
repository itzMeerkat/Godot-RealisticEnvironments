@tool
class_name WaterCutoutTrapezoid
extends MeshInstance3D
## Editable top-view trapezoid water cutout segment.

const DEBUG_COLOR := Color(0.2, 0.7, 1.0, 0.9)

## Enables this trapezoid cutout. Disabled cutouts stay editable and visible in
## debug mode but are not submitted to the ocean shader.
@export var enabled := true :
	set(value):
		enabled = value

## Half of the trapezoid length along local Z, in meters. Increase this to cover
## more of the hull length; decrease it if water disappears beyond the hull.
@export_range(0.01, 100.0, 0.01, "or_greater") var half_length := 1.0 :
	set(value):
		half_length = maxf(value, 0.01)
		_rebuild_mesh()

## Half width at the local -Z end of the trapezoid, in meters. This is usually
## one end of the hull segment, such as bow-side or stern-side width.
@export_range(0.01, 100.0, 0.01, "or_greater") var start_half_width := 1.0 :
	set(value):
		start_half_width = maxf(value, 0.01)
		_rebuild_mesh()

## Half width at the local +Z end of the trapezoid, in meters. Use different
## start/end widths to approximate a tapering hull instead of a rectangle.
@export_range(0.01, 100.0, 0.01, "or_greater") var end_half_width := 1.0 :
	set(value):
		end_half_width = maxf(value, 0.01)
		_rebuild_mesh()

## Lower height boundary relative to this cutout's origin. Water below this
## boundary fades back in, which helps when the hull lifts partly out of water.
@export_range(-20.0, 20.0, 0.01) var vertical_min_offset := -1.0 :
	set(value):
		vertical_min_offset = value
		_rebuild_mesh()

## Upper height boundary relative to this cutout's origin. Water above this
## boundary fades back in so tall waves are not hidden too far up the hull.
@export_range(-20.0, 20.0, 0.01) var vertical_max_offset := 0.35 :
	set(value):
		vertical_max_offset = value
		_rebuild_mesh()

## Vertical soft edge distance for both min and max height boundaries. Larger
## values hide hard transitions but can mask more water around the hull.
@export_range(0.001, 10.0, 0.01, "or_greater") var height_feather := 0.35 :
	set(value):
		height_feather = maxf(value, 0.001)

## Horizontal feather width in meters around the trapezoid outline. This does
## not change the discarded area, but controls how much edge foam blends over it.
@export_range(0.0, 4.0, 0.01, "or_greater") var feather := 0.85 :
	set(value):
		feather = maxf(value, 0.0)

## Foam amount added at the cutout edge. Higher values hide the boundary better;
## lower values keep the hull-water contact cleaner and less white.
@export_range(0.0, 1.0, 0.01) var foam_amount := 0.75 :
	set(value):
		foam_amount = clampf(value, 0.0, 1.0)

## Shows the editable cutout wireframe in the editor. The wireframe is only a
## helper mesh and is not rendered as water.
@export var debug_draw := true :
	set(value):
		debug_draw = value
		_update_debug_visibility()

## Shows the helper wireframe at runtime. Leave off for gameplay and turn on
## only when tuning cutouts in a running scene.
@export var debug_draw_in_game := false :
	set(value):
		debug_draw_in_game = value
		_update_debug_visibility()

var _debug_mesh := ImmediateMesh.new()
var _debug_material : StandardMaterial3D


func _ready() -> void:
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	extra_cull_margin = 10000.0
	mesh = _debug_mesh
	_rebuild_mesh()
	_update_material()
	_update_debug_visibility()

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
