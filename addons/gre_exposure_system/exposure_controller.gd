@tool
class_name GREExposureController
extends Node
## Sets a camera's exposure from the light falling on the scene, as an incident-light
## meter would, and adapts to it over time as an eye does. It reads a light source (any
## node with get_scene_illuminance() and get_illuminance_unit_lux(), e.g. GRESkySystem).
## With adapt_to_view, a view brighter than that light (a low moon's or sun's glow,
## bright sky) adapts the eye further, as glare does; a darker one (the sea) does not.
##
## The meter: a grey card (18 %) in the metered light renders at 0.18 (a white diffuser
## at 1), times exposure_compensation_ev. The view counts as the light under which a grey
## card is as bright as its log-average luminance plus its bright parts' glare (GREViewLuminanceEffect). With perceptual_adaptation the eye adapts only
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
## Readings above this illuminance (lux; full sun is ~130000) count as it: a sudden jump
## to daylight overflows the sky's buffers pre-exposed for the night (infinite readings),
## and an exposure of 0 from them would never recover.
const BRIGHTEST_ILLUMINANCE := 1e6

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
## Time constant (s) of adapting to more light: the eye adapts to light quickly and to
## darkness slowly (darken_seconds).
@export_range(0.0, 60.0, 0.1, "or_greater") var brighten_seconds := 1.0
## Time constant (s) of adapting to less light.
@export_range(0.0, 600.0, 0.1, "or_greater") var darken_seconds := 5.0
## See like an eye in dim light: colours fade to a slightly blue grey where the scene
## is dark (rods take over from cones, GRENightVisionEffect). Added to the target's
## compositor at runtime; needs a RenderingDevice (Forward+ or Mobile).
@export var night_vision := true
## How far colours shift toward rod vision (0-1).
@export_range(0.0, 1.0, 0.01) var night_vision_strength := 1.0
## Adapt to the view as well: the eye adapts to what it looks at, so a bright glow in
## view (a low moon in haze) lowers the exposure instead of clipping to white. Measured
## on the rendered image by a GREViewLuminanceEffect added to the target's compositor at
## runtime; needs a RenderingDevice (Forward+ or Mobile).
@export var adapt_to_view := true

var _light_source : Node
var _attributes : CameraAttributes
## The target's compositor holding the effects below, which are null without.
var _compositor : Compositor
var _night_vision : GRENightVisionEffect
var _view_meter : GREViewLuminanceEffect
## Illuminance (lux) the eye is adapted to; < 0 before the first reading.
var _adapted_lux := -1.0


func _ready() -> void:
	if Engine.is_editor_hint():
		set_process(false)
		return
	_light_source = get_node_or_null(light_source_path)
	if not _is_light_source(_light_source):
		push_error("GREExposureController %s: light_source_path must point to a node with get_scene_illuminance() and get_illuminance_unit_lux(); exposure is fixed." % get_path())
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
		push_error("GREExposureController %s: target_path must point to a WorldEnvironment or a Camera3D; exposure is fixed." % get_path())
		set_process(false)
		return
	if (adapt_to_view or night_vision) and RenderingServer.get_rendering_device() == null:
		push_error("GREExposureController %s: adapt_to_view and night vision need a RenderingDevice (Forward+ or Mobile renderer); they are off." % get_path())
		return
	# The meter runs first: it measures the view before night vision changes it.
	if adapt_to_view:
		var meter := GREViewLuminanceEffect.new()
		if meter.is_valid():
			_add_effect(target, meter)
			_view_meter = meter
	if night_vision:
		var effect := GRENightVisionEffect.new()
		if effect.is_valid():
			_add_effect(target, effect)
			_night_vision = effect


func _exit_tree() -> void:
	if _compositor:
		var effects := _compositor.compositor_effects
		effects.erase(_view_meter)
		effects.erase(_night_vision)
		_compositor.compositor_effects = effects
	_compositor = null
	_night_vision = null
	_view_meter = null
	# Re-entering the tree (a reparent, a level put back) runs _ready() again, which adds
	# the effects back.
	request_ready()


## Appends effect to the target's compositor (created if missing).
func _add_effect(target : Node, effect : CompositorEffect) -> void:
	if _compositor == null:
		_compositor = target.get(&"compositor")
	if _compositor == null:
		_compositor = Compositor.new()
		target.set(&"compositor", _compositor)
	var effects := _compositor.compositor_effects
	effects.push_back(effect)
	_compositor.compositor_effects = effects


func _get_configuration_warnings() -> PackedStringArray:
	var warnings := PackedStringArray()
	if not _is_light_source(get_node_or_null(light_source_path)):
		warnings.push_back("light_source_path must point to a node with get_scene_illuminance() and get_illuminance_unit_lux(), e.g. a GRESkySystem. Without it the exposure is fixed.")
	var target := get_node_or_null(target_path)
	if not (target is WorldEnvironment or target is Camera3D):
		warnings.push_back("target_path must point to the WorldEnvironment (e.g. GRESkySystem/WorldEnvironment) or the Camera3D to expose. Without it the exposure is fixed.")
	return warnings


static func _is_light_source(node : Node) -> bool:
	return node != null and node.has_method(&"get_scene_illuminance") and node.has_method(&"get_illuminance_unit_lux")


## The emission (or light) energy that makes something seen from node's viewport glow
## at glow times the screen's white whatever the eye is adapted to: lamps, signal
## lights, screens, which would otherwise vanish at noon and blind at night. Reads the
## exposure of the camera's attributes, else the world's; call it every frame.
static func display_energy(node : Node, glow : float) -> float:
	var viewport := node.get_viewport()
	if viewport == null:
		return glow
	var camera := viewport.get_camera_3d()
	var world := viewport.find_world_3d()
	var attributes : CameraAttributes = null
	if camera != null and camera.attributes != null:
		attributes = camera.attributes
	elif world != null:
		attributes = world.camera_attributes
	return glow / maxf(attributes.exposure_multiplier, 1e-6) if attributes != null else glow


## The illuminance (lux) the exposure is currently adapted to; < 0 before the first reading.
func get_adapted_illuminance() -> float:
	return _adapted_lux


func _process(delta : float) -> void:
	# A freed light source leaves the exposure where it was.
	if _attributes == null or not is_instance_valid(_light_source):
		return
	var lux : float = _light_source.get_scene_illuminance()
	if lux < 0.0 or is_nan(lux):
		return
	if _view_meter:
		var view_luminance := _view_meter.get_view_luminance()
		if view_luminance > 0.0:
			lux = maxf(lux, view_luminance * PI / GREY_REFLECTANCE)
	lux = clampf(lux, DARKEST_GREY_LUMINANCE * PI / GREY_REFLECTANCE, BRIGHTEST_ILLUMINANCE)
	if _adapted_lux < 0.0:
		_adapted_lux = lux
	else:
		var time_constant := brighten_seconds if lux > _adapted_lux else darken_seconds
		var weight := 1.0 - exp(-delta / time_constant) if time_constant > 0.0 else 1.0
		_adapted_lux = exp(lerpf(log(_adapted_lux), log(lux), weight))
	var unit_lux : float = _light_source.get_illuminance_unit_lux()
	if not (unit_lux > 0.0 and is_finite(unit_lux)):
		return
	_attributes.exposure_multiplier = _get_exposure(_adapted_lux, unit_lux)
	var luminance_scale := unit_lux / _attributes.exposure_multiplier
	if _view_meter:
		_view_meter.luminance_scale = luminance_scale
	if _night_vision:
		_night_vision.luminance_scale = luminance_scale
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
