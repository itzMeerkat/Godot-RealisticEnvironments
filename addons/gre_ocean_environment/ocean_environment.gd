@tool
class_name GREOceanEnvironment
extends Node3D
## A ready-wired open-ocean environment (ocean_environment.tscn): wind, sky with
## clouds and atmosphere, the ocean, and exposure, connected to each other.
## Instance it, add a Camera3D whose far plane reaches beyond the horizon, and run.
## Tune each system through Editable Children; set the sea's height here.

## World height of the sea surface. Sets both the ocean's water_level and the
## sky's sea_level, which must match (the horizon and the haze sit at it).
@export var sea_level := 0.0 :
	set(value):
		sea_level = value
		_apply_sea_level()

## The environment's GREWindSystem.
@onready var wind : GREWindSystem = $WindSystem
## The environment's GRESkySystem.
@onready var sky : GRESkySystem = $SkySystem
## The environment's GREOceanSystem.
@onready var ocean : GREOceanSystem = $Ocean
## The environment's GREExposureController.
@onready var exposure : GREExposureController = $ExposureController


func _ready() -> void:
	_apply_sea_level()


func _apply_sea_level() -> void:
	if not is_node_ready():
		return
	ocean.water_level = sea_level
	sky.sea_level = sea_level
