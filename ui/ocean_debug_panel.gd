class_name OceanDebugPanel
extends CanvasLayer

const RESOLUTIONS := [128, 256, 512, 1024]
const PANEL_SIZE := Vector2(420, 560)

var water : OceanSystem
var camera : Camera3D

var _panel : PanelContainer
var _fps_label : Label
var _camera_position_label : Label
var _mesh_quality_option : OptionButton
var _map_size_option : OptionButton
var _controls_ready := false
var _is_syncing := false


func _ready() -> void:
	_build()


func setup(ocean_system : OceanSystem, active_camera : Camera3D) -> void:
	water = ocean_system
	camera = active_camera
	if _controls_ready:
		_rebuild()


func set_panel_visible(is_visible : bool) -> void:
	visible = is_visible


func toggle_panel_visible() -> void:
	visible = not visible


func is_interacting() -> bool:
	if not visible or not _panel:
		return false

	var focused_control := get_viewport().gui_get_focus_owner()
	if focused_control and is_ancestor_of(focused_control):
		return true

	return _panel.get_global_rect().has_point(_panel.get_global_mouse_position())


func _process(_delta : float) -> void:
	if not visible or not _fps_label:
		return
	var fps := Engine.get_frames_per_second()
	_fps_label.text = "FPS: %d (%s)" % [fps, "%.2fms" % (1.0 / maxf(fps, 1.0) * 1000.0)]
	if camera and _camera_position_label:
		_camera_position_label.text = "Camera Position: %+.2v" % camera.global_position


func _build() -> void:
	_controls_ready = false
	_panel = PanelContainer.new()
	_panel.name = "Panel"
	_panel.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_panel.offset_left = 20.0
	_panel.offset_top = 20.0
	_panel.custom_minimum_size = PANEL_SIZE
	_panel.size = PANEL_SIZE
	add_child(_panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 12)
	margin.add_theme_constant_override("margin_top", 10)
	margin.add_theme_constant_override("margin_right", 12)
	margin.add_theme_constant_override("margin_bottom", 10)
	_panel.add_child(margin)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 8)
	margin.add_child(root)

	var title := Label.new()
	title.text = "OceanWaves"
	title.add_theme_font_size_override("font_size", 18)
	root.add_child(title)

	_fps_label = Label.new()
	root.add_child(_fps_label)

	var scroll := ScrollContainer.new()
	scroll.name = "Scroll"
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	root.add_child(scroll)

	var content := VBoxContainer.new()
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", 8)
	scroll.add_child(content)

	content.add_child(HSeparator.new())
	_add_ocean_controls(content)

	content.add_child(HSeparator.new())
	_add_cascade_tabs(content)

	content.add_child(HSeparator.new())
	_add_camera_controls(content)

	var hint := Label.new()
	hint.modulate = Color.WEB_GRAY
	hint.text = "Press %s-H to toggle GUI visibility\nPress %s-F to toggle fullscreen" % [_shortcut_modifier(), _shortcut_modifier()]
	content.add_child(hint)

	_controls_ready = true
	_populate_values()


func _rebuild() -> void:
	for child in get_children():
		child.queue_free()
	await get_tree().process_frame
	_build()


func _add_ocean_controls(parent : VBoxContainer) -> void:
	_map_size_option = _add_option_row(
		parent,
		"Wave Resolution",
		"The resolution of the displacement/normal maps used for each wave cascade.\nThis is also the FFT input size.",
	)
	for resolution in RESOLUTIONS:
		_map_size_option.add_item("%dx%d" % [resolution, resolution], resolution)
	_map_size_option.item_selected.connect(func(index : int) -> void:
		if _is_syncing or not water:
			return
		water.map_size = _map_size_option.get_item_id(index)
	)

	_mesh_quality_option = _add_option_row(parent, "Wave Mesh Quality", "")
	_mesh_quality_option.item_selected.connect(func(index : int) -> void:
		if _is_syncing or not water:
			return
		water.mesh_quality = _mesh_quality_option.get_item_id(index)
	)

	var update_spin := _add_float_row(
		parent,
		"Updates per Second",
		"Denotes how many times wave spectrums will be updated per second.\n(0 is uncapped)",
		0.0,
		60.0,
		1.0,
		false,
	)
	update_spin.value_changed.connect(func(value : float) -> void:
		if not _is_syncing and water:
			water.updates_per_second = value
	)

	var water_color := _add_color_row(parent, "Water Color", "")
	water_color.color_changed.connect(func(value : Color) -> void:
		if not _is_syncing and water:
			water.water_color = value
	)

	var foam_color := _add_color_row(parent, "Foam Color", "")
	foam_color.color_changed.connect(func(value : Color) -> void:
		if not _is_syncing and water:
			water.foam_color = value
	)

	update_spin.name = "UpdatesPerSecond"
	water_color.name = "WaterColor"
	foam_color.name = "FoamColor"


