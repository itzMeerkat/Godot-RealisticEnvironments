@tool
class_name SkySystem
extends Node3D

const SkyProfileResource := preload("res://addons/sky_system/sky_profile.gd")

signal time_of_day_changed(time_of_day : float)
signal lighting_changed

const SOLAR_YEAR_DAYS := 365.2422
const SYNODIC_MONTH_DAYS := 29.530588
const LUNAR_ORBIT_INCLINATION_DEGREES := 5.145
## Below this sun height (15 degrees down, its twilight gone) the moon is the
## atmosphere's key light instead of the sun; the other body lights it too.
const MOON_KEY_SUN_HEIGHT := -0.2588
## The sun's light energy above the atmosphere, in the units of the scene's lights. The
## light is white there; the atmosphere colours it on the way down (a clear noon sun
## reaches the sea pale yellow at about 1.0). sun_energy_multiplier scales it.
const SOLAR_ENERGY := 1.3
## Illuminance (lux) of the sun and of the full moon above the atmosphere, facing them.
## They tie the scene's light units to lux (get_illuminance_unit_lux()) and set the
## moon's energy.
const SOLAR_ILLUMINANCE_LUX := 128000.0
const FULL_MOON_ILLUMINANCE_LUX := 0.27
## The full moon's light energy above the atmosphere (the sunlight it reflects, white):
## physical, about 1/470000 of the sun's. An exposure controller (get_scene_illuminance())
## makes the night visible. moon_energy_multiplier scales it.
const MOON_ENERGY := SOLAR_ENERGY * FULL_MOON_ILLUMINANCE_LUX / SOLAR_ILLUMINANCE_LUX
## Rec. 709 luminance of linear rgb.
const LUMINANCE_WEIGHTS := Vector3(0.2126, 0.7152, 0.0722)
## Angular radii (rad) of the sun's and the moon's disks, as the sky material's
## sun_disk_size and moon_disk_size.
const SUN_ANGULAR_RADIUS := 0.00465
const MOON_ANGULAR_RADIUS := 0.00465
## As shaders/compute/atmosphere_common.glslinc.
const ATMOSPHERE_EARTH_RADIUS := 6371000.0
const ATMOSPHERE_RAYLEIGH_SCATTERING := Vector3(5.802e-6, 13.558e-6, 33.1e-6)
const ATMOSPHERE_RAYLEIGH_SCALE_HEIGHT := 8000.0
const ATMOSPHERE_OZONE_ABSORPTION := Vector3(0.650e-6, 1.881e-6, 0.085e-6)
const ATMOSPHERE_OZONE_CENTER := 25000.0
const ATMOSPHERE_OZONE_HALF_WIDTH := 15000.0
## As TRANSMITTANCE_STEPS in shaders/compute/atmosphere_transmittance.glsl.
const ATMOSPHERE_TRANSMITTANCE_STEPS := 40
## The sky's radiance map (ambient light and reflections) is refreshed when the
## camera's altitude changes by more than this share (or 2 m), see _process_atmosphere().
const RADIANCE_ALTITUDE_TOLERANCE := 0.1
## Global shader uniforms the atmosphere publishes (project.godot [shader_globals];
## read through shaders/atmosphere.gdshaderinc).
const GLOBAL_ENABLED := &"atmosphere_enabled"
const GLOBAL_VIEW_TEXTURES : Array[StringName] = [&"atmosphere_view_transmittance", &"atmosphere_view_inscatter", &"atmosphere_view_inscatter_lobe"]
const GLOBAL_OBSERVER := &"atmosphere_observer"
const GLOBAL_LIGHT := &"atmosphere_light"
const GLOBAL_MAX_DISTANCE := &"atmosphere_max_distance"
const GLOBAL_EXPOSURE := &"atmosphere_exposure"
## A light whose irradiance is below this share of the other's is hidden (the moon by
## day, the sun deep in twilight): it would cost a shadowed light for nothing.
const NEGLIGIBLE_LIGHT_SHARE := 0.001

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
## Multiplies the sun's light energy above the atmosphere (SOLAR_ENERGY).
@export_range(0.0, 8.0, 0.01) var sun_energy_multiplier := 1.0 :
	set(value):
		sun_energy_multiplier = value
		_update_sky()
## Multiplies the full moon's light energy above the atmosphere (MOON_ENERGY).
@export_range(0.0, 8.0, 0.01) var moon_energy_multiplier := 1.0 :
	set(value):
		moon_energy_multiplier = value
		_update_sky()
## Multiplies starfield visibility from the active SkyProfile.
@export_range(0.0, 8.0, 0.01) var star_brightness := 1.0 :
	set(value):
		star_brightness = value
		_update_sky()
## The stars' visibility curve (SkyProfile).
@export var profile : Resource :
	set(value):
		profile = value
		_update_sky()

@export_group("Visuals")
## World height of the sea surface. The sea's horizon lies below eye level by
## sqrt(2 h / R) for a camera h meters above it (earth radius R), and the sky
## shows down to there. The atmosphere's haze (CloudPreset haze_*) is densest here.
@export var sea_level := 0.0 :
	set(value):
		sea_level = value
		_update_sky()
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

@export_group("Clouds")
## Renders volumetric clouds into the sky, the starfield and (through
## get_cloud_cubemap()) the ocean's sky reflection. Needs a RenderingDevice
## (Forward+ or Mobile renderer) and a cloud_preset.
@export var clouds_enabled := true :
	set(value):
		clouds_enabled = value
		if is_node_ready():
			_setup_clouds()
