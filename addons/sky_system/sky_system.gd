@tool
class_name SkySystem
extends Node3D

const SkyProfileResource := preload("res://addons/sky_system/sky_profile.gd")

signal time_of_day_changed(time_of_day : float)
signal lighting_changed

const SOLAR_YEAR_DAYS := 365.2422
const SYNODIC_MONTH_DAYS := 29.530588
const LUNAR_ORBIT_INCLINATION_DEGREES := 5.145
const SUNSET_PROFILE_TIME := 0.75
const SUNRISE_PROFILE_TIME := 0.25
const NOON_PROFILE_TIME := 0.5
const MIDNIGHT_PROFILE_TIME := 0.0

## Normalized day time. 0 is midnight, 0.25 sunrise, 0.5 noon, 0.75 sunset.
@export_range(0.0, 1.0, 0.001) var time_of_day := 0.35 :
	set(value):
		time_of_day = fposmod(value, 1.0)
		_update_sky()
		time_of_day_changed.emit(time_of_day)
## Advances time_of_day automatically during gameplay.
@export var cycle_enabled := true
## Real seconds required for one full in-game day.
@export_range(1.0, 86400.0, 1.0, "or_greater") var cycle_duration_seconds := 600.0
@export_group("Astronomy")
## Observer latitude in degrees. This controls sun/moon altitude and seasonality.
@export_range(-89.0, 89.0, 0.1) var latitude_degrees := 35.0 :
	set(value):
		latitude_degrees = value
		_update_sky()
## Day within the solar year. 0 and 365.2422 wrap to the same seasonal position.
@export_range(0.0, 365.2422, 0.1) var day_of_year := 80.0 :
	set(value):
		day_of_year = fposmod(value, SOLAR_YEAR_DAYS)
		_update_sky()
## Lunar age in days. 0 is new moon, about 14.765 is full moon.
@export_range(0.0, 29.530588, 0.01) var lunar_age_days := 14.765 :
	set(value):
		lunar_age_days = fposmod(value, SYNODIC_MONTH_DAYS)
		_update_sky()
## Rotates celestial north around world up, useful when a level's north is not -Z.
@export_range(-180.0, 180.0, 0.1) var north_offset_degrees := 0.0 :
	set(value):
		north_offset_degrees = value
		_update_sky()
## Planetary axis tilt in degrees. Earth-like default is 23.44.
@export_range(0.0, 45.0, 0.01) var axis_tilt_degrees := 23.44 :
	set(value):
		axis_tilt_degrees = value
		_update_sky()
## When cycle_enabled is true, also advances day_of_year and lunar_age_days.
@export var advance_calendar_with_cycle := true
## Multiplies the sampled sun light energy.
@export_range(0.0, 8.0, 0.01) var sun_energy_multiplier := 1.0 :
	set(value):
		sun_energy_multiplier = value
		_update_sky()
## Multiplies the sampled moon light energy.
@export_range(0.0, 8.0, 0.01) var moon_energy_multiplier := 1.0 :
	set(value):
		moon_energy_multiplier = value
		_update_sky()
## Multiplies starfield visibility from the active SkyProfile.
@export_range(0.0, 8.0, 0.01) var star_brightness := 1.0 :
	set(value):
		star_brightness = value
		_update_sky()
## Color and energy curves sampled by this sky system.
@export var profile : Resource :
	set(value):
		profile = value
		_update_sky()

@export_group("Visuals")
## Keeps starfield and optional body meshes centered around the active camera.
@export var follow_active_camera := true
## Renders sun/moon disks directly in the sky shader instead of using mesh billboards.
@export var render_bodies_in_sky := true :
	set(value):
		render_bodies_in_sky = value
		_update_sky()
## Distance from origin/camera for optional sun and moon visual meshes.
@export_range(100.0, 10000.0, 1.0, "or_greater") var celestial_visual_distance := 900.0 :
	set(value):
		celestial_visual_distance = value
		_update_visual_positions()
## Radius of the starfield sphere.
@export_range(100.0, 10000.0, 1.0, "or_greater") var starfield_radius := 1200.0 :
	set(value):
		starfield_radius = value
		_update_visual_positions()
