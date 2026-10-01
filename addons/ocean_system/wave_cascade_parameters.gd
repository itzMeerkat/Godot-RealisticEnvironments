@tool
class_name WaveCascadeParameters extends Resource
## Tunable settings for one FFT wave cascade. Use several cascades with different
## tile lengths to combine large swell, mid waves, and small surface detail.
##
## Each cascade owns two spectrum slots. Any change to the spectrum inputs (wind,
## fetch, depth, swell, spread, detail) is generated into the inactive slot and
## crossfaded in, so the sea never jumps. Changing tile_length resets both slots.

signal scale_changed

const SPECTRUM_SLOT_COUNT := 2

## Inputs that one spectrum slot was generated from.
class SpectrumInputs:
	var wind_speed := 0.0
	## Spectrum-space direction in degrees (see _world_wind_direction_to_spectrum_direction()).
	var wind_direction := 0.0
	var fetch_length := 0.0
	var water_depth_meters := 0.0
	var swell := 0.0
	var spread := 0.0
	var detail := 0.0

@export_group("Scale")
## Repeating world-space size of this wave layer in meters. Larger tiles create
## broad swell and long waves; smaller tiles add local chop and surface detail.
## Changing it regenerates the spectrum immediately (no crossfade).
@export var tile_length := Vector2(50, 50) :
	set(value): tile_length = Vector2(maxf(0.0001, value.x), maxf(0.0001, value.y)); request_spectrum_reset(); scale_changed.emit()
## Multiplies vertex displacement contributed by this cascade. 1 is the height
## the wind and fetch produce (JONSWAP); lower it for detail-only layers, raise
## it to exaggerate swell, and use 0 to disable height.
@export_range(0, 2) var displacement_scale := 1.0 :
	set(value): displacement_scale = value; scale_changed.emit()
## Multiplies normal and foam detail contributed by this cascade. This affects
## lighting and whitecap appearance without changing the mesh displacement.
## 1 gives the physical slopes of the spectrum. The shader turns unresolved
## slopes into roughness, so steeper slopes make distant water rough and dark.
@export_range(0, 2) var normal_scale := 1.0 :
	set(value): normal_scale = value; scale_changed.emit()

@export_group("Wind")
## Local wind speed in meters per second when OceanSystem.use_external_wind is
## disabled. Higher values generate taller, steeper, more energetic waves.
@export var wind_speed := 20.0 :
	set(value): wind_speed = maxf(0.0001, value)
## Local wind direction in degrees when OceanSystem.use_external_wind is disabled.
## Public heading convention is 0 = +Z and 90 = +X.
@export_range(-360, 360) var wind_direction := 0.0
## Multiplies the external wind provider speed for this cascade. Use per-layer
## multipliers to make small chop respond more strongly than large swell.
@export var wind_speed_multiplier := 1.0 :
	set(value): wind_speed_multiplier = maxf(0.0, value)
## Adds a per-cascade direction offset to the external wind direction in degrees.
## Small offsets help break up parallel layers while keeping global wind control.
@export_range(-360, 360) var wind_direction_offset := 0.0
## Maximum turn speed toward the target wind direction when auto turn rate is
## disabled. Lower values make waves preserve their old travel direction longer.
@export_range(0.0, 180.0, 0.1, "or_greater") var wave_turn_rate_degrees_per_second := 5.0
## Derives turn speed from tile_length when enabled. Long swells turn slowly,
## while short chop follows changing wind much faster.
@export var auto_turn_rate_from_tile_length := true

@export_group("Spectrum")
## Effective fetch length in kilometers. Higher values represent wind blowing
## across water for longer distance, producing more developed organized waves.
@export var fetch_length := 550.0 :
	set(value): fetch_length = maxf(0.0001, value)
## Mean water depth in meters for the finite-depth spectrum. Shallower water
## changes wave speed and attenuates longer waves compared with deep water.
@export_range(0.1, 1000.0, 0.1, "or_greater") var water_depth_meters := 20.0 :
	set(value): water_depth_meters = maxf(0.1, value)