## Cloud weather. In the editor a new preset applies at once; at runtime it
## blends in over cloud_transition_seconds (see also transition_clouds_to()).
@export var cloud_preset : CloudPreset :
	set(value):
		cloud_preset = value
		if is_node_ready():
			_start_cloud_transition()
## Seconds a new cloud_preset takes to blend in at runtime.
@export_range(0.0, 600.0, 0.1, "or_greater") var cloud_transition_seconds := 30.0
## Optional wind source the clouds drift with: get_wind_speed() and
## get_wind_direction_degrees(), or wind_speed / wind_direction properties.
## Empty uses cloud_wind_speed and cloud_wind_direction.
@export var cloud_wind_source_path : NodePath :
	set(value):
		cloud_wind_source_path = value
		if is_node_ready():
			_resolve_cloud_wind_source()
## Multiplies the wind source's speed: wind at cloud height is stronger than at the surface.
@export_range(0.0, 10.0, 0.01) var cloud_wind_speed_multiplier := 2.0
## Cloud drift speed in m/s when cloud_wind_source_path is empty.
@export_range(0.0, 100.0, 0.1, "or_greater") var cloud_wind_speed := 15.0
## Cloud drift heading in degrees when cloud_wind_source_path is empty. 0 = +Z, 90 = +X.
@export_range(-360.0, 360.0, 1.0) var cloud_wind_direction := 0.0
@export_subgroup("Cloud Lighting")
## Brightness of cloud lit by the sun or moon.
@export_range(0.0, 8.0, 0.01) var cloud_light_intensity := 1.0
## Multiplies the sky light (from the atmosphere) that fills cloud shadows.
@export_range(0.0, 8.0, 0.01) var cloud_ambient_intensity := 1.0
## How strongly clouds toward the sun or moon block the atmosphere's light (the
## haze's glow around it and its brightness):
## multiplies their opacity (clamped to 1). 1 uses the opacity as rendered; 2
## blocks the glow fully behind half-opaque cloud; 0 never blocks it.
@export_range(0.0, 8.0, 0.01, "or_greater") var cloud_haze_shadow_strength := 1.0 :
	set(value):
		cloud_haze_shadow_strength = value
		if is_node_ready():
			_update_sky()
@export_subgroup("Cloud Quality")
## Edge length in texels of the cloud cubemap faces.
@export_range(256, 2048, 128) var cloud_cubemap_size := 1024 :
	set(value):
		cloud_cubemap_size = value
		if is_node_ready():
			_setup_clouds()
## Each frame re-renders one cloud texel in every stride x stride block. Higher
## is cheaper; the clouds then take stride^2 frames to fully update.
@export_enum("1:1", "2:2", "4:4") var cloud_update_stride := 4
## Raymarch steps along each view ray.
@export_range(8, 256, 1) var cloud_view_steps := 64
## Raymarch steps from each cloud sample toward the sun or moon.
@export_range(1, 16, 1) var cloud_light_steps := 6
## Clouds farther than this (m) are not drawn.
@export_range(10000.0, 400000.0, 1000.0, "or_greater") var cloud_max_distance := 120000.0

@onready var _world_environment := $WorldEnvironment as WorldEnvironment
@onready var _sun_light := $SunLight as DirectionalLight3D
@onready var _moon_light := $MoonLight as DirectionalLight3D
@onready var _sun_visual := $SunVisual as MeshInstance3D
@onready var _moon_visual := $MoonVisual as MeshInstance3D
@onready var _starfield := $Starfield as MeshInstance3D

var _elapsed_time := 0.0
var _sun_hour_angle := 0.0
## True while _process advances several calendar properties; their setters then
## skip _update_sky and _process runs it once afterwards.
var _advancing_cycle := false

# Lighting state, recomputed by _update_lighting_state() whenever an input changes.
# The public getters return these, so reading the sky costs nothing per call.
var _sun_direction := Vector3.UP
var _moon_direction := Vector3.DOWN
var _sun_visibility := 1.0
var _moon_visibility := 0.0
var _moon_phase := 1.0
var _star_visibility := 0.0
## Colours of the sun's and the moon's light at the sea (brightest channel 1): white
## light coloured by the atmosphere along their direction.
var _sun_color := Color.WHITE
var _moon_color := Color.WHITE
## pi * energy * transmittance of the air (not the haze) along the sun's direction,
## and the same for the full moon: the sky shader's disks, which the haze, the clouds
## and the moon's phase dim themselves.
var _sun_irradiance := Color.BLACK
var _moon_irradiance := Color.BLACK
## Share of the sun's and the moon's light that reaches the sea, per channel: the
## atmosphere's transmittance times the share of the disk above the horizon.
var _sun_transmittance := Color.WHITE
var _moon_transmittance := Color.BLACK
# The atmosphere's haze, from the weather (CloudPreset haze_*), recomputed by _update_sky().
## Extinction at sea level (1/m); 0 without a cloud_preset.
var _haze_density := 0.0
var _haze_scale_height := 1000.0
var _haze_anisotropy := 0.97
## Irradiance (scene units) of the sun's and the moon's lights on a level surface at the sea.
var _direct_irradiance := 0.0
## Luminance of the sky's irradiance on a level surface at the camera, through the
## clouds (read back from AtmosphereRenderer.camera_sky_light_buffer); < 0 until the
## first readback arrives.
var _sky_irradiance := -1.0
var _sky_light_read_pending := false
## The camera's exposure (its CameraAttributes.exposure_multiplier, or the world's), read
## every frame: the atmosphere's and the clouds' textures are stored pre-exposed by it.
var _exposure := 1.0
## The atmosphere's key light: the sun, or the moon once the sun is well down
## (MOON_KEY_SUN_HEIGHT). It has the haze's lobe.
var _haze_light_direction := Vector3.UP
## That light above the atmosphere: pi * energy, white.
var _haze_light_color := Color.BLACK
## The other body, which lights the atmosphere too.
var _haze_secondary_direction := Vector3.DOWN
var _haze_secondary_color := Color.BLACK

