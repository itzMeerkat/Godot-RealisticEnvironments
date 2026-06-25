class_name FloatingBoatAnimationAutoplay
extends Node

## AnimationPlayer that owns the looping boat animation.
@export var animation_player_path := NodePath("../Sketchfab_Scene/AnimationPlayer")
## Animation name to set looping and play on _ready().
@export var animation_name := "Sail"


func _ready() -> void:
	var animation_player := get_node_or_null(animation_player_path) as AnimationPlayer
	if animation_player == null:
		push_warning("Boat animation autoplay could not find AnimationPlayer: %s" % str(animation_player_path))
		return

	var animation := animation_player.get_animation(animation_name)
	if animation == null:
		push_warning("Boat animation autoplay could not find animation: %s" % animation_name)
		return

	animation.loop_mode = Animation.LOOP_LINEAR
	animation_player.play(animation_name)
