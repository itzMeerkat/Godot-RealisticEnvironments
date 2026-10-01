class_name ProjectileWeaponController
extends Node3D
## Drives a set of ProjectileLaunchers: aims them at the center-screen point on a
## horizontal plane (ballistic pitch solve, yaw turning, aim marker), fires them
## all on an input action, and pushes the carrying rigid body back on every shot.

const AIM_MARKER_NODE_NAME := &"AimMarker"

## Enables aiming, firing and recoil.
@export var enabled := true
## Collects every ProjectileLauncher under the carrying body (or this node's
## parent when there is no body) in _ready.
@export var auto_collect_launchers := true
## Launchers controlled in addition to the collected ones.
@export var launcher_paths: Array[NodePath] = []
## Carrying rigid body: receives recoil and defines the yaw axis. Empty uses
## the nearest RigidBody3D ancestor; without one there is no body recoil.
@export var body_path: NodePath

@export_group("Input")
## InputMap action that fires every launcher.
@export var fire_action: StringName = &"fire_projectile"
## Minimum seconds between accepted fire inputs.
@export_range(0.0, 10.0, 0.01, "or_greater") var cooldown := 0.5
## Aims and fires only while the nearest ancestor exposing controlled_property
## has it set (e.g. FloatingBoat.player_controlled). Others stay idle.
@export var require_controlled_owner := true
## Ancestor boolean property checked by require_controlled_owner.
@export var controlled_property: StringName = &"player_controlled"

@export_group("Aim")
## Optional Camera3D used for center-screen aiming. Leave empty to use the active viewport camera.
@export var camera_path: NodePath
## World Y height of the horizontal plane used for center-screen aim intersection.
@export var aim_plane_y := 0.0
## Turns each launcher's yaw target (see ProjectileLauncher.yaw_target_path) toward the aim point.
@export var rotate_launchers := true
## Exponential smoothing speed for yaw rotation. Set 0 for instant rotation.
@export_range(0.0, 60.0, 0.01) var yaw_smoothing := 18.0
## Maximum accepted camera ray distance to the aim plane.
@export_range(0.0, 100000.0, 0.1, "or_greater") var max_aim_distance := 10000.0

@export_group("Marker")
## Shows the aim marker at the current aim point.
@export var marker_visible := true
## Radius of the aim marker ring.
@export_range(0.1, 100.0, 0.01, "or_greater") var marker_radius := 1.25
## Height of the aim marker center line.
@export_range(0.0, 100.0, 0.01, "or_greater") var marker_height := 4.0
## Segment count used to draw the marker ring.
@export_range(8, 128, 1) var marker_segments := 48
## Marker color when ballistic solving is off.
@export var marker_color := Color(1.0, 0.35, 0.05, 1.0)
## Marker color when at least one launcher can reach the aim point.
@export var reachable_marker_color := Color(0.2, 1.0, 0.25, 1.0)
## Marker color when no launcher can reach the aim point.
@export var unreachable_marker_color := Color(1.0, 0.1, 0.05, 1.0)
## Draws the marker without depth testing so it stays visible through waves/geometry.
@export var marker_on_top := true

@export_group("Ballistics")
## Numerically solves launch pitch so projectiles can hit the aim point.
@export var solve_ballistics := true
## Requires every launcher to have a solution before the marker is reachable.
@export var require_all_launchers_reachable := false
## Chooses the highest valid arc instead of the lowest valid arc.
@export var prefer_high_arc := false
## Minimum pitch angle considered by the solver.
@export_range(-10.0, 89.0, 0.1, "degrees") var min_pitch_degrees := 0.0
## Maximum pitch angle considered by the solver.
@export_range(-10.0, 89.0, 0.1, "degrees") var max_pitch_degrees := 65.0
## Coarse pitch samples tested before refinement.
@export_range(8, 256, 1) var pitch_search_steps := 64
## Binary refinement steps after the best coarse pitch is found.
@export_range(1, 32, 1) var pitch_refine_steps := 12
## Projectile simulation step used by the solver, in seconds.
@export_range(0.001, 0.1, 0.001) var simulation_step := 0.016
## Maximum simulated flight time per pitch candidate.
@export_range(0.1, 60.0, 0.1) var max_simulation_time := 12.0
## Acceptable vertical miss distance when the trajectory reaches the aim point.
@export_range(0.01, 10.0, 0.01, "or_greater") var impact_height_tolerance := 0.35

