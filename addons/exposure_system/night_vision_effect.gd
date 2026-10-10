class_name NightVisionEffect
extends CompositorEffect
## Rod vision in dim light (night_vision.glsl): colours fade to a slightly blue grey
## where the scene's luminance is low, per pixel. ExposureController adds it to its
## target's compositor at runtime and sets luminance_scale every frame; it runs after
## the transparent pass, on the HDR colour before tonemapping.

const SHADER := preload("res://addons/exposure_system/night_vision.glsl")

## cd/m2 of a colour-buffer value of 1 (lux of the scene's irradiance 1 over the
## exposure). 0 turns the effect off.
var luminance_scale := 0.0 :
	set(value):
		_params_mutex.lock()
		luminance_scale = value
		_params_mutex.unlock()
## 0-1: how far colours shift toward rod vision.
var strength := 1.0 :
	set(value):
		_params_mutex.lock()
		strength = value
		_params_mutex.unlock()

var _rd : RenderingDevice
var _shader := RID()
var _pipeline := RID()
var _params_mutex := Mutex.new()


func _init() -> void:
	effect_callback_type = EFFECT_CALLBACK_TYPE_POST_TRANSPARENT
	_rd = RenderingServer.get_rendering_device()
	# Without a RenderingDevice (Compatibility renderer) the compositor does not run.
	if _rd == null:
		return
	var spirv := SHADER.get_spirv()
	if not spirv.compile_error_compute.is_empty():
		push_error("Night vision shader failed to compile; night vision is off: %s" % spirv.compile_error_compute)
		return
	_shader = _rd.shader_create_from_spirv(spirv)
	if _shader.is_valid():
		_pipeline = _rd.compute_pipeline_create(_shader)
	if not _pipeline.is_valid():
		push_error("Night vision pipeline could not be created; night vision is off.")


## Whether the effect's compute shader was created (it needs a RenderingDevice).
func is_valid() -> bool:
	return _pipeline.is_valid()


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and _rd != null and _shader.is_valid():
		# Freeing the shader frees its pipeline.
		_rd.free_rid(_shader)


func _render_callback(_callback_type: int, render_data: RenderData) -> void:
	_params_mutex.lock()
	var scale := luminance_scale
	var amount := strength
	_params_mutex.unlock()
	if not _pipeline.is_valid() or scale <= 0.0 or amount <= 0.0:
		return
	var render_scene_buffers := render_data.get_render_scene_buffers() as RenderSceneBuffersRD
	var size := render_scene_buffers.get_internal_size()
	if size.x == 0 or size.y == 0:
		return
	var push := PackedFloat32Array([float(size.x), float(size.y), scale, amount]).to_byte_array()
	for view in render_scene_buffers.get_view_count():
		var image := RDUniform.new()
		image.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
		image.binding = 0
		image.add_id(render_scene_buffers.get_color_layer(view))
		var uniform_set := UniformSetCacheRD.get_cache(_shader, 0, [image])
		var compute_list := _rd.compute_list_begin()
		_rd.compute_list_bind_compute_pipeline(compute_list, _pipeline)
		_rd.compute_list_bind_uniform_set(compute_list, uniform_set, 0)
		_rd.compute_list_set_push_constant(compute_list, push, push.size())
		_rd.compute_list_dispatch(compute_list, ceili(size.x / 8.0), ceili(size.y / 8.0), 1)
		_rd.compute_list_end()
