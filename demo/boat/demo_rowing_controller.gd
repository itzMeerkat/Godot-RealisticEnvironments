class_name DemoRowingController
extends Node
## Simple demo-only oar driver. It moves WaterReactionProbe nodes through a
## submerged power stroke and an above-water recovery stroke.

@export var left_probe_path : NodePath
@export var right_probe_path : NodePath
@export var row_forward_action: StringName = &"row_forward"
@export var row_back_action: StringName = &"row_back"
@export var row_left_action: StringName = &"row_left"
@export var row_right_action: StringName = &"row_right"
@export var left_oar_action: StringName = &"row_left_oar"
@export var right_oar_action: StringName = &"row_right_oar"
@export var require_player_controlled_parent := true
@export var animate_probes := true
@export var gate_probes_by_oar_actions := false
@export var debug_rowing_input := true
@export var animate_oar_nodes := true
@export var left_oar_node_path : NodePath
@export var right_oar_node_path : NodePath
@export var oar_stroke_axis := Vector3.UP
@export_range(0.0, 90.0, 0.1) var oar_pressed_angle_degrees := 34.0
@export_range(0.0, 30.0, 0.01) var oar_animation_smoothing := 14.0
@export_range(0.1, 10.0, 0.01, "or_greater") var stroke_frequency := 1.25
@export_range(0.1, 20.0, 0.01, "or_greater") var stroke_distance := 3.2
@export_range(0.0, 10.0, 0.01, "or_greater") var recovery_lift := 1.15
@export_range(0.05, 0.95, 0.01) var power_stroke_fraction := 0.58
@export_range(0.0, 30.0, 0.01) var idle_smoothing := 8.0

var _left_probe : WaterReactionProbe
var _right_probe : WaterReactionProbe
var _left_oar : Node3D
var _right_oar : Node3D
var _rest_positions := {}
var _rest_oar_bases := {}
var _phases := {}
var _last_action_pressed := {}
var _reported_missing_actions := {}


func _enter_tree() -> void:
	process_priority = -50


func _ready() -> void:
	_resolve_probes()
	_resolve_oars()
	if not require_player_controlled_parent or _is_parent_player_controlled():
		_log_action_binding(left_oar_action)
		_log_action_binding(right_oar_action)


func _physics_process(delta: float) -> void:
	_resolve_probes()
	_resolve_oars()

	if gate_probes_by_oar_actions:
		var allow_input := not require_player_controlled_parent or _is_parent_player_controlled()
		var left_strength := _get_action_strength(left_oar_action)
		var right_strength := _get_action_strength(right_oar_action)
		_log_oar_action(&"left", left_oar_action, left_strength, left_probe_path, _left_probe, allow_input)
		_log_oar_action(&"right", right_oar_action, right_strength, right_probe_path, _right_probe, allow_input)
		_set_probe_enabled(_left_probe, allow_input and left_strength > 0.05)
		_set_probe_enabled(_right_probe, allow_input and right_strength > 0.05)
		_update_oar_node(_left_oar, left_strength if allow_input else 0.0, 1.0, delta)
		_update_oar_node(_right_oar, right_strength if allow_input else 0.0, -1.0, delta)
		if not animate_probes:
			return

	if _left_probe == null and _right_probe == null:
		return

	var forward := _get_action_strength(row_forward_action) - _get_action_strength(row_back_action)
	var turn := _get_action_strength(row_right_action) - _get_action_strength(row_left_action)
	var left_command := clampf(forward + turn, -1.0, 1.0)
	var right_command := clampf(forward - turn, -1.0, 1.0)

	if require_player_controlled_parent and not _is_parent_player_controlled():
		left_command = 0.0
		right_command = 0.0

	_update_probe(_left_probe, left_command, delta)
	_update_probe(_right_probe, right_command, delta)


func _set_probe_enabled(probe : WaterReactionProbe, enabled : bool) -> void:
	if probe != null:
		probe.enabled = enabled


func _resolve_probes() -> void:
	if _left_probe == null and not left_probe_path.is_empty():
		_left_probe = get_node_or_null(left_probe_path) as WaterReactionProbe
	if _right_probe == null and not right_probe_path.is_empty():
		_right_probe = get_node_or_null(right_probe_path) as WaterReactionProbe


func _resolve_oars() -> void:
	if _left_oar == null:
		if not left_oar_node_path.is_empty():
			_left_oar = get_node_or_null(left_oar_node_path) as Node3D
		elif _left_probe != null:
			_left_oar = _left_probe.get_parent() as Node3D
	if _right_oar == null:
		if not right_oar_node_path.is_empty():
			_right_oar = get_node_or_null(right_oar_node_path) as Node3D
		elif _right_probe != null:
			_right_oar = _right_probe.get_parent() as Node3D