## Strength of the sun disk drawn into the radiance sky material.
@export_range(0.0, 3.0, 0.01) var radiance_sun_disk_strength := 0.16 :
	set(value):
		radiance_sun_disk_strength = value
		_update_sky()
## Strength of the sun halo drawn into the radiance sky material.
@export_range(0.0, 1.0, 0.01) var radiance_sun_halo_strength := 0.18 :
	set(value):
		radiance_sun_halo_strength = value
		_update_sky()

@export_group("Ocean Integration")
## Optional ocean node whose water_color and foam_color can be driven by SkyProfile.
@export var ocean_path : NodePath :
	set(value):
		ocean_path = value
		_ocean = null
		_update_sky()
## If enabled, writes profile water/foam colors into the referenced ocean node.
@export var drive_ocean_colors := false :
	set(value):
		drive_ocean_colors = value
		_update_sky()

@onready var _world_environment := $WorldEnvironment as WorldEnvironment
@onready var _sun_light := $SunLight as DirectionalLight3D
@onready var _moon_light := $MoonLight as DirectionalLight3D
@onready var _sun_visual := $SunVisual as MeshInstance3D
@onready var _moon_visual := $MoonVisual as MeshInstance3D
@onready var _starfield := $Starfield as MeshInstance3D

var _ocean : Node
var _elapsed_time := 0.0
var _sun_hour_angle := 0.0
var _moon_phase := 1.0
var _star_visibility := 0.0
var _profile_sample_time := 0.5


func _ready() -> void:
	if not Engine.is_editor_hint():
		_ensure_unique_runtime_resources()
	if profile == null:
		profile = SkyProfileResource.new()
	_update_sky()


func _process(delta : float) -> void:
	if not Engine.is_editor_hint() and cycle_enabled:
		var day_delta := delta / maxf(cycle_duration_seconds, 1.0)
		time_of_day = time_of_day + day_delta
		if advance_calendar_with_cycle:
			day_of_year = day_of_year + day_delta
			lunar_age_days = lunar_age_days + day_delta
	_elapsed_time += delta
	_update_visual_positions()
	_update_starfield_time()


func _ensure_unique_runtime_resources() -> void:
	if _world_environment and _world_environment.environment:
		_world_environment.environment = _world_environment.environment.duplicate()
		var environment := _world_environment.environment
		if environment.sky:
			environment.sky = environment.sky.duplicate()
			if environment.sky.sky_material:
				environment.sky.sky_material = environment.sky.sky_material.duplicate()
	_duplicate_material_override(_sun_visual)
	_duplicate_material_override(_moon_visual)
	_duplicate_material_override(_starfield)


func _duplicate_material_override(visual : MeshInstance3D) -> void:
	if visual and visual.material_override:
		visual.material_override = visual.material_override.duplicate()


func get_time_of_day() -> float:
	return time_of_day


func get_sun_direction() -> Vector3:
	var solar_coordinates := _get_solar_equatorial_coordinates()
	_sun_hour_angle = _get_solar_hour_angle()
	return _equatorial_to_horizontal_direction(solar_coordinates.y, _sun_hour_angle)


func get_moon_direction() -> Vector3:
	return _get_moon_state()["direction"]


func get_sun_visibility() -> float:
	return _sun_altitude_visibility(get_sun_direction().y)


func get_moon_visibility() -> float:
	return _moon_altitude_visibility(get_moon_direction().y)


func get_night_factor() -> float:
	return _night_factor_from_sun_height(get_sun_direction().y)


func get_moon_phase() -> float:
	_moon_phase = float(_get_moon_state()["phase"])
	return _moon_phase


func get_star_visibility() -> float:
	var sun_direction := get_sun_direction()
	var moon_state := _get_moon_state()
	var moon_direction : Vector3 = moon_state["direction"]
	return _calculate_star_visibility(sun_direction.y, _moon_altitude_visibility(moon_direction.y), float(moon_state["phase"]))