## Swell bias used by the directional spectrum. Higher values favor smoother,
## longer, more organized waves aligned with the wind direction.
@export_range(0, 2) var swell := 0.8
## Directional spread control. Lower values make waves more aligned with wind;
## higher values broaden directions for a rougher, less organized sea surface.
@export_range(0, 1) var spread := 0.2
## High-frequency preservation. Lower values damp tiny ripples; higher values
## keep more small-scale detail in this cascade.
@export_range(0, 1) var detail := 1.0

@export_group("Spectrum Refresh")
## Wave direction change, in degrees, before a new spectrum is generated and
## crossfaded in. Lower values react sooner but regenerate spectra more often.
@export_range(0.0, 45.0, 0.1) var spectrum_direction_refresh_threshold := 2.0
## Wind speed change, in m/s, before a new spectrum is generated and crossfaded
## in. Smaller edits accumulate until they pass this threshold.
@export_range(0.0, 10.0, 0.01, "or_greater") var spectrum_speed_refresh_threshold := 0.25
## Seconds used to crossfade from the active spectrum to a newly generated one.
## Longer blends hide changes but delay the full response.
@export_range(0.01, 60.0, 0.01, "or_greater") var spectrum_blend_duration := 4.0

@export_group("Foam")
## Foam accumulates where the surface Jacobian (of the unscaled displacement)
## drops below this value. Higher values create whitecaps sooner; lower values
## reserve foam for breaking crests (below 0 the surface folds over).
@export_range(0, 2) var whitecap := 0.82
## Foam persistence and growth strength for this cascade. Higher values create
## more visible foam that grows quickly and decays more slowly.
@export_range(0, 10) var foam_amount := 5.0

var spectrum_seed := Vector2i.ZERO
var has_runtime_seed := false
var time : float
var foam_grow_rate : float
var foam_decay_rate : float

var active_spectrum_slot := 0
var pending_spectrum_slot := 1
var is_blending_spectrum := false
## Linear crossfade progress from 0 to 1 while is_blending_spectrum is true.
var spectrum_blend_progress := 0.0
## Spectrum-space wave direction, turned gradually toward the wind.
var current_wave_direction := 0.0

var _slot_inputs : Array[SpectrumInputs] = [SpectrumInputs.new(), SpectrumInputs.new()]
var _slot_dirty : Array[bool] = [true, true]
var _needs_reset := true
var _direction_initialized := false


## Seeds the cascade once. A resource shared by several oceans keeps its first seed.
func initialize_runtime_state(seed : Vector2i, initial_time : float) -> void:
	if has_runtime_seed:
		return
	spectrum_seed = seed
	time = initial_time
	has_runtime_seed = true
	request_spectrum_reset()


## Regenerates the active spectrum on the next advance() without crossfading.
## Used when GPU resources are rebuilt or the tile size changes.
func request_spectrum_reset() -> void:
	_needs_reset = true


## Advances time, wave direction, foam rates, and the spectrum crossfade by one
## wave-simulation update.
func advance(delta : float, external_wind_speed : float, external_wind_direction : float, use_external_wind : bool) -> void:
	time += delta
	# Constants normalize foam_amount (0-10) into per-update growth and decay.
	foam_grow_rate = delta * foam_amount * 21.2
	foam_decay_rate = delta * maxf(0.5, 10.0 - foam_amount) * 1.15

	var target_direction := _get_target_spectrum_direction(external_wind_direction, use_external_wind)
	if _direction_initialized:
		current_wave_direction = _move_toward_degrees(current_wave_direction, target_direction, get_effective_turn_rate() * delta)
	else:
		current_wave_direction = target_direction
		_direction_initialized = true

	var target := _build_target_inputs(external_wind_speed, use_external_wind)
	if _needs_reset:
		_needs_reset = false
		is_blending_spectrum = false
		spectrum_blend_progress = 0.0
		_slot_inputs[active_spectrum_slot] = target
		_slot_dirty[active_spectrum_slot] = true
		return

	if is_blending_spectrum:
		spectrum_blend_progress += delta / spectrum_blend_duration
		if spectrum_blend_progress >= 1.0:
			var finished_slot := pending_spectrum_slot
			pending_spectrum_slot = active_spectrum_slot
			active_spectrum_slot = finished_slot
			is_blending_spectrum = false
			spectrum_blend_progress = 0.0
		return

	if _inputs_need_refresh(_slot_inputs[active_spectrum_slot], target):
		_slot_inputs[pending_spectrum_slot] = target
		_slot_dirty[pending_spectrum_slot] = true
		is_blending_spectrum = true
		spectrum_blend_progress = 0.0


