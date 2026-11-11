class_name GREOceanInteraction extends RefCounted
## GREOceanSystem's interactive waves (internal): the waves hulls make as they move through
## the water (GREWaterSurface.submit_disturbance()), simulated on a window of map_size^2
## cells around the camera. Surface queries leave them out unless their owner opts in
## (GREWaterSurface.set_query_wave_response()); GREOceanSurfaceQueries then reads state_buffer
## (docs/buoyancy-and-interactive-waves-plan.md).
##
## One step per physics tick: the hulls' sources and the damped border
## (interaction_source.glsl), a forward FFT of h + i dh/dt, every mode's exact evolution
## by the finite-depth dispersion relation (interaction_evolve.glsl), the inverse FFT,
## then the maps the water samples, the waves (interaction_output.glsl) and the foam the
## hulls churn up (interaction_foam.glsl), and their mips. Its GPU resources are freed
## with it.
##
## The window is world-locked and centred on the camera: cell c lives in texel
## c mod map_size, so the map repeats (the water samples it with repeat wrapping) and
## moving the window only clears the cells it enters. It does not lead the camera toward
## where it looks: turning the camera would swing it, clearing and fading wakes and foam
## as it went. The FFT's periodic domain is that same wrap; the damped border keeps
## waves from crossing it.

const SHADER_DIR := 'res://addons/gre_ocean_system/shaders/compute/'
## Hulls simulated at once, the nearest to the window's centre (InteractionHull array
## in interaction_common.glslinc).
const MAX_DISTURBANCES := 16
## Floats of one hull record (InteractionHull: five vec4s).
const FLOATS_PER_HULL := 20
## The border band where waves are damped before they reach the window's edge, as a
## share of the window, and its damping (1/s) at the edge.
const BORDER_SHARE := 0.1
const BORDER_DAMPING := 8.0
## Viscosity (m^2/s) damping the shortest waves (each at viscosity k^2), and the
## damping (1/s) of every wave, so the window does not fill up with old ripples.
const VISCOSITY := 0.01
const DAMPING := 0.03
## Drawn heights (m) and slopes approach these smoothly (interaction_output.glsl).
const MAX_HEIGHT := 2.0
const MAX_SLOPE := 0.7
## A hull that moved further than this share of its half length in one step relative
## to the water (a teleport) starts over instead of making a wave of the jump.
const MAX_STEP_SHARE := 0.5
## Foam (interaction_foam.glsl): its e-folding lifetime (s). A hull holds coverage over
## its footprint grown by FOAM_REACH, densest along its middle, rising from nothing at
## HULL_FOAM_START_SPEED (m/s through the water, turning included) to
## HULL_FOAM_MAX_COVERAGE at HULL_FOAM_FULL_SPEED (well below full coverage, so the foam
## stays lace and the trail breaks up). Crests foam past CREST_FOAM_SLOPE at
## CREST_FOAM_RATE (1/s) per unit of slope, toward CREST_FOAM_MAX_COVERAGE.
const FOAM_LIFETIME := 8.0
const HULL_FOAM_START_SPEED := 1.0
const HULL_FOAM_FULL_SPEED := 8.0
const HULL_FOAM_MAX_COVERAGE := 0.6
const FOAM_REACH := 1.25
const CREST_FOAM_SLOPE := 0.35
const CREST_FOAM_RATE := 1.5
const CREST_FOAM_MAX_COVERAGE := 0.6