func _update_sky() -> void:
	if not is_inside_tree():
		return
	var active_profile = _get_profile()
	var sun_direction := get_sun_direction()
	var moon_state := _get_moon_state()
	var moon_direction : Vector3 = moon_state["direction"]
	var sun_visibility := _sun_altitude_visibility(sun_direction.y)
	var moon_visibility := _moon_altitude_visibility(moon_direction.y)
	var night_factor := _night_factor_from_sun_height(sun_direction.y)
	_moon_phase = float(moon_state["phase"])
	_star_visibility = _calculate_star_visibility(sun_direction.y, moon_visibility, _moon_phase)
	_profile_sample_time = _get_profile_sample_time(sun_direction.y)

	_update_light(_sun_light, sun_direction, active_profile.sample_sun_color(_profile_sample_time), active_profile.sample_sun_energy(_profile_sample_time) * _solar_energy_from_height(sun_direction.y) * sun_energy_multiplier)
	_update_light(_moon_light, moon_direction, active_profile.sample_moon_color(_profile_sample_time), active_profile.sample_moon_energy(_profile_sample_time) * moon_visibility * _moon_phase * night_factor * moon_energy_multiplier)
	_update_environment(active_profile, sun_direction, moon_direction, sun_visibility, moon_visibility)
	_update_starfield_visibility(active_profile.sample_star_visibility(_star_visibility) * star_brightness)
	_update_visual_colors(active_profile, sun_visibility, moon_visibility)
	_update_ocean_colors(active_profile)
	_update_visual_positions()
	lighting_changed.emit()


func _update_light(light : DirectionalLight3D, direction : Vector3, color : Color, energy : float) -> void:
	if light == null:
		return
	light.light_color = color
	light.light_energy = energy
	light.visible = energy > 0.001
	light.look_at(global_position - direction, _get_look_up(direction))


func _update_environment(active_profile, sun_direction : Vector3, moon_direction : Vector3, sun_visibility : float, moon_visibility : float) -> void:
	if _world_environment == null or _world_environment.environment == null:
		return
	var environment := _world_environment.environment
	var top_color : Color = active_profile.sample_sky_top_color(_profile_sample_time)
	var horizon_color : Color = active_profile.sample_sky_horizon_color(_profile_sample_time)
	var sun_color : Color = active_profile.sample_sun_color(_profile_sample_time)
	var moon_color : Color = active_profile.sample_moon_color(_profile_sample_time)
	environment.ambient_light_color = top_color.lerp(horizon_color, 0.35)
	environment.ambient_light_energy = active_profile.sample_ambient_energy(_profile_sample_time) * lerpf(0.35, 1.0, smoothstep(-0.08, 0.35, sun_direction.y))
	if environment.sky and environment.sky.sky_material:
		var material := environment.sky.sky_material
		if material is ShaderMaterial:
			var shader_material := material as ShaderMaterial
			shader_material.set_shader_parameter(&"sky_top_color", top_color)
			shader_material.set_shader_parameter(&"sky_horizon_color", horizon_color)
			shader_material.set_shader_parameter(&"ground_bottom_color", top_color.darkened(0.55))
			shader_material.set_shader_parameter(&"ground_horizon_color", horizon_color.darkened(0.25))
			shader_material.set_shader_parameter(&"sun_direction", sun_direction)
			shader_material.set_shader_parameter(&"sun_color", sun_color)
			shader_material.set_shader_parameter(&"sun_visibility", sun_visibility if render_bodies_in_sky else 0.0)
			shader_material.set_shader_parameter(&"radiance_sun_disk_strength", radiance_sun_disk_strength)
			shader_material.set_shader_parameter(&"radiance_sun_halo_strength", radiance_sun_halo_strength)
			shader_material.set_shader_parameter(&"moon_direction", moon_direction)
			shader_material.set_shader_parameter(&"moon_color", moon_color)
			shader_material.set_shader_parameter(&"moon_visibility", moon_visibility if render_bodies_in_sky else 0.0)
			shader_material.set_shader_parameter(&"moon_phase", _moon_phase)
		else:
			material.set(&"sky_top_color", top_color)
			material.set(&"sky_horizon_color", horizon_color)
			material.set(&"ground_bottom_color", top_color.darkened(0.55))
			material.set(&"ground_horizon_color", horizon_color.darkened(0.25))


