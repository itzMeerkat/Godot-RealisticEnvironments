@tool
extends Node3D

@onready var viewport : Variant = Engine.get_singleton(&'EditorInterface').get_editor_viewport_3d(0) if Engine.is_editor_hint() else get_viewport()
@onready var camera : Variant = viewport.get_camera_3d()
@onready var sky_system := $SkySystem
@onready var water := $Water
@onready var wind_system := $WindSystem
@onready var buoyant_body : BuoyantBody = $FloatingBox/BuoyantBody
@onready var debug_panel : OceanDebugPanel = $OceanDebugPanel

func _init() -> void:
	if Engine.is_editor_hint(): return
	if DisplayServer.window_get_vsync_mode() == DisplayServer.VSYNC_ENABLED:
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	DisplayServer.window_set_size(DisplayServer.screen_get_size() * 0.75)
	DisplayServer.window_set_position(DisplayServer.screen_get_size() * 0.25 / 2.0)

func _ready() -> void:
	if Engine.is_editor_hint(): return
	debug_panel.setup(water, wind_system, sky_system, buoyant_body)

func _process(_delta : float) -> void:
	if not Engine.is_editor_hint():
		camera.enable_camera_movement = not debug_panel.is_interacting()

func _physics_process(_delta: float) -> void:
	var wind_speed:float = wind_system.get_wind_speed()
	$OceanAudioPlayer.volume_db = lerpf(-30.0, 15.0, minf(wind_speed / 15.0, 1.0))
	$WindAudioPlayer.volume_db = lerpf(5.0, -30.0, minf(wind_speed / 15.0, 1.0))

func _input(event: InputEvent) -> void:
	if event.is_action_pressed(&'toggle_debug_ui'):
		debug_panel.toggle_panel_visible()
	elif event.is_action_pressed(&'toggle_fullscreen'):
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN if DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_WINDOWED else DisplayServer.WINDOW_MODE_WINDOWED)
	elif event.is_action_pressed(&'ui_cancel'):
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
