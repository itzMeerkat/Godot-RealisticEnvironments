class_name DemoInputActions
extends RefCounted

const ACTION_CYCLE_CAMERA_MODE := &"cycle_camera_mode"
const ACTION_CAMERA_MOVE_FORWARD := &"camera_move_forward"
const ACTION_CAMERA_MOVE_BACK := &"camera_move_back"
const ACTION_CAMERA_MOVE_LEFT := &"camera_move_left"
const ACTION_CAMERA_MOVE_RIGHT := &"camera_move_right"
const ACTION_CAMERA_MOVE_UP := &"camera_move_up"
const ACTION_CAMERA_MOVE_DOWN := &"camera_move_down"
const ACTION_CAMERA_BOOST := &"camera_boost"

static func ensure_defaults() -> void:
	_ensure_key_action(ACTION_CYCLE_CAMERA_MODE, KEY_C, 0.5)
	_ensure_key_action(ACTION_CAMERA_MOVE_FORWARD, KEY_W)
	_ensure_key_action(ACTION_CAMERA_MOVE_BACK, KEY_S)
	_ensure_key_action(ACTION_CAMERA_MOVE_LEFT, KEY_A)
	_ensure_key_action(ACTION_CAMERA_MOVE_RIGHT, KEY_D)
	_ensure_key_action(ACTION_CAMERA_MOVE_UP, KEY_E)
	_ensure_key_action(ACTION_CAMERA_MOVE_DOWN, KEY_Q)
	_ensure_key_action(ACTION_CAMERA_BOOST, KEY_SHIFT)

static func ensure_project_settings_defaults() -> void:
	_ensure_project_key_action(ACTION_CYCLE_CAMERA_MODE, KEY_C, 0.5)
	_ensure_project_key_action(ACTION_CAMERA_MOVE_FORWARD, KEY_W)
	_ensure_project_key_action(ACTION_CAMERA_MOVE_BACK, KEY_S)
	_ensure_project_key_action(ACTION_CAMERA_MOVE_LEFT, KEY_A)
	_ensure_project_key_action(ACTION_CAMERA_MOVE_RIGHT, KEY_D)
	_ensure_project_key_action(ACTION_CAMERA_MOVE_UP, KEY_E)
	_ensure_project_key_action(ACTION_CAMERA_MOVE_DOWN, KEY_Q)
	_ensure_project_key_action(ACTION_CAMERA_BOOST, KEY_SHIFT)

static func _ensure_key_action(action: StringName, key: Key, deadzone := 0.2) -> void:
	if not InputMap.has_action(action):
		InputMap.add_action(action, deadzone)
	elif not is_equal_approx(InputMap.action_get_deadzone(action), deadzone):
		InputMap.action_set_deadzone(action, deadzone)

	if _action_has_key(action, key):
		return

	var event := InputEventKey.new()
	event.keycode = key
	event.physical_keycode = key
	InputMap.action_add_event(action, event)

static func _ensure_project_key_action(action: StringName, key: Key, deadzone := 0.2) -> void:
	var setting_name := "input/%s" % String(action)
	if ProjectSettings.has_setting(setting_name):
		return

	var event := InputEventKey.new()
	event.keycode = key
	event.physical_keycode = key
	ProjectSettings.set_setting(setting_name, {
		"deadzone": deadzone,
		"events": [event],
	})
	ProjectSettings.save()

static func _action_has_key(action: StringName, key: Key) -> bool:
	for event in InputMap.action_get_events(action):
		var key_event := event as InputEventKey
		if key_event == null:
			continue
		if key_event.keycode == key or key_event.physical_keycode == key:
			return true
	return false
