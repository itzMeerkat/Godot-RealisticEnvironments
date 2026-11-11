class_name GREWaveCascadeState
extends RefCounted
## GREOceanSystem's simulation state of one GREWaveCascade (internal): its random seed and
## clock, the band of wavenumbers it draws, its two spectrum slots and their
## crossfade, and the times of its two newest FFT frames.
##
## Any change to the spectrum's inputs (wind, fetch, depth, swell, spread, detail) is
## generated into the inactive slot and crossfaded in, so the sea never jumps. A new
## tile length or band, or rebuilt GPU resources, regenerate the active slot at once.

const SLOT_COUNT := 2
## wavenumber_band.y of the smallest cascade: no upper limit.
const UNBOUNDED_WAVENUMBER := 1.0e30

## Inputs that one spectrum slot was generated from.
class SpectrumInputs:
	var wind_speed := 0.0
	## Spectrum-space direction in degrees (see _world_to_spectrum_direction()).
	var wind_direction := 0.0
	var fetch_length := 0.0
	var water_depth := 0.0
	var swell := 0.0
	var spread := 0.0
	var detail := 0.0

## Random seed of the cascade's spectrum.
var spectrum_seed := Vector2i.ZERO
## The cascade's clock (s) at its newest FFT frame.
var time := 0.0
## The wavenumbers (rad/m) the cascade draws, [x, y): the cascades split the spectrum
## by tile length, so each wavelength comes from one cascade only
## (GREOceanSystem._update_spectrum_bands()).
var wavenumber_band := Vector2(0.0, UNBOUNDED_WAVENUMBER)
## Foam added and decayed by the latest update, for fft_unpack.glsl (set by advance()).
var foam_grow_rate := 0.0
var foam_decay_rate := 0.0
## Whole texels (x along world x, y along world z) the foam drifts by in the latest
## update, and the drift (m) not yet moved (set by advance_foam_drift()).
var foam_shift := Vector2i.ZERO
var _foam_drift := Vector2.ZERO
## The spectrum slot shown, and the one a new spectrum is generated into and
## crossfaded from.
var active_slot := 0
var pending_slot := 1
## Whether a crossfade between the slots is running, and its linear progress (0-1).
var is_blending := false
var blend_progress := 0.0
## Spectrum-space wave direction (degrees), turned gradually toward the wind.
var wave_direction := 0.0
## Ocean time of the newest and of the previous FFT frame, and how many frames have
## been computed since the GPU resources were (re)built.
var frame_time := 0.0
var previous_frame_time := 0.0
var frame_count := 0

var _slot_inputs : Array[SpectrumInputs] = [SpectrumInputs.new(), SpectrumInputs.new()]
var _slot_dirty : Array[bool] = [true, true]
var _needs_reset := true
var _direction_initialized := false
## GREWaveCascade.tile_length the active slot was generated for.
var _tile_length := 0.0


func _init(initial_seed : Vector2i, initial_time : float) -> void:
	spectrum_seed = initial_seed
	time = initial_time


## Regenerates the active spectrum on the next advance(), without crossfading.
func regenerate() -> void:
	_needs_reset = true


## Advances time, wave direction, foam rates and the spectrum crossfade by one
## FFT update of delta seconds, toward spectrum under the wind (speed m/s, world
## direction in degrees) the ocean resolved.
func advance(delta : float, cascade : GREWaveCascade, spectrum : GREWaveSpectrum, wind_speed : float, wind_direction : float) -> void:
	time += delta
	foam_grow_rate = delta * cascade.foam_generation
	foam_decay_rate = delta / cascade.foam_lifetime
	if cascade.tile_length != _tile_length:
		_tile_length = cascade.tile_length
		_needs_reset = true

	var target_direction := _world_to_spectrum_direction(wind_direction)
	if _direction_initialized:
		wave_direction = _move_toward_degrees(wave_direction, target_direction, _get_turn_rate(cascade, spectrum) * delta)
	else:
		wave_direction = target_direction
		_direction_initialized = true

	var target := _build_target_inputs(spectrum, wind_speed)
	if _needs_reset:
		_needs_reset = false
		is_blending = false
		blend_progress = 0.0
		_slot_inputs[active_slot] = target
		_slot_dirty[active_slot] = true
		return

	if is_blending:
		blend_progress += delta / spectrum.blend_duration
		if blend_progress >= 1.0:
			var finished_slot := pending_slot
			pending_slot = active_slot
			active_slot = finished_slot
			is_blending = false
			blend_progress = 0.0
		return

	if _inputs_need_refresh(_slot_inputs[active_slot], target, spectrum):
		_slot_inputs[pending_slot] = target
		_slot_dirty[pending_slot] = true
		is_blending = true
		blend_progress = 0.0