## The SkySystem whose atmosphere the global shader uniforms show: the one set up
## last. Another one leaving the tree (e.g. the previous scene) must not clear them.
static var _global_atmosphere_owner : SkySystem
## Null when there is no RenderingDevice.
var _atmosphere_renderer : AtmosphereRenderer
## Bound to the atmosphere's global textures while there is no atmosphere.
var _placeholder_volume : ImageTexture3D
## Camera altitude the sky's radiance map was last rendered for.
var _radiance_observer_altitude := -1.0

## Null while clouds are disabled or unavailable.
var _cloud_renderer : CloudRenderer
## The cloud weather on screen: cloud_preset, or a blend toward it.
var _cloud_state : CloudPreset
var _cloud_transition_from : CloudPreset
var _cloud_transition_elapsed := 0.0
## 0 when no transition is running.
var _cloud_transition_duration := 0.0
## Duration of the next transition, set by transition_clouds_to(); < 0 uses cloud_transition_seconds.
var _next_cloud_transition_seconds := -1.0
var _cloud_wind_source : Node
## World XZ distance the wind has carried the clouds.
var _cloud_wind_offset := Vector2.ZERO
var _cloud_evolution_time := 0.0
var _cloud_frames_until_material_push := 0


func _init() -> void:
	_update_lighting_state()


func _ready() -> void:
	if not Engine.is_editor_hint():
		_ensure_unique_runtime_resources()
	if profile == null:
		profile = SkyProfileResource.new()
	if cloud_preset:
		_cloud_state = cloud_preset.duplicate()
	_resolve_cloud_wind_source()
	_setup_atmosphere()
	_setup_clouds()


func _enter_tree() -> void:
	if is_node_ready():
		_setup_atmosphere()
		_setup_clouds()


func _exit_tree() -> void:
	_release_clouds()
	_release_atmosphere()


func _process(delta : float) -> void:
	_update_exposure()
	if not Engine.is_editor_hint() and cycle_enabled:
		var day_delta := delta / maxf(cycle_duration_seconds, 1.0)
		_advancing_cycle = true
		time_of_day = time_of_day + day_delta
		if advance_calendar_with_cycle:
			day_of_year = day_of_year + day_delta
			lunar_age_days = lunar_age_days + day_delta
		_advancing_cycle = false
		_update_sky()
	_elapsed_time += delta
	_update_visual_positions()
	_update_starfield_time()
	if _cloud_transition_duration > 0.0:
		_process_weather_transition(delta)
	if _cloud_renderer:
		_process_clouds(delta)
	if _atmosphere_renderer:
		_process_atmosphere()


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
	return _sun_direction


func get_moon_direction() -> Vector3:
	return _moon_direction


## How much of the sun reaches the scene: the share of its disk above the horizon
## times cloud cover.
func get_sun_visibility() -> float:
	return _sun_visibility * _get_cloud_sun_light_scale()


## Colour of the sun's light at the sea (brightest channel 1): white light coloured
## by the atmosphere along the sun's direction.
func get_sun_color() -> Color:
	return _sun_color


func get_moon_visibility() -> float:
	return _moon_visibility


func get_moon_phase() -> float:
	return _moon_phase


func get_star_visibility() -> float:
	return _star_visibility


## The cloud cubemap (rgb: premultiplied cloud radiance, a: opacity, upper
## hemisphere only), or null while clouds are off. The object changes when the
## clouds are rebuilt; lighting_changed fires then.
func get_cloud_cubemap() -> Texture:
	return _cloud_renderer.cubemap if _cloud_renderer else null


## The cloud weather on screen (a blend while a transition runs), or null while
## clouds are off. Read-only.
func get_cloud_state() -> CloudPreset:
	return _cloud_state if _cloud_renderer else null


## The sky seen from the sea surface through the atmosphere, for consumers that
## draw their own sky (the ocean's sky reflection): view volumes holding only the
## rays' ends ([transmittance, isotropic in-scatter, lobe in-scatter per unit
## phase]; layout as shaders/compute/atmosphere_common.glslinc for an observer at
## altitude 0), or an empty array without an atmosphere. The textures stay the
## same objects while the atmosphere exists; lighting_changed fires when they change.
func get_atmosphere_sky_volumes() -> Array[Texture3D]:
	if _atmosphere_renderer == null:
		return []
	return [_atmosphere_renderer.sea_transmittance, _atmosphere_renderer.sea_inscatter, _atmosphere_renderer.sea_inscatter_lobe]


## xyz toward the light the atmosphere scatters (the sun, or the moon at night),
## w the Henyey-Greenstein g of the haze's forward lobe, whose phase function
## multiplies the lobe in-scatter.
func get_atmosphere_light() -> Vector4:
	return Vector4(_haze_light_direction.x, _haze_light_direction.y, _haze_light_direction.z, _haze_anisotropy)


## The scene's light meter: illuminance (lux) on a level surface at the active camera,
## from the sun's and the moon's lights and the sky (atmosphere and clouds), for an
## exposure controller. Negative until the sky's light has been measured once (a frame
## or two after the atmosphere is set up).
func get_scene_illuminance() -> float:
	if _atmosphere_renderer == null:
		return _direct_irradiance * get_illuminance_unit_lux()
	if _sky_irradiance < 0.0:
		return -1.0
	return (_direct_irradiance + _sky_irradiance) * get_illuminance_unit_lux()


