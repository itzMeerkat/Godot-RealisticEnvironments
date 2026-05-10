@tool
class_name WindSystem
extends Node
## Lightweight wind provider that can be used by ocean, particles, clouds,
## boats, or gameplay code without depending on any other plugin.

signal wind_changed

@export_group("Wind")
## Base wind speed in meters per second. Gusts are added on top when enabled.
@export_range(0.0, 100.0, 0.1, "or_greater") var wind_speed := 10.0 :
	set(value):
		wind_speed = maxf(0.0, value)
		wind_changed.emit()

## Compass-like wind heading in degrees. 0 points along +Z; 90 points along +X.
@export_range(-360.0, 360.0, 1.0) var wind_direction := 20.0 :
	set(value):
		wind_direction = value
		wind_changed.emit()

@export_group("Gusts")
## Maximum additional gust speed in meters per second. Set to 0 for steady wind.
@export_range(0.0, 100.0, 0.1, "or_greater") var gust_strength := 0.0 :
	set(value):
		gust_strength = maxf(0.0, value)
		wind_changed.emit()

## Gust cycles per second. Higher values make wind speed change faster.
@export_range(0.0, 10.0, 0.01, "or_greater") var gust_frequency := 0.1 :
	set(value):
		gust_frequency = maxf(0.0, value)
		wind_changed.emit()

var _elapsed_time := 0.0


func _process(delta : float) -> void:
	if Engine.is_editor_hint():
		return
	_elapsed_time += delta


func get_wind_speed() -> float:
	return maxf(0.0, wind_speed + get_gust_offset())


func get_base_wind_speed() -> float:
	return wind_speed


func get_gust_offset() -> float:
	if gust_strength <= 0.0 or gust_frequency <= 0.0:
		return 0.0
	var phase := _elapsed_time * gust_frequency * TAU
	var layered_gust := (
		sin(phase) * 0.55
		+ sin(phase * 2.17 + 1.7) * 0.30
		+ sin(phase * 0.41 + 3.1) * 0.15
	)
	return layered_gust * gust_strength


func get_wind_direction_degrees() -> float:
	return wind_direction


func get_wind_direction_radians() -> float:
	return deg_to_rad(wind_direction)


func get_wind_vector_2d() -> Vector2:
	var radians := get_wind_direction_radians()
	return Vector2(sin(radians), cos(radians)) * get_wind_speed()


func get_wind_vector_3d() -> Vector3:
	var wind := get_wind_vector_2d()
	return Vector3(wind.x, 0.0, wind.y)