func _add_cascade_tabs(parent : VBoxContainer) -> void:
	var tabs := TabContainer.new()
	tabs.name = "CascadeTabs"
	tabs.custom_minimum_size = Vector2(0, 300)
	parent.add_child(tabs)

	if not water:
		return

	for i in water.parameters.size():
		var params := water.parameters[i]
		var tab_scroll := ScrollContainer.new()
		tab_scroll.name = "Cascade %d" % (i + 1)
		tab_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
		tabs.add_child(tab_scroll)

		var tab := VBoxContainer.new()
		tab.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		tab.add_theme_constant_override("separation", 6)
		tab_scroll.add_child(tab)

		_add_vector2_row(
			tab,
			"Tile Length",
			"Denotes the distance the cascade's tile should cover (in meters).",
			params.tile_length,
			func(value : Vector2) -> void: params.tile_length = value,
		)
		_add_bound_param(tab, "Displacement Scale", "", params.displacement_scale, 0.0, 2.0, 0.01, func(value : float) -> void: params.displacement_scale = value)
		_add_bound_param(tab, "Normal Scale", "", params.normal_scale, 0.0, 2.0, 0.01, func(value : float) -> void: params.normal_scale = value)
		tab.add_child(HSeparator.new())
		_add_bound_param(tab, "Wind Speed", "Denotes the average wind speed above the water (in meters per second).\nIncreasing makes waves steeper and more 'chaotic'.", params.wind_speed, 0.0001, 1000.0, 0.1, func(value : float) -> void: params.wind_speed = value, true)
		_add_bound_param(tab, "Wind Direction", "", params.wind_direction, -360.0, 360.0, 1.0, func(value : float) -> void: params.wind_direction = value)
		_add_bound_param(tab, "Fetch Length", "Denotes the distance from shoreline (in kilometers).\nIncreasing makes waves steeper, but reduces their 'choppiness'.", params.fetch_length, 0.0001, 10000.0, 1.0, func(value : float) -> void: params.fetch_length = value, true)
		_add_bound_param(tab, "Swell", "Modifies waves to clump in a more elongated, parallel manner.", params.swell, 0.0, 2.0, 0.01, func(value : float) -> void: params.swell = value)
		_add_bound_param(tab, "Spread", "Modifies how much wind and swell affect the direction of the waves.", params.spread, 0.0, 1.0, 0.01, func(value : float) -> void: params.spread = value)
		_add_bound_param(tab, "Detail", "Modifies the attenuation of high frequency waves.", params.detail, 0.0, 1.0, 0.01, func(value : float) -> void: params.detail = value)
		tab.add_child(HSeparator.new())
		_add_bound_param(tab, "Whitecap", "Modifies how steep a wave needs to be before foam can accumulate.", params.whitecap, 0.0, 2.0, 0.01, func(value : float) -> void: params.whitecap = value)
		_add_bound_param(tab, "Foam Amount", "", params.foam_amount, 0.0, 10.0, 0.01, func(value : float) -> void: params.foam_amount = value)


func _add_camera_controls(parent : VBoxContainer) -> void:
	_camera_position_label = Label.new()
	parent.add_child(_camera_position_label)

	var fov_spin := _add_float_row(parent, "Camera FOV", "", 20.0, 170.0, 1.0, false)
	fov_spin.name = "CameraFOV"
	fov_spin.value_changed.connect(func(value : float) -> void:
		if not _is_syncing and camera:
			camera.fov = value
	)


