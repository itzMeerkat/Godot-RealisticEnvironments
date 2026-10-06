@tool
class_name SkyProfile
extends Resource
## Color gradients and energy curves sampled by SkySystem. Time-based gradients
## use normalized day positions: 0 midnight, 0.25 sunrise, 0.5 noon, 0.75 sunset.
## The sun's and the moon's light are not here: the atmosphere colours and dims
## them (SkySystem).

## Zenith sky color across the day.
@export var sky_top_gradient : Gradient
## Horizon sky color across the day.
@export var sky_horizon_gradient : Gradient
## Star visibility response to night factor.
@export var star_visibility_curve : Curve
## Environment ambient light energy across the day.
@export var ambient_energy_curve : Curve


func _init() -> void:
	_ensure_defaults()


func sample_sky_top_color(time_of_day : float) -> Color:
	_ensure_defaults()
	return sky_top_gradient.sample(_wrap_time(time_of_day))


func sample_sky_horizon_color(time_of_day : float) -> Color:
	_ensure_defaults()
	return sky_horizon_gradient.sample(_wrap_time(time_of_day))


func sample_star_visibility(night_factor : float) -> float:
	_ensure_defaults()
	return star_visibility_curve.sample_baked(clampf(night_factor, 0.0, 1.0))


func sample_ambient_energy(time_of_day : float) -> float:
	_ensure_defaults()
	return ambient_energy_curve.sample_baked(_wrap_time(time_of_day))


func _ensure_defaults() -> void:
	if sky_top_gradient == null:
		sky_top_gradient = _make_gradient([
			Color(0.005, 0.008, 0.018),
			Color(0.36, 0.30, 0.42),
			Color(0.12, 0.42, 0.78),
			Color(0.38, 0.24, 0.34),
			Color(0.005, 0.008, 0.018),
		])
	if sky_horizon_gradient == null:
		sky_horizon_gradient = _make_gradient([
			Color(0.015, 0.018, 0.035),
			Color(1.0, 0.46, 0.22),
			Color(0.58, 0.78, 0.94),
			Color(1.0, 0.36, 0.18),
			Color(0.015, 0.018, 0.035),
		])
	if star_visibility_curve == null:
		star_visibility_curve = _make_curve([
			Vector2(0.0, 0.0),
			Vector2(0.35, 0.0),
			Vector2(0.70, 0.85),
			Vector2(1.0, 1.0),
		])
	if ambient_energy_curve == null:
		ambient_energy_curve = _make_curve([
			Vector2(0.0, 0.035),
			Vector2(0.25, 0.22),
			Vector2(0.50, 0.65),
			Vector2(0.75, 0.22),
			Vector2(1.0, 0.035),
		])


func _make_gradient(colors : Array[Color]) -> Gradient:
	var gradient := Gradient.new()
	var offsets := PackedFloat32Array()
	var packed_colors := PackedColorArray()
	for i in colors.size():
		offsets.push_back(float(i) / float(colors.size() - 1))
		packed_colors.push_back(colors[i])
	gradient.offsets = offsets
	gradient.colors = packed_colors
	return gradient


func _make_curve(points : Array[Vector2]) -> Curve:
	var curve := Curve.new()
	curve.min_value = 0.0
	curve.max_value = 2.0
	for point in points:
		curve.add_point(point)
	curve.bake()
	return curve


func _wrap_time(value : float) -> float:
	return fposmod(value, 1.0)
