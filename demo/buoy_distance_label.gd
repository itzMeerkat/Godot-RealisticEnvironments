class_name BuoyDistanceLabel
extends Label3D

@export var target_path : NodePath :
	set(value):
		target_path = value
		_target = null

@export var use_horizontal_distance := true
@export var distance_format := "%.1f m"

var _target : Node3D


func _ready() -> void:
	_resolve_target()
	_update_text()


func _process(_delta : float) -> void:
	_update_text()


func set_target(target : Node3D) -> void:
	_target = target
	if is_inside_tree() and target != null:
		target_path = get_path_to(target)
	elif target == null:
		target_path = NodePath("")
	_update_text()


func _resolve_target() -> void:
	if _target != null or target_path.is_empty():
		return
	_target = get_node_or_null(target_path) as Node3D


func _update_text() -> void:
	_resolve_target()
	if _target == null:
		text = "-- m"
		return

	var source := get_parent() as Node3D
	if source == null:
		text = "-- m"
		return

	var distance := 0.0
	if use_horizontal_distance:
		var source_position := Vector2(source.global_position.x, source.global_position.z)
		var target_position := Vector2(_target.global_position.x, _target.global_position.z)
		distance = source_position.distance_to(target_position)
	else:
		distance = source.global_position.distance_to(_target.global_position)

	text = distance_format % distance