func _update_starfield_visibility(visibility : float) -> void:
	if _starfield == null:
		return
	_starfield.visible = visibility > 0.001
	var material := _starfield.material_override as ShaderMaterial
	if material:
		material.set_shader_parameter(&"star_visibility", visibility)
		material.set_shader_parameter(&"star_brightness", star_brightness)
		material.set_shader_parameter(&"horizon_softness", 0.08)


func _update_starfield_time() -> void:
	if _starfield == null:
		return
	var material := _starfield.material_override as ShaderMaterial
	if material:
		material.set_shader_parameter(&"time", _elapsed_time)


func _update_visual_colors(active_profile, sun_visibility : float, moon_visibility : float) -> void:
	if render_bodies_in_sky:
		if _sun_visual:
			_sun_visual.visible = false
		if _moon_visual:
			_moon_visual.visible = false
		return
	_set_visual_color(_sun_visual, active_profile.sample_sun_color(_profile_sample_time), sun_visibility)
	_set_visual_color(_moon_visual, active_profile.sample_moon_color(_profile_sample_time), moon_visibility * _moon_phase)


func _set_visual_color(visual : MeshInstance3D, color : Color, visibility : float) -> void:
	if visual == null:
		return
	visual.visible = visibility > 0.001
	var shader_material := visual.material_override as ShaderMaterial
	if shader_material:
		shader_material.set_shader_parameter(&"body_color", color)
		shader_material.set_shader_parameter(&"visibility", visibility)
		return
	var material := visual.material_override as StandardMaterial3D
	if material:
		material.albedo_color = Color(color.r, color.g, color.b, visibility)
		material.emission = color
		material.emission_energy_multiplier = visibility


func _update_visual_positions() -> void:
	var camera := _get_active_camera()
	if camera == null:
		return
	var origin := camera.global_position if follow_active_camera else global_position
	if not render_bodies_in_sky:
		_position_body_visual(_sun_visual, origin, get_sun_direction())
		_position_body_visual(_moon_visual, origin, get_moon_direction())
	if _starfield:
		_starfield.global_position = origin
		var star_axis := _get_celestial_north_axis()
		var sidereal_angle := _get_local_sidereal_time()
		_starfield.global_transform = Transform3D(Basis(star_axis, sidereal_angle).scaled(Vector3.ONE * starfield_radius), origin)


func _position_body_visual(visual : MeshInstance3D, origin : Vector3, direction : Vector3) -> void:
	if visual == null:
		return
	visual.global_position = origin + direction * celestial_visual_distance
	visual.look_at(origin, _get_look_up(direction))


func _update_ocean_colors(active_profile) -> void:
	if not drive_ocean_colors:
		return
	var ocean := _get_ocean()
	if ocean == null:
		return
	if ocean.get(&"water_color") != null:
		ocean.set(&"water_color", active_profile.sample_water_color(_profile_sample_time))
	if ocean.get(&"foam_color") != null:
		ocean.set(&"foam_color", active_profile.sample_foam_color(_profile_sample_time))


func _get_solar_equatorial_coordinates() -> Vector2:
	var obliquity := deg_to_rad(axis_tilt_degrees)
	var solar_longitude := _get_solar_ecliptic_longitude()
	var right_ascension := atan2(cos(obliquity) * sin(solar_longitude), cos(solar_longitude))
	var declination := asin(sin(obliquity) * sin(solar_longitude))
	return Vector2(_wrap_pi(right_ascension), declination)


func _get_solar_ecliptic_longitude() -> float:
	return TAU * fposmod((day_of_year - 80.0) / SOLAR_YEAR_DAYS, 1.0)


func _get_solar_hour_angle() -> float:
	return _wrap_pi(TAU * (time_of_day - 0.5))


