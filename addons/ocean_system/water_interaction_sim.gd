class_name WaterInteractionSim
extends RefCounted
## iWave interaction simulation around the camera. Created and driven by
## OceanSystem (see docs/water-interaction-plan.md, Phase 3).
##
## Simulates eta = h + p, the wave deviation from the hull-conforming rest
## state, on a grid_size x grid_size window of cell_size meters that follows the
## camera with wrap-around addressing. OceanSystem calls step() once per physics
## tick, so every step sees a new hull pose. Each step:
##   1. pressure: hull pressure head p (draft, minus the bow-wave rise), hull
##      coverage and bow rise from HullProfiles, and eta packed for the FFT
##   2. FFT -> multiply by g|k| (exact deep-water dispersion) -> inverse FFT
##   3. step: time integration, viscosity, absorbing border, foam, render texture
## render_texture (rgba16f: h, eta, foam, hull coverage) is sampled by the water
## material and the surface query shader.

const SHADER_DIR := 'res://addons/ocean_system/shaders/compute/'
const WORKGROUP_SIZE := 16
const MAX_HULLS := 32
const MAX_IMPULSES := 64
const FLOATS_PER_HULL := 36
const GRAVITY := 9.81

## Simulation tunables, set by OceanSystem.
var gravity_scale := 1.0
var damping := 0.2
var viscosity := 0.1
var sponge_cells := 24.0
var sponge_damping := 12.0
var foam_grow := 1.5
var foam_decay := 0.35
var foam_slope_threshold := 0.15
var foam_bow_rate := 0.5

var grid_size : int
var cell_size : float
## rgba16f: x = visible offset h, y = eta (h + p), z = foam, w = hull coverage.
var render_texture : RID
## Integer cell coordinate of the window's first cell.
var window_origin := Vector2i.ZERO

var _context : RenderingContext
var _device : RenderingDevice
var _log2_size : int
var _states : Array[RID] = []
var _pressure : RID
var _spectrum : RID
var _hull_buffer : RID
var _cascade_buffer : RID
var _impulse_buffer : RID
var _profile_sampler : RID
var _empty_profiles : RID
var _shaders := {}
var _pipelines := {}
var _scroll_sets : Array[RID] = []
var _impulse_sets : Array[RID] = []
var _step_sets : Array[RID] = []
var _fft_set : RID
var _operator_set : RID
## Pressure sets also reference the wave generator's displacement textures and
## the ocean's profile texture array, so the device frees them together with
## those textures; they are kept out of the deletion queue.
var _pressure_sets := {}
var _current := 0
var _has_window := false
var _pending_impulses := PackedVector4Array()


func _init(device : RenderingDevice, size : int, meters_per_cell : float) -> void:
	assert(size >= 64 and size <= 1024 and (size & (size - 1)) == 0, "Interaction grid size must be a power of two in 64..1024.")
	assert(meters_per_cell > 0.0, "Interaction cell size must be positive.")
	grid_size = size
	cell_size = meters_per_cell
	_log2_size = int(round(log(float(size)) / log(2.0)))
	_device = device
	_context = RenderingContext.create(device)

	for shader_name in ['iwave_scroll', 'iwave_impulse', 'iwave_pressure', 'iwave_fft', 'iwave_operator', 'iwave_step']:
		_shaders[shader_name] = _context.load_shader(SHADER_DIR + shader_name + '.glsl')
		_pipelines[shader_name] = _context.deletion_queue.push(_device.compute_pipeline_create(_shaders[shader_name]))

	var dims := Vector2i(size, size)
	var storage := RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
	var empty_state := PackedFloat32Array()
	empty_state.resize(size * size * 4)
	for i in range(2, empty_state.size(), 4):
		# Fresh cells have no pressure history (IWAVE_NO_PRESSURE in iwave_common.glslinc).
		empty_state[i] = -1.0e30
		empty_state[i + 1] = -1.0e30
	for i in 2:
		_states.push_back(_context.create_texture(dims, RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT, storage, 0, RDTextureView.new(), [empty_state.to_byte_array()]).rid)
	_pressure = _context.create_texture(dims, RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT, storage).rid
	_spectrum = _context.create_texture(dims, RenderingDevice.DATA_FORMAT_R32G32_SFLOAT, storage).rid
	var empty_render := PackedByteArray()
	empty_render.resize(size * size * 8)
	render_texture = _context.create_texture(dims, RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT, storage | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT, 0, RDTextureView.new(), [empty_render]).rid

	_hull_buffer = _context.create_storage_buffer(MAX_HULLS * FLOATS_PER_HULL * 4).rid
	_cascade_buffer = _context.create_storage_buffer(OceanSystem.MAX_CASCADES * OceanSurfaceQueries.BYTES_PER_CASCADE).rid
	_impulse_buffer = _context.create_storage_buffer(MAX_IMPULSES * 16).rid

	var sampler_state := RDSamplerState.new()
	sampler_state.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler_state.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler_state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	sampler_state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	_profile_sampler = _context.deletion_queue.push(_device.sampler_create(sampler_state))
	# Bound when no hull profiles exist; never read then (hull count is 0).
	_empty_profiles = _context.create_texture(Vector2i.ONE, RenderingDevice.DATA_FORMAT_R16G16_SFLOAT, RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT, 1, RDTextureView.new(), [PackedByteArray([0, 0, 0, 0])]).rid

	for i in 2:
		_scroll_sets.push_back(_create_set('iwave_scroll', [
			_uniform(0, RenderingDevice.UNIFORM_TYPE_IMAGE, [_states[i]]),
			_uniform(1, RenderingDevice.UNIFORM_TYPE_IMAGE, [render_texture]),
		]))
		_impulse_sets.push_back(_create_set('iwave_impulse', [
			_uniform(0, RenderingDevice.UNIFORM_TYPE_IMAGE, [_states[i]]),
			_uniform(1, RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, [_impulse_buffer]),
		]))
		_step_sets.push_back(_create_set('iwave_step', [
			_uniform(0, RenderingDevice.UNIFORM_TYPE_IMAGE, [_states[i]]),
			_uniform(1, RenderingDevice.UNIFORM_TYPE_IMAGE, [_states[1 - i]]),
			_uniform(2, RenderingDevice.UNIFORM_TYPE_IMAGE, [_pressure]),
			_uniform(3, RenderingDevice.UNIFORM_TYPE_IMAGE, [_spectrum]),
			_uniform(4, RenderingDevice.UNIFORM_TYPE_IMAGE, [render_texture]),
		]))
	_fft_set = _create_set('iwave_fft', [_uniform(0, RenderingDevice.UNIFORM_TYPE_IMAGE, [_spectrum])])
	_operator_set = _create_set('iwave_operator', [_uniform(0, RenderingDevice.UNIFORM_TYPE_IMAGE, [_spectrum])])


