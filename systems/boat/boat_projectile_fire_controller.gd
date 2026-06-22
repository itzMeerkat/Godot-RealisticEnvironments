class_name BoatProjectileFireController
extends Node
## Demo input bridge that fires a ProjectileLauncher on the player-controlled boat.

@export var enabled := true
@export var only_player_controlled := true
@export var fire_action: StringName = &"fire_projectile"
@export var launcher_paths: Array[NodePath] = []
@export var launcher_path := NodePath("../ProjectileLauncher")
@export var aim_controller_path: NodePath
@export_range(0.0, 10.0, 0.01, "or_greater") var cooldown := 0.5

var launchers: Array[ProjectileLauncher] = []
var aim_controller: Node
var _cooldown_remaining := 0.0


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
	if only_player_controlled and not _is_player_controlled_parent():
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
	var paths := launcher_paths
	if paths.is_empty() and not launcher_path.is_empty():
		paths = [launcher_path]

	for path in paths:
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


func _is_player_controlled_parent() -> bool:
	var node := get_parent()
	while node != null:
		var value = node.get(&"player_controlled")
		if value != null:
			return bool(value)
		node = node.get_parent()
	return true
