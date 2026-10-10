@tool
class_name FloatingBoat
extends RigidBody3D
## Root of a floating boat: player drive input, stability torques, model
## animation autoplay and a debug position trail. Buoyancy, damage, weapons and
## the hull footprint are child nodes (see the template scene).

const DEBUG_HISTORY_MAX_POINTS := 240
const DEBUG_HISTORY_MIN_DISTANCE := 0.2
const DEBUG_HISTORY_COLOR := Color(0.2, 1.0, 0.45, 1.0)

## Marks this body as controlled by the local player. Only the player's boat
## reads drive input; child weapon controllers check this property too.
@export var player_controlled := false :
	set(value):
		player_controlled = value
		_update_history_visibility()
		update_configuration_warnings()

@export_group("Drive")
## InputMap action used for forward throttle.
@export var move_forward_action: StringName = &"boat_forward"
## InputMap action used for reverse throttle.
@export var move_back_action: StringName = &"boat_back"
## InputMap action used for left yaw torque.
@export var turn_left_action: StringName = &"boat_turn_left"
## InputMap action used for right yaw torque.
@export var turn_right_action: StringName = &"boat_turn_right"
## Forward speed above which forward throttle stops adding force.
@export_range(0.0, 20.0, 0.01, "or_greater") var max_forward_speed := 5.0
## Reverse speed above which reverse throttle stops adding force.
@export_range(0.0, 20.0, 0.01, "or_greater") var max_reverse_speed := 1.8
## Forward acceleration in m/s^2 before multiplying by mass.
@export_range(0.0, 20.0, 0.01, "or_greater") var forward_acceleration := 2.4
## Reverse acceleration in m/s^2 before multiplying by mass.
@export_range(0.0, 20.0, 0.01, "or_greater") var reverse_acceleration := 1.2
## Yaw torque per kg applied at full turn input.
@export_range(0.0, 40.0, 0.01, "or_greater") var turn_torque_per_kg := 12.0
## Fraction of turn torque retained at very low speed.
@export_range(0.0, 1.0, 0.01) var low_speed_turn_factor := 0.55
## Extra side-slip damping force per kg applied along the boat's right axis.
@export_range(0.0, 20.0, 0.01, "or_greater") var extra_lateral_damping := 0.9

@export_group("Stability")
## Per-mass torque damping in local axes: X = pitch, Y = yaw, Z = roll. Zero disables it.
@export var local_angular_damping := Vector3.ZERO
## Per-mass torque spring that rotates the body's up axis back toward world up
## around its roll axis. Zero disables it.
@export_range(0.0, 1000.0, 0.01, "or_greater") var roll_righting_torque_per_kg := 0.0
## Cap for the total roll righting torque. Set 0 for uncapped.
@export_range(0.0, 10000000.0, 1.0, "or_greater") var max_roll_righting_torque := 0.0
## Roll error below this angle is ignored to avoid small corrective jitter.
@export_range(0.0, 30.0, 0.1, "degrees") var roll_righting_dead_zone_degrees := 0.0

@export_group("Model Animation")
## AnimationPlayer of the imported model. Only used when autoplay_animation is set.
@export var animation_player_path: NodePath
## Animation looped from _ready (e.g. sails). Empty plays nothing.
@export var autoplay_animation: StringName = &""

@export_group("Debug")
## Shows a world-space movement trail while player_controlled.
@export var debug_enabled := false :
	set(value):
		debug_enabled = value
		_update_history_visibility()

var _history_points := PackedVector3Array()
var _history_mesh_instance : MeshInstance3D
var _history_mesh := ImmediateMesh.new()
## False when a drive action is missing from the InputMap: the boat then ignores input.
var _drive_enabled := true


func _ready() -> void:
	if Engine.is_editor_hint():
		set_physics_process(false)
		return
	_create_history_node()
	for action in [move_forward_action, move_back_action, turn_left_action, turn_right_action]:
		if not InputMap.has_action(action):
			push_error("FloatingBoat %s: InputMap has no action \"%s\" (enable the Boat Template plugin, add it in Project Settings > Input Map, or set the *_action exports); the boat ignores drive input." % [get_path(), action])
			_drive_enabled = false
	if autoplay_animation != &"":
		_play_model_animation()


func _physics_process(_delta: float) -> void:
	if player_controlled and _drive_enabled:
		_apply_drive()
	_apply_roll_righting_torque()
	_apply_local_angular_damping()
	if player_controlled and debug_enabled:
		_record_history_point()


func _get_configuration_warnings() -> PackedStringArray:
	var warnings := PackedStringArray()
	if player_controlled:
		var missing := PackedStringArray()
		for action in [move_forward_action, move_back_action, turn_left_action, turn_right_action]:
			if not ProjectSettings.has_setting("input/" + action):
				missing.push_back(action)
		if not missing.is_empty():
			warnings.push_back("The Input Map lacks %s: the boat ignores drive input. Enable the Boat Template plugin (it adds them), add them in Project Settings > Input Map, or set the *_action exports." % ", ".join(missing))
	if autoplay_animation != &"":
		var animation_player := get_node_or_null(animation_player_path) as AnimationPlayer
		if animation_player == null:
			warnings.push_back("autoplay_animation is set but animation_player_path does not point to an AnimationPlayer.")
		elif not animation_player.has_animation(autoplay_animation):
			warnings.push_back("The AnimationPlayer has no animation \"%s\" (autoplay_animation)." % autoplay_animation)
	return warnings