## Queues a splash: a Gaussian bump of the given radius and amplitude (m) added
## to the wave state on the next step.
func add_impulse(position : Vector3, radius : float, amplitude : float) -> void:
	assert(_pending_impulses.size() < MAX_IMPULSES, "More than %d water impulses queued in one step." % MAX_IMPULSES)
	assert(radius > 0.0, "Water impulse radius must be positive.")
	_pending_impulses.push_back(Vector4(position.x, position.z, radius, amplitude))


## World-space XZ of the window center.
func get_window_center() -> Vector2:
	return (Vector2(window_origin) + Vector2.ONE * float(grid_size) * 0.5) * cell_size


func get_half_extent() -> float:
	return float(grid_size) * cell_size * 0.5


## Wave generator textures were rebuilt; pressure sets referencing the old ones
## were freed with them by the device.
func clear_uniform_set_cache() -> void:
	_pressure_sets.clear()


## Moves the window to the camera and advances the simulation by one step of
## dt seconds. hull_data holds hull_count SimHull records (FLOATS_PER_HULL floats each).
func step(dt : float, camera_position : Vector3, hull_data : PackedFloat32Array, hull_count : int, cascade_data : PackedByteArray, cascade_count : int, water_level : float, wave_blend_alpha : float, current_displacement : RID, previous_displacement : RID, hull_profiles : RID) -> void:
	assert(hull_count <= MAX_HULLS, "At most %d hulls can force the interaction simulation." % MAX_HULLS)
	var new_origin := Vector2i(floori(camera_position.x / cell_size), floori(camera_position.z / cell_size)) - Vector2i.ONE * (grid_size / 2)
	var scroll := _has_window and new_origin != window_origin
	var old_origin := window_origin
	window_origin = new_origin
	_has_window = true

	if hull_count > 0:
		var hull_bytes := hull_data.to_byte_array()
		_device.buffer_update(_hull_buffer, 0, hull_bytes.size(), hull_bytes)
	_device.buffer_update(_cascade_buffer, 0, cascade_data.size(), cascade_data)
	var impulse_count := _pending_impulses.size()
	if impulse_count > 0:
		var impulse_bytes := _pending_impulses.to_byte_array()
		_device.buffer_update(_impulse_buffer, 0, impulse_bytes.size(), impulse_bytes)

	var groups := grid_size / WORKGROUP_SIZE
	var profiles := hull_profiles if hull_profiles.is_valid() else _empty_profiles
	var compute_list := _device.compute_list_begin()
	if scroll:
		_dispatch(compute_list, 'iwave_scroll', _scroll_sets[_current], [old_origin.x, old_origin.y, window_origin.x, window_origin.y, grid_size], Vector3i(groups, groups, 1))
		_device.compute_list_add_barrier(compute_list)
	if impulse_count > 0:
		_dispatch(compute_list, 'iwave_impulse', _impulse_sets[_current], [window_origin.x, window_origin.y, grid_size, cell_size, impulse_count], Vector3i(groups, groups, 1))
		_device.compute_list_add_barrier(compute_list)
	_dispatch(compute_list, 'iwave_pressure', _get_pressure_set(_current, profiles, current_displacement, previous_displacement),
		[window_origin.x, window_origin.y, grid_size, cell_size, hull_count, cascade_count, water_level, wave_blend_alpha], Vector3i(groups, groups, 1))
	_device.compute_list_add_barrier(compute_list)
	_dispatch_fft(compute_list, false, -1.0)
	_dispatch_fft(compute_list, true, -1.0)
	_dispatch(compute_list, 'iwave_operator', _operator_set, [grid_size, cell_size, GRAVITY * gravity_scale], Vector3i(groups, groups, 1))
	_device.compute_list_add_barrier(compute_list)
	_dispatch_fft(compute_list, true, 1.0)
	_dispatch_fft(compute_list, false, 1.0)
	_dispatch(compute_list, 'iwave_step', _step_sets[_current], [
		window_origin.x, window_origin.y, grid_size, cell_size, dt,
		damping, viscosity, sponge_cells, sponge_damping, foam_grow, foam_decay, foam_slope_threshold, foam_bow_rate,
	], Vector3i(groups, groups, 1))
	_device.compute_list_add_barrier(compute_list)
	_current = 1 - _current
	_device.compute_list_end()
	_pending_impulses.clear()


