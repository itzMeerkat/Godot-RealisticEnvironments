@tool
class_name GREVolumetricCloudEffect
extends CompositorEffect
## The clouds as the camera sees them, from anywhere: below, inside or above the
## cloud layer. Traced on screen after the transparent pass and composited over
## everything, each pixel's cloud in front of its surface and inside the atmosphere.
## GRESkySystem sets the parameters; the effect sits in the WorldEnvironment's
## compositor (sky_system.tscn) and has no exported state.
##
## Per view and frame, three compute passes (shaders/compute/cloud_*.glsl) on a cloud
## buffer of half the screen's size per axis:
## - trace: one cloud pixel of every 2x2 block raymarched (GRECloudRenderer's noise,
##   weather map and parameters), up to the scene's depth;
## - reconstruct: every cloud pixel from the traces and the previous frame's buffer,
##   reprojected by the cloud's distance;
## - composite: upsampled by matching the scene's depth, over the colour buffer.
## The buffers live in the viewport's render buffers (context
## [constant BUFFER_CONTEXT]), so every viewport keeps its own history.

const TRACE_SHADER := preload("res://addons/gre_sky_system/shaders/compute/cloud_trace.glsl")
const RECONSTRUCT_SHADER := preload("res://addons/gre_sky_system/shaders/compute/cloud_reconstruct.glsl")
const COMPOSITE_SHADER := preload("res://addons/gre_sky_system/shaders/compute/cloud_composite.glsl")
## Render-buffer context holding the cloud buffers.
const BUFFER_CONTEXT := &"volumetric_clouds"
## Bytes of the Frame buffer (cloud_screen_common.glslinc): two mat4s and seven vec4s.
const FRAME_SIZE := 2 * 64 + 7 * 16
## Traced pixel of each 2x2 block, frame after frame: diagonal first.
const PATTERN : Array[Vector2i] = [Vector2i(0, 0), Vector2i(1, 1), Vector2i(1, 0), Vector2i(0, 1)]
## A camera that jumps farther than this (m) in a frame drops its history.
const MAX_HISTORY_MOTION := 2000.0
## Viewports kept track of; older ones are forgotten (their history restarts).
const MAX_TRACKED_BUFFERS := 16

## Off while there are no clouds or no atmosphere.
var active := false
## GRECloudRenderer.get_trace_resources(), or empty. Clear it before they are freed.
var cloud_resources : Array[RID] = []
## World height of the sea surface (GRESkySystem.sea_level): cloud altitudes are above it.
var sea_level := 0.0
## Weight of a traced pixel's previous value (0 replaces it).
var history_weight := 0.6
## As GREAerialPerspectiveEffect: the view volume's observer (world position and its
## altitude as the volume uses it), the key light and the haze lobe's g, the volume
## (GREAtmosphereRenderer.view_*) and its last regular slice. Clear the textures before
## they are freed.
var observer_position := Vector3.ZERO
var observer_altitude := 0.0
var light_direction := Vector3.UP
var phase_g := 0.97
var view_textures : Array[RID] = []
var max_distance := 100000.0
## The camera is under the water (GRESkySystem.set_camera_underwater()): no clouds on screen.
## They would show wherever the water left no depth, in front of the water between.
var camera_underwater := false

var _rd : RenderingDevice
## Per pass, per version ("single", "msaa"): [shader, pipeline].
var _passes := {}
var _linear_repeat := RID()
var _linear_clamp := RID()
var _nearest_clamp := RID()
## Per render buffers instance and view: _ViewState.
var _states := {}
var _params_mutex := Mutex.new()


## The history of one view of one viewport.
class _ViewState:
	var frame_buffer := RID()
	var previous_view_projection := Projection.IDENTITY
	var previous_camera := Vector3.ZERO
	var size := Vector2i.ZERO
	var has_history := false
	## Which of the two cloud buffers holds the latest frame.
	var parity := 0
	## Frames rendered: picks the traced pixel of each block.
	var frame := 0