## Cells per side of the window (a power of two, 128-1024) and their size (m).
var map_size : int
var cell_size : float
## Check context.failed after init_gpu().
var context : GRERenderingContext
## The maps the water samples (rgba16f, full mips): the waves (height, slope x, slope z,
## squared slope) and the foam (coverage, 0, 0, 0).
var map : GRERenderingContext.Descriptor
var foam_map : GRERenderingContext.Descriptor
## The FFT buffer: an input half, then the output half holding the state after the last
## step, h + i dh/dt per texel (texel c mod map_size holds cell c, as the map).
var state_buffer : GRERenderingContext.Descriptor
var _pipelines := {}
var _hull_buffer : GRERenderingContext.Descriptor
var _mip_steps : Array[Vector2i] = []
var _mip_sets : Array[RID] = []
## The window's first cell, and whether a step has placed it yet.
var _origin := Vector2i.ZERO
var _has_origin := false
var _window_center := Vector2.ZERO
## Owner instance id -> its hull record's first eight floats at the last step.
var _previous := {}
var _too_many_reported := false
## The foam's drift (m, within one cell) not yet moved by whole cells: the foam of
## cell c lies at the cell's centre plus this (get_foam_offset()). And the foam buffer
## half holding the last step's foam.
var _foam_drift := Vector2.ZERO
var _foam_read_half := 0


## Creates the GPU resources for a window of size x size cells of cell meters. Check
## context.failed afterwards.
func init_gpu(size : int, cell : float) -> void:
	assert(context == null, "GREOceanInteraction.init_gpu() must only be called once.")
	map_size = size
	cell_size = cell
	context = GRERenderingContext.new(RenderingServer.get_rendering_device())
	var butterfly_shader := context.load_shader(SHADER_DIR + 'fft_butterfly.glsl')
	var fft_shader := context.load_shader(SHADER_DIR + 'fft_compute.glsl', StringName('size_%d' % map_size))
	var transpose_shader := context.load_shader(SHADER_DIR + 'transpose.glsl')
	var source_shader := context.load_shader(SHADER_DIR + 'interaction_source.glsl')
	var evolve_shader := context.load_shader(SHADER_DIR + 'interaction_evolve.glsl')
	var output_shader := context.load_shader(SHADER_DIR + 'interaction_output.glsl')
	var foam_shader := context.load_shader(SHADER_DIR + 'interaction_foam.glsl')
	var mip_chain_shader := context.load_shader(SHADER_DIR + 'mip_chain.glsl')
	if context.failed:
		return

	var stages := int(log(map_size) / log(2))
	var mip_count := stages + 1
	var source_level := 0
	while source_level < mip_count - 1:
		var levels := mini(GREWaveGenerator.MIP_LEVELS_PER_DISPATCH, mip_count - 1 - source_level)
		_mip_steps.push_back(Vector2i(source_level, levels))
		source_level += levels

	var butterfly_factors := context.create_storage_buffer(stages * map_size * 4 * 4)
	# One complex field: input half, then output half (fft_compute.glsl with one spectrum).
	# Zeroed: the first step reads the output half as the flat starting state.
	var fft_buffer := context.create_storage_buffer(map_size * map_size * 2 * 8)
	state_buffer = fft_buffer
	_hull_buffer = context.create_storage_buffer(MAX_DISTURBANCES * FLOATS_PER_HULL * 4)
	# Two halves: last step's foam and this step's (zeroed: no foam to start with).
	var foam_buffer := context.create_storage_buffer(map_size * map_size * 2 * 4)
	var usage := RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT
	map = context.create_texture(Vector2i(map_size, map_size), RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT, usage, 0, [], mip_count)
	foam_map = context.create_texture(Vector2i(map_size, map_size), RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT, usage, 0, [], mip_count)
	if context.failed:
		return
	context.device.texture_clear(map.rid, Color(0, 0, 0, 0), 0, mip_count, 0, 1)
	context.device.texture_clear(foam_map.rid, Color(0, 0, 0, 0), 0, mip_count, 0, 1)
	var views : Array[GRERenderingContext.Descriptor] = []
	var foam_views : Array[GRERenderingContext.Descriptor] = []
	for mip in mip_count:
		views.push_back(context.create_texture_slice_view(map, 0, mip))
		foam_views.push_back(context.create_texture_slice_view(foam_map, 0, mip))
	for mip_step in _mip_steps:
		# mip_chain.glsl filters two maps per dispatch: the waves (z = 0) and the foam (z = 1).
		var chain : Array[GRERenderingContext.Descriptor] = []
		for map_views in [views, foam_views]:
			chain.push_back(map_views[mip_step.x])
			for level in GREWaveGenerator.MIP_LEVELS_PER_DISPATCH:
				chain.push_back(map_views[mip_step.x + mini(level + 1, mip_step.y)])
		_mip_sets.push_back(context.create_descriptor_set(chain, mip_chain_shader, 0))

	@warning_ignore("integer_division")
	var groups_16 := map_size / 16
	@warning_ignore("integer_division")
	var groups_32 := map_size / 32
	@warning_ignore("integer_division")
	var butterfly_groups := maxi(1, map_size / 128)
	var fft_set := context.create_descriptor_set([butterfly_factors, fft_buffer], fft_shader, 0)
	_pipelines[&'butterfly'] = context.create_pipeline([butterfly_groups, stages, 1], [context.create_descriptor_set([butterfly_factors], butterfly_shader, 0)], butterfly_shader)
	_pipelines[&'fft'] = context.create_pipeline([1, map_size, 1], [fft_set], fft_shader)
	_pipelines[&'transpose'] = context.create_pipeline([groups_32, groups_32, 1], [context.create_descriptor_set([fft_buffer], transpose_shader, 0)], transpose_shader)
	_pipelines[&'source'] = context.create_pipeline([groups_16, groups_16, 1], [context.create_descriptor_set([fft_buffer, _hull_buffer], source_shader, 0)], source_shader)
	_pipelines[&'evolve'] = context.create_pipeline([groups_16, groups_16, 1], [context.create_descriptor_set([fft_buffer], evolve_shader, 0)], evolve_shader)
	_pipelines[&'output'] = context.create_pipeline([groups_16, groups_16, 1], [context.create_descriptor_set([fft_buffer, _hull_buffer, views[0]], output_shader, 0)], output_shader)
	_pipelines[&'foam'] = context.create_pipeline([groups_16, groups_16, 1], [context.create_descriptor_set([fft_buffer, _hull_buffer, foam_buffer, foam_views[0]], foam_shader, 0)], foam_shader)
	var mip_pipelines : Array[Callable] = []
	for mip_step in _mip_steps:
		var groups := ceili((map_size >> (mip_step.x + 1)) / 16.0)
		mip_pipelines.push_back(context.create_pipeline([groups, groups, 2], [_mip_sets[0]], mip_chain_shader))
	_pipelines[&'mip_chain'] = mip_pipelines
	if context.failed:
		return

	var compute_list := context.compute_list_begin()
	_pipelines[&'butterfly'].call(context, compute_list)
	context.compute_list_end()


