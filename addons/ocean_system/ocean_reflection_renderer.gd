class_name OceanReflectionRenderer
extends Node

const DEFAULT_WATER_LAYER := 20
const PLANAR_REFLECTION_CLIP_EFFECT := preload("res://addons/ocean_system/planar_reflection_clip_effect.gd")

## Enables the offscreen mirrored camera pass. When disabled, the viewport stops
## rendering and the water material receives zero planar reflection strength.
@export var enabled := true :
	set(value):
		enabled = value
		set_process(enabled)
		if _viewport != null:
			_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS if enabled else SubViewport.UPDATE_DISABLED
		_update_clip_effect()
		_update_water_material()

## Maximum side length of the planar reflection texture in pixels. Larger values
## sharpen reflected objects but increase render cost and memory use.
@export_range(128, 4096, 1) var texture_size := 1024 :
	set(value):
		texture_size = value
		_update_viewport_size()

## Multiplier applied to the main viewport size before clamping to texture_size.
## Lower values are cheaper and blurrier; higher values preserve detail.
@export_range(0.1, 1.0, 0.05) var resolution_scale := 0.5 :
	set(value):
		resolution_scale = value
		_update_viewport_size()

## Overall brightness of dynamic geometry reflections. This is multiplied by the
## water Fresnel term, so grazing angles still appear stronger.
@export_range(0.0, 1.0, 0.01) var reflection_strength := 0.42 :
	set(value):
		reflection_strength = value
		_update_water_material()

## UV distortion amount from wave normals. Higher values make reflected objects
## wobble and break up more; too high can make reflections hard to read.
@export_range(0.0, 0.08, 0.001) var reflection_distortion := 0.018 :
	set(value):
		reflection_distortion = value
		_update_water_material()

## Fresnel falloff exponent for planar reflections. Higher values concentrate
## reflections near grazing angles; lower values make them visible head-on.
@export_range(0.25, 8.0, 0.05) var fresnel_power := 4.0 :
	set(value):
		fresnel_power = value
		_update_water_material()

## Render layers visible to the reflection camera. The configured water layer is
## always removed so the ocean does not recursively reflect itself.
@export_flags_3d_render var reflection_cull_mask := 0xFFFFF :
	set(value):
		reflection_cull_mask = value
		_update_water_material()

## Clears reflected pixels whose depth reconstructs below the water plane. This
## prevents submerged/sinking geometry from appearing in the planar reflection.
@export var clip_below_water := true :
	set(value):
		clip_below_water = value
		_update_clip_effect()

## Extra distance below the water plane that remains visible in the reflection.
## A small bias avoids edge flicker when geometry intersects the surface.
@export_range(0.0, 1.0, 0.005) var clip_bias := 0.03 :
	set(value):
		clip_bias = value
		_update_clip_effect()

## Render layer assigned to the water mesh for exclusion from the reflection
## camera. Keep this layer reserved for water if planar reflections are enabled.
@export_range(1, 20, 1) var water_layer := DEFAULT_WATER_LAYER :
	set(value):
		water_layer = value
		if water != null:
			water.layers = _layer_bit(water_layer)
		_update_water_material()

var water : MeshInstance3D
var water_level := 0.0

var _viewport : SubViewport
var _camera : Camera3D
var _reflection_environment : Environment
var _reflection_compositor : Compositor
var _clip_effect : CompositorEffect

func _ready() -> void:
	process_priority = 110
	_create_reflection_environment()
	_create_reflection_viewport()
	set_process(enabled)
	_update_water_material()

func _process(_delta: float) -> void:
	if not enabled:
		return

	_update_viewport_world()
	_update_viewport_size()
	var source_camera := _get_source_camera()
	if source_camera == null or _camera == null:
		return

	_sync_camera(source_camera)

func setup(target_water: MeshInstance3D, target_water_level: float) -> void:
	water = target_water
	water_level = target_water_level
	if water != null:
		water.layers = _layer_bit(water_layer)
	_update_clip_effect()
	_update_water_material()

func set_water_level(value: float) -> void:
	water_level = value
	_update_clip_effect()
	_update_water_material()

