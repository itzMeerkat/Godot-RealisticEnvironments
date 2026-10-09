@tool
class_name WaveGenerator extends Node
## Handles the compute pipeline for wave spectra generation/FFT.
##
## Output goes to two fixed pairs of maps, A and B (descriptors
## displacement_map_a/b, normal_map_a/b). Each cascade updates on its own
## schedule (OceanSystem) into whichever map does not hold its newest frame, so
## A and B hold every cascade's two latest frames, in either order
## (cascade_newest_output).

const G := 9.81
## Every wave's phase repeats after this many seconds (spectrum_modulate.glsl rounds the
## frequencies to multiples of 2 pi / it), so the clock reaches the GPU modulo it and
## keeps its float32 precision in long sessions.
const WAVE_REPEAT_SECONDS := 1000.0
const SPECTRUM_SLOT_COUNT := WaveCascadeParameters.SPECTRUM_SLOT_COUNT
## Mip levels mip_chain.glsl builds per dispatch (a 16 x 16 workgroup halves a 32 x 32
## tile five times).
const MIP_LEVELS_PER_DISPATCH := 5

var map_size : int
var context : RenderingContext
var pipelines : Dictionary = {}
var descriptors : Dictionary = {}
var output_descriptors : Array[Dictionary] = []
## unpack_sets[output][layer]
var unpack_sets : Array[Array] = []
## mip_sets[output][layer][step]: the descriptor set of mip_chain.glsl's step-th
## dispatch (source level and the levels it writes, both maps).
var mip_sets : Array[Array] = []
## Per mip_chain step: [source level, levels written].
var mip_steps : Array[Vector2i] = []
## Levels of the displacement and normal map mip chains (down to 1x1).
var mip_count := 1
var fft_buffer_set : RID
var cascade_capacity := 0
var spectrum_layer_capacity := 0
## Per cascade: the output (0 = A, 1 = B) holding its newest frame.
var cascade_newest_output := PackedInt32Array()