## Moves the window with camera (null keeps it where it is) and simulates delta seconds:
## the waves and foam of the hulls in disturbances (owner instance id -> GREWaterDisturbance),
## on water water_depth meters deep whose surface drifts at drift (m/s, world space).
func step(delta : float, camera : Camera3D, disturbances : Dictionary, water_depth : float, drift : Vector3) -> void:
	assert(context != null and not context.failed, "GREOceanInteraction.step() needs working GPU resources.")
	var window_size := map_size * cell_size
	if camera != null:
		_window_center = Vector2(camera.global_position.x, camera.global_position.z)
	@warning_ignore("integer_division")
	var origin := Vector2i((_window_center / cell_size).floor()) - Vector2i(map_size / 2, map_size / 2)
	var previous_origin := _origin if _has_origin else origin
	_origin = origin
	_has_origin = true
	var hull_count := _write_hulls(delta, disturbances)
	# The foam's data drifts in whole cells (never resampled, so never blurred); the rest
	# carries over as an offset the foam pass and the water apply, so it moves smoothly.
	_foam_drift += Vector2(drift.x, drift.z) * delta
	var shift := Vector2i((_foam_drift / cell_size).floor())
	_foam_drift -= Vector2(shift) * cell_size

	var push_fft_forward := GRERenderingContext.create_push_constant([0, 1, -1.0])
	var push_fft_inverse := GRERenderingContext.create_push_constant([0, 1, 1.0])
	var push_transpose := GRERenderingContext.create_push_constant([0, 1])
	var compute_list := context.compute_list_begin()
	_pipelines[&'source'].call(context, compute_list, GRERenderingContext.create_push_constant([
		origin.x, origin.y, previous_origin.x, previous_origin.y,
		cell_size, hull_count, BORDER_SHARE * window_size, BORDER_DAMPING, delta]))
	_fft(compute_list, push_fft_forward, push_transpose)
	context.compute_list_add_barrier(compute_list)
	_pipelines[&'evolve'].call(context, compute_list, GRERenderingContext.create_push_constant([cell_size, water_depth, VISCOSITY, DAMPING, delta]))
	_fft(compute_list, push_fft_inverse, push_transpose)
	for pass_index in 2:
		context.compute_list_add_barrier(compute_list)
		_pipelines[&'output'].call(context, compute_list, GRERenderingContext.create_push_constant([pass_index, origin.x, origin.y, cell_size, hull_count, MAX_HEIGHT, MAX_SLOPE]))
	# Reads only the simulated waves and the hulls: alongside the second output pass.
	_pipelines[&'foam'].call(context, compute_list, GRERenderingContext.create_push_constant([
		origin.x, origin.y, previous_origin.x, previous_origin.y, shift.x, shift.y, _foam_read_half, hull_count,
		cell_size, delta, exp(-delta / FOAM_LIFETIME), FOAM_REACH, CREST_FOAM_SLOPE, CREST_FOAM_RATE, CREST_FOAM_MAX_COVERAGE,
		_foam_drift.x, _foam_drift.y]))
	_foam_read_half = 1 - _foam_read_half
	for i in _mip_steps.size():
		context.compute_list_add_barrier(compute_list)
		_pipelines[&'mip_chain'][i].call(context, compute_list, GRERenderingContext.create_push_constant([map_size >> _mip_steps[i].x, _mip_steps[i].y]), [_mip_sets[i]])
	context.compute_list_end()


