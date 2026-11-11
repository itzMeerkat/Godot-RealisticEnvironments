@tool
class_name GREFloatingBoat
extends RigidBody3D
## Root of a floating boat: player drive input, model animation autoplay and a
## debug position trail. Buoyancy, damage and weapons are child nodes (see the
## template scene).
##
## The propeller and rudder act at propulsion_position, so the bow lifts as the boat
## speeds up and the boat heels and slides into turns. Both fade out as that point
## leaves the water.

const DEBUG_HISTORY_MAX_POINTS := 240
const DEBUG_HISTORY_MIN_DISTANCE := 0.2
const DEBUG_HISTORY_COLOR := Color(0.2, 1.0, 0.45, 1.0)
## Depth (m) of propulsion_position under the surface at which thrust and rudder reach
## full strength; they fade to nothing at the surface.
const _FULL_DRIVE_DEPTH := 0.1
## Below this distance (m) between the rudder and the centre of mass along the hull,
## turning is a plain torque.
const _MIN_RUDDER_ARM := 0.1
## Thrust fades out over this share of the speed limit below it, so the boat settles
## at the limit with thrust balancing drag instead of switching on and off.
const _SPEED_LIMIT_SOFTNESS := 0.1

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
## Yaw acceleration at full rudder and max_forward_speed, whatever the boat's mass
## and inertia. The water's sideways drag (GREBuoyantBody) holds the turn rate it
## settles at.
@export_range(0.0, 180.0, 0.1, "or_greater", "suffix:°/s²") var turn_acceleration := 40.0
## Share of the rudder's effect at rest (the propeller's wash); full at
## max_forward_speed.
@export_range(0.0, 1.0, 0.01) var low_speed_turn_factor := 0.55
## Where the propeller pushes and the rudder pushes sideways, in the boat's space:
## at the stern (+Z), below the waterline.
@export var propulsion_position := Vector3(0.0, -0.4, 2.3)
## The GREBuoyantBody floating this boat: thrust and rudder fade out as
## propulsion_position leaves the water. Empty: they always work.
@export var buoyancy_path : NodePath :
	set(value):
		buoyancy_path = value
		update_configuration_warnings()

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
## Resolved buoyancy_path (null when empty).
var _buoyancy : GREBuoyantBody


func _ready() -> void:
	if Engine.is_editor_hint():
		set_physics_process(false)
		return
	_create_history_node()
	if not buoyancy_path.is_empty():
		var buoyancy := get_node_or_null(buoyancy_path)
		if buoyancy is GREBuoyantBody:
			_buoyancy = buoyancy
		else:
			push_error("GREFloatingBoat %s: buoyancy_path does not point to a GREBuoyantBody; thrust and rudder ignore the water." % get_path())
	for action in [move_forward_action, move_back_action, turn_left_action, turn_right_action]:
		if not InputMap.has_action(action):
			push_error("GREFloatingBoat %s: InputMap has no action \"%s\" (enable the Boat Template plugin, add it in Project Settings > Input Map, or set the *_action exports); the boat ignores drive input." % [get_path(), action])
			_drive_enabled = false
	if autoplay_animation != &"":
		_play_model_animation()


func _physics_process(_delta: float) -> void:
	if player_controlled and _drive_enabled:
		_apply_drive()
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
	if not buoyancy_path.is_empty() and not get_node_or_null(buoyancy_path) is GREBuoyantBody:
		warnings.push_back("buoyancy_path does not point to a GREBuoyantBody: thrust and rudder ignore the water.")
	if autoplay_animation != &"":
		var animation_player := get_node_or_null(animation_player_path) as AnimationPlayer
		if animation_player == null:
			warnings.push_back("autoplay_animation is set but animation_player_path does not point to an AnimationPlayer.")
		elif not animation_player.has_animation(autoplay_animation):
			warnings.push_back("The AnimationPlayer has no animation \"%s\" (autoplay_animation)." % autoplay_animation)
	return warnings


## Clears the debug position trail.
func clear_position_history() -> void:
	_history_points.clear()
	_rebuild_history_mesh()


func _apply_drive() -> void:
	var throttle := Input.get_action_strength(move_forward_action) - Input.get_action_strength(move_back_action)
	var turn_input := Input.get_action_strength(turn_left_action) - Input.get_action_strength(turn_right_action)
	# Offset of the propeller from the body's origin, in world orientation (as apply_force() takes it).
	var propulsion_offset := global_transform.basis * propulsion_position
	var immersion := 1.0
	if _buoyancy != null:
		immersion = clampf(_buoyancy.get_point_depth(global_position + propulsion_offset) / _FULL_DRIVE_DEPTH, 0.0, 1.0)
	if immersion <= 0.0:
		return
	var hull_forward := -global_transform.basis.z.normalized()
	var forward := Vector3(hull_forward.x, 0.0, hull_forward.z)
	forward = forward.normalized() if forward.length_squared() > 0.0001 else Vector3.FORWARD
	var horizontal_velocity := Vector3(linear_velocity.x, 0.0, linear_velocity.z)
	var forward_speed := horizontal_velocity.dot(forward)
	if absf(throttle) > 0.001:
		var acceleration := forward_acceleration if throttle > 0.0 else reverse_acceleration
		var speed_limit := max_forward_speed if throttle > 0.0 else max_reverse_speed
		var headroom := clampf((speed_limit - forward_speed * signf(throttle)) / maxf(speed_limit * _SPEED_LIMIT_SOFTNESS, 0.001), 0.0, 1.0)
		if headroom > 0.0:
			apply_force(hull_forward * throttle * acceleration * mass * immersion * headroom, propulsion_offset)
	if absf(turn_input) > 0.001:
		var speed_factor := lerpf(low_speed_turn_factor, 1.0, clampf(absf(forward_speed) / maxf(max_forward_speed, 0.001), 0.0, 1.0))
		var state := PhysicsServer3D.body_get_direct_state(get_rid())
		var yaw_inverse_inertia := Vector3.UP.dot(state.inverse_inertia_tensor * Vector3.UP)
		if yaw_inverse_inertia <= 0.0:
			return
		var yaw_torque := deg_to_rad(turn_acceleration) * turn_input * speed_factor * immersion / yaw_inverse_inertia
		# The rudder pushes the stern sideways: a side force whose moment about the
		# centre of mass is that torque (and which also heels and slides the boat).
		var right := forward.cross(Vector3.UP)
		var yaw_per_newton := (propulsion_offset - state.center_of_mass).cross(right).dot(Vector3.UP)
		if absf(yaw_per_newton) < _MIN_RUDDER_ARM:
			apply_torque(Vector3.UP * yaw_torque)
		else:
			apply_force(right * (yaw_torque / yaw_per_newton), propulsion_offset)


func _play_model_animation() -> void:
	var animation_player := get_node_or_null(animation_player_path) as AnimationPlayer
	if animation_player == null:
		push_error("GREFloatingBoat %s: animation_player_path does not point to an AnimationPlayer." % get_path())
		return
	var animation := animation_player.get_animation(autoplay_animation)
	if animation == null:
		push_error("GREFloatingBoat %s: the model has no animation '%s'." % [get_path(), autoplay_animation])
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
