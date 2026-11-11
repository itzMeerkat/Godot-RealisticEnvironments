@tool
class_name GREWindSystem
extends Node
## Wind provider for the ocean, the clouds and gameplay code: a base wind with
## optional procedural gusts. It is a wind source (the contract core's GREWindSource
## reads), so GREOceanSystem.wind_source_path and GRESkySystem.cloud_wind_source_path
## accept it. Depends on nothing.

## Emitted when an export changes (not on every gust).
signal wind_changed

@export_group("Wind")
## Base wind speed in meters per second. Gusts are added on top at runtime
## (get_wind_speed()).
@export_range(0.0, 100.0, 0.1, "or_greater") var wind_speed := 10.0 :
	set(value):
		wind_speed = maxf(0.0, value)
		wind_changed.emit()

## Direction the wind blows toward, in degrees: 0 along +Z, 90 along +X.
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


## Current wind speed (m/s): wind_speed plus the gust, never negative.
func get_wind_speed() -> float:
	return maxf(0.0, wind_speed + _get_gust())


## Direction the wind blows toward, in degrees: 0 along +Z, 90 along +X.
func get_wind_direction_degrees() -> float:
	return wind_direction


## Wind velocity in the XZ plane (x, z) in m/s, gusts included.
func get_wind_vector_2d() -> Vector2:
	var radians := deg_to_rad(wind_direction)
	return Vector2(sin(radians), cos(radians)) * get_wind_speed()


## Wind velocity as Vector3(x, 0, z) in m/s, gusts included.
func get_wind_vector_3d() -> Vector3:
	var wind := get_wind_vector_2d()
	return Vector3(wind.x, 0.0, wind.y)


## The gust added to wind_speed right now (m/s, may be negative).
func _get_gust() -> float:
	if gust_strength <= 0.0 or gust_frequency <= 0.0:
		return 0.0
	var phase := _elapsed_time * gust_frequency * TAU
	var layered_gust := (
		sin(phase) * 0.55
		+ sin(phase * 2.17 + 1.7) * 0.30
		+ sin(phase * 0.41 + 3.1) * 0.15
	)
	return layered_gust * gust_strength