## The window the map covers: centre (world x, z), half size (m) and 1 / size (the map's
## uv per meter). Matches interaction_window in water.gdshaderinc.
func get_window() -> Vector4:
	var window_size := map_size * cell_size
	@warning_ignore("integer_division")
	var center := (Vector2(_origin) + Vector2(map_size / 2, map_size / 2)) * cell_size
	return Vector4(center.x, center.y, window_size * 0.5, 1.0 / window_size)


## The window's first cell (x, z): it covers cells origin to origin + map_size - 1.
func get_origin() -> Vector2i:
	return _origin


## Where the foam lies relative to its cells (m, world x and z): the drift not yet moved
## by whole cells. The water samples the foam map that much upwind
## (interaction_foam_offset in water.gdshaderinc).
func get_foam_offset() -> Vector2:
	return _foam_drift


## Rows, transpose, rows (fft_compute.glsl, transpose.glsl): from the input half into
## the output half, transposed. Each pass reads what the one before wrote.
func _fft(compute_list : int, push_fft : PackedByteArray, push_transpose : PackedByteArray) -> void:
	context.compute_list_add_barrier(compute_list)
	_pipelines[&'fft'].call(context, compute_list, push_fft)
	context.compute_list_add_barrier(compute_list)
	_pipelines[&'transpose'].call(context, compute_list, push_transpose)
	context.compute_list_add_barrier(compute_list)
	_pipelines[&'fft'].call(context, compute_list, push_fft)