func _init() -> void:
	effect_callback_type = EFFECT_CALLBACK_TYPE_POST_TRANSPARENT
	_rd = RenderingServer.get_rendering_device()
	# Without a RenderingDevice (Compatibility renderer) the compositor does not run.
	if _rd == null:
		return
	for pass_shader in [[&"trace", TRACE_SHADER], [&"reconstruct", RECONSTRUCT_SHADER], [&"composite", COMPOSITE_SHADER]]:
		var versions := {}
		for version in [&"single", &"msaa"]:
			var shader_file : RDShaderFile = pass_shader[1]
			var spirv := shader_file.get_spirv(version)
			if not spirv.compile_error_compute.is_empty():
				# That version is skipped: no clouds on screen with it.
				push_error("Volumetric cloud shader %s (%s) failed to compile: %s" % [pass_shader[0], version, spirv.compile_error_compute])
				continue
			var shader := _rd.shader_create_from_spirv(spirv)
			if not shader.is_valid():
				continue
			var pipeline := _rd.compute_pipeline_create(shader)
			if pipeline.is_valid():
				versions[version] = [shader, pipeline]
			else:
				_rd.free_rid(shader)
		_passes[pass_shader[0]] = versions
	_linear_repeat = _rd.sampler_create(GRERenderingContext.linear_sampler_state(RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT))
	_linear_clamp = _rd.sampler_create(GRERenderingContext.linear_sampler_state(RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE))
	var nearest_state := RDSamplerState.new()
	nearest_state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	nearest_state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	nearest_state.repeat_w = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	_nearest_clamp = _rd.sampler_create(nearest_state)

## Sets parameters by name (the variables above) all at once, so the render callback
## never reads a half-updated set.
func set_parameters(values : Dictionary) -> void:
	_params_mutex.lock()
	for parameter : StringName in values:
		assert(parameter in self, "Unknown %s parameter %s." % [get_script().get_global_name(), parameter])
		var value : Variant = values[parameter]
		# A copy of the property's own (typed) kind: set() ignores an untyped array for a
		# typed one, and the caller keeps its array.
		if value is Array:
			var copy : Array = (get(parameter) as Array).duplicate()
			copy.assign(value)
			value = copy
		set(parameter, value)
	_params_mutex.unlock()


func _notification(what: int) -> void:
	if what != NOTIFICATION_PREDELETE or _rd == null:
		return
	for state : _ViewState in _states.values():
		if state.frame_buffer.is_valid():
			_rd.free_rid(state.frame_buffer)
	# Freeing a shader frees its pipelines.
	for versions : Dictionary in _passes.values():
		for shader_pipeline : Array in versions.values():
			_rd.free_rid(shader_pipeline[0])
	for sampler in [_linear_repeat, _linear_clamp, _nearest_clamp]:
		_rd.free_rid(sampler)