## Lux of a scene irradiance of 1 (a light of energy 1 / pi facing the surface; a white
## diffuser under it has radiance 1 / pi).
func get_illuminance_unit_lux() -> float:
	return SOLAR_ILLUMINANCE_LUX / (PI * SOLAR_ENERGY)


## Makes preset the cloud_preset, blending to it over seconds (0 = at once).
func transition_clouds_to(preset : CloudPreset, seconds : float) -> void:
	_next_cloud_transition_seconds = seconds
	cloud_preset = preset


## Recomputes the astronomy and the lights behind the public getters.
func _update_lighting_state() -> void:
	var solar_coordinates := _get_solar_equatorial_coordinates()
	_sun_hour_angle = _get_solar_hour_angle()
	_sun_direction = _equatorial_to_horizontal_direction(solar_coordinates.y, _sun_hour_angle)
	var moon_state := _get_moon_state()
	_moon_direction = moon_state["direction"]
	_moon_phase = float(moon_state["phase"])
	_sun_visibility = _disk_above_horizon(_sun_direction.y, SUN_ANGULAR_RADIUS)
	_moon_visibility = _disk_above_horizon(_moon_direction.y, MOON_ANGULAR_RADIUS)
	_star_visibility = _calculate_star_visibility(_sun_direction.y, _moon_visibility, _moon_phase)
	_update_haze_medium()
	_sun_transmittance = _get_body_transmittance(_sun_direction, SUN_ANGULAR_RADIUS, true)
	_moon_transmittance = _get_body_transmittance(_moon_direction, MOON_ANGULAR_RADIUS, true)
	_sun_color = _light_color(_get_atmosphere_transmittance(0.0, _above_horizon(_sun_direction), true))
	_moon_color = _light_color(_get_atmosphere_transmittance(0.0, _above_horizon(_moon_direction), true))
	# The disks are drawn behind the haze and the clouds, which dim them themselves.
	_sun_irradiance = _get_atmosphere_transmittance(0.0, _above_horizon(_sun_direction), false) * (_get_sun_energy() * PI)
	_moon_irradiance = _get_atmosphere_transmittance(0.0, _above_horizon(_moon_direction), false) * (MOON_ENERGY * moon_energy_multiplier * PI)


func _update_sky() -> void:
	if _advancing_cycle:
		return
	_update_lighting_state()
	if not is_inside_tree():
		return
	var active_profile = _get_profile()
	var cloud_light_scale := _get_cloud_sun_light_scale()
	var sun_energy := _get_sun_energy() * cloud_light_scale
	var moon_energy := _get_moon_energy() * cloud_light_scale
	# The lights reach the scene through the atmosphere between space and the sea.
	_update_light(_sun_light, _sun_direction, sun_energy, _sun_transmittance)
	_update_light(_moon_light, _moon_direction, moon_energy, _moon_transmittance)
	var sun_irradiance := _level_irradiance(sun_energy, _sun_transmittance, _sun_direction)
	var moon_irradiance := _level_irradiance(moon_energy, _moon_transmittance, _moon_direction)
	_direct_irradiance = sun_irradiance + moon_irradiance
	if _moon_light and moon_irradiance < NEGLIGIBLE_LIGHT_SHARE * sun_irradiance:
		_moon_light.visible = false
	elif _sun_light and sun_irradiance < NEGLIGIBLE_LIGHT_SHARE * moon_irradiance:
		_sun_light.visible = false
	if _sun_direction.y >= MOON_KEY_SUN_HEIGHT:
		_update_haze_lighting(_sun_direction, sun_energy, _moon_direction, moon_energy)
	else:
		_update_haze_lighting(_moon_direction, moon_energy, _sun_direction, sun_energy)
	_update_environment(_sun_direction, _moon_direction, _sun_visibility, _moon_visibility)
	_push_atmosphere_parameters()
	_update_starfield_visibility(active_profile.sample_star_visibility(_star_visibility) * star_brightness)
	_update_visual_colors(_sun_visibility, _moon_visibility)
	_update_visual_positions()
	lighting_changed.emit()


## The haze of the current weather (none without a cloud_preset).
func _update_haze_medium() -> void:
	if _cloud_state == null:
		_haze_density = 0.0
		return
	_haze_density = 3.912 / _cloud_state.haze_visibility
	_haze_scale_height = _cloud_state.haze_scale_height
	_haze_anisotropy = _cloud_state.haze_anisotropy


## The light the atmosphere scatters: white at energy above the atmosphere, where pi *
## energy is its irradiance. The atmosphere dims and colours it down to each of its
## points itself, and scatters it on (AtmosphereRenderer).
func _update_haze_lighting(direction : Vector3, energy : float, secondary_direction : Vector3, secondary_energy : float) -> void:
	_haze_light_direction = direction
	_haze_light_color = Color(1.0, 1.0, 1.0) * (energy * PI)
	_haze_secondary_direction = secondary_direction
	_haze_secondary_color = Color(1.0, 1.0, 1.0) * (secondary_energy * PI)


## The sun's light energy above the atmosphere.
func _get_sun_energy() -> float:
	return SOLAR_ENERGY * sun_energy_multiplier


## The moon's light energy above the atmosphere: the full moon's times the lit share
## of its disk.
func _get_moon_energy() -> float:
	return MOON_ENERGY * moon_energy_multiplier * _moon_phase


## Luminance of a light's irradiance (scene units) on a level surface at the sea.
static func _level_irradiance(energy : float, transmittance : Color, direction : Vector3) -> float:
	return PI * energy * _luminance(transmittance) * maxf(direction.y, 0.0)


static func _luminance(color : Color) -> float:
	return Vector3(color.r, color.g, color.b).dot(LUMINANCE_WEIGHTS)