@export_group("Recoil")
## Pushes the carrying body opposite the fire direction, at the muzzle, on every shot.
@export var body_recoil_enabled := true
## Uses projectile_mass * initial_speed of the shot as the base impulse; otherwise fallback_impulse.
@export var use_projectile_momentum := true
## Multiplier applied to the base impulse (and the launcher's recoil_strength).
@export_range(0.0, 10000.0, 0.001, "or_greater") var impulse_multiplier := 1.0
## Base impulse used when use_projectile_momentum is off.
@export_range(0.0, 1000000.0, 0.001, "or_greater") var fallback_impulse := 100.0

var launchers: Array[ProjectileLauncher] = []
var body: RigidBody3D
var aim_point := Vector3.ZERO
var has_aim_point := false
var has_reachable_solution := false
var _cooldown_remaining := 0.0
var _gravity := 9.8
var _marker_instance: MeshInstance3D
var _marker_mesh := ImmediateMesh.new()
var _marker_material: StandardMaterial3D
var _current_launch_directions := {}
var _last_valid_launch_directions := {}


func _ready() -> void:
	body = get_node(body_path) as RigidBody3D if not body_path.is_empty() else _find_ancestor_rigid_body()
	assert(body_path.is_empty() or body != null, "ProjectileWeaponController %s: body_path does not point to a RigidBody3D." % get_path())
	_gravity = float(ProjectSettings.get_setting("physics/3d/default_gravity"))
	_create_marker()
	refresh_launchers()


## Re-collects launchers (after adding or removing them at runtime).
func refresh_launchers() -> void:
	for launcher in launchers:
		launcher.fired.disconnect(_on_launcher_fired)
	launchers.clear()
	for path in launcher_paths:
		var launcher := get_node(path) as ProjectileLauncher
		assert(launcher != null, "ProjectileWeaponController %s: launcher path %s is not a ProjectileLauncher." % [get_path(), path])
		if not launchers.has(launcher):
			launchers.push_back(launcher)
	if auto_collect_launchers:
		_collect_launchers(body if body != null else get_parent())
	for launcher in launchers:
		launcher.fired.connect(_on_launcher_fired)
	_current_launch_directions.clear()
	_last_valid_launch_directions.clear()


func _process(delta: float) -> void:
	_cooldown_remaining = maxf(_cooldown_remaining - delta, 0.0)
	has_aim_point = enabled and not launchers.is_empty() and _is_controlled() and _update_aim_point()
	_update_ballistic_solutions()
	_update_marker()
	if has_aim_point and rotate_launchers:
		_aim_launchers(delta)


func _unhandled_input(event: InputEvent) -> void:
	if not enabled or _cooldown_remaining > 0.0 or launchers.is_empty():
		return
	if not event.is_action_pressed(fire_action) or not _is_controlled():
		return
	fire()
	get_viewport().set_input_as_handled()


## Fires every launcher along its solved direction (or its muzzle -Z without a
## solution) and starts the cooldown.
func fire() -> void:
	for launcher in launchers:
		launcher.fire(get_launch_direction_for_launcher(launcher))
	_cooldown_remaining = cooldown


func get_aim_point() -> Vector3:
	return aim_point


## Solved direction for this frame, else the last solved one, else the muzzle's -Z.
func get_launch_direction_for_launcher(launcher: ProjectileLauncher) -> Vector3:
	var key := launcher.get_instance_id()
	if _current_launch_directions.has(key):
		return _current_launch_directions[key]
	if _last_valid_launch_directions.has(key):
		return _last_valid_launch_directions[key]
	return -launcher.get_muzzle_transform().basis.z.normalized()


