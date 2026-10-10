@tool
class_name ExposureController
extends Node
## Sets a camera's exposure from the light falling on the scene, as an incident-light
## meter would, and adapts to it over time as an eye does. It reads a light source (any
## node with get_scene_illuminance() and get_illuminance_unit_lux(), e.g. SkySystem), not
## the rendered image, so looking at the sun or the sea does not change it.
##
## The meter: a grey card (18 %) in the metered light renders at 0.18 (a white diffuser
## at 1), times exposure_compensation_ev. With perceptual_adaptation the eye adapts only
## partly in dim light (Krawczyk, Myszkowski and Seidel 2005, "Lightness perception in
## tone reproduction for high dynamic range images"): twilight and night stay darker than
## day.
##
## Writes target's CameraAttributes.exposure_multiplier at runtime only (in the editor it
## only shows configuration warnings). Godot applies it to the scene's light before
## rendering (needs physical light units off).

## Grey card reflectance: the meter's middle grey.
const GREY_REFLECTANCE := 0.18
## Grey-card luminance (cd/m2) at and above which the eye counts as fully adapted, like
## a photograph: a bright overcast day.
const DAYLIGHT_GREY_LUMINANCE := 1000.0
## Grey-card luminance (cd/m2) below which the eye adapts no further (a moonless night).
const DARKEST_GREY_LUMINANCE := 1e-4

## The node metering the light: get_scene_illuminance() (lux on a level surface at the
## camera, negative while unknown) and get_illuminance_unit_lux() (lux of a scene
## irradiance of 1).
@export var light_source_path : NodePath :
	set(value):
		light_source_path = value
		update_configuration_warnings()
## A WorldEnvironment (its camera_attributes) or a Camera3D (its attributes) to expose.
## One without CameraAttributes gets a CameraAttributesPractical.
@export var target_path : NodePath :
	set(value):
		target_path = value
		update_configuration_warnings()
## Exposure on top of the meter's, in stops.
@export_range(-10.0, 10.0, 0.1) var exposure_compensation_ev := 0.0
## Adapt like an eye (dim light stays darker) instead of like a camera (every light
## level exposed alike).
@export var perceptual_adaptation := true
## Time constants (s) of adapting to more light and to less: the eye adapts to light
## quickly and to darkness slowly.
@export_range(0.0, 60.0, 0.1, "or_greater") var brighten_seconds := 1.0
@export_range(0.0, 600.0, 0.1, "or_greater") var darken_seconds := 5.0
## See like an eye in dim light: colours fade to a slightly blue grey where the scene
## is dark (rods take over from cones, NightVisionEffect). Added to the target's
## compositor at runtime; needs a RenderingDevice (Forward+ or Mobile).
@export var night_vision := true
## How far colours shift toward rod vision (0-1).
@export_range(0.0, 1.0, 0.01) var night_vision_strength := 1.0

var _light_source : Node
var _attributes : CameraAttributes
## The target's compositor holding _night_vision, and the effect; null without.
var _compositor : Compositor
var _night_vision : NightVisionEffect
## Illuminance (lux) the eye is adapted to; < 0 before the first reading.
var _adapted_lux := -1.0


func _ready() -> void:
	if Engine.is_editor_hint():
		set_process(false)
		return
	_light_source = get_node_or_null(light_source_path)
	if not _is_light_source(_light_source):
		push_error("ExposureController %s: light_source_path must point to a node with get_scene_illuminance() and get_illuminance_unit_lux(); exposure is fixed." % get_path())
		set_process(false)
		return
	var target := get_node_or_null(target_path)
	if target is WorldEnvironment:
		if target.camera_attributes == null:
			target.camera_attributes = CameraAttributesPractical.new()
		_attributes = target.camera_attributes
	elif target is Camera3D:
		if target.attributes == null:
			target.attributes = CameraAttributesPractical.new()
		_attributes = target.attributes
	else:
		push_error("ExposureController %s: target_path must point to a WorldEnvironment or a Camera3D; exposure is fixed." % get_path())
		set_process(false)
		return
	if night_vision:
		_add_night_vision(target)


