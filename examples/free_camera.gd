extends Camera3D
## A fly camera for the examples, read from the keyboard and mouse directly (no
## Input Map actions needed). Hold the right mouse button to look around; W A S D
## move, Q / E go down / up, Shift is faster, the mouse wheel changes the speed.

@export var speed := 10.0
@export var mouse_sensitivity := 0.003

var _yaw := 0.0
var _pitch := 0.0


func _ready() -> void:
	_yaw = rotation.y
	_pitch = rotation.x


func _unhandled_input(event : InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_RIGHT:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if event.pressed else Input.MOUSE_MODE_VISIBLE
		elif event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed:
			speed *= 1.25
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed:
			speed /= 1.25
	elif event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		_yaw -= event.relative.x * mouse_sensitivity
		_pitch = clampf(_pitch - event.relative.y * mouse_sensitivity, -1.5, 1.5)
		rotation = Vector3(_pitch, _yaw, 0.0)


func _process(delta : float) -> void:
	var move := Vector3(
		float(Input.is_physical_key_pressed(KEY_D)) - float(Input.is_physical_key_pressed(KEY_A)),
		float(Input.is_physical_key_pressed(KEY_E)) - float(Input.is_physical_key_pressed(KEY_Q)),
		float(Input.is_physical_key_pressed(KEY_S)) - float(Input.is_physical_key_pressed(KEY_W)))
	if move == Vector3.ZERO:
		return
	var boost := 4.0 if Input.is_physical_key_pressed(KEY_SHIFT) else 1.0
	position += global_basis * move.normalized() * speed * boost * delta
