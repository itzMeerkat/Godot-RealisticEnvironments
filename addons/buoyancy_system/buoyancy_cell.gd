@tool
class_name BuoyancyCell
extends Resource
## One editable voxel-like buoyancy cell.

@export var enabled := true :
	set(value):
		enabled = value
		emit_changed()

@export var local_center := Vector3.ZERO :
	set(value):
		local_center = value
		emit_changed()

@export var size := Vector3.ONE :
	set(value):
		size = value.max(Vector3(0.001, 0.001, 0.001))
		emit_changed()

@export_range(0.0, 20000.0, 1.0, "or_greater") var density := 450.0 :
	set(value):
		density = maxf(value, 0.0)
		emit_changed()

@export_range(0.0, 1.0, 0.01) var buoyancy_efficiency := 1.0 :
	set(value):
		buoyancy_efficiency = clampf(value, 0.0, 1.0)
		emit_changed()

@export_range(0.0, 1.0, 0.01) var flooding_fraction := 0.0 :
	set(value):
		flooding_fraction = clampf(value, 0.0, 1.0)
		emit_changed()

@export_range(0.0, 100.0, 0.01, "or_greater") var vertical_damping_multiplier := 1.0 :
	set(value):
		vertical_damping_multiplier = maxf(value, 0.0)
		emit_changed()

@export_range(0.0, 100.0, 0.01, "or_greater") var longitudinal_water_drag_multiplier := 1.0 :
	set(value):
		longitudinal_water_drag_multiplier = maxf(value, 0.0)
		emit_changed()

@export_range(0.0, 100.0, 0.01, "or_greater") var lateral_water_drag_multiplier := 1.0 :
	set(value):
		lateral_water_drag_multiplier = maxf(value, 0.0)
		emit_changed()


func get_volume() -> float:
	return maxf(size.x, 0.0) * maxf(size.y, 0.0) * maxf(size.z, 0.0)


func get_mass() -> float:
	return density * get_volume() if enabled else 0.0
