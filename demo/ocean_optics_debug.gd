extends Node3D

@export var initial_camera_position := Vector3(18.0, 7.0, 26.0)
@export var initial_camera_target := Vector3(0.0, 0.0, 0.0)
@export var move_speed := 12.0
@export var boost_multiplier := 4.0
@export var mouse_sensitivity := 0.0025

@onready var sky_system : SkySystem = $SkySystem
@onready var water : OceanSystem = $Water
@onready var wind_system : WindSystem = $WindSystem
@onready var debug_panel : OceanDebugPanel = $OceanDebugPanel
@onready var camera : Camera3D = $Camera3D

var _mouse_look := false
var _yaw := 0.0
var _pitch := 0.0


func _ready() -> void:
	if Engine.is_editor_hint():
		return
	camera.current = true
	camera.global_position = initial_camera_position
	camera.look_at(initial_camera_target, Vector3.UP)
	_yaw = camera.rotation.y
	_pitch = camera.rotation.x
	water.use_external_wind = true
	water.wind_source_path = water.get_path_to(wind_system)
	water.sky_source_path = water.get_path_to(sky_system)
	debug_panel.setup(water, wind_system, sky_system)
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)


func _process(delta : float) -> void:
	if Engine.is_editor_hint():
		return
	_move_camera(delta)


func _input(event : InputEvent) -> void:
	if Engine.is_editor_hint():
		return
	if event.is_action_pressed(&"toggle_debug_ui"):
		debug_panel.toggle_panel_visible()
	elif event.is_action_pressed(&"toggle_fullscreen"):
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN if DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_WINDOWED else DisplayServer.WINDOW_MODE_WINDOWED)
	elif event.is_action_pressed(&"ui_cancel"):
		_mouse_look = false
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)

	var mouse_button := event as InputEventMouseButton
	if mouse_button != null and mouse_button.button_index == MOUSE_BUTTON_RIGHT:
		if debug_panel.visible and debug_panel.is_interacting():
			return
		_mouse_look = mouse_button.pressed
		Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED if _mouse_look else Input.MOUSE_MODE_VISIBLE)

	var mouse_motion := event as InputEventMouseMotion
	if mouse_motion != null and _mouse_look:
		_yaw -= mouse_motion.relative.x * mouse_sensitivity
		_pitch = clampf(_pitch - mouse_motion.relative.y * mouse_sensitivity, -1.45, 1.25)
		camera.rotation = Vector3(_pitch, _yaw, 0.0)


func _move_camera(delta : float) -> void:
	var direction := Vector3.ZERO
	var basis := camera.global_transform.basis
	if Input.is_action_pressed(&"camera_move_forward"):
		direction -= basis.z
	if Input.is_action_pressed(&"camera_move_back"):
		direction += basis.z
	if Input.is_action_pressed(&"camera_move_left"):
		direction -= basis.x
	if Input.is_action_pressed(&"camera_move_right"):
		direction += basis.x
	if Input.is_action_pressed(&"camera_move_up"):
		direction += Vector3.UP
	if Input.is_action_pressed(&"camera_move_down"):
		direction -= Vector3.UP
	if direction.length_squared() <= 0.0001:
		return
	var speed := move_speed * (boost_multiplier if Input.is_action_pressed(&"camera_boost") else 1.0)
	camera.global_position += direction.normalized() * speed * delta
