extends Node
## Planar reflection pass for an GREOceanSystem (internal; preloaded, not a global
## class): renders a camera mirrored across the water plane into a SubViewport.
## Created and configured by GREOceanSystem, which sets the properties below and then
## calls apply(). The water reads the capture effect's texture (linear HDR, with mips
## for rough water), not the viewport's tonemapped output.

const PLANAR_REFLECTION_CAPTURE_EFFECT := preload("res://addons/gre_ocean_system/planar_reflection_capture_effect.gd")

## Enables the offscreen mirrored camera pass. When disabled, the viewport stops
## rendering and the water material receives zero planar reflection strength.
var enabled := true
## Maximum side length of the planar reflection texture in pixels (the aspect
## ratio is kept). Larger values sharpen reflected objects but cost more.
var texture_size := 1024
## Multiplier applied to the main viewport size before clamping to texture_size.
## Lower values are cheaper and blurrier; higher values preserve detail.
var resolution_scale := 0.5
## How much reflected geometry covers the sky reflection behind it (1 = fully).
var reflection_strength := 1.0
## Render layers visible to the reflection camera. The configured water layer is
## always removed so the ocean does not recursively reflect itself.
var reflection_cull_mask := 0xFFFFF
## Clears reflected pixels whose depth reconstructs below the water plane. This
## prevents submerged/sinking geometry from appearing in the planar reflection.
var clip_below_water := true
## Extra distance below the water plane that remains visible in the reflection.
## A small bias avoids edge flicker when geometry intersects the surface.
var clip_bias := 0.03
## Render layer assigned to the water mesh for exclusion from the reflection
## camera. Keep this layer reserved for water if planar reflections are enabled.
var water_layer := 20

var water_level := 0.0

var _viewport : SubViewport
var _camera : Camera3D
var _reflection_environment : Environment
var _capture_effect : GREPlanarReflectionCaptureEffect
## Sends a water shader parameter: GREOceanSystem._set_water_shader_parameter.
var _set_parameter : Callable


func _init(set_parameter : Callable) -> void:
	_set_parameter = set_parameter


func _ready() -> void:
	process_priority = 110
	_reflection_environment = Environment.new()
	_reflection_environment.background_mode = Environment.BG_COLOR
	_reflection_environment.background_color = Color(0.0, 0.0, 0.0, 0.0)
	_reflection_environment.background_energy_multiplier = 0.0
	# Its background must stay empty, so it can't share the scene's sky: flat ambient light
	# (set_ambient()) keeps what the sun doesn't reach from reflecting black.
	_reflection_environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	_reflection_environment.ambient_light_color = Color.BLACK
	_reflection_environment.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED

	_capture_effect = PLANAR_REFLECTION_CAPTURE_EFFECT.new()
	var compositor := Compositor.new()
	compositor.compositor_effects = [_capture_effect]

	_viewport = SubViewport.new()
	_viewport.name = "PlanarReflectionViewport"
	_viewport.disable_3d = false
	_viewport.transparent_bg = true
	_viewport.msaa_3d = Viewport.MSAA_DISABLED
	_viewport.screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED
	_viewport.use_taa = false
	_viewport.world_3d = get_viewport().world_3d
	add_child(_viewport)

	_camera = Camera3D.new()
	_camera.name = "PlanarReflectionCamera"
	_camera.current = true
	_camera.environment = _reflection_environment
	_camera.compositor = compositor
	# Mirrored from the main camera every frame; with physics interpolation on, interpolating it
	# again would lag the reflection behind the view.
	_camera.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	_viewport.add_child(_camera)


## Applies the current settings to the reflection and to water, the ocean's geometry
## (it goes on water_layer). GREOceanSystem calls this after changing any property.
func apply(water : GeometryInstance3D, target_water_level: float) -> void:
	water_level = target_water_level
	water.layers = _layer_bit(water_layer)
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS if enabled else SubViewport.UPDATE_DISABLED
	set_process(enabled)
	_capture_effect.enabled = enabled
	_capture_effect.set_parameters({&"clip_below_water": clip_below_water, &"water_level": water_level, &"clip_bias": clip_bias})
	_update_viewport_size()
	_update_water_material()


## The ambient light reflected geometry gets (radiance, scene units). GREOceanSystem calls this every
## frame.
func set_ambient(radiance: Color) -> void:
	_reflection_environment.ambient_light_color = radiance


func _process(_delta: float) -> void:
	_viewport.world_3d = get_viewport().world_3d
	_update_viewport_size()
	var source_camera := get_viewport().get_camera_3d()
	# No active camera (e.g. during scene changes): keep the last reflection.
	if source_camera == null:
		return
	_sync_camera(source_camera)
	_update_view_projection()


func _update_viewport_size() -> void:
	# Scale both axes alike: a different aspect would narrow the reflection
	# camera's field of view and cut off the sides of the reflection.
	var scaled := Vector2(get_viewport().get_visible_rect().size) * resolution_scale
	scaled *= minf(1.0, float(texture_size) / maxf(scaled.x, scaled.y))
	_viewport.size = Vector2i(maxi(int(roundf(scaled.x)), 128), maxi(int(roundf(scaled.y)), 128))
	_capture_effect.set_size(_viewport.size)


func _sync_camera(source_camera: Camera3D) -> void:
	var source_transform := source_camera.global_transform
	var reflected_origin := _reflect_position(source_transform.origin)
	var reflected_forward := _reflect_direction(-source_transform.basis.z).normalized()
	var reflected_up := _reflect_direction(source_transform.basis.y).normalized()

	_camera.global_position = reflected_origin
	_camera.look_at(reflected_origin + reflected_forward, reflected_up)
	_camera.fov = source_camera.fov
	_camera.size = source_camera.size
	_camera.near = source_camera.near
	_camera.far = source_camera.far
	_camera.keep_aspect = source_camera.keep_aspect
	_camera.projection = source_camera.projection
	_camera.h_offset = source_camera.h_offset
	_camera.v_offset = source_camera.v_offset
	_camera.frustum_offset = source_camera.frustum_offset
	_camera.attributes = source_camera.attributes
	_camera.cull_mask = reflection_cull_mask & ~_layer_bit(water_layer)


func _reflect_position(position: Vector3) -> Vector3:
	var reflected := position
	reflected.y = 2.0 * water_level - position.y
	return reflected


func _reflect_direction(direction: Vector3) -> Vector3:
	return Vector3(direction.x, -direction.y, direction.z)


func _update_water_material() -> void:
	_set_parameter.call(&"planar_reflection_enabled", enabled)
	_set_parameter.call(&"planar_reflection_texture", _capture_effect.texture)
	_set_parameter.call(&"planar_reflection_distance", _capture_effect.distance_texture)
	_set_parameter.call(&"planar_reflection_strength", reflection_strength if enabled else 0.0)
	_update_view_projection()


## The reflection parameters that change every frame.
func _update_view_projection() -> void:
	var view_projection := _camera.get_camera_projection() * Projection(_camera.global_transform.affine_inverse())
	_set_parameter.call(&"planar_reflection_view_projection", view_projection)
	_set_parameter.call(&"planar_reflection_camera_position", _camera.global_position)


func _layer_bit(layer: int) -> int:
	return 1 << clampi(layer - 1, 0, 19)