func init_gpu(num_cascades : int) -> void:
	assert(context == null, "WaveGenerator.init_gpu() must only be called once.")
	cascade_capacity = num_cascades
	spectrum_layer_capacity = num_cascades * SPECTRUM_SLOT_COUNT
	cascade_newest_output.resize(num_cascades)
	cascade_newest_output.fill(1) # the first update writes A

	# --- DEVICE/SHADER CREATION ---
	context = RenderingContext.new(RenderingServer.get_rendering_device())
	var spectrum_compute_shader := context.load_shader('res://addons/ocean_system/shaders/compute/spectrum_compute.glsl')
	var fft_butterfly_shader := context.load_shader('res://addons/ocean_system/shaders/compute/fft_butterfly.glsl')
	var spectrum_modulate_shader := context.load_shader('res://addons/ocean_system/shaders/compute/spectrum_modulate.glsl')
	# One shader version per map size: the FFT workgroup is exactly one row wide.
	var fft_compute_shader := context.load_shader('res://addons/ocean_system/shaders/compute/fft_compute.glsl', StringName('size_%d' % map_size))
	var transpose_shader := context.load_shader('res://addons/ocean_system/shaders/compute/transpose.glsl')
	var fft_unpack_shader := context.load_shader('res://addons/ocean_system/shaders/compute/fft_unpack.glsl')
	var mip_chain_shader := context.load_shader('res://addons/ocean_system/shaders/compute/mip_chain.glsl')

	# --- DESCRIPTOR PREPARATION ---
	var dims := Vector2i(map_size, map_size)
	var num_fft_stages := int(log(map_size) / log(2))
	# Both output maps carry full mip chains (down to 1x1). Displacement mips let
	# coarse mesh vertices sample prefiltered waves; normal mips hold mean slope,
	# mean squared slope and foam, so distant water is filtered and its unresolved
	# slope variance becomes roughness in the water shader.
	mip_count = num_fft_stages + 1
	mip_steps.clear()
	var source_level := 0
	while source_level < mip_count - 1:
		var levels := mini(MIP_LEVELS_PER_DISPATCH, mip_count - 1 - source_level)
		mip_steps.push_back(Vector2i(source_level, levels))
		source_level += levels

	descriptors[&'spectrum'] = context.create_texture(dims, RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT, RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT, spectrum_layer_capacity)
	descriptors[&'butterfly_factors'] = context.create_storage_buffer(num_fft_stages*map_size * 4 * 4)         # Size: (#FFT stages * map size * sizeof(vec4))
	# One region per spectrum slot, not per layer: cascades are transformed one after another.
	descriptors[&'fft_buffer'] = context.create_storage_buffer(SPECTRUM_SLOT_COUNT * map_size*map_size * 4*2 * 2 * 4) # Size: (slots * map size^2 * 4 FFTs * 2 temp buffers (for Stockham FFT) * sizeof(vec2))
	output_descriptors.clear()
	unpack_sets.clear()
	mip_sets.clear()
	var output_usage := RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT
	for i in range(2):
		var displacement_map := context.create_texture(dims, RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT, output_usage, spectrum_layer_capacity, [], mip_count)
		var normal_map := context.create_texture(dims, RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT, output_usage, spectrum_layer_capacity, [], mip_count)
		# Start from zero: a cascade's first update reads the other output's foam,
		# and until its second update the other output (sampled, with weight 0, by
		# the interaction simulation and surface queries) was never written.
		# Uninitialized memory can hold NaN, which nothing recovers from.
		context.device.texture_clear(displacement_map.rid, Color(0, 0, 0, 0), 0, mip_count, 0, spectrum_layer_capacity)
		context.device.texture_clear(normal_map.rid, Color(0, 0, 0, 0), 0, mip_count, 0, spectrum_layer_capacity)
		output_descriptors.push_back({
			&'displacement_map': displacement_map,
			&'normal_map': normal_map,
			# views[layer][mip]: storage bindings need single-level views.
			&'displacement_views': _create_layer_mip_views(displacement_map),
			&'normal_views': _create_layer_mip_views(normal_map),
		})

	var spectrum_compute_set := context.create_descriptor_set([descriptors[&'spectrum']], spectrum_compute_shader, 0)
	var spectrum_modulate_set := context.create_descriptor_set([descriptors[&'spectrum']], spectrum_modulate_shader, 0)
	var fft_butterfly_set := context.create_descriptor_set([descriptors[&'butterfly_factors']], fft_butterfly_shader, 0)
	var fft_compute_set := context.create_descriptor_set([descriptors[&'butterfly_factors'], descriptors[&'fft_buffer']], fft_compute_shader, 0)
	var transpose_set := context.create_descriptor_set([descriptors[&'fft_buffer']], transpose_shader, 0)
	fft_buffer_set = context.create_descriptor_set([descriptors[&'fft_buffer']], spectrum_modulate_shader, 1)
	for i in range(output_descriptors.size()):
		var output := output_descriptors[i]
		var previous_output := output_descriptors[(i + 1) % output_descriptors.size()]
		var output_unpack_sets : Array[RID] = []
		var output_mip_sets : Array[Array] = []
		for layer in spectrum_layer_capacity:
			var displacement_views : Array = output[&'displacement_views'][layer]
			var normal_views : Array = output[&'normal_views'][layer]
			var previous_normal_views : Array = previous_output[&'normal_views'][layer]
			output_unpack_sets.push_back(context.create_descriptor_set([displacement_views[0], normal_views[0], previous_normal_views[0]], fft_unpack_shader, 0))
			var layer_mip_sets : Array[RID] = []
			for step in mip_steps:
				var chain : Array[RenderingContext.Descriptor] = []
				for views in [displacement_views, normal_views]:
					chain.push_back(views[step.x])
					for level in MIP_LEVELS_PER_DISPATCH:
						# Slots past the levels written repeat the last one (never written).
						chain.push_back(views[step.x + mini(level + 1, step.y)])
				layer_mip_sets.push_back(context.create_descriptor_set(chain, mip_chain_shader, 0))
			output_mip_sets.push_back(layer_mip_sets)
		unpack_sets.push_back(output_unpack_sets)
		mip_sets.push_back(output_mip_sets)
	descriptors[&'displacement_map_a'] = output_descriptors[0][&'displacement_map']
	descriptors[&'displacement_map_b'] = output_descriptors[1][&'displacement_map']
	descriptors[&'normal_map_a'] = output_descriptors[0][&'normal_map']
	descriptors[&'normal_map_b'] = output_descriptors[1][&'normal_map']

	# --- COMPUTE PIPELINE CREATION ---
	@warning_ignore("integer_division")
	var groups_16 := map_size / 16
	@warning_ignore("integer_division")
	var butterfly_groups := maxi(1, map_size / 128)
	@warning_ignore("integer_division")
	var groups_32 := map_size / 32
	pipelines[&'spectrum_compute'] = context.create_pipeline([groups_16, groups_16, 1], [spectrum_compute_set], spectrum_compute_shader)
	pipelines[&'spectrum_modulate'] = context.create_pipeline([groups_16, groups_16, 1], [spectrum_modulate_set, fft_buffer_set], spectrum_modulate_shader)
	pipelines[&'fft_butterfly'] = context.create_pipeline([butterfly_groups, num_fft_stages, 1], [fft_butterfly_set], fft_butterfly_shader)
	pipelines[&'fft_compute'] = context.create_pipeline([1, map_size, 4], [fft_compute_set], fft_compute_shader)
	pipelines[&'transpose'] = context.create_pipeline([groups_32, groups_32, 4], [transpose_set], transpose_shader)
	pipelines[&'fft_unpack'] = context.create_pipeline([groups_16, groups_16, 1], [unpack_sets[0][0], fft_buffer_set], fft_unpack_shader)
	var mip_pipelines : Array[Callable] = []
	for step in mip_steps:
		# Workgroups cover the first level written; z: displacement, normal map.
		var groups := ceili((map_size >> (step.x + 1)) / 16.0)
		mip_pipelines.push_back(context.create_pipeline([groups, groups, 2], [mip_sets[0][0][0]], mip_chain_shader))
	pipelines[&'mip_chain'] = mip_pipelines

	# We only need to generate butterfly factors once for each map_size.
	var compute_list := context.compute_list_begin()
	pipelines[&'fft_butterfly'].call(context, compute_list)
	context.compute_list_end()

