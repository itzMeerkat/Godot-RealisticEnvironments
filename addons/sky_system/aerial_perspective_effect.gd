@tool
class_name AerialPerspectiveEffect
extends CompositorEffect
## Aerial perspective over the scene's opaque geometry: blends every opaque pixel
## toward the atmosphere's in-scattered light by the transmittance to its surface,
## both read from the camera's view volume (AtmosphereRenderer), which also hazes
## the sky. SkySystem sets the parameters; the effect sits in the WorldEnvironment's
## compositor (sky_system.tscn) and has no exported state.
##
## Runs before the transparent pass, as one fullscreen triangle blended into the
## scene's colour buffer (shaders/aerial_perspective.glsl): with MSAA into the
## multisampled buffer, per sample, so the transparent pass's resolve keeps it.
## Transparent surfaces are drawn afterwards and haze themselves for their own
## distance (atmosphere.gdshaderinc, atmosphere_fog()).

const SHADER := preload("res://addons/sky_system/shaders/aerial_perspective.glsl")

## Off while there is nothing to haze (no atmosphere, or a clear one).
var active := false :
	set(value):
		_params_mutex.lock()
		active = value
		_params_mutex.unlock()
## World position of the observer the view volume was built for, and its altitude
## (m) as the volume uses it (AtmosphereRenderer.get_observer_altitude()).
var observer_position := Vector3.ZERO :
	set(value):
		_params_mutex.lock()
		observer_position = value
		_params_mutex.unlock()
var observer_altitude := 0.0 :
	set(value):
		_params_mutex.lock()
		observer_altitude = value
		_params_mutex.unlock()
## Toward the key light, and the Henyey-Greenstein g of the haze's forward lobe.
var light_direction := Vector3.UP :
	set(value):
		_params_mutex.lock()
		light_direction = value
		_params_mutex.unlock()
var phase_g := 0.97 :
	set(value):
		_params_mutex.lock()
		phase_g = value
		_params_mutex.unlock()
## The view volume (AtmosphereRenderer.view_*) as RenderingDevice textures, and the
## distance of its last regular slice. Clear the textures before they are freed.
var view_textures : Array[RID] = [] :
	set(value):
		_params_mutex.lock()
		view_textures = value
		_params_mutex.unlock()
var max_distance := 100000.0 :
	set(value):
		_params_mutex.lock()
		max_distance = value
		_params_mutex.unlock()

var _rd : RenderingDevice
## Shader per version: "single" and "msaa".
var _shaders := {}
## Pipelines per "version/framebuffer format".
var _pipelines := {}
var _depth_sampler := RID()
var _volume_sampler := RID()
var _params_mutex := Mutex.new()


func _init() -> void:
	effect_callback_type = EFFECT_CALLBACK_TYPE_PRE_TRANSPARENT
	_rd = RenderingServer.get_rendering_device()
	# Without a RenderingDevice (Compatibility renderer) the compositor does not run.
	if _rd == null:
		return
	for version in [&"single", &"msaa"]:
		var spirv := SHADER.get_spirv(version)
		assert(spirv.compile_error_vertex.is_empty() and spirv.compile_error_fragment.is_empty(), "Aerial perspective shader failed to compile: %s%s" % [spirv.compile_error_vertex, spirv.compile_error_fragment])
		_shaders[version] = _rd.shader_create_from_spirv(spirv)
		assert(_shaders[version].is_valid(), "Aerial perspective shader could not be created.")
	var depth_state := RDSamplerState.new()
	depth_state.min_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	depth_state.mag_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	_depth_sampler = _rd.sampler_create(depth_state)
	var volume_state := RDSamplerState.new()
	volume_state.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	volume_state.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	volume_state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	volume_state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	volume_state.repeat_w = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	_volume_sampler = _rd.sampler_create(volume_state)


func _notification(what: int) -> void:
	if what != NOTIFICATION_PREDELETE or _rd == null:
		return
	# Freeing a shader frees its pipelines.
	for shader in _shaders.values():
		_rd.free_rid(shader)
	_rd.free_rid(_depth_sampler)
	_rd.free_rid(_volume_sampler)


