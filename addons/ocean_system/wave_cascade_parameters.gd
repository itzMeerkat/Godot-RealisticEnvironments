@tool
class_name WaveCascadeParameters extends Resource
## Tunable settings for one FFT wave cascade. Use several cascades with different
## tile lengths to combine large swell, mid waves, and small surface detail.

signal scale_changed

## Denotes the distance the cascade's tile should cover (in meters).
@export var tile_length := Vector2(50, 50) :
	set(value): tile_length = Vector2(maxf(0.0001, value.x), maxf(0.0001, value.y)); should_generate_spectrum = true; scale_changed.emit()
## Multiplies vertex displacement from this cascade.
@export_range(0, 2) var displacement_scale := 1.0 :
	set(value): displacement_scale = value; scale_changed.emit()
## Multiplies normal and foam detail from this cascade.
@export_range(0, 2) var normal_scale := 1.0 :
	set(value): normal_scale = value; scale_changed.emit()

## Denotes the average wind speed above the water (in meters per second). Increasing makes waves steeper and more 'chaotic'.
@export var wind_speed := 20.0 :
	set(value): wind_speed = max(0.0001, value); should_generate_spectrum = true
## Local wind direction in degrees when OceanSystem.use_external_wind is disabled.
@export_range(-360, 360) var wind_direction := 0.0 :
	set(value): wind_direction = value; should_generate_spectrum = true
## Multiplies speed from an external wind provider before generating this cascade.
@export var wind_speed_multiplier := 1.0 :
	set(value): wind_speed_multiplier = maxf(0.0, value); should_generate_spectrum = true
## Adds an offset to external wind direction for this cascade.
@export_range(-360, 360) var wind_direction_offset := 0.0 :
	set(value): wind_direction_offset = value; should_generate_spectrum = true
## Denotes the distance from shoreline (in kilometers). Increasing makes waves steeper, but reduces their 'choppiness'.
@export var fetch_length := 550.0 :
	set(value): fetch_length = max(0.0001, value); should_generate_spectrum = true
## Swell factor used by the wave spectrum. Higher values favor longer organized waves.
@export_range(0, 2) var swell := 0.8 :
	set(value): swell = value; should_generate_spectrum = true
## Modifies how much wind and swell affect the direction of the waves.
@export_range(0, 1) var spread := 0.2 :
	set(value): spread = value; should_generate_spectrum = true
## Modifies the attenuation of high frequency waves.
@export_range(0, 1) var detail := 1.0 :
	set(value): detail = value; should_generate_spectrum = true

## Modifies how steep a wave needs to be before foam can accumulate.
@export_range(0, 2) var whitecap := 0.5 :
	set(value): whitecap = value
## Controls how quickly foam grows and decays in this cascade.
@export_range(0, 10) var foam_amount := 5.0 :
	set(value): foam_amount = value

var spectrum_seed := Vector2i.ZERO
var has_runtime_seed := false
var should_generate_spectrum := true

var time : float
var foam_grow_rate : float
var foam_decay_rate : float


func get_effective_wind_speed(external_wind_speed : float, use_external_wind : bool) -> float:
	if not use_external_wind:
		return wind_speed
	return maxf(0.0001, external_wind_speed * wind_speed_multiplier)


func get_effective_wind_direction(external_wind_direction : float, use_external_wind : bool) -> float:
	if not use_external_wind:
		return wind_direction
	return external_wind_direction + wind_direction_offset


func initialize_runtime_state(seed : Vector2i, initial_time : float) -> void:
	if has_runtime_seed:
		return
	spectrum_seed = seed
	time = initial_time
	has_runtime_seed = true
