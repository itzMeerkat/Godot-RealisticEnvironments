class_name GREWindSource
extends RefCounted
## The wind contract: how systems read a wind provider (GREWindSystem, or any node of
## yours) without depending on its type.
##
## A wind source is any node with get_wind_speed() (m/s) and
## get_wind_direction_degrees() (the direction the wind blows toward: 0 along +Z, 90
## along +X), or with wind_speed and wind_direction properties. Methods win over
## properties, so a source can add gusts to its speed.


## Whether node provides both values.
static func is_valid(node : Node) -> bool:
	return node != null and _has_value(node, &"get_wind_speed", &"wind_speed") and _has_value(node, &"get_wind_direction_degrees", &"wind_direction")


## Wind speed (m/s) of a valid source.
static func get_speed(node : Node) -> float:
	return _read(node, &"get_wind_speed", &"wind_speed")


## Direction (degrees, 0 = +Z, 90 = +X) the wind of a valid source blows toward.
static func get_direction(node : Node) -> float:
	return _read(node, &"get_wind_direction_degrees", &"wind_direction")


## Wind velocity (m/s) in the XZ plane, as (x, z).
static func get_velocity(node : Node) -> Vector2:
	return direction_to_vector(get_direction(node)) * get_speed(node)


## Unit (x, z) vector of a direction in degrees (0 = +Z, 90 = +X).
static func direction_to_vector(degrees : float) -> Vector2:
	var radians := deg_to_rad(degrees)
	return Vector2(sin(radians), cos(radians))


static func _has_value(node : Node, method : StringName, property : StringName) -> bool:
	return node.has_method(method) or node.get(property) != null


static func _read(node : Node, method : StringName, property : StringName) -> float:
	if node.has_method(method):
		return float(node.call(method))
	return float(node.get(property))
