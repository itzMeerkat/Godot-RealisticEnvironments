@tool
extends Node3D

@onready var sky_system := $SkySystem
@onready var water := $Water
@onready var wind_system := $WindSystem
@onready var debug_panel : OceanDebugPanel = $OceanDebugPanel
@onready var camera_rig : PlayerCameraRig = $PlayerCameraRig
@onready var compass_hud : CompassHud = $CompassLayer/CompassHud
@onready var buoy_distance_label : BuoyDistanceLabel = $Buoy/RigidBody3D/DistanceLabel

var player_boat : FloatingDebugBody
var buoyant_body : BuoyantBody

func _init() -> void:
	if Engine.is_editor_hint(): return
	if DisplayServer.window_get_vsync_mode() == DisplayServer.VSYNC_ENABLED:
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	DisplayServer.window_set_size(DisplayServer.screen_get_size() * 0.75)
	DisplayServer.window_set_position(DisplayServer.screen_get_size() * 0.25 / 2.0)

func _ready() -> void:
	if Engine.is_editor_hint():
		return
	_configure_player_boat()
	if buoy_distance_label != null:
		buoy_distance_label.set_target(player_boat)
	compass_hud.setup(player_boat, wind_system)
	debug_panel.setup(water, wind_system, sky_system, buoyant_body, player_boat)

func _process(_delta : float) -> void:
	if not Engine.is_editor_hint():
		camera_rig.enable_camera_movement = not debug_panel.is_interacting()

func _physics_process(_delta: float) -> void:
	var wind_speed:float = wind_system.get_wind_speed()
	#$OceanAudioPlayer.volume_db = lerpf(-30.0, 15.0, minf(wind_speed / 15.0, 1.0))
	#$WindAudioPlayer.volume_db = lerpf(5.0, -30.0, minf(wind_speed / 15.0, 1.0))

func _input(event: InputEvent) -> void:
	if event.is_action_pressed(&'toggle_debug_ui'):
		debug_panel.toggle_panel_visible()
	elif event.is_action_pressed(&'toggle_fullscreen'):
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN if DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_WINDOWED else DisplayServer.WINDOW_MODE_WINDOWED)
	elif event.is_action_pressed(&'ui_cancel'):
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)


func _configure_player_boat() -> void:
	player_boat = _find_player_boat()
	if player_boat == null:
		push_warning("No player-controlled FloatingDebugBody found. Falling back to the first floating body in the scene.")
		player_boat = _find_first_boat()
		if player_boat != null:
			player_boat.player_controlled = true
	if player_boat == null:
		push_warning("No FloatingDebugBody found. Camera and debug panel are not bound to a boat.")
		return

	for boat in _get_boats():
		boat.player_controlled = boat == player_boat

	buoyant_body = player_boat.get_node_or_null("BuoyantBody") as BuoyantBody

	var first_person_anchor := player_boat.get_node_or_null("CameraTargets/FirstPersonSeat") as Node3D
	var third_person_focus := player_boat.get_node_or_null("CameraTargets/ThirdPersonFocus") as Node3D
	camera_rig.set_target_paths(
		camera_rig.get_path_to(player_boat),
		camera_rig.get_path_to(first_person_anchor) if first_person_anchor != null else NodePath(""),
		camera_rig.get_path_to(third_person_focus) if third_person_focus != null else NodePath("")
	)


func _find_player_boat() -> FloatingDebugBody:
	for boat in _get_boats():
		if boat.player_controlled:
			return boat
	return null


func _find_first_boat() -> FloatingDebugBody:
	var boats := _get_boats()
	return boats[0] if not boats.is_empty() else null


func _get_boats() -> Array[FloatingDebugBody]:
	var boats : Array[FloatingDebugBody] = []
	for child in get_children():
		var boat := child as FloatingDebugBody
		if boat != null:
			boats.push_back(boat)
	return boats