## Share of a sun's or moon's light that reaches the sea, per channel: the
## atmosphere's transmittance (taken at the horizon while the body sets) times the
## share of its disk above the horizon.
func _get_body_transmittance(direction : Vector3, angular_radius : float, with_haze : bool) -> Color:
	var visible := _disk_above_horizon(direction.y, angular_radius)
	if visible <= 0.0:
		return Color.BLACK
	return _get_atmosphere_transmittance(0.0, _above_horizon(direction), with_haze) * visible


## Share of a disk of angular_radius whose centre's elevation has sine height that is
## above the sea's horizon (seen from the sea; no refraction).
static func _disk_above_horizon(height : float, angular_radius : float) -> float:
	var d := clampf(asin(clampf(height, -1.0, 1.0)) / angular_radius, -1.0, 1.0)
	return 1.0 - (acos(d) - d * sqrt(1.0 - d * d)) / PI


## direction lifted onto the horizon when below it.
static func _above_horizon(direction : Vector3) -> Vector3:
	return Vector3(direction.x, maxf(direction.y, 0.0), direction.z).normalized()


## A light's colour from its transmittance: brightest channel 1 (white for black).
static func _light_color(transmittance : Color) -> Color:
	var peak := maxf(transmittance.r, maxf(transmittance.g, transmittance.b))
	if peak <= 0.0:
		return Color.WHITE
	return Color(transmittance.r / peak, transmittance.g / peak, transmittance.b / peak)


## Share of the light from direction that crosses the atmosphere from space down to
## altitude (m above the sea), per channel: the transmittance LUT's integral
## (shaders/compute/atmosphere_transmittance.glsl, same media and steps), with or
## without the haze. Black where the planet is in the way.
func _get_atmosphere_transmittance(altitude : float, direction : Vector3, with_haze : bool) -> Color:
	var h := maxf(altitude, 0.0)
	var r := ATMOSPHERE_EARTH_RADIUS + h
	var mu := direction.normalized().y
	# atmosphere_horizon_mu().
	if mu < -sqrt(h * (2.0 * ATMOSPHERE_EARTH_RADIUS + h)) / r:
		return Color.BLACK
	var top := maxf(AtmosphereRenderer.AIR_TOP_ALTITUDE, AtmosphereRenderer.HAZE_TOP_SCALE_HEIGHTS * _haze_scale_height)
	if h >= top:
		return Color.WHITE
	# Distance to the top along mu (atmosphere_distance_to_top()).
	var c := (top - h) * (2.0 * ATMOSPHERE_EARTH_RADIUS + top + h)
	var b := r * mu
	var root := sqrt(b * b + c)
	var ray_length := c / (b + root) if mu >= 0.0 else root - b
	var haze_density := _haze_density if with_haze else 0.0
	var optical_depth := Vector3.ZERO
	var previous_t := 0.0
	var previous_height := h
	for i in range(1, ATMOSPHERE_TRANSMITTANCE_STEPS + 1):
		var step := float(i) / ATMOSPHERE_TRANSMITTANCE_STEPS
		var t := ray_length * step * step
		# Altitude along the ray (atmosphere_altitude_along()).
		var k := t * (2.0 * r * mu + t)
		var height := h + k / (sqrt(r * r + k) + r)
		# Mean extinction over the step (atmosphere_mean_extinction()).
		var extinction := Vector3.ONE * (haze_density * _exponential_mean(previous_height, height, _haze_scale_height)) \
				+ ATMOSPHERE_RAYLEIGH_SCATTERING * _exponential_mean(previous_height, height, ATMOSPHERE_RAYLEIGH_SCALE_HEIGHT) \
				+ ATMOSPHERE_OZONE_ABSORPTION * _ozone_mean(previous_height, height)
		optical_depth += extinction * (t - previous_t)
		previous_t = t
		previous_height = height
	return Color(exp(-optical_depth.x), exp(-optical_depth.y), exp(-optical_depth.z))


## As atmosphere_exponential_mean().
static func _exponential_mean(h_a : float, h_b : float, scale_height : float) -> float:
	var a := maxf(h_a, 0.0) / scale_height
	var x := maxf(h_b, 0.0) / scale_height - a
	return exp(-a) * (1.0 - 0.5 * x if absf(x) < 1e-4 else (1.0 - exp(-x)) / x)


## As atmosphere_ozone_integral().
static func _ozone_integral(h : float) -> float:
	var w := ATMOSPHERE_OZONE_HALF_WIDTH
	var u := clampf(h - ATMOSPHERE_OZONE_CENTER, -w, w)
	return (u + w) * (u + w) / (2.0 * w) if u <= 0.0 else 0.5 * w + u - u * u / (2.0 * w)


## As atmosphere_ozone_mean().
static func _ozone_mean(h_a : float, h_b : float) -> float:
	var dh := h_b - h_a
	if absf(dh) < 1.0:
		return maxf(1.0 - absf(0.5 * (h_a + h_b) - ATMOSPHERE_OZONE_CENTER) / ATMOSPHERE_OZONE_HALF_WIDTH, 0.0)
	return (_ozone_integral(h_b) - _ozone_integral(h_a)) / dh


