@tool
class_name CurrentSystem
extends Node
## Lightweight ocean-current provider. Currents are intentionally independent
## from wind and wave direction; callers should treat this as horizontal water
## motion, not weather.

signal current_changed

@export_group("Current")
## Current speed in meters per second.
@export_range(0.0, 100.0, 0.01, "or_greater") var current_speed := 0.0 :
	set(value):
		current_speed = maxf(0.0, value)
		current_changed.emit()

## Compass-like current heading in degrees. 0 points along +Z; 90 points along +X.
@export_range(-360.0, 360.0, 1.0) var current_direction := 0.0 :
	set(value):
		current_direction = value
		current_changed.emit()


func get_current_speed(_world_position := Vector3.ZERO) -> float:
	return current_speed


func get_current_direction_degrees(_world_position := Vector3.ZERO) -> float:
	return current_direction


func get_current_direction_radians(world_position := Vector3.ZERO) -> float:
	return deg_to_rad(get_current_direction_degrees(world_position))


func get_current_vector_2d(world_position := Vector3.ZERO) -> Vector2:
	var radians := get_current_direction_radians(world_position)
	return Vector2(sin(radians), cos(radians)) * get_current_speed(world_position)


func get_current_vector_3d(world_position := Vector3.ZERO) -> Vector3:
	var current := get_current_vector_2d(world_position)
	return Vector3(current.x, 0.0, current.y)