func _populate_values() -> void:
	if not water:
		return

	_is_syncing = true

	for i in _map_size_option.get_item_count():
		if _map_size_option.get_item_id(i) == water.map_size:
			_map_size_option.select(i)
			break

	_mesh_quality_option.clear()
	var mesh_quality_keys : Array = water.MeshQuality.keys()
	for mesh_quality in water.MeshQuality.size():
		_mesh_quality_option.add_item(str(mesh_quality_keys[mesh_quality]).capitalize(), mesh_quality)
		if mesh_quality == water.mesh_quality:
			_mesh_quality_option.select(_mesh_quality_option.get_item_count() - 1)

	_set_named_spin("UpdatesPerSecond", water.updates_per_second)
	_set_named_color("WaterColor", water.water_color)
	_set_named_color("FoamColor", water.foam_color)
	if camera:
		_set_named_spin("CameraFOV", camera.fov)

	_is_syncing = false


func _add_bound_param(
	parent : VBoxContainer,
	label : String,
	tooltip : String,
	value : float,
	minimum : float,
	maximum : float,
	step : float,
	callback : Callable,
	allow_greater := false,
) -> void:
	var spin := _add_float_row(parent, label, tooltip, minimum, maximum, step, allow_greater)
	spin.value = value
	spin.value_changed.connect(func(new_value : float) -> void:
		if not _is_syncing:
			callback.call(new_value)
	)


func _add_float_row(
	parent : VBoxContainer,
	label : String,
	tooltip : String,
	minimum : float,
	maximum : float,
	step : float,
	allow_greater : bool,
) -> SpinBox:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	parent.add_child(row)

	var text := Label.new()
	text.text = label
	text.tooltip_text = tooltip
	text.custom_minimum_size = Vector2(160, 0)
	row.add_child(text)

	var spin := SpinBox.new()
	spin.min_value = minimum
	spin.max_value = maximum
	spin.step = step
	spin.allow_greater = allow_greater
	spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spin.tooltip_text = tooltip
	row.add_child(spin)
	return spin


func _add_vector2_row(parent : VBoxContainer, label : String, tooltip : String, value : Vector2, callback : Callable) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	parent.add_child(row)

	var text := Label.new()
	text.text = label
	text.tooltip_text = tooltip
	text.custom_minimum_size = Vector2(160, 0)
	row.add_child(text)

	var x_spin := SpinBox.new()
	x_spin.min_value = 0.0001
	x_spin.max_value = 10000.0
	x_spin.step = 1.0
	x_spin.allow_greater = true
	x_spin.value = value.x
	x_spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(x_spin)

	var y_spin := SpinBox.new()
	y_spin.min_value = 0.0001
	y_spin.max_value = 10000.0
	y_spin.step = 1.0
	y_spin.allow_greater = true
	y_spin.value = value.y
	y_spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(y_spin)

	var emit_value := func(_new_value : float) -> void:
		if not _is_syncing:
			callback.call(Vector2(x_spin.value, y_spin.value))
	x_spin.value_changed.connect(emit_value)
	y_spin.value_changed.connect(emit_value)


func _add_color_row(parent : VBoxContainer, label : String, tooltip : String) -> ColorPickerButton:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	parent.add_child(row)

	var text := Label.new()
	text.text = label
	text.tooltip_text = tooltip
	text.custom_minimum_size = Vector2(160, 0)
	row.add_child(text)

	var picker := ColorPickerButton.new()
	picker.edit_alpha = false
	picker.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(picker)
	return picker


func _add_option_row(parent : VBoxContainer, label : String, tooltip : String) -> OptionButton:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	parent.add_child(row)

	var text := Label.new()
	text.text = label
	text.tooltip_text = tooltip
	text.custom_minimum_size = Vector2(160, 0)
	row.add_child(text)

	var option := OptionButton.new()
	option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	option.tooltip_text = tooltip
	row.add_child(option)
	return option


func _set_named_spin(node_name : StringName, value : float) -> void:
	var spin := find_child(node_name, true, false) as SpinBox
	if spin:
		spin.value = value


func _set_named_color(node_name : StringName, value : Color) -> void:
	var picker := find_child(node_name, true, false) as ColorPickerButton
	if picker:
		picker.color = value


func _shortcut_modifier() -> String:
	return "Cmd" if OS.get_name() == "macOS" else "Ctrl"
