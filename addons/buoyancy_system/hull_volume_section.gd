@tool
class_name HullVolumeSection
extends Resource
## One editable cross-section of a HullVolume.
##
## The section lives in the HullVolume's local space at z_position. Points are
## local Vector2(x, y) coordinates around the section outline.

@export var z_position := 0.0 :
	set(value):
		z_position = value
		emit_changed()

@export var points := PackedVector2Array([
	Vector2(-1.0, 0.0),
	Vector2(-0.65, -0.9),
	Vector2(0.65, -0.9),
	Vector2(1.0, 0.0),
]) :
	set(value):
		points = value
		emit_changed()


func get_area() -> float:
	if points.size() < 3:
		return 0.0
	var signed_area := 0.0
	for i in points.size():
		var a := points[i]
		var b := points[(i + 1) % points.size()]
		signed_area += a.x * b.y - b.x * a.y
	return absf(signed_area) * 0.5


func get_bounds() -> Rect2:
	if points.is_empty():
		return Rect2(Vector2.ZERO, Vector2.ZERO)
	var min_point := points[0]
	var max_point := points[0]
	for point in points:
		min_point.x = minf(min_point.x, point.x)
		min_point.y = minf(min_point.y, point.y)
		max_point.x = maxf(max_point.x, point.x)
		max_point.y = maxf(max_point.y, point.y)
	return Rect2(min_point, max_point - min_point)


func get_half_width() -> float:
	var half_width := 0.0
	for point in points:
		half_width = maxf(half_width, absf(point.x))
	return half_width


func get_bottom_y() -> float:
	if points.is_empty():
		return 0.0
	var bottom := points[0].y
	for point in points:
		bottom = minf(bottom, point.y)
	return bottom


func get_top_y() -> float:
	if points.is_empty():
		return 0.0
	var top := points[0].y
	for point in points:
		top = maxf(top, point.y)
	return top