func clear_position_history() -> void:
	_history_points.clear()
	_rebuild_history_mesh()


func _apply_drive() -> void:
	var throttle := Input.get_action_strength(move_forward_action) - Input.get_action_strength(move_back_action)
	var turn_input := Input.get_action_strength(turn_left_action) - Input.get_action_strength(turn_right_action)
	var forward := -global_transform.basis.z
	forward.y = 0.0
	forward = forward.normalized() if forward.length_squared() > 0.0001 else Vector3.FORWARD
	var right := global_transform.basis.x
	right.y = 0.0
	right = right.normalized() if right.length_squared() > 0.0001 else Vector3.RIGHT

	var horizontal_velocity := Vector3(linear_velocity.x, 0.0, linear_velocity.z)
	var forward_speed := horizontal_velocity.dot(forward)
	if absf(throttle) > 0.001:
		var acceleration := forward_acceleration if throttle > 0.0 else reverse_acceleration
		var speed_limit := max_forward_speed if throttle > 0.0 else max_reverse_speed
		if forward_speed * signf(throttle) < speed_limit:
			apply_central_force(forward * throttle * acceleration * mass)
	if absf(turn_input) > 0.001:
		var speed_factor := lerpf(low_speed_turn_factor, 1.0, clampf(absf(forward_speed) / maxf(max_forward_speed, 0.001), 0.0, 1.0))
		apply_torque(Vector3.UP * turn_input * turn_torque_per_kg * mass * speed_factor)
	var side_speed := horizontal_velocity.dot(right)
	if extra_lateral_damping > 0.0 and absf(side_speed) > 0.001:
		apply_central_force(-right * side_speed * extra_lateral_damping * mass)


func _apply_local_angular_damping() -> void:
	if local_angular_damping == Vector3.ZERO or angular_velocity.length_squared() <= 0.0:
		return
	var body_basis := global_transform.basis.orthonormalized()
	var local_angular_velocity := body_basis.inverse() * angular_velocity
	apply_torque(body_basis * (-local_angular_velocity * local_angular_damping * mass))


func _apply_roll_righting_torque() -> void:
	if roll_righting_torque_per_kg <= 0.0:
		return
	var body_basis := global_transform.basis.orthonormalized()
	var roll_axis := body_basis.z
	var target_up := Vector3.UP - roll_axis * Vector3.UP.dot(roll_axis)
	# Bow pointing straight up or down: roll is undefined.
	if target_up.length_squared() <= 0.0001:
		return
	var roll_error := body_basis.y.signed_angle_to(target_up.normalized(), roll_axis)
	var dead_zone := deg_to_rad(roll_righting_dead_zone_degrees)
	if absf(roll_error) <= dead_zone:
		return
	roll_error -= signf(roll_error) * dead_zone
	var torque := roll_axis * roll_error * roll_righting_torque_per_kg * mass
	if max_roll_righting_torque > 0.0 and torque.length_squared() > max_roll_righting_torque * max_roll_righting_torque:
		torque = torque.normalized() * max_roll_righting_torque
	apply_torque(torque)


func _play_model_animation() -> void:
	var animation_player := get_node_or_null(animation_player_path) as AnimationPlayer
	if animation_player == null:
		push_error("FloatingBoat %s: animation_player_path does not point to an AnimationPlayer." % get_path())
		return
	var animation := animation_player.get_animation(autoplay_animation)
	if animation == null:
		push_error("FloatingBoat %s: the model has no animation '%s'." % [get_path(), autoplay_animation])
		return
	animation.loop_mode = Animation.LOOP_LINEAR
	animation_player.play(autoplay_animation)


func _record_history_point() -> void:
	if not _history_points.is_empty() and _history_points[_history_points.size() - 1].distance_to(global_position) < DEBUG_HISTORY_MIN_DISTANCE:
		return
	_history_points.push_back(global_position)
	if _history_points.size() > DEBUG_HISTORY_MAX_POINTS:
		_history_points.remove_at(0)
	_rebuild_history_mesh()


func _create_history_node() -> void:
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.no_depth_test = true
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.albedo_color = DEBUG_HISTORY_COLOR
	_history_mesh_instance = MeshInstance3D.new()
	_history_mesh_instance.name = "PositionHistory"
	_history_mesh_instance.top_level = true
	_history_mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_history_mesh_instance.extra_cull_margin = 10000.0
	_history_mesh_instance.mesh = _history_mesh
	_history_mesh_instance.material_override = material
	add_child(_history_mesh_instance, false, INTERNAL_MODE_BACK)
	_history_mesh_instance.global_transform = Transform3D.IDENTITY
	_update_history_visibility()


func _update_history_visibility() -> void:
	if _history_mesh_instance != null:
		_history_mesh_instance.visible = player_controlled and debug_enabled


func _rebuild_history_mesh() -> void:
	_history_mesh.clear_surfaces()
	if _history_points.size() < 2:
		return
	_history_mesh.surface_begin(Mesh.PRIMITIVE_LINE_STRIP)
	for point in _history_points:
		_history_mesh.surface_add_vertex(point)
	_history_mesh.surface_end()
