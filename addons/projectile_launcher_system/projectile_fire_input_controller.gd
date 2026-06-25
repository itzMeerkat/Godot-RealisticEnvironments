class_name ProjectileFireInputController
extends Node
## Input bridge that fires one or more ProjectileLauncher nodes.

## Enables this input bridge.
@export var enabled := true
## When enabled, input is ignored unless an ancestor exposes controlled_property as true.
@export var require_controlled_owner := true
## Ancestor boolean property used to decide whether this controller may fire.
@export var controlled_property: StringName = &"player_controlled"
## InputMap action that triggers all configured launchers.
@export var fire_action: StringName = &"fire_projectile"
## ProjectileLaunchers fired together when fire_action is pressed.
@export var launcher_paths: Array[NodePath] = []
## Optional aim controller that supplies solved fire directions per launcher.
@export var aim_controller_path: NodePath
## Minimum seconds between accepted fire inputs.
@export_range(0.0, 10.0, 0.01, "or_greater") var cooldown := 0.5

var launchers: Array[ProjectileLauncher] = []
var aim_controller: Node
var _cooldown_remaining := 0.0


func _enter_tree() -> void:
	add_to_group(&"projectile_fire_input_controller")


func _exit_tree() -> void:
	remove_from_group(&"projectile_fire_input_controller")


func _ready() -> void:
	_resolve_launchers()
	_resolve_aim_controller()


func _process(delta: float) -> void:
	if _cooldown_remaining > 0.0:
		_cooldown_remaining = maxf(_cooldown_remaining - delta, 0.0)


func _unhandled_input(event: InputEvent) -> void:
	if not enabled:
		return
	if _cooldown_remaining > 0.0:
		return
	if not event.is_action_pressed(fire_action):
		return
	if require_controlled_owner and not _is_controlled_owner():
		return

	_resolve_launchers()
	_resolve_aim_controller()
	if launchers.is_empty():
		return

	for launcher in launchers:
		launcher.fire(_get_fire_direction(launcher))
	_cooldown_remaining = cooldown
	get_viewport().set_input_as_handled()


func _resolve_launchers() -> void:
	launchers.clear()
	for path in launcher_paths:
		var launcher := get_node_or_null(path) as ProjectileLauncher
		if launcher != null and not launchers.has(launcher):
			launchers.push_back(launcher)


func _resolve_aim_controller() -> void:
	if not aim_controller_path.is_empty():
		aim_controller = get_node_or_null(aim_controller_path)


func _get_fire_direction(launcher: ProjectileLauncher) -> Vector3:
	if aim_controller != null and aim_controller.has_method(&"get_launch_direction_for_launcher"):
		var direction: Vector3 = aim_controller.call(&"get_launch_direction_for_launcher", launcher)
		if direction.length_squared() > 0.0001:
			return direction.normalized()
	return Vector3.ZERO


func _is_controlled_owner() -> bool:
	if controlled_property == &"":
		return true
	var node := get_parent()
	while node != null:
		var value = node.get(controlled_property)
		if value != null:
			return bool(value)
		node = node.get_parent()
	return true
