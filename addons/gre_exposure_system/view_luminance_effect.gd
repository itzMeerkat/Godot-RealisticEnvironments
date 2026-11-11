class_name GREViewLuminanceEffect
extends CompositorEffect
## Measures what the eye looks at: the log-average luminance (cd/m2) of the rendered
## view plus the glare of its bright parts (view_luminance.glsl), read back
## asynchronously a few frames late.
## GREExposureController adds it to its target's compositor at runtime, sets
## luminance_scale every frame and reads get_view_luminance(). It runs after the
## transparent pass, on the HDR colour before tonemapping, and changes nothing.

const SHADER := preload("res://addons/gre_exposure_system/view_luminance.glsl")
## The darkest luminance (cd/m2) counted: below a moonless night's.
const FLOOR_LUMINANCE := 1e-5

## cd/m2 of a colour-buffer value of 1 (lux of the scene's irradiance 1 over the
## exposure). 0 pauses the measurement.
var luminance_scale := 0.0 :
	set(value):
		_mutex.lock()
		luminance_scale = value
		_mutex.unlock()

var _rd : RenderingDevice
var _shader := RID()
var _pipeline := RID()
var _result_buffer := RID()
var _mutex := Mutex.new()
## Whether a readback is in flight (the buffer is not written again until it lands),
## and the luminance_scale of its frame.
var _pending := false
var _pending_scale := 0.0
## The latest measurement (cd/m2); < 0 before the first.
var _view_luminance := -1.0


func _init() -> void:
	effect_callback_type = EFFECT_CALLBACK_TYPE_POST_TRANSPARENT
	_rd = RenderingServer.get_rendering_device()
	# Without a RenderingDevice (Compatibility renderer) the compositor does not run.
	if _rd == null:
		return
	var spirv := SHADER.get_spirv()
	if not spirv.compile_error_compute.is_empty():
		push_error("View luminance shader failed to compile; exposure ignores the view: %s" % spirv.compile_error_compute)
		return
	_shader = _rd.shader_create_from_spirv(spirv)
	if _shader.is_valid():
		_pipeline = _rd.compute_pipeline_create(_shader)
	_result_buffer = _rd.storage_buffer_create(4)
	if not _pipeline.is_valid() or not _result_buffer.is_valid():
		push_error("View luminance GPU resources could not be created; exposure ignores the view.")
		if _result_buffer.is_valid():
			_rd.free_rid(_result_buffer)
		_result_buffer = RID()
		_pipeline = RID()


## Whether the effect's GPU resources were created (it needs a RenderingDevice).
func is_valid() -> bool:
	return _pipeline.is_valid() and _result_buffer.is_valid()


## The view's latest luminance, glare included (cd/m2); < 0 before the first measurement.
func get_view_luminance() -> float:
	_mutex.lock()
	var luminance := _view_luminance
	_mutex.unlock()
	return luminance


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and _rd != null:
		if _result_buffer.is_valid():
			_rd.free_rid(_result_buffer)
		# Freeing the shader frees its pipeline.
		if _shader.is_valid():
			_rd.free_rid(_shader)


func _render_callback(_callback_type: int, render_data: RenderData) -> void:
	_mutex.lock()
	var scale := luminance_scale
	var busy := _pending
	_mutex.unlock()
	if not is_valid() or scale <= 0.0 or busy:
		return
	var render_scene_buffers := render_data.get_render_scene_buffers() as RenderSceneBuffersRD
	var size := render_scene_buffers.get_internal_size()
	if size.x == 0 or size.y == 0:
		return
	var push := PackedFloat32Array([float(size.x), float(size.y), FLOOR_LUMINANCE / scale, scale]).to_byte_array()
	var image := RDUniform.new()
	image.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	image.binding = 0
	image.add_id(render_scene_buffers.get_color_layer(0))
	var result := RDUniform.new()
	result.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	result.binding = 1
	result.add_id(_result_buffer)
	var uniform_set := UniformSetCacheRD.get_cache(_shader, 0, [image, result])
	var compute_list := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(compute_list, _pipeline)
	_rd.compute_list_bind_uniform_set(compute_list, uniform_set, 0)
	_rd.compute_list_set_push_constant(compute_list, push, push.size())
	_rd.compute_list_dispatch(compute_list, 1, 1, 1)
	_rd.compute_list_end()
	_mutex.lock()
	_pending = true
	_pending_scale = scale
	_mutex.unlock()
	if _rd.buffer_get_data_async(_result_buffer, _on_result) != OK:
		_mutex.lock()
		_pending = false
		_mutex.unlock()


func _on_result(data : PackedByteArray) -> void:
	_mutex.lock()
	_pending = false
	if data.size() >= 4:
		var log_luminance := data.decode_float(0)
		if is_finite(log_luminance):
			_view_luminance = exp(log_luminance) * _pending_scale
	_mutex.unlock()
