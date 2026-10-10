extends Camera3D
## A camera for the examples that orbits a target and follows it. Hold the right
## mouse button and move the mouse to orbit; the mouse wheel zooms. Reads the mouse
## directly (no Input Map actions needed).

@export var target_path : NodePath
@export var distance := 7.0
@export var height := 1.5
@export var mouse_sensitivity := 0.004

var _target : Node3D
var _yaw := 0.0
var _pitch := -0.25


func _ready() -> void:
	_target = get_node_or_null(target_path) as Node3D
	if _target == null:
		push_error("OrbitCamera %s: target_path does not point to a Node3D." % get_path())
		set_process(false)


func _unhandled_input(event : InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_RIGHT:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if event.pressed else Input.MOUSE_MODE_VISIBLE
		elif event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed:
			distance = maxf(distance / 1.15, 2.0)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed:
			distance = minf(distance * 1.15, 200.0)
	elif event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		_yaw -= event.relative.x * mouse_sensitivity
		_pitch = clampf(_pitch - event.relative.y * mouse_sensitivity, -1.4, 0.3)


func _process(_delta : float) -> void:
	var focus := _target.global_position + Vector3.UP * height
	var offset := Basis.from_euler(Vector3(_pitch, _yaw, 0.0)) * Vector3(0.0, 0.0, distance)
	global_position = focus + offset
	look_at(focus)