func _render_callback(_callback_type: int, render_data: RenderData) -> void:
	_params_mutex.lock()
	var is_active := active and view_textures.size() == 3
	var textures := view_textures.duplicate()
	var observer := observer_position
	var params := [observer_altitude, light_direction.x, light_direction.y, light_direction.z, phase_g, max_distance]
	_params_mutex.unlock()
	if not is_active:
		return
	var render_scene_buffers := render_data.get_render_scene_buffers() as RenderSceneBuffersRD
	var render_scene_data := render_data.get_render_scene_data()
	var msaa := render_scene_buffers.get_msaa_3d() != RenderingServer.VIEWPORT_MSAA_DISABLED
	var version := &"msaa" if msaa else &"single"
	var shader : RID = _shaders[version]
	var size := render_scene_buffers.get_internal_size()
	var camera_transform := render_scene_data.get_cam_transform()
	# Camera-relative: positions stay precise far from the world origin.
	var camera_rotation := Transform3D(camera_transform.basis, Vector3.ZERO)
	var camera_offset := camera_transform.origin - observer

	for view in render_scene_buffers.get_view_count():
		var framebuffer := FramebufferCacheRD.get_cache_multipass([render_scene_buffers.get_color_layer(view, msaa)], [], 1)
		var framebuffer_format := _rd.framebuffer_get_format(framebuffer)
		var depth_uniform := RDUniform.new()
		depth_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
		depth_uniform.binding = 0
		depth_uniform.add_id(_depth_sampler)
		depth_uniform.add_id(render_scene_buffers.get_depth_layer(view, msaa))
		var uniforms : Array[RDUniform] = [depth_uniform]
		for i in 3:
			var volume_uniform := RDUniform.new()
			volume_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
			volume_uniform.binding = i + 1
			volume_uniform.add_id(_volume_sampler)
			volume_uniform.add_id(textures[i])
			uniforms.push_back(volume_uniform)
		var uniform_set := UniformSetCacheRD.get_cache(shader, 0, uniforms)

		var view_projection := render_scene_data.get_view_projection(view) * Projection(camera_rotation.affine_inverse())
		var inv_view_projection := view_projection.inverse()
		var push := PackedFloat32Array()
		for column in [inv_view_projection.x, inv_view_projection.y, inv_view_projection.z, inv_view_projection.w]:
			push.append_array([column.x, column.y, column.z, column.w])
		push.append_array([camera_offset.x, camera_offset.y, camera_offset.z, params[0]])
		push.append_array([params[1], params[2], params[3], params[4]])
		push.append_array([float(size.x), float(size.y), params[5], 0.0])

		var push_bytes := push.to_byte_array()
		var draw_list := _rd.draw_list_begin(framebuffer)
		_rd.draw_list_bind_render_pipeline(draw_list, _get_pipeline(version, framebuffer_format, render_scene_buffers.get_texture_samples()))
		_rd.draw_list_bind_uniform_set(draw_list, uniform_set, 0)
		_rd.draw_list_set_push_constant(draw_list, push_bytes, push_bytes.size())
		_rd.draw_list_draw(draw_list, false, 1, 3)
		_rd.draw_list_end()


## colour * transmittance (second output) + in-scatter (first output); alpha is kept.
func _get_pipeline(version : StringName, framebuffer_format : int, samples : RenderingDevice.TextureSamples) -> RID:
	var key := "%s/%d" % [version, framebuffer_format]
	if _pipelines.has(key) and _rd.render_pipeline_is_valid(_pipelines[key]):
		return _pipelines[key]
	var rasterization := RDPipelineRasterizationState.new()
	rasterization.cull_mode = RenderingDevice.POLYGON_CULL_DISABLED
	var multisample := RDPipelineMultisampleState.new()
	multisample.sample_count = samples
	multisample.enable_sample_shading = version == &"msaa"
	multisample.min_sample_shading = 1.0
	var attachment := RDPipelineColorBlendStateAttachment.new()
	attachment.enable_blend = true
	attachment.src_color_blend_factor = RenderingDevice.BLEND_FACTOR_ONE
	attachment.dst_color_blend_factor = RenderingDevice.BLEND_FACTOR_SRC1_COLOR
	attachment.color_blend_op = RenderingDevice.BLEND_OP_ADD
	attachment.src_alpha_blend_factor = RenderingDevice.BLEND_FACTOR_ZERO
	attachment.dst_alpha_blend_factor = RenderingDevice.BLEND_FACTOR_ONE
	attachment.alpha_blend_op = RenderingDevice.BLEND_OP_ADD
	var blend := RDPipelineColorBlendState.new()
	blend.attachments = [attachment]
	var pipeline := _rd.render_pipeline_create(_shaders[version], framebuffer_format, RenderingDevice.INVALID_FORMAT_ID, RenderingDevice.RENDER_PRIMITIVE_TRIANGLES, rasterization, multisample, RDPipelineDepthStencilState.new(), blend)
	assert(pipeline.is_valid(), "Aerial perspective pipeline could not be created.")
	_pipelines[key] = pipeline
	return pipeline