## The atmosphere's parameters that follow the weather and the lights. The camera's
## are set every frame by _process_atmosphere().
func _push_atmosphere_parameters() -> void:
	if _atmosphere_renderer == null:
		return
	_atmosphere_renderer.haze_density = _haze_density
	_atmosphere_renderer.haze_scale_height = _haze_scale_height
	_atmosphere_renderer.light_direction = _haze_light_direction
	_atmosphere_renderer.light_color = _haze_light_color
	_atmosphere_renderer.secondary_direction = _haze_secondary_direction
	_atmosphere_renderer.secondary_color = _haze_secondary_color
	_atmosphere_renderer.cloud_shadow_strength = cloud_haze_shadow_strength
	if _cloud_state:
		_atmosphere_renderer.cloud_altitude = _cloud_state.base_altitude
		_atmosphere_renderer.cloud_top_altitude = _cloud_state.base_altitude + _cloud_state.thickness
		_atmosphere_renderer.cloud_ambient_altitude = _cloud_state.base_altitude + 0.5 * _cloud_state.thickness
	if _global_atmosphere_owner == self:
		RenderingServer.global_shader_parameter_set(GLOBAL_LIGHT, get_atmosphere_light())
	var effect := _get_aerial_perspective_effect()
	if effect:
		effect.active = _haze_density > 0.0
		effect.light_direction = _haze_light_direction
		effect.phase_g = _haze_anisotropy


func _get_aerial_perspective_effect() -> AerialPerspectiveEffect:
	if _world_environment == null or _world_environment.compositor == null:
		return null
	for effect in _world_environment.compositor.compositor_effects:
		if effect is AerialPerspectiveEffect:
			return effect
	return null


## A sun or moon light: energy above the atmosphere, transmittance down to the sea.
func _update_light(light : DirectionalLight3D, direction : Vector3, energy : float, transmittance : Color) -> void:
	if light == null:
		return
	var peak := maxf(transmittance.r, maxf(transmittance.g, transmittance.b))
	light.light_color = _light_color(transmittance)
	light.light_energy = energy * peak
	light.visible = light.light_energy > 0.0
	light.look_at(global_position - direction, _get_look_up(direction))


## The sky material's lights. The environment's ambient light is the sky's radiance
## map as rendered (energy 1): the atmosphere and the clouds set its brightness.
func _update_environment(sun_direction : Vector3, moon_direction : Vector3, sun_visibility : float, moon_visibility : float) -> void:
	if _world_environment == null or _world_environment.environment == null:
		return
	var environment := _world_environment.environment
	if environment.sky == null or not environment.sky.sky_material is ShaderMaterial:
		return
	var shader_material := environment.sky.sky_material as ShaderMaterial
	shader_material.set_shader_parameter(&"sun_direction", sun_direction)
	shader_material.set_shader_parameter(&"sun_color", _sun_color)
	shader_material.set_shader_parameter(&"sun_irradiance", Vector3(_sun_irradiance.r, _sun_irradiance.g, _sun_irradiance.b))
	shader_material.set_shader_parameter(&"sun_visibility", sun_visibility if render_bodies_in_sky else 0.0)
	shader_material.set_shader_parameter(&"radiance_sun_disk_strength", radiance_sun_disk_strength)
	shader_material.set_shader_parameter(&"radiance_sun_halo_strength", radiance_sun_halo_strength)
	shader_material.set_shader_parameter(&"moon_direction", moon_direction)
	shader_material.set_shader_parameter(&"moon_color", _moon_color)
	shader_material.set_shader_parameter(&"moon_irradiance", Vector3(_moon_irradiance.r, _moon_irradiance.g, _moon_irradiance.b))
	shader_material.set_shader_parameter(&"moon_visibility", moon_visibility if render_bodies_in_sky else 0.0)
	shader_material.set_shader_parameter(&"moon_phase", _moon_phase)
	_radiance_observer_altitude = _get_atmosphere_observer_altitude()


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


func _update_visual_colors(sun_visibility : float, moon_visibility : float) -> void:
	if render_bodies_in_sky:
		if _sun_visual:
			_sun_visual.visible = false
		if _moon_visual:
			_moon_visual.visible = false
		return
	_set_visual_color(_sun_visual, _sun_color, sun_visibility)
	_set_visual_color(_moon_visual, _moon_color, moon_visibility * _moon_phase)


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


func _calculate_star_visibility(sun_height : float, moon_visibility : float, moon_phase : float) -> float:
	var twilight_visibility := 1.0 - smoothstep(-0.30, -0.10, sun_height)
	var moon_washout := moon_visibility * moon_phase * 0.45
	return clampf(twilight_visibility * (1.0 - moon_washout), 0.0, 1.0)


func _wrap_pi(value : float) -> float:
	return fposmod(value + PI, TAU) - PI


func _get_look_up(direction : Vector3) -> Vector3:
	return Vector3.FORWARD if absf(direction.dot(Vector3.UP)) > 0.98 else Vector3.UP


func _get_active_camera() -> Camera3D:
	var viewport := get_viewport()
	if viewport == null:
		return null
	return viewport.get_camera_3d()


func _get_profile():
	if profile == null:
		profile = SkyProfileResource.new()
	return profile


func _setup_clouds() -> void:
	_release_clouds()
	if clouds_enabled:
		var device := RenderingServer.get_rendering_device()
		if cloud_preset == null:
			push_error("SkySystem.clouds_enabled needs a cloud_preset; clouds are off: %s" % get_path())
		elif device == null:
			push_error("SkySystem clouds need a RenderingDevice (Forward+ or Mobile renderer); clouds are off.")
		else:
			if _cloud_state == null:
				_cloud_state = cloud_preset.duplicate()
			assert(_atmosphere_renderer != null, "SkySystem clouds need the atmosphere (their sky light).")
			_cloud_renderer = CloudRenderer.new(device, cloud_cubemap_size, _atmosphere_renderer.sky_ambient_buffer)
	_push_cloud_material_parameters()
	_update_sky()


func _release_clouds() -> void:
	if _cloud_renderer == null:
		return
	var renderer := _cloud_renderer
	_cloud_renderer = null
	# Unbind the cubemap before its texture is freed.
	_push_cloud_material_parameters()
	renderer.release()