func _get_moon_state() -> Dictionary:
	var obliquity := deg_to_rad(axis_tilt_degrees)
	var phase_angle := TAU * fposmod(lunar_age_days / SYNODIC_MONTH_DAYS, 1.0)
	var lunar_longitude := _get_solar_ecliptic_longitude() + phase_angle
	var lunar_latitude := deg_to_rad(LUNAR_ORBIT_INCLINATION_DEGREES) * sin(TAU * fposmod(lunar_age_days / 27.21222, 1.0))
	var right_ascension := atan2(sin(lunar_longitude) * cos(obliquity) - tan(lunar_latitude) * sin(obliquity), cos(lunar_longitude))
	var declination := asin(sin(lunar_latitude) * cos(obliquity) + cos(lunar_latitude) * sin(obliquity) * sin(lunar_longitude))
	var hour_angle := _wrap_pi(_get_local_sidereal_time() - right_ascension)
	var phase := clampf((1.0 - cos(phase_angle)) * 0.5, 0.0, 1.0)
	return {
		"direction": _equatorial_to_horizontal_direction(declination, hour_angle),
		"phase": phase,
	}


func _get_local_sidereal_time() -> float:
	var solar_coordinates := _get_solar_equatorial_coordinates()
	return _wrap_pi(_get_solar_hour_angle() + solar_coordinates.x)


func _equatorial_to_horizontal_direction(declination : float, hour_angle : float) -> Vector3:
	var latitude := deg_to_rad(latitude_degrees)
	var east := -cos(declination) * sin(hour_angle)
	var north := cos(latitude) * sin(declination) - sin(latitude) * cos(declination) * cos(hour_angle)
	var up := sin(latitude) * sin(declination) + cos(latitude) * cos(declination) * cos(hour_angle)
	return _horizontal_to_world(Vector3(east, up, -north)).normalized()


func _horizontal_to_world(local_direction : Vector3) -> Vector3:
	return Basis(Vector3.UP, deg_to_rad(north_offset_degrees)) * local_direction


func _get_celestial_north_axis() -> Vector3:
	var latitude := deg_to_rad(latitude_degrees)
	return _horizontal_to_world(Vector3(0.0, sin(latitude), -cos(latitude))).normalized()


func _sun_altitude_visibility(sun_height : float) -> float:
	return smoothstep(-0.035, 0.045, sun_height)


func _moon_altitude_visibility(moon_height : float) -> float:
	return smoothstep(-0.025, 0.045, moon_height)


func _night_factor_from_sun_height(sun_height : float) -> float:
	return 1.0 - smoothstep(-0.30, -0.10, sun_height)


func _calculate_star_visibility(sun_height : float, moon_visibility : float, moon_phase : float) -> float:
	var twilight_visibility := 1.0 - smoothstep(-0.30, -0.10, sun_height)
	var moon_washout := moon_visibility * moon_phase * 0.45
	return clampf(twilight_visibility * (1.0 - moon_washout), 0.0, 1.0)


func _solar_energy_from_height(sun_height : float) -> float:
	return pow(clampf(sun_height, 0.0, 1.0), 0.45)


func _get_profile_sample_time(sun_height : float) -> float:
	var horizon_amount := smoothstep(-0.08, 0.20, sun_height)
	if sun_height > 0.20:
		return NOON_PROFILE_TIME
	var twilight_amount := smoothstep(-0.18, -0.08, sun_height)
	if _sun_hour_angle < 0.0:
		if sun_height < -0.08:
			return lerpf(MIDNIGHT_PROFILE_TIME, SUNRISE_PROFILE_TIME, twilight_amount)
		return lerpf(SUNRISE_PROFILE_TIME, NOON_PROFILE_TIME, horizon_amount)
	if sun_height > -0.08:
		return lerpf(SUNSET_PROFILE_TIME, NOON_PROFILE_TIME, horizon_amount)
	return lerpf(1.0, SUNSET_PROFILE_TIME, twilight_amount)


func _wrap_pi(value : float) -> float:
	return fposmod(value + PI, TAU) - PI


func _get_look_up(direction : Vector3) -> Vector3:
	return Vector3.FORWARD if absf(direction.dot(Vector3.UP)) > 0.98 else Vector3.UP


func _get_active_camera() -> Camera3D:
	var viewport := get_viewport()
	if viewport == null:
		return null
	return viewport.get_camera_3d()


func _get_ocean() -> Node:
	if _ocean == null and not ocean_path.is_empty():
		_ocean = get_node_or_null(ocean_path)
	return _ocean


func _get_profile():
	if profile == null:
		profile = SkyProfileResource.new()
	return profile