func has_current_solution_for_launcher(launcher: ProjectileLauncher) -> bool:
	return _current_launch_directions.has(launcher.get_instance_id())


func _collect_launchers(node: Node) -> void:
	for child in node.get_children():
		if child is ProjectileLauncher and not launchers.has(child):
			launchers.push_back(child)
		_collect_launchers(child)


func _find_ancestor_rigid_body() -> RigidBody3D:
	var node := get_parent()
	while node != null:
		if node is RigidBody3D:
			return node
		node = node.get_parent()
	return null


func _is_controlled() -> bool:
	if not require_controlled_owner:
		return true
	var node := get_parent()
	while node != null:
		var value = node.get(controlled_property)
		if value != null:
			return bool(value)
		node = node.get_parent()
	return true


func _on_launcher_fired(_projectile: Node, fire_direction: Vector3, shot_data: Dictionary) -> void:
	if not body_recoil_enabled or body == null:
		return
	var impulse_magnitude := fallback_impulse
	if use_projectile_momentum:
		impulse_magnitude = float(shot_data["projectile_mass"]) * float(shot_data["initial_speed"])
	var impulse := -fire_direction.normalized() * impulse_magnitude * impulse_multiplier * float(shot_data["recoil_strength"])
	var muzzle_transform: Transform3D = shot_data["muzzle_transform"]
	body.apply_impulse(impulse, muzzle_transform.origin - body.global_position)


func _update_aim_point() -> bool:
	var camera := get_node(camera_path) as Camera3D if not camera_path.is_empty() else get_viewport().get_camera_3d()
	if camera == null:
		return false
	var center := get_viewport().get_visible_rect().size * 0.5
	var ray_origin := camera.project_ray_origin(center)
	var ray_direction := camera.project_ray_normal(center)
	if absf(ray_direction.y) <= 0.0001:
		return false
	var distance := (aim_plane_y - ray_origin.y) / ray_direction.y
	if distance <= 0.0 or distance > max_aim_distance:
		return false
	aim_point = ray_origin + ray_direction * distance
	aim_point.y = aim_plane_y
	return true


func _aim_launchers(delta: float) -> void:
	var weight := 1.0 if yaw_smoothing <= 0.0 else 1.0 - exp(-yaw_smoothing * delta)
	var reference : Node3D = body if body != null else get_parent()
	var yaw_axis := reference.global_transform.basis.y.normalized()
	for launcher in launchers:
		var yaw_target : Node3D = launcher.get_node(launcher.yaw_target_path) if not launcher.yaw_target_path.is_empty() else launcher
		_rotate_target_toward_aim(launcher, yaw_target, yaw_axis, weight)


func _rotate_target_toward_aim(launcher: Node3D, yaw_target: Node3D, yaw_axis: Vector3, weight: float) -> void:
	var pivot := launcher.global_position
	var desired_direction := _project_on_yaw_plane(aim_point - pivot, yaw_axis)
	var current_direction := _project_on_yaw_plane(-launcher.global_transform.basis.z, yaw_axis)
	if desired_direction.length_squared() <= 0.0001 or current_direction.length_squared() <= 0.0001:
		return
	var yaw_delta := current_direction.normalized().signed_angle_to(desired_direction.normalized(), yaw_axis) * weight
	if absf(yaw_delta) <= 0.00001:
		return
	var yaw_rotation := Basis(yaw_axis, yaw_delta)
	var target_transform := yaw_target.global_transform
	target_transform.origin = pivot + yaw_rotation * (target_transform.origin - pivot)
	target_transform.basis = yaw_rotation * target_transform.basis
	yaw_target.global_transform = target_transform


func _project_on_yaw_plane(vector: Vector3, yaw_axis: Vector3) -> Vector3:
	return vector - yaw_axis * vector.dot(yaw_axis)