func get_effective_turn_rate() -> float:
	if not auto_turn_rate_from_tile_length:
		return wave_turn_rate_degrees_per_second
	var tile := maxf(tile_length.x, tile_length.y)
	if tile >= 200.0:
		return 0.5
	if tile >= 80.0:
		return 2.0
	if tile >= 30.0:
		return 8.0
	return 20.0


## Slots the generator must propagate this update: the active one, plus the
## pending one while a crossfade is running.
func get_slots_to_update() -> PackedInt32Array:
	if is_blending_spectrum:
		return PackedInt32Array([active_spectrum_slot, pending_spectrum_slot])
	return PackedInt32Array([active_spectrum_slot])


func get_slot_inputs(slot : int) -> SpectrumInputs:
	return _slot_inputs[slot]


func is_spectrum_slot_dirty(slot : int) -> bool:
	return _slot_dirty[slot]


func mark_spectrum_slot_clean(slot : int) -> void:
	_slot_dirty[slot] = false


## Packed as [active layer, pending layer, active weight, pending weight]. The
## weights are equal-power (cos/sin) so crossfading two independent wave fields
## keeps the wave height constant. The pending weight is exactly 0 when idle.
func get_spectrum_blend_state(cascade_index : int) -> Vector4:
	var active_layer := cascade_index * SPECTRUM_SLOT_COUNT + active_spectrum_slot
	var pending_layer := cascade_index * SPECTRUM_SLOT_COUNT + pending_spectrum_slot
	if not is_blending_spectrum:
		return Vector4(float(active_layer), float(pending_layer), 1.0, 0.0)
	var angle := spectrum_blend_progress * PI * 0.5
	return Vector4(float(active_layer), float(pending_layer), cos(angle), sin(angle))


func _build_target_inputs(external_wind_speed : float, use_external_wind : bool) -> SpectrumInputs:
	var inputs := SpectrumInputs.new()
	inputs.wind_speed = maxf(0.0001, external_wind_speed * wind_speed_multiplier) if use_external_wind else wind_speed
	inputs.wind_direction = current_wave_direction
	inputs.fetch_length = fetch_length
	inputs.water_depth_meters = water_depth_meters
	inputs.swell = swell
	inputs.spread = spread
	inputs.detail = detail
	return inputs


func _inputs_need_refresh(active : SpectrumInputs, target : SpectrumInputs) -> bool:
	return (
		_get_wrapped_degrees_delta(active.wind_direction, target.wind_direction) >= spectrum_direction_refresh_threshold
		or absf(active.wind_speed - target.wind_speed) >= spectrum_speed_refresh_threshold
		or not is_equal_approx(active.fetch_length, target.fetch_length)
		or not is_equal_approx(active.water_depth_meters, target.water_depth_meters)
		or not is_equal_approx(active.swell, target.swell)
		or not is_equal_approx(active.spread, target.spread)
		or not is_equal_approx(active.detail, target.detail)
	)


func _get_target_spectrum_direction(external_wind_direction : float, use_external_wind : bool) -> float:
	var world_direction := external_wind_direction + wind_direction_offset if use_external_wind else wind_direction
	return _world_wind_direction_to_spectrum_direction(world_direction)


func _move_toward_degrees(from : float, to : float, max_delta : float) -> float:
	var delta := wrapf(to - from + 180.0, 0.0, 360.0) - 180.0
	if absf(delta) <= max_delta:
		return to
	return from + signf(delta) * max_delta


func _get_wrapped_degrees_delta(a : float, b : float) -> float:
	return absf(wrapf(a - b + 180.0, 0.0, 360.0) - 180.0)


func _world_wind_direction_to_spectrum_direction(world_direction : float) -> float:
	# The FFT path maps world X/Z onto texture Y/X, so convert the public
	# 0=+Z, 90=+X heading into the spectrum-space angle expected by the shader.
	return 90.0 - world_direction