func _render_callback(_callback_type: int, render_data: RenderData) -> void:
	_params_mutex.lock()
	var is_active := active and cloud_resources.size() == 6 and view_textures.size() == 3
	var underwater := camera_underwater
	var resources := cloud_resources.duplicate()
	var volumes := view_textures.duplicate()
	var observer := observer_position
	var settings := [sea_level, history_weight, observer_altitude, light_direction, phase_g, max_distance]
	_params_mutex.unlock()
	if not is_active:
		return
	if underwater:
		# What was traced before the dive is stale when the camera comes back up.
		for state : _ViewState in _states.values():
			state.has_history = false
		return
	var render_scene_buffers : RenderSceneBuffersRD = render_data.get_render_scene_buffers()
	var render_scene_data := render_data.get_render_scene_data()
	var msaa := render_scene_buffers.get_msaa_3d() != RenderingServer.VIEWPORT_MSAA_DISABLED
	var version := &"msaa" if msaa else &"single"
	# Reported in _init().
	for versions : Dictionary in _passes.values():
		if not versions.has(version):
			return
	var size := render_scene_buffers.get_internal_size()
	if size.x < 2 or size.y < 2:
		return
	var cloud_size := Vector2i(ceili(size.x / 2.0), ceili(size.y / 2.0))
	var trace_size := Vector2i(ceili(cloud_size.x / 2.0), ceili(cloud_size.y / 2.0))
	var camera_transform := render_scene_data.get_cam_transform()
	# Camera-relative: positions stay precise far from the world origin.
	var camera_rotation := Transform3D(camera_transform.basis, Vector3.ZERO)
	var camera := camera_transform.origin

	for view in render_scene_buffers.get_view_count():
		var state := _get_state(render_scene_buffers, view)
		var names := _ensure_buffers(render_scene_buffers, view, cloud_size, trace_size, state)
		var pattern := PATTERN[state.frame % PATTERN.size()]
		var view_projection := render_scene_data.get_view_projection(view) * Projection(camera_rotation.affine_inverse())
		var motion := camera - state.previous_camera
		var history_valid := state.has_history and motion.length() < MAX_HISTORY_MOTION
		var frame_data := _pack_frame(view_projection.inverse(), state.previous_view_projection, camera, motion, history_valid,
				camera - observer, settings, size, cloud_size, pattern, state.frame)
		_rd.buffer_update(state.frame_buffer, 0, frame_data.size(), frame_data)
		var depth := render_scene_buffers.get_depth_layer(view, msaa)
		var trace_color := render_scene_buffers.get_texture(BUFFER_CONTEXT, names[0])
		var trace_distance := render_scene_buffers.get_texture(BUFFER_CONTEXT, names[1])
		var previous_color := render_scene_buffers.get_texture(BUFFER_CONTEXT, names[2 + state.parity * 2])
		var previous_distance := render_scene_buffers.get_texture(BUFFER_CONTEXT, names[3 + state.parity * 2])
		var current_color := render_scene_buffers.get_texture(BUFFER_CONTEXT, names[2 + (1 - state.parity) * 2])
		var current_distance := render_scene_buffers.get_texture(BUFFER_CONTEXT, names[3 + (1 - state.parity) * 2])

		var trace_pass : Array = _passes[&"trace"][version]
		var trace_set := UniformSetCacheRD.get_cache(trace_pass[0], 0, [
			GRERenderingContext.sampled_uniform(1, _linear_repeat, resources[0]),
			GRERenderingContext.sampled_uniform(2, _linear_repeat, resources[1]),
			GRERenderingContext.sampled_uniform(3, _linear_clamp, resources[2]),
			GRERenderingContext.buffer_uniform(4, resources[3]),
			GRERenderingContext.buffer_uniform(5, resources[4]),
			GRERenderingContext.buffer_uniform(6, state.frame_buffer),
			GRERenderingContext.sampled_uniform(7, _nearest_clamp, depth),
			GRERenderingContext.image_uniform(8, trace_color),
			GRERenderingContext.image_uniform(9, trace_distance),
			GRERenderingContext.sampled_uniform(10, _linear_clamp, resources[5]),
		])
		var reconstruct_pass : Array = _passes[&"reconstruct"][version]
		var reconstruct_set := UniformSetCacheRD.get_cache(reconstruct_pass[0], 0, [
			GRERenderingContext.buffer_uniform(0, state.frame_buffer),
			GRERenderingContext.sampled_uniform(1, _nearest_clamp, depth),
			GRERenderingContext.sampled_uniform(2, _nearest_clamp, trace_color),
			GRERenderingContext.sampled_uniform(3, _nearest_clamp, trace_distance),
			GRERenderingContext.sampled_uniform(4, _linear_clamp, previous_color),
			GRERenderingContext.sampled_uniform(5, _nearest_clamp, previous_distance),
			GRERenderingContext.image_uniform(6, current_color),
			GRERenderingContext.image_uniform(7, current_distance),
		])
		var composite_pass : Array = _passes[&"composite"][version]
		var composite_uniforms : Array[RDUniform] = [
			GRERenderingContext.buffer_uniform(0, state.frame_buffer),
			GRERenderingContext.sampled_uniform(1, _nearest_clamp, depth),
			GRERenderingContext.sampled_uniform(2, _nearest_clamp, current_color),
			GRERenderingContext.sampled_uniform(3, _nearest_clamp, current_distance),
		]
		for i in 3:
			composite_uniforms.push_back(GRERenderingContext.sampled_uniform(4 + i, _linear_clamp, volumes[i]))
		composite_uniforms.push_back(GRERenderingContext.image_uniform(7, render_scene_buffers.get_color_layer(view, false)))
		var composite_set := UniformSetCacheRD.get_cache(composite_pass[0], 0, composite_uniforms)

		var compute_list := _rd.compute_list_begin()
		_rd.compute_list_bind_compute_pipeline(compute_list, trace_pass[1])
		_rd.compute_list_bind_uniform_set(compute_list, trace_set, 0)
		_rd.compute_list_dispatch(compute_list, ceili(trace_size.x / 8.0), ceili(trace_size.y / 8.0), 1)
		_rd.compute_list_add_barrier(compute_list)
		_rd.compute_list_bind_compute_pipeline(compute_list, reconstruct_pass[1])
		_rd.compute_list_bind_uniform_set(compute_list, reconstruct_set, 0)
		_rd.compute_list_dispatch(compute_list, ceili(cloud_size.x / 8.0), ceili(cloud_size.y / 8.0), 1)
		_rd.compute_list_add_barrier(compute_list)
		_rd.compute_list_bind_compute_pipeline(compute_list, composite_pass[1])
		_rd.compute_list_bind_uniform_set(compute_list, composite_set, 0)
		_rd.compute_list_dispatch(compute_list, ceili(size.x / 8.0), ceili(size.y / 8.0), 1)
		_rd.compute_list_end()

		state.previous_view_projection = view_projection
		state.previous_camera = camera
		state.has_history = true
		state.parity = 1 - state.parity
		state.frame += 1