func _exit_tree() -> void:
	if _compositor and _night_vision:
		var effects := _compositor.compositor_effects
		effects.erase(_night_vision)
		_compositor.compositor_effects = effects
	_compositor = null
	_night_vision = null


## Appends a NightVisionEffect to the target's compositor (created if missing).
func _add_night_vision(target : Node) -> void:
	if RenderingServer.get_rendering_device() == null:
		push_error("ExposureController %s: night vision needs a RenderingDevice (Forward+ or Mobile renderer); it is off." % get_path())
		return
	var effect := NightVisionEffect.new()
	if not effect.is_valid():
		return
	_compositor = target.get(&"compositor")
	if _compositor == null:
		_compositor = Compositor.new()
		target.set(&"compositor", _compositor)
	var effects := _compositor.compositor_effects
	effects.push_back(effect)
	_compositor.compositor_effects = effects
	_night_vision = effect


func _get_configuration_warnings() -> PackedStringArray:
	var warnings := PackedStringArray()
	if not _is_light_source(get_node_or_null(light_source_path)):
		warnings.push_back("light_source_path must point to a node with get_scene_illuminance() and get_illuminance_unit_lux(), e.g. a SkySystem. Without it the exposure is fixed.")
	var target := get_node_or_null(target_path)
	if not (target is WorldEnvironment or target is Camera3D):
		warnings.push_back("target_path must point to the WorldEnvironment (e.g. SkySystem/WorldEnvironment) or the Camera3D to expose. Without it the exposure is fixed.")
	return warnings


static func _is_light_source(node : Node) -> bool:
	return node != null and node.has_method(&"get_scene_illuminance") and node.has_method(&"get_illuminance_unit_lux")


## The illuminance (lux) the exposure is currently adapted to; < 0 before the first reading.
func get_adapted_illuminance() -> float:
	return _adapted_lux


func _process(delta : float) -> void:
	if _attributes == null:
		return
	var lux : float = _light_source.get_scene_illuminance()
	if lux < 0.0:
		return
	lux = maxf(lux, DARKEST_GREY_LUMINANCE * PI / GREY_REFLECTANCE)
	if _adapted_lux < 0.0:
		_adapted_lux = lux
	else:
		var time_constant := brighten_seconds if lux > _adapted_lux else darken_seconds
		var weight := 1.0 - exp(-delta / time_constant) if time_constant > 0.0 else 1.0
		_adapted_lux = exp(lerpf(log(_adapted_lux), log(lux), weight))
	var unit_lux : float = _light_source.get_illuminance_unit_lux()
	_attributes.exposure_multiplier = _get_exposure(_adapted_lux, unit_lux)
	if _night_vision:
		_night_vision.luminance_scale = unit_lux / _attributes.exposure_multiplier
		_night_vision.strength = night_vision_strength


## The exposure for an eye adapted to lux, in the light source's units (unit_lux: lux of
## its irradiance 1): a white diffuser in that light (radiance irradiance / pi) renders
## at 1, dimmed in dim light by perceptual adaptation.
func _get_exposure(lux : float, unit_lux : float) -> float:
	var exposure := PI * unit_lux / lux * pow(2.0, exposure_compensation_ev)
	if perceptual_adaptation:
		var grey_luminance := GREY_REFLECTANCE * lux / PI
		exposure *= minf(_lightness_key(grey_luminance) / _lightness_key(DAYLIGHT_GREY_LUMINANCE), 1.0)
	return exposure


## Krawczyk et al.'s key: the lightness (0-1) an eye adapted to a scene of mean
## luminance (cd/m2) gives that luminance.
static func _lightness_key(luminance : float) -> float:
	return 1.03 - 2.0 / (2.0 + log(luminance + 1.0) / log(10.0))