func _start_cloud_transition() -> void:
	var seconds := cloud_transition_seconds if _next_cloud_transition_seconds < 0.0 else _next_cloud_transition_seconds
	_next_cloud_transition_seconds = -1.0
	if cloud_preset == null:
		_cloud_state = null
		_setup_clouds()
		return
	if Engine.is_editor_hint() or seconds <= 0.0 or _cloud_state == null:
		_cloud_state = cloud_preset.duplicate()
		_cloud_transition_duration = 0.0
		if _cloud_renderer:
			_cloud_renderer.restart_history()
			_update_sky()
		else:
			_setup_clouds()
		return
	_cloud_transition_from = _cloud_state.duplicate()
	_cloud_transition_elapsed = 0.0
	_cloud_transition_duration = seconds


func _process_weather_transition(delta : float) -> void:
	_cloud_transition_elapsed += delta
	var weight := clampf(_cloud_transition_elapsed / _cloud_transition_duration, 0.0, 1.0)
	_cloud_state.blend(_cloud_transition_from, cloud_preset, smoothstep(0.0, 1.0, weight))
	if weight >= 1.0:
		_cloud_transition_duration = 0.0
	_update_sky()


func _process_clouds(delta : float) -> void:
	_cloud_wind_offset += _get_cloud_wind_velocity() * delta
	_cloud_evolution_time += _cloud_state.evolution_speed * delta

	# The brighter of the sun and the moon through the atmosphere down to the middle of
	# the cloud layer: high clouds stay lit after the sea has lost the sun, and the moon
	# takes over once the sun no longer reaches them.
	var cloud_altitude := _cloud_state.base_altitude + 0.5 * _cloud_state.thickness
	var light_direction := _sun_direction
	var light_color := _get_atmosphere_transmittance(cloud_altitude, _sun_direction, true) * _get_sun_energy()
	var moon_color := _get_atmosphere_transmittance(cloud_altitude, _moon_direction, true) * _get_moon_energy()
	if _luminance(moon_color) > _luminance(light_color):
		light_direction = _moon_direction
		light_color = moon_color
	light_color *= cloud_light_intensity * _exposure

	_cloud_renderer.update_stride = cloud_update_stride
	_cloud_renderer.view_steps = cloud_view_steps
	_cloud_renderer.light_steps = cloud_light_steps
	_cloud_renderer.max_distance = cloud_max_distance
	_cloud_renderer.render(_get_cloud_camera_position(), _cloud_state, _cloud_wind_offset, _cloud_evolution_time,
		light_direction, light_color, cloud_ambient_intensity)

	# Re-sending the parameters once per full refresh also makes the sky
	# re-render its radiance map, so ambient light and reflections follow the clouds.
	_cloud_frames_until_material_push -= 1
	if _cloud_frames_until_material_push <= 0:
		_cloud_frames_until_material_push = _cloud_renderer.get_refresh_frames()
		_push_cloud_material_parameters()


## Cloud uniforms go through the RenderingServer so the runtime texture is never
## stored in (and saved with) the sky or starfield material resources.
func _push_cloud_material_parameters() -> void:
	var enabled := _cloud_renderer != null
	var texture_rid = _cloud_renderer.cubemap.get_rid() if enabled else null
	for material : Material in [_world_environment.environment.sky.sky_material, _starfield.material_override]:
		RenderingServer.material_set_param(material.get_rid(), &"clouds_enabled", enabled)
		RenderingServer.material_set_param(material.get_rid(), &"cloud_cubemap", texture_rid)
	if enabled:
		RenderingServer.material_set_param(_world_environment.environment.sky.sky_material.get_rid(), &"cloud_base_altitude", _cloud_state.base_altitude)
	_radiance_observer_altitude = _get_atmosphere_observer_altitude()


func _setup_atmosphere() -> void:
	_release_atmosphere()
	var device := RenderingServer.get_rendering_device()
	if device == null:
		push_error("SkySystem's atmosphere needs a RenderingDevice (Forward+ or Mobile renderer); the sky is empty.")
		return
	_atmosphere_renderer = AtmosphereRenderer.new(device)
	_global_atmosphere_owner = self
	_update_exposure()
	RenderingServer.global_shader_parameter_set(GLOBAL_MAX_DISTANCE, AtmosphereRenderer.MAX_DISTANCE)
	var volumes : Array[Texture3DRD] = [_atmosphere_renderer.view_transmittance, _atmosphere_renderer.view_inscatter, _atmosphere_renderer.view_inscatter_lobe]
	var volume_rids : Array[RID] = []
	for i in volumes.size():
		RenderingServer.global_shader_parameter_set(GLOBAL_VIEW_TEXTURES[i], volumes[i])
		volume_rids.push_back(volumes[i].texture_rd_rid)
	var effect := _get_aerial_perspective_effect()
	if effect:
		effect.view_textures = volume_rids
		effect.max_distance = AtmosphereRenderer.MAX_DISTANCE
	_update_sky()
	# Consumers start reading once the volumes hold this frame's atmosphere.
	_process_atmosphere()
	RenderingServer.global_shader_parameter_set(GLOBAL_ENABLED, true)


