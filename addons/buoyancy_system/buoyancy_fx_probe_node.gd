@tool
class_name BuoyancyFxProbeNode
extends MeshInstance3D
## Editable water-contact probe used for effects and events. It does not apply
## buoyancy forces.

signal probe_changed

const FX_PROBE_COLOR := Color(1.0, 0.62, 0.14, 0.38)
const DISABLED_FX_PROBE_COLOR := Color(0.25, 0.25, 0.25, 0.12)

@export var enabled := true :
	set(value):
		enabled = value
		_update_editor_visuals()
		_emit_probe_changed()

@export var tag := "side" :
	set(value):
		tag = value
		_emit_probe_changed()

@export_range(0.01, 10.0, 0.01, "or_greater") var display_radius := 0.12 :
	set(value):
		display_radius = maxf(value, 0.01)
		_update_editor_visuals()
		_emit_probe_changed()

@export_range(0.01, 20.0, 0.01, "or_greater") var trigger_radius := 0.25 :
	set(value):
		trigger_radius = maxf(value, 0.01)
		_emit_probe_changed()

@export_range(-10.0, 10.0, 0.001) var enter_depth_threshold := 0.03 :
	set(value):
		enter_depth_threshold = value
		_emit_probe_changed()

@export_range(-10.0, 10.0, 0.001) var exit_depth_threshold := -0.03 :
	set(value):
		exit_depth_threshold = value
		_emit_probe_changed()


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


func get_enter_depth_threshold(default_value: float) -> float:
	return enter_depth_threshold if enter_depth_threshold > exit_depth_threshold else default_value


func get_exit_depth_threshold(default_value: float) -> float:
	return exit_depth_threshold if enter_depth_threshold > exit_depth_threshold else default_value


func _update_editor_visuals() -> void:
	if not Engine.is_editor_hint():
		return
	if mesh == null or not (mesh is SphereMesh):
		mesh = SphereMesh.new()
	var sphere := mesh as SphereMesh
	sphere.radius = display_radius
	sphere.height = display_radius * 2.0
	var material := material_override as StandardMaterial3D
	if material == null:
		material = StandardMaterial3D.new()
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		material.no_depth_test = true
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.albedo_color = FX_PROBE_COLOR if enabled else DISABLED_FX_PROBE_COLOR
	material_override = material


func _emit_probe_changed() -> void:
	if is_inside_tree():
		probe_changed.emit()
