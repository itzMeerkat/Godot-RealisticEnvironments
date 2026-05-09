@tool
class_name WindSystem
extends Node

signal wind_changed

@export var wind_speed := 10.0 :
	set(value):
		wind_speed = maxf(0.0, value)
		wind_changed.emit()

@export_range(-360.0, 360.0, 1.0) var wind_direction := 20.0 :
	set(value):
		wind_direction = value
		wind_changed.emit()

@export var gust_strength := 0.0 :
	set(value):
		gust_strength = maxf(0.0, value)
		wind_changed.emit()

@export var gust_frequency := 0.1 :
	set(value):
		gust_frequency = maxf(0.0, value)
		wind_changed.emit()


func get_wind_speed() -> float:
	return wind_speed


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