## Unbinds the atmosphere's textures from every consumer, then frees them.
func _release_atmosphere() -> void:
	if _atmosphere_renderer == null:
		return
	if _global_atmosphere_owner == self:
		_global_atmosphere_owner = null
		RenderingServer.global_shader_parameter_set(GLOBAL_ENABLED, false)
		if _placeholder_volume == null:
			var image := Image.create_empty(1, 1, false, Image.FORMAT_RGBAH)
			image.fill(Color.WHITE)
			_placeholder_volume = ImageTexture3D.new()
			_placeholder_volume.create(Image.FORMAT_RGBAH, 1, 1, 1, false, [image])
		for global in GLOBAL_VIEW_TEXTURES:
			RenderingServer.global_shader_parameter_set(global, _placeholder_volume)
	var effect := _get_aerial_perspective_effect()
	if effect:
		effect.active = false
		effect.view_textures = []
	var renderer := _atmosphere_renderer
	_atmosphere_renderer = null
	_sky_irradiance = -1.0
	# Sky sources' consumers (the ocean) drop the sea-level volumes on this signal.
	lighting_changed.emit()
	renderer.release()


## Renders the atmosphere for the active camera and points its consumers at that
## camera. Refreshes the sky's radiance map once the camera's altitude has moved on.
func _process_atmosphere() -> void:
	var camera_position := _get_cloud_camera_position()
	var observer_altitude := _get_atmosphere_observer_altitude()
	var cloud_cubemap := _cloud_renderer.cubemap.texture_rd_rid if _cloud_renderer else RID()
	_atmosphere_renderer.render(camera_position.y - sea_level, cloud_cubemap, _exposure)
	_read_camera_sky_light()
	if _global_atmosphere_owner == self:
		RenderingServer.global_shader_parameter_set(GLOBAL_OBSERVER, Vector4(camera_position.x, camera_position.y, camera_position.z, observer_altitude))
	var effect := _get_aerial_perspective_effect()
	if effect:
		effect.observer_position = camera_position
		effect.observer_altitude = observer_altitude
	if absf(observer_altitude - _radiance_observer_altitude) > maxf(2.0, RADIANCE_ALTITUDE_TOLERANCE * _radiance_observer_altitude):
		_refresh_sky_radiance()


## Reads the sky's light at the camera back from the GPU, one request at a time: the
## light meter lags a frame or two.
func _read_camera_sky_light() -> void:
	if _sky_light_read_pending:
		return
	_sky_light_read_pending = true
	var renderer := _atmosphere_renderer
	var exposure := _exposure
	# The callback may run outside the main thread's frame logic; hand the data over deferred.
	var on_read := func(data : PackedByteArray) -> void:
		_on_camera_sky_light_read.call_deferred(renderer, exposure, data)
	var error := RenderingServer.get_rendering_device().buffer_get_data_async(renderer.camera_sky_light_buffer, on_read, 0, AtmosphereRenderer.SKY_LIGHT_SIZE)
	assert(error == OK, "buffer_get_data_async failed: %s" % error_string(error))


func _on_camera_sky_light_read(renderer : AtmosphereRenderer, exposure : float, data : PackedByteArray) -> void:
	_sky_light_read_pending = false
	# A readback from a renderer released since describes a sky that is gone.
	if renderer != _atmosphere_renderer:
		return
	var floats := data.to_float32_array()
	_sky_irradiance = Vector3(floats[8], floats[9], floats[10]).dot(LUMINANCE_WEIGHTS) / exposure


## Reads the camera's exposure and publishes it with the atmosphere.
func _update_exposure() -> void:
	var camera := _get_render_camera()
	var attributes : CameraAttributes = camera.attributes if camera and camera.attributes else get_world_3d().camera_attributes
	_exposure = attributes.exposure_multiplier if attributes else 1.0
	if _global_atmosphere_owner == self:
		RenderingServer.global_shader_parameter_set(GLOBAL_EXPOSURE, _exposure)


## The camera altitude the atmosphere's camera volume is built for (0 without one).
func _get_atmosphere_observer_altitude() -> float:
	if _atmosphere_renderer == null:
		return 0.0
	return _atmosphere_renderer.get_observer_altitude(_get_cloud_camera_position().y - sea_level)


## The sky reads the camera's altitude from the atmosphere, not POSITION (which
## re-renders the radiance map on every camera move), so the engine does not see
## it change. Re-sending a sky parameter makes it render the radiance map again.
func _refresh_sky_radiance() -> void:
	_radiance_observer_altitude = _get_atmosphere_observer_altitude()
	var material := _world_environment.environment.sky.sky_material
	RenderingServer.material_set_param(material.get_rid(), &"sun_direction", _sun_direction)


func _get_cloud_sun_light_scale() -> float:
	return _cloud_state.sun_light_scale if _cloud_renderer else 1.0


func _resolve_cloud_wind_source() -> void:
	_cloud_wind_source = null if cloud_wind_source_path.is_empty() else get_node(cloud_wind_source_path)


func _get_cloud_wind_velocity() -> Vector2:
	var speed := cloud_wind_speed
	var direction := cloud_wind_direction
	if _cloud_wind_source:
		speed = _read_wind_value(&"get_wind_speed", &"wind_speed") * cloud_wind_speed_multiplier
		direction = _read_wind_value(&"get_wind_direction_degrees", &"wind_direction")
	var radians := deg_to_rad(direction)
	return Vector2(sin(radians), cos(radians)) * speed


func _read_wind_value(method : StringName, property : StringName) -> float:
	if _cloud_wind_source.has_method(method):
		return float(_cloud_wind_source.call(method))
	return float(_cloud_wind_source.get(property))


func _get_cloud_camera_position() -> Vector3:
	var camera := _get_render_camera()
	return camera.global_position if camera else global_position


## The camera the sky is rendered for: the editor's in the editor, else the active one.
func _get_render_camera() -> Camera3D:
	if Engine.is_editor_hint():
		return Engine.get_singleton(&"EditorInterface").get_editor_viewport_3d(0).get_camera_3d()
	return _get_active_camera()
