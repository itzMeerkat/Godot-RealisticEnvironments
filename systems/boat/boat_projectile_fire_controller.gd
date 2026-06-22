class_name BoatProjectileFireController
extends Node
## Demo input bridge that fires a ProjectileLauncher on the player-controlled boat.

@export var enabled := true
@export var only_player_controlled := true
@export var fire_action: StringName = &"fire_projectile"
@export var launcher_path := NodePath("../ProjectileLauncher")
@export_range(0.0, 10.0, 0.01, "or_greater") var cooldown := 0.5

var launcher: ProjectileLauncher
var _cooldown_remaining := 0.0


func _ready() -> void:
	_resolve_launcher()


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

	_resolve_launcher()
	if launcher == null:
		return

	launcher.fire()
	_cooldown_remaining = cooldown
	get_viewport().set_input_as_handled()


func _resolve_launcher() -> void:
	if not launcher_path.is_empty():
		launcher = get_node_or_null(launcher_path) as ProjectileLauncher


func _is_player_controlled_parent() -> bool:
	var node := get_parent()
	while node != null:
		var value = node.get(&"player_controlled")
		if value != null:
			return bool(value)
		node = node.get_parent()
	return true
