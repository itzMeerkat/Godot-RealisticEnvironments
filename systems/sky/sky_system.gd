@tool
class_name SkySystem
extends Node3D

const SkyProfileResource := preload("res://systems/sky/sky_profile.gd")

signal time_of_day_changed(time_of_day : float)
signal lighting_changed

@export_range(0.0, 1.0, 0.001) var time_of_day := 0.35 :
	set(value):
		time_of_day = fposmod(value, 1.0)
		_update_sky()
		time_of_day_changed.emit(time_of_day)
@export var cycle_enabled := true
@export_range(1.0, 86400.0, 1.0, "or_greater") var cycle_duration_seconds := 600.0
@export_range(-89.0, 89.0, 0.1) var axis_tilt_degrees := 25.0 :
	set(value):
		axis_tilt_degrees = value
		_update_sky()
@export_range(0.0, 8.0, 0.01) var sun_energy_multiplier := 1.0 :
	set(value):
		sun_energy_multiplier = value
		_update_sky()
@export_range(0.0, 8.0, 0.01) var moon_energy_multiplier := 1.0 :
	set(value):
		moon_energy_multiplier = value
		_update_sky()
@export_range(0.0, 8.0, 0.01) var star_brightness := 1.0 :
	set(value):
		star_brightness = value
		_update_sky()
@export var profile : Resource :
	set(value):
		profile = value
		_update_sky()

@export_group("Visuals")
@export var follow_active_camera := true
@export var render_bodies_in_sky := true :
	set(value):
		render_bodies_in_sky = value
		_update_sky()
@export_range(100.0, 10000.0, 1.0, "or_greater") var celestial_visual_distance := 900.0
@export_range(100.0, 10000.0, 1.0, "or_greater") var starfield_radius := 1200.0
@export_range(0.0, 3.0, 0.01) var radiance_sun_disk_strength := 0.16 :
	set(value):
		radiance_sun_disk_strength = value
		_update_sky()
@export_range(0.0, 1.0, 0.01) var radiance_sun_halo_strength := 0.18 :
	set(value):
		radiance_sun_halo_strength = value
		_update_sky()

@export_group("Ocean Integration")
@export var ocean_path : NodePath :
	set(value):
		ocean_path = value
		_ocean = null
		_update_sky()
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


func _ready() -> void:
	if profile == null:
		profile = SkyProfileResource.new()
	_update_sky()


func _process(delta : float) -> void:
	if not Engine.is_editor_hint() and cycle_enabled:
		time_of_day = time_of_day + delta / maxf(cycle_duration_seconds, 1.0)
	_elapsed_time += delta
	_update_visual_positions()
	_update_starfield_time()


func get_time_of_day() -> float:
	return time_of_day


func get_sun_direction() -> Vector3:
	return _get_body_direction(time_of_day)


func get_moon_direction() -> Vector3:
	return -get_sun_direction()


func get_sun_visibility() -> float:
	return smoothstep(-0.05, 0.08, get_sun_direction().y)


func get_moon_visibility() -> float:
	return smoothstep(-0.05, 0.08, get_moon_direction().y)


func get_night_factor() -> float:
	return 1.0 - smoothstep(-0.08, 0.18, get_sun_direction().y)


func _update_sky() -> void:
	if not is_inside_tree():
		return
	var active_profile = _get_profile()
	var sun_direction := get_sun_direction()
	var moon_direction := -sun_direction
	var sun_visibility := get_sun_visibility()
	var moon_visibility := get_moon_visibility()
	var night_factor := get_night_factor()

	_update_light(_sun_light, sun_direction, active_profile.sample_sun_color(time_of_day), active_profile.sample_sun_energy(time_of_day) * sun_visibility * sun_energy_multiplier)
	_update_light(_moon_light, moon_direction, active_profile.sample_moon_color(time_of_day), active_profile.sample_moon_energy(time_of_day) * moon_visibility * moon_energy_multiplier)
	_update_environment(active_profile, sun_direction, moon_direction, sun_visibility, moon_visibility)
	_update_starfield_visibility(active_profile.sample_star_visibility(night_factor) * star_brightness)
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
	var top_color : Color = active_profile.sample_sky_top_color(time_of_day)
	var horizon_color : Color = active_profile.sample_sky_horizon_color(time_of_day)
	var sun_color : Color = active_profile.sample_sun_color(time_of_day)
	var moon_color : Color = active_profile.sample_moon_color(time_of_day)
	environment.ambient_light_color = top_color.lerp(horizon_color, 0.35)
	environment.ambient_light_energy = active_profile.sample_ambient_energy(time_of_day)
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
	_set_visual_color(_sun_visual, active_profile.sample_sun_color(time_of_day), sun_visibility)
	_set_visual_color(_moon_visual, active_profile.sample_moon_color(time_of_day), moon_visibility)


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
		_starfield.scale = Vector3.ONE * starfield_radius


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
		ocean.set(&"water_color", active_profile.sample_water_color(time_of_day))
	if ocean.get(&"foam_color") != null:
		ocean.set(&"foam_color", active_profile.sample_foam_color(time_of_day))


func _get_body_direction(value : float) -> Vector3:
	var angle := TAU * (value - 0.25)
	var base_direction := Vector3(cos(angle), sin(angle), 0.0)
	var tilt_basis := Basis(Vector3.RIGHT, deg_to_rad(axis_tilt_degrees))
	return (tilt_basis * base_direction).normalized()


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