func _update_ballistic_solutions() -> void:
	_current_launch_directions.clear()
	has_reachable_solution = false
	if not has_aim_point or not solve_ballistics:
		return
	var reachable_count := 0
	for launcher in launchers:
		var result := _solve_ballistic_direction(launcher)
		if bool(result["reachable"]):
			var key := launcher.get_instance_id()
			_current_launch_directions[key] = result["direction"]
			_last_valid_launch_directions[key] = result["direction"]
			reachable_count += 1
	if require_all_launchers_reachable:
		has_reachable_solution = reachable_count == launchers.size()
	else:
		has_reachable_solution = reachable_count > 0


func _solve_ballistic_direction(launcher: ProjectileLauncher) -> Dictionary:
	var origin := launcher.get_muzzle_transform().origin
	var horizontal_delta := aim_point - origin
	horizontal_delta.y = 0.0
	var horizontal_distance := horizontal_delta.length()
	if horizontal_distance <= 0.001:
		return {"reachable": false}

	var horizontal_direction := horizontal_delta / horizontal_distance
	var shot := {
		"origin": origin,
		"horizontal_direction": horizontal_direction,
		"horizontal_distance": horizontal_distance,
		"target_y": aim_point.y,
		"initial_speed": maxf(launcher.initial_speed, 0.001),
		"inherited_velocity": launcher.get_inherited_velocity_at(origin),
		"drag_coefficient": launcher.drag_coefficient,
		"projectile_mass": maxf(launcher.projectile_mass, 0.001),
	}
	var pitch_min := deg_to_rad(minf(min_pitch_degrees, max_pitch_degrees))
	var pitch_max := deg_to_rad(maxf(min_pitch_degrees, max_pitch_degrees))
	var best_pitch := 0.0
	var best_abs_error := INF
	var best_reachable := false
	var intervals: Array[Vector2] = []
	var previous_pitch := pitch_min
	var previous_error := 0.0
	var has_previous := false

	var steps := maxi(pitch_search_steps, 2)
	for i in range(steps + 1):
		var pitch := lerpf(pitch_min, pitch_max, float(i) / float(steps))
		var sample := _simulate_ballistic_pitch(shot, pitch)
		if not bool(sample["has_error"]):
			continue
		var error := float(sample["height_error"])
		if absf(error) < best_abs_error:
			best_abs_error = absf(error)
			best_pitch = pitch
			best_reachable = bool(sample["reached_range"])
		if has_previous and ((previous_error <= 0.0 and error >= 0.0) or (previous_error >= 0.0 and error <= 0.0)):
			intervals.push_back(Vector2(previous_pitch, pitch))
		has_previous = true
		previous_pitch = pitch
		previous_error = error

	if not intervals.is_empty():
		var interval := intervals[intervals.size() - 1] if prefer_high_arc else intervals[0]
		best_pitch = _refine_ballistic_pitch(shot, interval.x, interval.y)
	elif best_abs_error > impact_height_tolerance or not best_reachable:
		return {"reachable": false}

	return {
		"reachable": true,
		"direction": (horizontal_direction * cos(best_pitch) + Vector3.UP * sin(best_pitch)).normalized(),
	}


func _refine_ballistic_pitch(shot: Dictionary, low_pitch: float, high_pitch: float) -> float:
	var low := low_pitch
	var high := high_pitch
	var low_error := float(_simulate_ballistic_pitch(shot, low).get("height_error", 0.0))
	for _i in pitch_refine_steps:
		var mid := (low + high) * 0.5
		var mid_error := float(_simulate_ballistic_pitch(shot, mid).get("height_error", 0.0))
		if (low_error <= 0.0 and mid_error >= 0.0) or (low_error >= 0.0 and mid_error <= 0.0):
			high = mid
		else:
			low = mid
			low_error = mid_error
	return (low + high) * 0.5