## Computes the cascade's next frame (at params.time; call params.advance()
## first) into the output that does not hold its newest frame, which it then
## becomes.
func update_cascade(cascade_index : int, params : WaveCascadeParameters) -> void:
	assert(context != null, "WaveGenerator.update_cascade() called before init_gpu().")
	assert(cascade_index < cascade_capacity, "More cascades than the generator was initialized for.")
	var write_output := 1 - cascade_newest_output[cascade_index]
	var compute_list := context.compute_list_begin()
	for slot in params.get_slots_to_update():
		_update_spectrum_slot(compute_list, cascade_index, slot, params, write_output)
	context.compute_list_end()
	cascade_newest_output[cascade_index] = write_output

func _update_spectrum_slot(compute_list : int, cascade_index : int, slot : int, params : WaveCascadeParameters, write_output : int) -> void:
	var spectrum_layer := cascade_index * SPECTRUM_SLOT_COUNT + slot
	var inputs := params.get_slot_inputs(slot)
	# Every pass reads what the previous one wrote. Dispatches inside one compute
	# list are not ordered, so each dependency needs a barrier.
	## --- WAVE SPECTRA UPDATE ---
	if params.is_spectrum_slot_dirty(slot):
		var alpha := JONSWAP_alpha(inputs.wind_speed, inputs.fetch_length*1e3)
		var omega := JONSWAP_peak_angular_frequency(inputs.wind_speed, inputs.fetch_length*1e3)
		pipelines[&'spectrum_compute'].call(context, compute_list, RenderingContext.create_push_constant([params.spectrum_seed.x, params.spectrum_seed.y, params.tile_length.x, params.tile_length.y, alpha, omega, inputs.wind_speed, deg_to_rad(inputs.wind_direction), inputs.water_depth_meters, inputs.swell, inputs.detail, inputs.spread, spectrum_layer]))
		params.mark_spectrum_slot_clean(slot)
		context.compute_list_add_barrier(compute_list)
	pipelines[&'spectrum_modulate'].call(context, compute_list, RenderingContext.create_push_constant([params.tile_length.x, params.tile_length.y, inputs.water_depth_meters, fposmod(params.time, WAVE_REPEAT_SECONDS), spectrum_layer, slot]))
	context.compute_list_add_barrier(compute_list)

	## --- WAVE SPECTRA INVERSE FOURIER TRANSFORM ---
	var fft_push_constant := RenderingContext.create_push_constant([slot])
	# Note: We need not do a second transpose after computing FFT on rows since rotating the wave by
	#       PI/2 doesn't affect it visually.
	pipelines[&'fft_compute'].call(context, compute_list, fft_push_constant)
	context.compute_list_add_barrier(compute_list)
	pipelines[&'transpose'].call(context, compute_list, fft_push_constant)
	context.compute_list_add_barrier(compute_list)
	pipelines[&'fft_compute'].call(context, compute_list, fft_push_constant)
	context.compute_list_add_barrier(compute_list)

	## --- DISPLACEMENT/NORMAL MAP UPDATE ---
	pipelines[&'fft_unpack'].call(context, compute_list, RenderingContext.create_push_constant([slot, params.whitecap, params.foam_grow_rate, params.foam_decay_rate, params.displacement_scale]), [unpack_sets[write_output][spectrum_layer], fft_buffer_set])

	## --- MIP CHAINS (displacement and normal maps of this layer, up to five levels a dispatch) ---
	for step in mip_steps.size():
		context.compute_list_add_barrier(compute_list)
		var push_constant := RenderingContext.create_push_constant([map_size >> mip_steps[step].x, mip_steps[step].y])
		pipelines[&'mip_chain'][step].call(context, compute_list, push_constant, [mip_sets[write_output][spectrum_layer][step]])

## views[layer][mip] of a texture array, for storage bindings.
func _create_layer_mip_views(texture : RenderingContext.Descriptor) -> Array[Array]:
	var views : Array[Array] = []
	for layer in spectrum_layer_capacity:
		var layer_views : Array[RenderingContext.Descriptor] = []
		for mip in mip_count:
			layer_views.push_back(context.create_texture_slice_view(texture, layer, mip))
		views.push_back(layer_views)
	return views

func _notification(what):
	if what == NOTIFICATION_PREDELETE and context != null:
		context.free()

# Source: https://wikiwaves.org/Ocean-Wave_Spectra#JONSWAP_Spectrum
static func JONSWAP_alpha(wind_speed:=20.0, fetch_length:=550e3) -> float:
	return 0.076 * pow(wind_speed**2 / (fetch_length*G), 0.22)

# Source: https://wikiwaves.org/Ocean-Wave_Spectra#JONSWAP_Spectrum
static func JONSWAP_peak_angular_frequency(wind_speed:=20.0, fetch_length:=550e3) -> float:
	return 22.0 * pow(G*G / (wind_speed*fetch_length), 1.0/3.0)
