class_name OceanDebugPanel
extends CanvasLayer

const RESOLUTIONS := [128, 256, 512, 1024]
const PANEL_SIZE := Vector2(420, 560)

var water : OceanSystem
var wind_source : Node
var sky_system : Node

var _panel : PanelContainer
var _fps_label : Label
var _map_size_option : OptionButton
var _controls_ready := false
var _is_syncing := false


func _ready() -> void:
	_build()


func setup(ocean_system : OceanSystem, active_wind_source : Node = null, active_sky_system : Node = null) -> void:
	water = ocean_system
	wind_source = active_wind_source if active_wind_source != null else water.get_wind_source()
	sky_system = active_sky_system
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

	if wind_source:
		content.add_child(HSeparator.new())
		_add_wind_controls(content)

	if sky_system:
		content.add_child(HSeparator.new())
		_add_sky_controls(content)

	content.add_child(HSeparator.new())
	_add_ocean_controls(content)

	content.add_child(HSeparator.new())
	_add_cascade_tabs(content)

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

	var foam_intensity := _add_float_row(parent, "Foam Intensity", "Scales the visible whitecap amount in the water shader.", 0.0, 4.0, 0.01, true)
	foam_intensity.value_changed.connect(func(value : float) -> void:
		if not _is_syncing and water:
			water.foam_intensity = value
	)

	var foam_threshold := _add_float_row(parent, "Foam Threshold", "Higher values keep only stronger crest foam.", 0.0, 2.0, 0.01, false)
	foam_threshold.value_changed.connect(func(value : float) -> void:
		if not _is_syncing and water:
			water.foam_threshold = value
	)

	var foam_softness := _add_float_row(parent, "Foam Softness", "Lower values make foam edges sharper.", 0.01, 2.0, 0.01, false)
	foam_softness.value_changed.connect(func(value : float) -> void:
		if not _is_syncing and water:
			water.foam_softness = value
	)

	update_spin.name = "UpdatesPerSecond"
	water_color.name = "WaterColor"
	foam_color.name = "FoamColor"
	foam_intensity.name = "FoamIntensity"
	foam_threshold.name = "FoamThreshold"
	foam_softness.name = "FoamSoftness"


func _add_wind_controls(parent : VBoxContainer) -> void:
	var title := Label.new()
	title.text = "Wind"
	title.add_theme_font_size_override("font_size", 15)
	parent.add_child(title)

	var use_external := _add_check_row(parent, "Use External Wind", "When enabled, ocean cascades derive wind speed and direction from the assigned wind source.")
	use_external.name = "UseExternalWind"
	use_external.toggled.connect(func(is_pressed : bool) -> void:
		if _is_syncing or not water:
			return
		water.use_external_wind = is_pressed
		_rebuild()
	)

	var speed := _add_float_row(parent, "External Wind Speed", "Wind speed read from the assigned wind source.", 0.0, 1000.0, 0.1, true)
	speed.name = "ExternalWindSpeed"
	speed.value_changed.connect(func(value : float) -> void:
		if not _is_syncing and wind_source:
			_set_wind_source_speed(value)
	)

	var direction := _add_float_row(parent, "External Wind Direction", "Wind direction in degrees read from the assigned wind source.", -360.0, 360.0, 1.0, false)
	direction.name = "ExternalWindDirection"
	direction.value_changed.connect(func(value : float) -> void:
		if not _is_syncing and wind_source:
			_set_wind_source_direction(value)
	)


