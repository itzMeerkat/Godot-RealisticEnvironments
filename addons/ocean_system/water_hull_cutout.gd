@tool
class_name WaterHullCutout
extends Node3D
## Visual-only water mask that hides the ocean surface under a boat hull.

@export var enabled := true
@export var half_extents := Vector2(4.2, 12.8)
@export_range(0.0, 4.0, 0.01, "or_greater") var feather := 0.75
@export_range(0.0, 1.0, 0.01) var foam_amount := 0.85


func _enter_tree() -> void:
	add_to_group(&"water_hull_cutout")


func _exit_tree() -> void:
	remove_from_group(&"water_hull_cutout")
