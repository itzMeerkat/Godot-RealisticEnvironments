@tool
class_name SkyProfile
extends Resource
## How visible SkySystem makes the stars. The sky, the sun's and the moon's light
## and the ambient light are not here: the atmosphere makes them (SkySystem).

## Star visibility response to night factor.
@export var star_visibility_curve : Curve


func _init() -> void:
	_ensure_defaults()


func sample_star_visibility(night_factor : float) -> float:
	_ensure_defaults()
	return star_visibility_curve.sample_baked(clampf(night_factor, 0.0, 1.0))


func _ensure_defaults() -> void:
	if star_visibility_curve == null:
		star_visibility_curve = _make_curve([
			Vector2(0.0, 0.0),
			Vector2(0.35, 0.0),
			Vector2(0.70, 0.85),
			Vector2(1.0, 1.0),
		])


func _make_curve(points : Array[Vector2]) -> Curve:
	var curve := Curve.new()
	curve.min_value = 0.0
	curve.max_value = 2.0
	for point in points:
		curve.add_point(point)
	curve.bake()
	return curve