## Uploads the hulls nearest the window's centre whose footprint reaches into it, each
## with its pose at the last step moved along with the water since (first seen: its
## pose now, so a hull appearing makes no wave) and the foam its speed through the water
## churns up. Returns how many.
func _write_hulls(delta : float, disturbances : Dictionary) -> int:
	var half_size := map_size * cell_size * 0.5
	var candidates : Array[Array] = []
	for owner_id : int in disturbances:
		var disturbance : GREWaterDisturbance = disturbances[owner_id]
		var offset := Vector2(disturbance.position.x, disturbance.position.z) - _window_center
		if maxf(absf(offset.x), absf(offset.y)) > half_size + disturbance.half_extents.length():
			continue
		candidates.push_back([offset.length_squared(), owner_id, disturbance])
	candidates.sort_custom(func(a : Array, b : Array) -> bool: return a[0] < b[0])
	if candidates.size() > MAX_DISTURBANCES:
		if not _too_many_reported:
			push_error("GREOceanSystem: %d hulls are in the interactive wave window; only the %d nearest make waves." % [candidates.size(), MAX_DISTURBANCES])
			_too_many_reported = true
		candidates.resize(MAX_DISTURBANCES)
	var data := PackedFloat32Array()
	data.resize(MAX_DISTURBANCES * FLOATS_PER_HULL)
	var next_previous := {}
	for i in candidates.size():
		var owner_id : int = candidates[i][1]
		var disturbance : GREWaterDisturbance = candidates[i][2]
		var now := _hull_record(disturbance)
		var previous : PackedFloat32Array = now.duplicate()
		if _previous.has(owner_id):
			previous = _previous[owner_id].duplicate()
			previous[0] += disturbance.water_velocity.x * delta
			previous[1] += disturbance.water_velocity.z * delta
			if Vector2(now[0] - previous[0], now[1] - previous[1]).length() > MAX_STEP_SHARE * maxf(now[4], now[5]):
				previous = now.duplicate()
		for j in 8:
			data[i * FLOATS_PER_HULL + j] = now[j]
			data[i * FLOATS_PER_HULL + 8 + j] = previous[j]
		data[i * FLOATS_PER_HULL + 16] = _hull_foam(now, previous, delta, disturbance.wave_strength)
		next_previous[owner_id] = now
	_previous = next_previous
	var bytes := data.to_byte_array()
	context.device.buffer_update(_hull_buffer.rid, 0, bytes.size(), bytes)
	return candidates.size()


## The foam coverage a hull churns up: by its speed through the water (its centre's
## and its ends' as it turns), scaled by its wave strength; none out of the water.
func _hull_foam(now : PackedFloat32Array, previous : PackedFloat32Array, delta : float, wave_strength : float) -> float:
	if now[7] <= 0.0 or delta <= 0.0:
		return 0.0
	var speed := Vector2(now[0] - previous[0], now[1] - previous[1]).length() / delta
	var turn := Vector2(now[2], now[3]).angle_to(Vector2(previous[2], previous[3]))
	speed += absf(turn) / delta * now[4] * 0.5
	var share := clampf((speed - HULL_FOAM_START_SPEED) / (HULL_FOAM_FULL_SPEED - HULL_FOAM_START_SPEED), 0.0, 1.0)
	return minf(share * wave_strength, 1.0) * HULL_FOAM_MAX_COVERAGE


## A pose and shape of InteractionHull (interaction_common.glslinc).
func _hull_record(disturbance : GREWaterDisturbance) -> PackedFloat32Array:
	var forward := Vector2(disturbance.forward.x, disturbance.forward.z)
	forward = forward.normalized() if forward.length_squared() > 1e-8 else Vector2(0.0, -1.0)
	var half_extents := disturbance.half_extents.max(Vector2(cell_size, cell_size))
	return PackedFloat32Array([
		disturbance.position.x, disturbance.position.z, forward.x, forward.y,
		half_extents.x, half_extents.y, clampf(disturbance.shape_exponent, 1.0, 16.0),
		maxf(disturbance.depth, 0.0) * maxf(disturbance.wave_strength, 0.0),
	])


func _notification(what : int) -> void:
	if what == NOTIFICATION_PREDELETE and context != null:
		context.free()