func _update_probe(probe : WaterReactionProbe, command : float, delta : float) -> void:
	if probe == null:
		return
	if not _rest_positions.has(probe):
		_rest_positions[probe] = probe.position
		_phases[probe] = 0.0

	var rest_position : Vector3 = _rest_positions[probe]
	var target_position := rest_position + Vector3(0.0, recovery_lift, 0.0)
	var command_strength := absf(command)
	if command_strength > 0.05:
		var phase := float(_phases.get(probe, 0.0))
		phase = fposmod(phase + delta * stroke_frequency * command_strength, 1.0)
		_phases[probe] = phase
		var direction := 1.0 if command > 0.0 else -1.0
		var half_stroke := stroke_distance * 0.5
		if phase < power_stroke_fraction:
			var t := phase / maxf(power_stroke_fraction, 0.001)
			target_position = rest_position + Vector3(0.0, 0.0, lerpf(-half_stroke, half_stroke, t) * direction)
		else:
			var t := (phase - power_stroke_fraction) / maxf(1.0 - power_stroke_fraction, 0.001)
			target_position = rest_position + Vector3(0.0, recovery_lift, lerpf(half_stroke, -half_stroke, t) * direction)

	var weight := 1.0 if idle_smoothing <= 0.0 else 1.0 - exp(-idle_smoothing * delta)
	probe.position = probe.position.lerp(target_position, weight)


func _update_oar_node(oar : Node3D, strength : float, side_sign : float, delta : float) -> void:
	if not animate_oar_nodes or oar == null:
		return
	if not _rest_oar_bases.has(oar):
		_rest_oar_bases[oar] = oar.transform.basis

	var rest_basis : Basis = _rest_oar_bases[oar]
	var command_strength := clampf(strength, 0.0, 1.0)
	var stroke_axis := _normalized_or(oar_stroke_axis, Vector3.RIGHT)
	var stroke_angle := deg_to_rad(oar_pressed_angle_degrees) * command_strength * side_sign
	var target_basis := rest_basis * Basis(stroke_axis, stroke_angle)
	var target_transform := Transform3D(target_basis, oar.transform.origin)
	var weight := 1.0 if oar_animation_smoothing <= 0.0 else 1.0 - exp(-oar_animation_smoothing * delta)
	oar.transform = oar.transform.interpolate_with(target_transform, weight)


func _normalized_or(value : Vector3, fallback : Vector3) -> Vector3:
	if value.length_squared() <= 0.0001:
		return fallback.normalized()
	return value.normalized()


func _get_action_strength(action : StringName) -> float:
	if InputMap.has_action(action):
		return Input.get_action_strength(action)
	_log_missing_action(action)
	return 0.0


func _log_action_binding(action : StringName) -> void:
	if not debug_rowing_input:
		return
	if InputMap.has_action(action):
		print("[rowing] InputMap action ready: %s events=%s" % [String(action), InputMap.action_get_events(action).size()])
	else:
		print("[rowing] missing InputMap action: %s" % String(action))


func _log_missing_action(action : StringName) -> void:
	if not debug_rowing_input or _reported_missing_actions.has(action):
		return
	_reported_missing_actions[action] = true
	print("[rowing] missing InputMap action during physics: %s" % String(action))


func _log_oar_action(side : StringName, action : StringName, strength : float, probe_path : NodePath, probe : WaterReactionProbe, allow_input : bool) -> void:
	if not debug_rowing_input:
		return
	var pressed := strength > 0.05
	var key := "%s:%s" % [String(side), String(action)]
	var was_pressed := bool(_last_action_pressed.get(key, false))
	_last_action_pressed[key] = pressed
	if not allow_input or not pressed or was_pressed:
		return
	print(
		"[rowing] %s oar action pressed: action=%s strength=%.2f allow_input=%s probe_found=%s probe_path=%s"
		% [String(side), String(action), strength, str(allow_input), str(probe != null), String(probe_path)]
	)


func _is_parent_player_controlled() -> bool:
	var parent := get_parent()
	while parent != null:
		if _object_has_property(parent, &"player_controlled"):
			return bool(parent.get("player_controlled"))
		parent = parent.get_parent()
	return true


func _object_has_property(object : Object, property_name : StringName) -> bool:
	for property in object.get_property_list():
		if property.get("name") == String(property_name):
			return true
	return false