func release() -> void:
	for uniform_set in _pressure_sets.values():
		if _device.uniform_set_is_valid(uniform_set):
			_device.free_rid(uniform_set)
	_pressure_sets.clear()
	_context.free()


func _dispatch_fft(compute_list : int, along_columns : bool, direction : float) -> void:
	_dispatch(compute_list, 'iwave_fft', _fft_set, [grid_size, _log2_size, 1 if along_columns else 0, direction], Vector3i(grid_size, 1, 1))
	_device.compute_list_add_barrier(compute_list)


func _dispatch(compute_list : int, shader_name : String, uniform_set : RID, push_values : Array, groups : Vector3i) -> void:
	var push_constant := RenderingContext.create_push_constant(push_values)
	_device.compute_list_bind_compute_pipeline(compute_list, _pipelines[shader_name])
	_device.compute_list_bind_uniform_set(compute_list, uniform_set, 0)
	_device.compute_list_set_push_constant(compute_list, push_constant, push_constant.size())
	_device.compute_list_dispatch(compute_list, groups.x, groups.y, groups.z)


func _get_pressure_set(state_index : int, hull_profiles : RID, current_displacement : RID, previous_displacement : RID) -> RID:
	var key := "%d:%d:%d:%d" % [state_index, hull_profiles.get_id(), current_displacement.get_id(), previous_displacement.get_id()]
	if _pressure_sets.has(key):
		return _pressure_sets[key]
	# Drop entries whose textures (old profile arrays, rebuilt generators) are gone.
	for stale_key in _pressure_sets.keys():
		if not _device.uniform_set_is_valid(_pressure_sets[stale_key]):
			_pressure_sets.erase(stale_key)
	var uniform_set := _device.uniform_set_create([
		_uniform(0, RenderingDevice.UNIFORM_TYPE_IMAGE, [_pressure]),
		_uniform(1, RenderingDevice.UNIFORM_TYPE_IMAGE, [_spectrum]),
		_uniform(2, RenderingDevice.UNIFORM_TYPE_IMAGE, [_states[state_index]]),
		_uniform(3, RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, [_hull_buffer]),
		_uniform(4, RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, [_profile_sampler, hull_profiles]),
		_uniform(5, RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, [_cascade_buffer]),
		_uniform(6, RenderingDevice.UNIFORM_TYPE_IMAGE, [current_displacement]),
		_uniform(7, RenderingDevice.UNIFORM_TYPE_IMAGE, [previous_displacement]),
	], _shaders['iwave_pressure'], 0)
	_pressure_sets[key] = uniform_set
	return uniform_set


func _create_set(shader_name : String, uniforms : Array) -> RID:
	return _context.deletion_queue.push(_device.uniform_set_create(uniforms, _shaders[shader_name], 0))


func _uniform(binding : int, uniform_type : RenderingDevice.UniformType, ids : Array) -> RDUniform:
	var uniform := RDUniform.new()
	uniform.binding = binding
	uniform.uniform_type = uniform_type
	for id in ids:
		uniform.add_id(id)
	return uniform
