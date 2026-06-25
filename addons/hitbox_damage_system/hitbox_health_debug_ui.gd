class_name HitboxHealthDebugUI
extends CanvasLayer
## Lightweight debug UI that mirrors HitboxHealthManager group health.

const DEBUG_TITLE := "Hitbox Health"
const DEBUG_SCREEN_POSITION := Vector2(24.0, 88.0)
const DEBUG_PANEL_SIZE := Vector2(260.0, 0.0)
const DEBUG_REFRESH_INTERVAL := 0.15

## Shows the hitbox health debug panel.
@export var debug_enabled := true :
	set(value):
		debug_enabled = value
		_update_visibility()
## Optional manager path. Leave empty to find the nearest compatible manager.
@export var hitbox_manager_path: NodePath

var _manager: Node
var _panel: PanelContainer
var _content: VBoxContainer
var _title_label: Label
var _bars := {}
var _labels := {}
var _refresh_timer := 0.0


func _ready() -> void:
	_build_ui()
	_resolve_manager()
	_connect_manager_signals()
	_rebuild_rows()
	_refresh_values()
	_update_visibility()


func _process(delta: float) -> void:
	if not debug_enabled:
		return
	_refresh_timer -= delta
	if _refresh_timer > 0.0:
		return
	_refresh_timer = DEBUG_REFRESH_INTERVAL
	if _manager == null or not is_instance_valid(_manager):
		_resolve_manager()
		_connect_manager_signals()
		_rebuild_rows()
	_refresh_values()


func _build_ui() -> void:
	if _panel != null:
		return
	_panel = PanelContainer.new()
	_panel.name = "HitboxHealthPanel"
	_panel.offset_left = DEBUG_SCREEN_POSITION.x
	_panel.offset_top = DEBUG_SCREEN_POSITION.y
	_panel.offset_right = DEBUG_SCREEN_POSITION.x + DEBUG_PANEL_SIZE.x
	_panel.offset_bottom = DEBUG_SCREEN_POSITION.y + maxf(DEBUG_PANEL_SIZE.y, 1.0)
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_panel)

	_content = VBoxContainer.new()
	_content.name = "Content"
	_content.add_theme_constant_override("separation", 6)
	_panel.add_child(_content)

	_title_label = Label.new()
	_title_label.text = DEBUG_TITLE
	_content.add_child(_title_label)


func _rebuild_rows() -> void:
	if _content == null:
		return
	var groups := _get_display_groups()
	for child in _content.get_children():
		if child != _title_label:
			child.queue_free()
	_bars.clear()
	_labels.clear()
	for group in groups:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		_content.add_child(row)

		var label := Label.new()
		label.custom_minimum_size = Vector2(56.0, 0.0)
		label.text = String(group)
		row.add_child(label)

		var bar := ProgressBar.new()
		bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		bar.min_value = 0.0
		bar.max_value = 1.0
		bar.value = 1.0
		bar.show_percentage = false
		row.add_child(bar)

		var value_label := Label.new()
		value_label.custom_minimum_size = Vector2(78.0, 0.0)
		value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		row.add_child(value_label)

		_bars[group] = bar
		_labels[group] = value_label


func _refresh_values() -> void:
	if _manager == null or not is_instance_valid(_manager):
		return
	for group in _bars.keys():
		var max_health := _get_group_max_health(group)
		var health := _get_group_health(group)
		var bar := _bars[group] as ProgressBar
		if bar != null:
			bar.max_value = maxf(max_health, 0.001)
			bar.value = clampf(health, 0.0, bar.max_value)
		var label := _labels[group] as Label
		if label != null:
			label.text = "%d / %d" % [roundi(health), roundi(max_health)]


func _get_display_groups() -> Array[StringName]:
	var groups: Array[StringName] = []
	if _manager != null:
		var health_config = _manager.get(&"group_max_health")
		if health_config is Dictionary:
			for key in health_config.keys():
				groups.push_back(StringName(str(key)))
	if groups.is_empty():
		groups = [&"default"]
	return groups


func _get_group_health(group: StringName) -> float:
	if _manager != null and _manager.has_method(&"get_group_health"):
		return float(_manager.call(&"get_group_health", group))
	return 0.0


func _get_group_max_health(group: StringName) -> float:
	if _manager != null and _manager.has_method(&"get_group_max_health"):
		return float(_manager.call(&"get_group_max_health", group))
	return 1.0


func _resolve_manager() -> void:
	if not hitbox_manager_path.is_empty():
		_manager = get_node_or_null(hitbox_manager_path)
		if _manager != null:
			return
	_manager = _find_manager_nearby()


func _find_manager_nearby() -> Node:
	var parent := get_parent()
	if parent != null:
		var manager := _find_manager_descendant(parent)
		if manager != null:
			return manager
	return get_tree().get_first_node_in_group(&"hitbox_health_manager") if is_inside_tree() else null


func _find_manager_descendant(root: Node) -> Node:
	if root.has_method(&"handle_projectile_hit") and root.has_method(&"get_group_health"):
		return root
	for child in root.get_children():
		var child_node := child as Node
		if child_node == null or child_node == self:
			continue
		var manager := _find_manager_descendant(child_node)
		if manager != null:
			return manager
	return null


func _connect_manager_signals() -> void:
	if _manager == null or not is_instance_valid(_manager):
		return
	var changed_callable := Callable(self, "_on_group_health_changed")
	if _manager.has_signal(&"group_health_changed") and not _manager.is_connected(&"group_health_changed", changed_callable):
		_manager.connect(&"group_health_changed", changed_callable)
	var destroyed_callable := Callable(self, "_on_group_destroyed")
	if _manager.has_signal(&"group_destroyed") and not _manager.is_connected(&"group_destroyed", destroyed_callable):
		_manager.connect(&"group_destroyed", destroyed_callable)


func _on_group_health_changed(_group: StringName, _health: float, _max_health: float, _hit_data: Dictionary) -> void:
	_refresh_values()


func _on_group_destroyed(_group: StringName, _hit_data: Dictionary) -> void:
	_refresh_values()


func _update_visibility() -> void:
	if _panel != null:
		_panel.visible = debug_enabled