func get_reflection_texture() -> Texture2D:
	return _viewport.get_texture() if _viewport != null else null

func _create_reflection_viewport() -> void:
	if _viewport != null:
		return

	_viewport = SubViewport.new()
	_viewport.name = "PlanarReflectionViewport"
	_viewport.disable_3d = false
	_viewport.transparent_bg = true
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS if enabled else SubViewport.UPDATE_DISABLED
	_viewport.msaa_3d = Viewport.MSAA_DISABLED
	_viewport.screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED
	_viewport.use_taa = false
	add_child(_viewport)
	_update_viewport_world()

	_camera = Camera3D.new()
	_camera.name = "PlanarReflectionCamera"
	_camera.current = true
	_camera.environment = _reflection_environment
	_camera.compositor = _create_reflection_compositor()
	_viewport.add_child(_camera)

	_update_viewport_size()

func _update_viewport_size() -> void:
	if _viewport == null:
		return
	var root_viewport := get_viewport()
	if root_viewport == null:
		_viewport.size = Vector2i(texture_size, texture_size)
		return
	var scaled := Vector2(root_viewport.get_visible_rect().size) * resolution_scale
	var width := clampi(int(roundf(scaled.x)), 128, texture_size)
	var height := clampi(int(roundf(scaled.y)), 128, texture_size)
	_viewport.size = Vector2i(width, height)

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
	_update_water_material()

func _update_viewport_world() -> void:
	if _viewport == null:
		return
	var root_viewport := get_viewport()
	if root_viewport != null:
		_viewport.world_3d = root_viewport.world_3d

func _reflect_position(position: Vector3) -> Vector3:
	var reflected := position
	reflected.y = 2.0 * water_level - position.y
	return reflected

func _reflect_direction(direction: Vector3) -> Vector3:
	return Vector3(direction.x, -direction.y, direction.z)

func _get_source_camera() -> Camera3D:
	var viewport := get_viewport()
	if viewport == null:
		return null
	var camera := viewport.get_camera_3d()
	if camera == _camera:
		return null
	return camera

func _update_water_material() -> void:
	if water == null or not (water.material_override is ShaderMaterial):
		return
	var material := water.material_override as ShaderMaterial
	material.set_shader_parameter(&"planar_reflection_enabled", enabled)
	material.set_shader_parameter(&"planar_reflection_texture", get_reflection_texture())
	material.set_shader_parameter(&"planar_reflection_strength", reflection_strength if enabled else 0.0)
	material.set_shader_parameter(&"planar_reflection_distortion", reflection_distortion)
	material.set_shader_parameter(&"planar_reflection_fresnel_power", fresnel_power)
	material.set_shader_parameter(&"planar_reflection_plane_y", water_level)
	if _camera != null:
		var view_projection := _camera.get_camera_projection() * Projection(_camera.global_transform.affine_inverse())
		material.set_shader_parameter(&"planar_reflection_view_projection", view_projection)

func _create_reflection_environment() -> void:
	if _reflection_environment != null:
		return
	_reflection_environment = Environment.new()
	_reflection_environment.background_mode = Environment.BG_COLOR
	_reflection_environment.background_color = Color(0.0, 0.0, 0.0, 0.0)
	_reflection_environment.background_energy_multiplier = 0.0
	_reflection_environment.ambient_light_energy = 0.0
	_reflection_environment.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED

func _create_reflection_compositor() -> Compositor:
	if _reflection_compositor != null:
		return _reflection_compositor
	_reflection_compositor = Compositor.new()
	_clip_effect = PLANAR_REFLECTION_CLIP_EFFECT.new()
	_reflection_compositor.compositor_effects = [_clip_effect]
	_update_clip_effect()
	return _reflection_compositor

func _update_clip_effect() -> void:
	if _clip_effect == null:
		return
	_clip_effect.enabled = enabled and clip_below_water
	_clip_effect.water_level = water_level
	_clip_effect.clip_bias = clip_bias

func _layer_bit(layer: int) -> int:
	return 1 << clampi(layer - 1, 0, 19)