func _add_sky_controls(parent : VBoxContainer) -> void:
	var title := Label.new()
	title.text = "Sky"
	title.add_theme_font_size_override("font_size", 15)
	parent.add_child(title)

	var cycle_enabled := _add_check_row(parent, "Cycle Enabled", "When enabled, time of day advances automatically.")
	cycle_enabled.name = "SkyCycleEnabled"
	cycle_enabled.toggled.connect(func(is_pressed : bool) -> void:
		if not _is_syncing and sky_system:
			sky_system.cycle_enabled = is_pressed
	)

	var time_of_day := _add_float_row(parent, "Time of Day", "Normalized day time: 0 midnight, 0.25 sunrise, 0.5 noon, 0.75 sunset.", 0.0, 1.0, 0.001, false)
	time_of_day.name = "SkyTimeOfDay"
	time_of_day.value_changed.connect(func(value : float) -> void:
		if not _is_syncing and sky_system:
			sky_system.time_of_day = value
	)

	var cycle_duration := _add_float_row(parent, "Cycle Duration", "Seconds for a full day-night cycle.", 1.0, 86400.0, 1.0, true)
	cycle_duration.name = "SkyCycleDuration"
	cycle_duration.value_changed.connect(func(value : float) -> void:
		if not _is_syncing and sky_system:
			sky_system.cycle_duration_seconds = value
	)

	var sun_energy := _add_float_row(parent, "Sun Energy", "Multiplier applied to the sky profile's sun light curve.", 0.0, 8.0, 0.01, false)
	sun_energy.name = "SkySunEnergy"
	sun_energy.value_changed.connect(func(value : float) -> void:
		if not _is_syncing and sky_system:
			sky_system.sun_energy_multiplier = value
	)

	var moon_energy := _add_float_row(parent, "Moon Energy", "Multiplier applied to the sky profile's moon light curve.", 0.0, 8.0, 0.01, false)
	moon_energy.name = "SkyMoonEnergy"
	moon_energy.value_changed.connect(func(value : float) -> void:
		if not _is_syncing and sky_system:
			sky_system.moon_energy_multiplier = value
	)

	var star_brightness := _add_float_row(parent, "Star Brightness", "Multiplier applied to visible stars at night.", 0.0, 8.0, 0.01, false)
	star_brightness.name = "SkyStarBrightness"
	star_brightness.value_changed.connect(func(value : float) -> void:
		if not _is_syncing and sky_system:
			sky_system.star_brightness = value
	)


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
		if water.should_use_external_wind():
			_add_bound_param(tab, "Wind Speed Multiplier", "Scales the external wind source speed for this cascade.", params.wind_speed_multiplier, 0.0, 10.0, 0.01, func(value : float) -> void: params.wind_speed_multiplier = value, true)
			_add_bound_param(tab, "Wind Direction Offset", "Adds a per-cascade direction offset to the external wind source direction.", params.wind_direction_offset, -360.0, 360.0, 1.0, func(value : float) -> void: params.wind_direction_offset = value)
		else:
			_add_bound_param(tab, "Wind Speed", "Denotes the average wind speed above the water (in meters per second).\nIncreasing makes waves steeper and more 'chaotic'.", params.wind_speed, 0.0001, 1000.0, 0.1, func(value : float) -> void: params.wind_speed = value, true)
			_add_bound_param(tab, "Wind Direction", "", params.wind_direction, -360.0, 360.0, 1.0, func(value : float) -> void: params.wind_direction = value)
		_add_bound_param(tab, "Fetch Length", "Denotes the distance from shoreline (in kilometers).\nIncreasing makes waves steeper, but reduces their 'choppiness'.", params.fetch_length, 0.0001, 10000.0, 1.0, func(value : float) -> void: params.fetch_length = value, true)
		_add_bound_param(tab, "Swell", "Modifies waves to clump in a more elongated, parallel manner.", params.swell, 0.0, 2.0, 0.01, func(value : float) -> void: params.swell = value)
		_add_bound_param(tab, "Spread", "Modifies how much wind and swell affect the direction of the waves.", params.spread, 0.0, 1.0, 0.01, func(value : float) -> void: params.spread = value)
		_add_bound_param(tab, "Detail", "Modifies the attenuation of high frequency waves.", params.detail, 0.0, 1.0, 0.01, func(value : float) -> void: params.detail = value)
		tab.add_child(HSeparator.new())
		_add_bound_param(tab, "Whitecap", "Modifies how steep a wave needs to be before foam can accumulate.", params.whitecap, 0.0, 2.0, 0.01, func(value : float) -> void: params.whitecap = value)
		_add_bound_param(tab, "Foam Amount", "", params.foam_amount, 0.0, 10.0, 0.01, func(value : float) -> void: params.foam_amount = value)


func _populate_values() -> void:
	if not water:
		return

	_is_syncing = true

	for i in _map_size_option.get_item_count():
		if _map_size_option.get_item_id(i) == water.map_size:
			_map_size_option.select(i)
			break

	_set_named_spin("UpdatesPerSecond", water.updates_per_second)
	_set_named_color("WaterColor", water.water_color)
	_set_named_color("FoamColor", water.foam_color)
	_set_named_spin("FoamIntensity", water.foam_intensity)
	_set_named_spin("FoamThreshold", water.foam_threshold)
	_set_named_spin("FoamSoftness", water.foam_softness)
	_set_named_check("UseExternalWind", water.use_external_wind)
	if wind_source:
		_set_named_spin("ExternalWindSpeed", _get_wind_source_speed())
		_set_named_spin("ExternalWindDirection", _get_wind_source_direction())
	if sky_system:
		_set_named_check("SkyCycleEnabled", sky_system.cycle_enabled)
		_set_named_spin("SkyTimeOfDay", sky_system.time_of_day)
		_set_named_spin("SkyCycleDuration", sky_system.cycle_duration_seconds)
		_set_named_spin("SkySunEnergy", sky_system.sun_energy_multiplier)
		_set_named_spin("SkyMoonEnergy", sky_system.moon_energy_multiplier)
		_set_named_spin("SkyStarBrightness", sky_system.star_brightness)

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


func _add_check_row(parent : VBoxContainer, label : String, tooltip : String) -> CheckBox:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	parent.add_child(row)

	var text := Label.new()
	text.text = label
	text.tooltip_text = tooltip
	text.custom_minimum_size = Vector2(160, 0)
	row.add_child(text)

	var check := CheckBox.new()
	check.tooltip_text = tooltip
	check.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(check)
	return check


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


func _set_named_check(node_name : StringName, value : bool) -> void:
	var check := find_child(node_name, true, false) as CheckBox
	if check:
		check.button_pressed = value


func _get_wind_source_speed() -> float:
	if wind_source == null:
		return 0.0
	if wind_source.has_method(&'get_wind_speed'):
		return float(wind_source.call(&'get_wind_speed'))
	var value = wind_source.get(&'wind_speed')
	return 0.0 if value == null else float(value)


func _get_wind_source_direction() -> float:
	if wind_source == null:
		return 0.0
	if wind_source.has_method(&'get_wind_direction_degrees'):
		return float(wind_source.call(&'get_wind_direction_degrees'))
	var value = wind_source.get(&'wind_direction')
	return 0.0 if value == null else float(value)


func _set_wind_source_speed(value : float) -> void:
	if wind_source.get(&'wind_speed') != null:
		wind_source.set(&'wind_speed', value)


func _set_wind_source_direction(value : float) -> void:
	if wind_source.get(&'wind_direction') != null:
		wind_source.set(&'wind_direction', value)


func _shortcut_modifier() -> String:
	return "Cmd" if OS.get_name() == "macOS" else "Ctrl"
