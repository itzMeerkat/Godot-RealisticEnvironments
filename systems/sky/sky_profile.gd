@tool
class_name SkyProfile
extends Resource

@export var sun_color_gradient : Gradient
@export var moon_color_gradient : Gradient
@export var sky_top_gradient : Gradient
@export var sky_horizon_gradient : Gradient
@export var water_color_gradient : Gradient
@export var foam_color_gradient : Gradient
@export var sun_energy_curve : Curve
@export var moon_energy_curve : Curve
@export var star_visibility_curve : Curve
@export var ambient_energy_curve : Curve


func _init() -> void:
	_ensure_defaults()


func sample_sun_color(time_of_day : float) -> Color:
	_ensure_defaults()
	return sun_color_gradient.sample(_wrap_time(time_of_day))


func sample_moon_color(time_of_day : float) -> Color:
	_ensure_defaults()
	return moon_color_gradient.sample(_wrap_time(time_of_day))


func sample_sky_top_color(time_of_day : float) -> Color:
	_ensure_defaults()
	return sky_top_gradient.sample(_wrap_time(time_of_day))


func sample_sky_horizon_color(time_of_day : float) -> Color:
	_ensure_defaults()
	return sky_horizon_gradient.sample(_wrap_time(time_of_day))


func sample_water_color(time_of_day : float) -> Color:
	_ensure_defaults()
	return water_color_gradient.sample(_wrap_time(time_of_day))


func sample_foam_color(time_of_day : float) -> Color:
	_ensure_defaults()
	return foam_color_gradient.sample(_wrap_time(time_of_day))


func sample_sun_energy(time_of_day : float) -> float:
	_ensure_defaults()
	return sun_energy_curve.sample_baked(_wrap_time(time_of_day))


func sample_moon_energy(time_of_day : float) -> float:
	_ensure_defaults()
	return moon_energy_curve.sample_baked(_wrap_time(time_of_day))


func sample_star_visibility(night_factor : float) -> float:
	_ensure_defaults()
	return star_visibility_curve.sample_baked(clampf(night_factor, 0.0, 1.0))


func sample_ambient_energy(time_of_day : float) -> float:
	_ensure_defaults()
	return ambient_energy_curve.sample_baked(_wrap_time(time_of_day))


func _ensure_defaults() -> void:
	if sun_color_gradient == null:
		sun_color_gradient = _make_gradient([
			Color(0.05, 0.07, 0.12),
			Color(1.0, 0.48, 0.22),
			Color(1.0, 0.96, 0.82),
			Color(1.0, 0.42, 0.18),
			Color(0.05, 0.07, 0.12),
		])
	if moon_color_gradient == null:
		moon_color_gradient = _make_gradient([
			Color(0.35, 0.45, 0.70),
			Color(0.16, 0.20, 0.32),
			Color(0.02, 0.025, 0.04),
			Color(0.16, 0.20, 0.32),
			Color(0.35, 0.45, 0.70),
		])
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
	if water_color_gradient == null:
		water_color_gradient = _make_gradient([
			Color(0.015, 0.025, 0.045),
			Color(0.05, 0.08, 0.10),
			Color(0.10, 0.15, 0.18),
			Color(0.05, 0.07, 0.09),
			Color(0.015, 0.025, 0.045),
		])
	if foam_color_gradient == null:
		foam_color_gradient = _make_gradient([
			Color(0.28, 0.32, 0.40),
			Color(0.82, 0.63, 0.48),
			Color(0.73, 0.67, 0.62),
			Color(0.82, 0.58, 0.45),
			Color(0.28, 0.32, 0.40),
		])
	if sun_energy_curve == null:
		sun_energy_curve = _make_curve([
			Vector2(0.0, 0.0),
			Vector2(0.23, 0.0),
			Vector2(0.30, 0.65),
			Vector2(0.50, 1.25),
			Vector2(0.70, 0.65),
			Vector2(0.77, 0.0),
			Vector2(1.0, 0.0),
		])
	if moon_energy_curve == null:
		moon_energy_curve = _make_curve([
			Vector2(0.0, 0.18),
			Vector2(0.22, 0.08),
			Vector2(0.30, 0.0),
			Vector2(0.70, 0.0),
			Vector2(0.78, 0.08),
			Vector2(1.0, 0.18),
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
			Vector2(0.0, 0.08),
			Vector2(0.25, 0.28),
			Vector2(0.50, 0.75),
			Vector2(0.75, 0.28),
			Vector2(1.0, 0.08),
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
