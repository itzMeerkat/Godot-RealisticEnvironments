@tool
class_name WaveCascadeParameters extends Resource

signal scale_changed

## Denotes the distance the cascade's tile should cover (in meters).
@export var tile_length := Vector2(50, 50) :
	set(value): tile_length = value; should_generate_spectrum = true; scale_changed.emit()
@export_range(0, 2) var displacement_scale := 1.0 : # Note: This should be reduced as the number of cascades increases to avoid *too* much detail!
	set(value): displacement_scale = value; scale_changed.emit()
@export_range(0, 2) var normal_scale := 1.0 : # Note: This should be reduced as the number of cascades increases to avoid *too* much detail!
	set(value): normal_scale = value; scale_changed.emit()

## Denotes the average wind speed above the water (in meters per second). Increasing makes waves steeper and more 'chaotic'.
@export var wind_speed := 20.0 :
	set(value): wind_speed = max(0.0001, value); should_generate_spectrum = true
@export_range(-360, 360) var wind_direction := 0.0 :
	set(value): wind_direction = value; should_generate_spectrum = true
## Denotes the distance from shoreline (in kilometers). Increasing makes waves steeper, but reduces their 'choppiness'.
@export var fetch_length := 550.0 :
	set(value): fetch_length = max(0.0001, value); should_generate_spectrum = true
@export_range(0, 2) var swell := 0.8 :
	set(value): swell = value; should_generate_spectrum = true
## Modifies how much wind and swell affect the direction of the waves.
@export_range(0, 1) var spread := 0.2 :
	set(value): spread = value; should_generate_spectrum = true
## Modifies the attenuation of high frequency waves.
@export_range(0, 1) var detail := 1.0 :
	set(value): detail = value; should_generate_spectrum = true

## Modifies how steep a wave needs to be before foam can accumulate.
@export_range(0, 2) var whitecap := 0.5 : # Note: 'Wispier' foam can be created by increasing the 'foam_amount' and decreasing the 'whitecap' parameters.
	set(value): whitecap = value; should_generate_spectrum = true
@export_range(0, 10) var foam_amount := 5.0 :
	set(value): foam_amount = value; should_generate_spectrum = true

var spectrum_seed := Vector2i.ZERO
var should_generate_spectrum := true

var time : float
var foam_grow_rate : float
var foam_decay_rate : float