## The view's state, created on its first frame.
func _get_state(render_scene_buffers : RenderSceneBuffersRD, view : int) -> _ViewState:
	var key := "%d/%d" % [render_scene_buffers.get_instance_id(), view]
	if _states.has(key):
		return _states[key]
	if _states.size() >= MAX_TRACKED_BUFFERS:
		var oldest : String = _states.keys()[0]
		var dropped : _ViewState = _states[oldest]
		_rd.free_rid(dropped.frame_buffer)
		_states.erase(oldest)
	var state := _ViewState.new()
	state.frame_buffer = _rd.storage_buffer_create(FRAME_SIZE)
	_states[key] = state
	return state


## Creates the view's cloud buffers when missing (the render buffers drop them on a
## resize); a fresh set starts without history. Returns their names: trace colour,
## trace distance, then colour and distance of cloud buffer 0 and of buffer 1.
func _ensure_buffers(render_scene_buffers : RenderSceneBuffersRD, view : int, cloud_size : Vector2i, trace_size : Vector2i, state : _ViewState) -> Array[StringName]:
	var names : Array[StringName] = []
	for name in ["trace_color", "trace_distance", "color_0", "distance_0", "color_1", "distance_1"]:
		names.push_back(StringName("%s_%d" % [name, view]))
	if render_scene_buffers.has_texture(BUFFER_CONTEXT, names[0]) and state.size == cloud_size:
		return names
	var usage := RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
	var formats := [RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT, RenderingDevice.DATA_FORMAT_R32G32_SFLOAT,
			RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT, RenderingDevice.DATA_FORMAT_R32G32_SFLOAT,
			RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT, RenderingDevice.DATA_FORMAT_R32G32_SFLOAT]
	for i in names.size():
		if render_scene_buffers.has_texture(BUFFER_CONTEXT, names[i]):
			render_scene_buffers.clear_context(BUFFER_CONTEXT)
			break
	for i in names.size():
		var texture_size := trace_size if i < 2 else cloud_size
		render_scene_buffers.create_texture(BUFFER_CONTEXT, names[i], formats[i], usage, RenderingDevice.TEXTURE_SAMPLES_1, texture_size, 1, 1, true, false)
	state.size = cloud_size
	state.has_history = false
	return names


## The Frame buffer (cloud_screen_common.glslinc). settings: [sea level, history weight,
## observer altitude, light direction, phase g, view volume max distance].
static func _pack_frame(inv_view_projection : Projection, previous_view_projection : Projection, camera : Vector3,
		motion : Vector3, history_valid : bool, atmosphere_offset : Vector3, settings : Array, size : Vector2i,
		cloud_size : Vector2i, pattern : Vector2i, frame : int) -> PackedByteArray:
	var floats := PackedFloat32Array()
	for matrix in [inv_view_projection, previous_view_projection]:
		for column in [matrix.x, matrix.y, matrix.z, matrix.w]:
			floats.append_array([column.x, column.y, column.z, column.w])
	var light : Vector3 = settings[3]
	floats.append_array([
		camera.x, camera.y - settings[0], camera.z, 0.0,
		motion.x, motion.y, motion.z, 1.0 if history_valid else 0.0,
		atmosphere_offset.x, atmosphere_offset.y, atmosphere_offset.z, settings[2],
		light.x, light.y, light.z, settings[4],
		float(size.x), float(size.y), float(cloud_size.x), float(cloud_size.y),
		settings[5], settings[1], float(frame % 4096) * 0.618, 0.0,
	])
	var bytes := floats.to_byte_array()
	var pattern_bytes := PackedInt32Array([pattern.x, pattern.y, 0, 0]).to_byte_array()
	bytes.append_array(pattern_bytes)
	return bytes