## Simulates one shot in the vertical plane through the aim point. Returns the
## height error where it reaches the aim distance, or where it falls below the
## target height short of it.
func _simulate_ballistic_pitch(shot: Dictionary, pitch: float) -> Dictionary:
	var horizontal_direction: Vector3 = shot["horizontal_direction"]
	var horizontal_distance: float = shot["horizontal_distance"]
	var target_y: float = shot["target_y"]
	var drag_coefficient: float = shot["drag_coefficient"]
	var projectile_mass: float = shot["projectile_mass"]
	var launch_direction := (horizontal_direction * cos(pitch) + Vector3.UP * sin(pitch)).normalized()
	var velocity_3d: Vector3 = launch_direction * float(shot["initial_speed"]) + shot["inherited_velocity"]
	var velocity := Vector2(velocity_3d.dot(horizontal_direction), velocity_3d.y)
	var position := Vector2(0.0, (shot["origin"] as Vector3).y)
	var step := maxf(simulation_step, 0.001)
	var elapsed := 0.0
	while elapsed < max_simulation_time:
		var previous_position := position
		var acceleration := Vector2(0.0, -_gravity)
		var speed_squared := velocity.length_squared()
		if drag_coefficient > 0.0 and speed_squared > 0.0001:
			acceleration += -velocity.normalized() * speed_squared * drag_coefficient / projectile_mass
		velocity += acceleration * step
		position += velocity * step
		elapsed += step

		if position.x >= horizontal_distance:
			var segment_distance := position.x - previous_position.x
			var weight := 1.0 if absf(segment_distance) <= 0.0001 else clampf((horizontal_distance - previous_position.x) / segment_distance, 0.0, 1.0)
			return {"has_error": true, "reached_range": true, "height_error": lerpf(previous_position.y, position.y, weight) - target_y}
		if position.y <= target_y and velocity.y < 0.0:
			return {"has_error": true, "reached_range": false, "height_error": position.y - target_y}
	return {"has_error": false, "reached_range": false}


func _create_marker() -> void:
	_marker_material = StandardMaterial3D.new()
	_marker_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_marker_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_marker_instance = MeshInstance3D.new()
	_marker_instance.name = String(AIM_MARKER_NODE_NAME)
	_marker_instance.top_level = true
	_marker_instance.visible = false
	_marker_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_marker_instance.extra_cull_margin = 10000.0
	_marker_instance.mesh = _marker_mesh
	_marker_instance.material_override = _marker_material
	add_child(_marker_instance, false, INTERNAL_MODE_BACK)
	_marker_instance.global_transform = Transform3D.IDENTITY


func _update_marker() -> void:
	_marker_instance.visible = marker_visible and has_aim_point
	if not _marker_instance.visible:
		return
	_marker_material.no_depth_test = marker_on_top
	if solve_ballistics:
		_marker_material.albedo_color = reachable_marker_color if has_reachable_solution else unreachable_marker_color
	else:
		_marker_material.albedo_color = marker_color

	_marker_mesh.clear_surfaces()
	_marker_mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	var segments := maxi(marker_segments, 8)
	for i in segments:
		var a0 := float(i) / float(segments) * TAU
		var a1 := float(i + 1) / float(segments) * TAU
		_marker_mesh.surface_add_vertex(aim_point + Vector3(cos(a0), 0.0, sin(a0)) * marker_radius)
		_marker_mesh.surface_add_vertex(aim_point + Vector3(cos(a1), 0.0, sin(a1)) * marker_radius)
	_marker_mesh.surface_add_vertex(aim_point + Vector3.LEFT * marker_radius)
	_marker_mesh.surface_add_vertex(aim_point + Vector3.RIGHT * marker_radius)
	_marker_mesh.surface_add_vertex(aim_point + Vector3.FORWARD * marker_radius)
	_marker_mesh.surface_add_vertex(aim_point + Vector3.BACK * marker_radius)
	if marker_height > 0.0:
		_marker_mesh.surface_add_vertex(aim_point)
		_marker_mesh.surface_add_vertex(aim_point + Vector3.UP * marker_height)
	_marker_mesh.surface_end()
