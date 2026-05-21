@tool
class_name WaveCascadeParameters extends Resource
## Tunable settings for one FFT wave cascade. Use several cascades with different
## tile lengths to combine large swell, mid waves, and small surface detail.

signal scale_changed

const SPECTRUM_SLOT_COUNT := 2

## Denotes the distance the cascade's tile should cover (in meters).
@export var tile_length := Vector2(50, 50) :
	set(value): tile_length = Vector2(maxf(0.0001, value.x), maxf(0.0001, value.y)); mark_all_spectra_dirty(); scale_changed.emit()
## Multiplies vertex displacement from this cascade.
@export_range(0, 2) var displacement_scale := 1.0 :
	set(value): displacement_scale = value; scale_changed.emit()
## Multiplies normal and foam detail from this cascade.
@export_range(0, 2) var normal_scale := 1.0 :
	set(value): normal_scale = value; scale_changed.emit()

## Denotes the average wind speed above the water (in meters per second). Increasing makes waves steeper and more 'chaotic'.
@export var wind_speed := 20.0 :
	set(value): wind_speed = max(0.0001, value); mark_all_spectra_dirty()
## Local wind direction in degrees when OceanSystem.use_external_wind is disabled.
@export_range(-360, 360) var wind_direction := 0.0 :
	set(value): wind_direction = value; mark_all_spectra_dirty()
## Multiplies speed from an external wind provider before generating this cascade.
@export var wind_speed_multiplier := 1.0 :
	set(value): wind_speed_multiplier = maxf(0.0, value); mark_all_spectra_dirty()
## Adds an offset to external wind direction for this cascade.
@export_range(-360, 360) var wind_direction_offset := 0.0 :
	set(value): wind_direction_offset = value; mark_all_spectra_dirty()
## Maximum speed at which this cascade can turn toward the target wind direction.
## Lower values make long waves retain their old direction for longer.
@export_range(0.0, 180.0, 0.1, "or_greater") var wave_turn_rate_degrees_per_second := 5.0
## When enabled, turn rate is derived from tile length. Long waves turn slowly;
## short waves follow changing wind much faster.
@export var auto_turn_rate_from_tile_length := true
## Starts generating a new pending spectrum once the current wave direction has
## moved this far from the active spectrum direction.
@export_range(0.0, 45.0, 0.1) var spectrum_direction_refresh_threshold := 2.0
## Seconds used to blend from the active spectrum to the pending spectrum.
@export_range(0.01, 60.0, 0.01, "or_greater") var spectrum_direction_blend_duration := 4.0
## Denotes the distance from shoreline (in kilometers). Increasing makes waves steeper, but reduces their 'choppiness'.
@export var fetch_length := 550.0 :
	set(value): fetch_length = max(0.0001, value); mark_all_spectra_dirty()
## Mean water depth in meters for this cascade's finite-depth spectrum.
@export_range(0.1, 1000.0, 0.1, "or_greater") var water_depth_meters := 20.0 :
	set(value): water_depth_meters = maxf(0.1, value); mark_all_spectra_dirty()
## Swell factor used by the wave spectrum. Higher values favor longer organized waves.
@export_range(0, 2) var swell := 0.8 :
	set(value): swell = value; mark_all_spectra_dirty()
## Modifies how much wind and swell affect the direction of the waves.
@export_range(0, 1) var spread := 0.2 :
	set(value): spread = value; mark_all_spectra_dirty()
## Modifies the attenuation of high frequency waves.
@export_range(0, 1) var detail := 1.0 :
	set(value): detail = value; mark_all_spectra_dirty()

## Modifies how steep a wave needs to be before foam can accumulate.
@export_range(0, 2) var whitecap := 0.5 :
	set(value): whitecap = value
## Controls how quickly foam grows and decays in this cascade.
@export_range(0, 10) var foam_amount := 5.0 :
	set(value): foam_amount = value

var spectrum_seed := Vector2i.ZERO
var has_runtime_seed := false
var should_generate_spectrum := true
var active_spectrum_slot := 0
var pending_spectrum_slot := 1
var current_wave_direction : float
var target_wave_direction : float
var active_spectrum_direction : float
var pending_spectrum_direction : float
var spectrum_blend_alpha := 0.0
var is_blending_spectrum := false
var _spectrum_slot_dirty := [true, true]

var time : float
var foam_grow_rate : float
var foam_decay_rate : float


func get_effective_wind_speed(external_wind_speed : float, use_external_wind : bool) -> float:
	if not use_external_wind:
		return wind_speed
	return maxf(0.0001, external_wind_speed * wind_speed_multiplier)


