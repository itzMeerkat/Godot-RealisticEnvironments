class_name CompassHud
extends Control

const DIAL_COLOR := Color(0.015, 0.025, 0.035, 0.62)
const RING_COLOR := Color(0.72, 0.80, 0.86, 0.82)
const TICK_COLOR := Color(0.72, 0.80, 0.86, 0.45)
const CARDINAL_COLOR := Color(0.86, 0.91, 0.94, 0.88)
const BOAT_COLOR := Color(1.0, 0.78, 0.28, 0.96)
const BOAT_OUTLINE_COLOR := Color(0.08, 0.06, 0.02, 0.82)
const WIND_COLOR := Color(0.36, 0.82, 1.0, 0.95)
const WIND_SHADOW_COLOR := Color(0.02, 0.06, 0.08, 0.85)

@export var heading_target_path: NodePath
@export var wind_source_path: NodePath
@export_range(96.0, 220.0, 1.0) var dial_size := 136.0

var heading_target: Node3D
var wind_source: Node


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	custom_minimum_size = Vector2(dial_size, dial_size)
	if size.length_squared() <= 0.0:
		size = custom_minimum_size
	_resolve_paths()


func setup(active_heading_target: Node3D, active_wind_source: Node) -> void:
	heading_target = active_heading_target
	wind_source = active_wind_source
	visible = heading_target != null or wind_source != null
	queue_redraw()


func _process(_delta: float) -> void:
	if visible:
		queue_redraw()


func _draw() -> void:
	var draw_size := Vector2(minf(size.x, size.y), minf(size.x, size.y))
	var center := size * 0.5
	var radius := draw_size.x * 0.5 - 8.0
	if radius <= 0.0:
		return

	draw_circle(center, radius, DIAL_COLOR)
	draw_arc(center, radius, 0.0, TAU, 96, RING_COLOR, 2.0, true)
	_draw_ticks(center, radius)
	_draw_cardinals(center, radius)
	_draw_wind_arrow(center, radius)
	_draw_boat_heading(center)


func _resolve_paths() -> void:
	if heading_target_path != NodePath(""):
		heading_target = get_node_or_null(heading_target_path) as Node3D
	if wind_source_path != NodePath(""):
		wind_source = get_node_or_null(wind_source_path)
	visible = heading_target != null or wind_source != null


func _draw_ticks(center: Vector2, radius: float) -> void:
	for i in range(32):
		var degrees := float(i) * 360.0 / 32.0
		var direction := _degrees_to_screen_direction(degrees)
		var tick_length := 9.0 if i % 8 == 0 else 5.0
		var tick_width := 1.8 if i % 8 == 0 else 1.0
		draw_line(
			center + direction * (radius - tick_length),
			center + direction * (radius - 2.0),
			TICK_COLOR,
			tick_width,
			true
		)


func _draw_cardinals(center: Vector2, radius: float) -> void:
	var font := get_theme_default_font()
	if font == null:
		return
	var font_size := 11
	var labels := {
		"N": Vector2(0.0, -1.0),
		"E": Vector2(1.0, 0.0),
		"S": Vector2(0.0, 1.0),
		"W": Vector2(-1.0, 0.0),
	}
	for label in labels:
		var text_size := font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size)
		var _position: Vector2 = center + labels[label] * (radius - 21.0) - text_size * 0.5
		draw_string(font, _position, label, HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size, CARDINAL_COLOR)


func _draw_wind_arrow(center: Vector2, radius: float) -> void:
	if wind_source == null:
		return
	var direction := _degrees_to_screen_direction(_get_wind_direction_degrees())
	var right := Vector2(-direction.y, direction.x)
	var start := center - direction * 11.0
	var tip := center + direction * (radius - 27.0)
	var head_back := tip - direction * 13.0
	var left := head_back - right * 6.5
	var right_point := head_back + right * 6.5

	draw_line(start, tip, WIND_SHADOW_COLOR, 5.0, true)
	draw_line(start, tip, WIND_COLOR, 2.5, true)
	draw_colored_polygon(PackedVector2Array([tip, right_point, left]), WIND_COLOR)


func _draw_boat_heading(center: Vector2) -> void:
	if heading_target == null:
		return
	var direction := _degrees_to_screen_direction(_get_boat_heading_degrees())
	var right := Vector2(-direction.y, direction.x)
	var tip := center + direction * 25.0
	var tail := center - direction * 14.0
	var left := tail - right * 11.0
	var right_point := tail + right * 11.0
	var points := PackedVector2Array([tip, right_point, left])

	draw_colored_polygon(points, BOAT_OUTLINE_COLOR)
	draw_polyline(PackedVector2Array([tip, right_point, left, tip]), BOAT_OUTLINE_COLOR, 3.0, true)
	draw_colored_polygon(points, BOAT_COLOR)


func _get_boat_heading_degrees() -> float:
	var forward := -heading_target.global_transform.basis.z
	forward.y = 0.0
	if forward.length_squared() <= 0.0001:
		return 0.0
	forward = forward.normalized()
	return rad_to_deg(atan2(forward.x, forward.z))


func _get_wind_direction_degrees() -> float:
	if wind_source.has_method(&"get_wind_direction_degrees"):
		return float(wind_source.call(&"get_wind_direction_degrees"))
	var value = wind_source.get(&"wind_direction")
	return float(value) if value != null else 0.0


func _degrees_to_screen_direction(degrees: float) -> Vector2:
	var radians := deg_to_rad(degrees)
	return Vector2(sin(radians), -cos(radians))