## Moves the foam by the water's mean drift, velocity (m/s, world x and z), over
## delta seconds, in whole texels of texel_size meters (foam_shift); the rest carries over.
func advance_foam_drift(delta : float, velocity : Vector2, texel_size : float) -> void:
	_foam_drift += velocity * delta
	var texels := (_foam_drift / texel_size).floor()
	_foam_drift -= texels * texel_size
	foam_shift = Vector2i(texels)

## Slots the generator must propagate this update: the active one, plus the
## pending one while a crossfade is running.
func get_slots_to_update() -> PackedInt32Array:
	if is_blending:
		return PackedInt32Array([active_slot, pending_slot])
	return PackedInt32Array([active_slot])


## The inputs slot was (or is to be) generated from.
func get_slot_inputs(slot : int) -> SpectrumInputs:
	return _slot_inputs[slot]


## Whether slot's spectrum must be regenerated before it is used.
func is_slot_dirty(slot : int) -> bool:
	return _slot_dirty[slot]


## Marks slot's spectrum as generated (GREWaveGenerator calls it).
func mark_slot_clean(slot : int) -> void:
	_slot_dirty[slot] = false


## Packed as [active layer, pending layer, active weight, pending weight] for a
## cascade at cascade_index. The weights are equal-power (cos/sin) so crossfading two
## independent wave fields keeps the wave height constant. The pending weight is
## exactly 0 when idle.
func get_blend_state(cascade_index : int) -> Vector4:
	var active_layer := cascade_index * SLOT_COUNT + active_slot
	var pending_layer := cascade_index * SLOT_COUNT + pending_slot
	if not is_blending:
		return Vector4(float(active_layer), float(pending_layer), 1.0, 0.0)
	var angle := blend_progress * PI * 0.5
	return Vector4(float(active_layer), float(pending_layer), cos(angle), sin(angle))


## Degrees per second the waves turn toward a new wind direction: spectrum's set rate,
## or the automatic one (slower for longer tiles).
static func _get_turn_rate(cascade : GREWaveCascade, spectrum : GREWaveSpectrum) -> float:
	if not spectrum.auto_turn_rate:
		return spectrum.turn_rate
	if cascade.tile_length >= 200.0:
		return 0.5
	if cascade.tile_length >= 80.0:
		return 2.0
	if cascade.tile_length >= 30.0:
		return 8.0
	return 20.0


func _build_target_inputs(spectrum : GREWaveSpectrum, wind_speed : float) -> SpectrumInputs:
	var inputs := SpectrumInputs.new()
	inputs.wind_speed = maxf(0.0001, wind_speed)
	inputs.wind_direction = wave_direction
	inputs.fetch_length = spectrum.fetch_length
	inputs.water_depth = spectrum.water_depth
	inputs.swell = spectrum.swell
	inputs.spread = spectrum.spread
	inputs.detail = spectrum.detail
	return inputs


static func _inputs_need_refresh(active : SpectrumInputs, target : SpectrumInputs, spectrum : GREWaveSpectrum) -> bool:
	return (
		_wrapped_degrees_delta(active.wind_direction, target.wind_direction) >= spectrum.direction_refresh_threshold
		or absf(active.wind_speed - target.wind_speed) >= spectrum.speed_refresh_threshold
		or not is_equal_approx(active.fetch_length, target.fetch_length)
		or not is_equal_approx(active.water_depth, target.water_depth)
		or not is_equal_approx(active.swell, target.swell)
		or not is_equal_approx(active.spread, target.spread)
		or not is_equal_approx(active.detail, target.detail)
	)


static func _move_toward_degrees(from : float, to : float, max_delta : float) -> float:
	var delta := wrapf(to - from + 180.0, 0.0, 360.0) - 180.0
	if absf(delta) <= max_delta:
		return to
	return from + signf(delta) * max_delta


static func _wrapped_degrees_delta(a : float, b : float) -> float:
	return absf(wrapf(a - b + 180.0, 0.0, 360.0) - 180.0)


static func _world_to_spectrum_direction(world_direction : float) -> float:
	# The FFT path maps world X/Z onto texture Y/X, so convert the public
	# 0=+Z, 90=+X heading into the spectrum-space angle expected by the shader.
	return 90.0 - world_direction