func get_effective_wind_direction(external_wind_direction : float, use_external_wind : bool) -> float:
	var world_direction := wind_direction
	if not use_external_wind:
		return _world_wind_direction_to_spectrum_direction(world_direction)
	world_direction = external_wind_direction + wind_direction_offset
	return _world_wind_direction_to_spectrum_direction(world_direction)


func advance_direction_state(delta : float, external_wind_direction : float, use_external_wind : bool) -> void:
	target_wave_direction = get_effective_wind_direction(external_wind_direction, use_external_wind)
	if not has_runtime_seed:
		current_wave_direction = target_wave_direction
		active_spectrum_direction = current_wave_direction
		pending_spectrum_direction = current_wave_direction
		return

	var turn_step := get_effective_turn_rate() * delta
	current_wave_direction = _move_toward_degrees(current_wave_direction, target_wave_direction, turn_step)

	if is_blending_spectrum:
		spectrum_blend_alpha += delta / maxf(spectrum_direction_blend_duration, 0.01)
		if spectrum_blend_alpha >= 1.0:
			is_blending_spectrum = false
			var old_active_slot := active_spectrum_slot
			active_spectrum_slot = pending_spectrum_slot
			pending_spectrum_slot = old_active_slot
			active_spectrum_direction = pending_spectrum_direction
			spectrum_blend_alpha = 0.0
		return

	if _get_wrapped_degrees_delta(current_wave_direction, active_spectrum_direction) >= spectrum_direction_refresh_threshold:
		_begin_spectrum_direction_blend(current_wave_direction)


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


func get_spectrum_direction_for_slot(slot : int) -> float:
	if slot == active_spectrum_slot:
		return active_spectrum_direction
	if slot == pending_spectrum_slot:
		return pending_spectrum_direction
	return current_wave_direction


func is_spectrum_slot_dirty(slot : int) -> bool:
	_ensure_spectrum_slot_dirty_array()
	if slot < 0 or slot >= _spectrum_slot_dirty.size():
		return false
	return bool(_spectrum_slot_dirty[slot])


func mark_spectrum_slot_clean(slot : int) -> void:
	_ensure_spectrum_slot_dirty_array()
	if slot < 0 or slot >= _spectrum_slot_dirty.size():
		return
	_spectrum_slot_dirty[slot] = false
	should_generate_spectrum = _has_dirty_spectrum_slot()


func mark_all_spectra_dirty() -> void:
	_ensure_spectrum_slot_dirty_array()
	_spectrum_slot_dirty[active_spectrum_slot] = true
	if is_blending_spectrum:
		_spectrum_slot_dirty[pending_spectrum_slot] = true
	should_generate_spectrum = true


func get_spectrum_blend_state(cascade_index : int) -> Vector4:
	var active_layer := cascade_index * SPECTRUM_SLOT_COUNT + active_spectrum_slot
	var pending_layer := cascade_index * SPECTRUM_SLOT_COUNT + pending_spectrum_slot
	return Vector4(float(active_layer), float(pending_layer), spectrum_blend_alpha, 0.0)


func initialize_runtime_state(seed : Vector2i, initial_time : float) -> void:
	if has_runtime_seed:
		return
	spectrum_seed = seed
	time = initial_time
	current_wave_direction = _world_wind_direction_to_spectrum_direction(wind_direction)
	target_wave_direction = current_wave_direction
	active_spectrum_direction = current_wave_direction
	pending_spectrum_direction = current_wave_direction
	spectrum_blend_alpha = 0.0
	is_blending_spectrum = false
	active_spectrum_slot = 0
	pending_spectrum_slot = 1
	mark_all_spectra_dirty()
	has_runtime_seed = true


func _begin_spectrum_direction_blend(direction : float) -> void:
	_ensure_spectrum_slot_dirty_array()
	pending_spectrum_direction = direction
	spectrum_blend_alpha = 0.0
	is_blending_spectrum = true
	_spectrum_slot_dirty[pending_spectrum_slot] = true
	should_generate_spectrum = true


func _has_dirty_spectrum_slot() -> bool:
	_ensure_spectrum_slot_dirty_array()
	for dirty in _spectrum_slot_dirty:
		if dirty:
			return true
	return false


func _ensure_spectrum_slot_dirty_array() -> void:
	if _spectrum_slot_dirty.size() == SPECTRUM_SLOT_COUNT:
		return
	_spectrum_slot_dirty.clear()
	for i in SPECTRUM_SLOT_COUNT:
		_spectrum_slot_dirty.push_back(true)


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
