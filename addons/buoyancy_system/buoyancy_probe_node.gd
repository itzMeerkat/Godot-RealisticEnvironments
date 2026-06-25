@tool
class_name BuoyancyProbeNode
extends MeshInstance3D
## Editable point buoyancy probe. The node position is the top of the buoyant
## water column represented by this probe.

signal probe_changed

const PROBE_COLOR := Color(0.1, 0.8, 1.0, 0.32)
const DISABLED_PROBE_COLOR := Color(0.25, 0.25, 0.25, 0.12)
const EDITOR_PROBE_RADIUS := 0.16

## Enables this physical probe for buoyancy force sampling.
@export var enabled := true :
	set(value):
		enabled = value
		_update_editor_visuals()
		_emit_probe_changed()

## Displaced water volume represented by this probe when fully submerged, in cubic meters.
@export_range(0.001, 100000.0, 0.001, "or_greater") var max_submerged_volume_cubic_meters := 1.0 :
	set(value):
		max_submerged_volume_cubic_meters = maxf(value, 0.001)
		_emit_probe_changed()

## Vertical distance over which this probe ramps from dry to fully submerged.
@export_range(0.001, 100.0, 0.001, "or_greater") var buoyancy_height := 1.0 :
	set(value):
		buoyancy_height = maxf(value, 0.001)
		_emit_probe_changed()

## Multiplies body-forward/back water drag applied at this probe.
@export_range(0.0, 100.0, 0.01, "or_greater") var longitudinal_water_drag_multiplier := 1.0 :
	set(value):
		longitudinal_water_drag_multiplier = maxf(value, 0.0)
		_emit_probe_changed()

## Multiplies body-sideways water drag applied at this probe.
@export_range(0.0, 100.0, 0.01, "or_greater") var lateral_water_drag_multiplier := 1.0 :
	set(value):
		lateral_water_drag_multiplier = maxf(value, 0.0)
		_emit_probe_changed()

var _material : StandardMaterial3D


func _ready() -> void:
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	set_notify_transform(false)
	set_notify_local_transform(Engine.is_editor_hint())
	if Engine.is_editor_hint():
		extra_cull_margin = 10000.0
		_update_editor_visuals()
	else:
		visible = false
		mesh = null
		material_override = null


func _notification(what: int) -> void:
	if Engine.is_editor_hint() and what == NOTIFICATION_LOCAL_TRANSFORM_CHANGED:
		_emit_probe_changed()


func get_max_submerged_volume() -> float:
	return max_submerged_volume_cubic_meters


func get_buoyancy_height() -> float:
	return buoyancy_height


func _update_editor_visuals() -> void:
	if not Engine.is_editor_hint():
		return
	if mesh == null or not (mesh is SphereMesh):
		mesh = SphereMesh.new()
	var sphere := mesh as SphereMesh
	sphere.radius = EDITOR_PROBE_RADIUS
	sphere.height = EDITOR_PROBE_RADIUS * 2.0
	if _material == null:
		_material = StandardMaterial3D.new()
		_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_material.no_depth_test = true
		_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_material.albedo_color = PROBE_COLOR if enabled else DISABLED_PROBE_COLOR
	material_override = _material


func _emit_probe_changed() -> void:
	if is_inside_tree():
		probe_changed.emit()
