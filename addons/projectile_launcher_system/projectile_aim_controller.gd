class_name ProjectileAimController
extends Node3D
## Aims projectile launchers at the center-screen intersection with a horizontal plane.

const AIM_MARKER_NODE_NAME := &"AimMarker"

## Enables aim-point tracking, marker drawing, ballistic solving, and yaw rotation.
@export var enabled := true
## Optional Camera3D used for center-screen aiming. Leave empty to use the active viewport camera.
@export var camera_path: NodePath
## ProjectileLaunchers controlled by this aim controller.
@export var launcher_paths: Array[NodePath] = []
## Optional visual/yaw targets matching launcher_paths by index. Empty entries rotate the launcher itself.
@export var yaw_target_paths: Array[NodePath] = []

@export_group("Aim")
## World Y height of the horizontal plane used for center-screen aim intersection.
@export var aim_plane_y := 0.0
## Rotates launchers/yaw targets toward the current aim point.
@export var rotate_launchers := true
## Yaw axis reference. Empty uses this controller's parent, which is usually the boat body.
@export var yaw_reference_path: NodePath
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
## Marker color when no ballistic reachability result is available.
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
## Requires every configured launcher to have a solution before the marker is reachable.
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

var aim_point := Vector3.ZERO
var has_aim_point := false
var has_reachable_solution := false
var _marker_instance: MeshInstance3D
var _marker_mesh := ImmediateMesh.new()
var _marker_material: StandardMaterial3D
var _current_launch_directions := {}
var _current_reachable := {}
var _last_valid_launch_directions := {}


func _ready() -> void:
	_update_marker_visibility()


func _process(delta: float) -> void:
	if not enabled:
		has_aim_point = false
		_update_marker_visibility()
		return

	has_aim_point = _update_aim_point()
	_update_ballistic_solutions()
	_update_marker()
	if has_aim_point and rotate_launchers:
		_aim_launchers(delta)


func get_aim_point() -> Vector3:
	return aim_point


func has_current_solution_for_launcher(launcher: ProjectileLauncher) -> bool:
	var key := _get_launcher_key(launcher)
	return bool(_current_reachable.get(key, false))


func has_launch_direction_for_launcher(launcher: ProjectileLauncher) -> bool:
	var key := _get_launcher_key(launcher)
	return _current_launch_directions.has(key) or _last_valid_launch_directions.has(key)


func get_launch_direction_for_launcher(launcher: ProjectileLauncher) -> Vector3:
	var key := _get_launcher_key(launcher)
	if _current_launch_directions.has(key):
		return _current_launch_directions[key]
	if _last_valid_launch_directions.has(key):
		return _last_valid_launch_directions[key]
	return (-launcher.global_transform.basis.z).normalized()


func _update_aim_point() -> bool:
	var camera := _get_camera()
	if camera == null:
		return false

	var viewport := get_viewport()
	if viewport == null:
		return false
	var center := viewport.get_visible_rect().size * 0.5
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
	for i in launcher_paths.size():
		var launcher := get_node_or_null(launcher_paths[i]) as Node3D
		if launcher == null:
			continue
		var yaw_target := _get_yaw_target(i, launcher)
		if yaw_target == null:
			continue
		_rotate_target_toward_aim(launcher, yaw_target, weight)


func _get_yaw_target(index: int, launcher: Node3D) -> Node3D:
	if index < yaw_target_paths.size() and not yaw_target_paths[index].is_empty():
		var target := get_node_or_null(yaw_target_paths[index]) as Node3D
		if target != null:
			return target
	return launcher


func _rotate_target_toward_aim(launcher: Node3D, yaw_target: Node3D, weight: float) -> void:
	var pivot := launcher.global_position
	var yaw_axis := _get_yaw_axis()
	var desired_direction := aim_point - pivot
	desired_direction = _project_on_yaw_plane(desired_direction, yaw_axis)
	if desired_direction.length_squared() <= 0.0001:
		return
	desired_direction = desired_direction.normalized()

	var current_direction := -launcher.global_transform.basis.z
	current_direction = _project_on_yaw_plane(current_direction, yaw_axis)
	if current_direction.length_squared() <= 0.0001:
		return
	current_direction = current_direction.normalized()

	var yaw_delta := current_direction.signed_angle_to(desired_direction, yaw_axis) * clampf(weight, 0.0, 1.0)
	if absf(yaw_delta) <= 0.00001:
		return

	var yaw_rotation := Basis(yaw_axis, yaw_delta)
	var target_transform := yaw_target.global_transform
	target_transform.origin = pivot + yaw_rotation * (target_transform.origin - pivot)
	target_transform.basis = yaw_rotation * target_transform.basis
	yaw_target.global_transform = target_transform


func _get_yaw_axis() -> Vector3:
	var reference := _get_yaw_reference()
	if reference != null:
		var axis := reference.global_transform.basis.y.normalized()
		if axis.length_squared() > 0.0001:
			return axis
	return Vector3.UP


func _get_yaw_reference() -> Node3D:
	if not yaw_reference_path.is_empty():
		var configured_reference := get_node_or_null(yaw_reference_path) as Node3D
		if configured_reference != null:
			return configured_reference
	return get_parent() as Node3D


func _project_on_yaw_plane(vector: Vector3, yaw_axis: Vector3) -> Vector3:
	return vector - yaw_axis * vector.dot(yaw_axis)


func _update_ballistic_solutions() -> void:
	_current_launch_directions.clear()
	_current_reachable.clear()
	has_reachable_solution = false
	if not has_aim_point or not solve_ballistics:
		return

	var evaluated_count := 0
	var reachable_count := 0
	for path in launcher_paths:
		var launcher := get_node_or_null(path) as ProjectileLauncher
		if launcher == null:
			continue
		evaluated_count += 1
		var result := _solve_ballistic_direction(launcher)
		var key := _get_launcher_key(launcher)
		var reachable := bool(result.get("reachable", false))
		_current_reachable[key] = reachable
		if reachable:
			var direction: Vector3 = result["direction"]
			_current_launch_directions[key] = direction
			_last_valid_launch_directions[key] = direction
			reachable_count += 1

	if evaluated_count <= 0:
		has_reachable_solution = false
	elif require_all_launchers_reachable:
		has_reachable_solution = reachable_count == evaluated_count
	else:
		has_reachable_solution = reachable_count > 0


func _solve_ballistic_direction(launcher: ProjectileLauncher) -> Dictionary:
	var muzzle_transform := launcher.get_muzzle_transform()
	var origin := muzzle_transform.origin
	var horizontal_delta := aim_point - origin
	horizontal_delta.y = 0.0
	var horizontal_distance := horizontal_delta.length()
	if horizontal_distance <= 0.001:
		return {"reachable": false}

	var horizontal_direction := horizontal_delta / horizontal_distance
	var inherited_velocity := launcher.get_inherited_velocity_at(origin)
	var initial_speed := maxf(launcher.initial_speed, 0.001)
	var projectile_mass := maxf(launcher.projectile_mass, 0.001)
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
		var sample := _simulate_ballistic_pitch(origin, horizontal_direction, horizontal_distance, aim_point.y, initial_speed, inherited_velocity, launcher.drag_coefficient, projectile_mass, pitch)
		if not bool(sample.get("has_error", false)):
			continue
		var error := float(sample["height_error"])
		var abs_error := absf(error)
		if abs_error < best_abs_error:
			best_abs_error = abs_error
			best_pitch = pitch
			best_reachable = bool(sample.get("reached_range", false))
		if has_previous and ((previous_error <= 0.0 and error >= 0.0) or (previous_error >= 0.0 and error <= 0.0)):
			intervals.push_back(Vector2(previous_pitch, pitch))
		has_previous = true
		previous_pitch = pitch
		previous_error = error

	if not intervals.is_empty():
		var interval := intervals[intervals.size() - 1] if prefer_high_arc else intervals[0]
		best_pitch = _refine_ballistic_pitch(origin, horizontal_direction, horizontal_distance, aim_point.y, initial_speed, inherited_velocity, launcher.drag_coefficient, projectile_mass, interval.x, interval.y)
		best_reachable = true
	elif best_abs_error > impact_height_tolerance or not best_reachable:
		return {"reachable": false}

	var direction := (horizontal_direction * cos(best_pitch) + Vector3.UP * sin(best_pitch)).normalized()
	return {
		"reachable": true,
		"direction": direction,
		"pitch": best_pitch,
	}


func _refine_ballistic_pitch(origin: Vector3, horizontal_direction: Vector3, horizontal_distance: float, target_y: float, initial_speed: float, inherited_velocity: Vector3, drag_coefficient: float, projectile_mass: float, low_pitch: float, high_pitch: float) -> float:
	var low := low_pitch
	var high := high_pitch
	var low_sample := _simulate_ballistic_pitch(origin, horizontal_direction, horizontal_distance, target_y, initial_speed, inherited_velocity, drag_coefficient, projectile_mass, low)
	var low_error := float(low_sample.get("height_error", 0.0))
	for _i in pitch_refine_steps:
		var mid := (low + high) * 0.5
		var mid_sample := _simulate_ballistic_pitch(origin, horizontal_direction, horizontal_distance, target_y, initial_speed, inherited_velocity, drag_coefficient, projectile_mass, mid)
		var mid_error := float(mid_sample.get("height_error", 0.0))
		if (low_error <= 0.0 and mid_error >= 0.0) or (low_error >= 0.0 and mid_error <= 0.0):
			high = mid
		else:
			low = mid
			low_error = mid_error
	return (low + high) * 0.5


func _simulate_ballistic_pitch(origin: Vector3, horizontal_direction: Vector3, horizontal_distance: float, target_y: float, initial_speed: float, inherited_velocity: Vector3, drag_coefficient: float, projectile_mass: float, pitch: float) -> Dictionary:
	var launch_direction := (horizontal_direction * cos(pitch) + Vector3.UP * sin(pitch)).normalized()
	var velocity_3d := launch_direction * initial_speed + inherited_velocity
	var velocity := Vector2(velocity_3d.dot(horizontal_direction), velocity_3d.y)
	var position := Vector2(0.0, origin.y)
	var previous_position := position
	var gravity := float(ProjectSettings.get_setting("physics/3d/default_gravity", 9.8))
	var step := maxf(simulation_step, 0.001)
	var elapsed := 0.0
	while elapsed < max_simulation_time:
		previous_position = position
		var acceleration := Vector2(0.0, -gravity)
		var speed_squared := velocity.length_squared()
		if drag_coefficient > 0.0 and speed_squared > 0.0001:
			acceleration += -velocity.normalized() * speed_squared * drag_coefficient / projectile_mass
		velocity += acceleration * step
		position += velocity * step
		elapsed += step

		if position.x >= horizontal_distance:
			var segment_distance := position.x - previous_position.x
			var weight := 1.0 if absf(segment_distance) <= 0.0001 else clampf((horizontal_distance - previous_position.x) / segment_distance, 0.0, 1.0)
			var interpolated_y := lerpf(previous_position.y, position.y, weight)
			return {
				"has_error": true,
				"reached_range": true,
				"height_error": interpolated_y - target_y,
			}

		if position.y <= target_y and velocity.y < 0.0 and position.x < horizontal_distance:
			return {
				"has_error": true,
				"reached_range": false,
				"height_error": position.y - target_y,
			}

	return {
		"has_error": false,
		"reached_range": false,
	}


func _get_camera() -> Camera3D:
	if not camera_path.is_empty():
		var configured_camera := get_node_or_null(camera_path) as Camera3D
		if configured_camera != null:
			return configured_camera
	var viewport := get_viewport()
	return viewport.get_camera_3d() if viewport != null else null


func _update_marker() -> void:
	if not marker_visible or not has_aim_point:
		_update_marker_visibility()
		return

	_ensure_marker_node()
	if _marker_instance == null:
		return
	_marker_instance.visible = true
	_marker_instance.top_level = true
	_marker_instance.global_transform = Transform3D.IDENTITY

	_marker_mesh.clear_surfaces()
	_marker_mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	_add_marker_ring()
	_add_marker_cross()
	_add_marker_height_line()
	_marker_mesh.surface_end()
	_update_marker_material()


func _add_marker_ring() -> void:
	var segments := maxi(marker_segments, 8)
	for i in segments:
		var a0 := float(i) / float(segments) * TAU
		var a1 := float(i + 1) / float(segments) * TAU
		_marker_mesh.surface_add_vertex(aim_point + Vector3(cos(a0) * marker_radius, 0.0, sin(a0) * marker_radius))
		_marker_mesh.surface_add_vertex(aim_point + Vector3(cos(a1) * marker_radius, 0.0, sin(a1) * marker_radius))


func _add_marker_cross() -> void:
	_marker_mesh.surface_add_vertex(aim_point + Vector3.LEFT * marker_radius)
	_marker_mesh.surface_add_vertex(aim_point + Vector3.RIGHT * marker_radius)
	_marker_mesh.surface_add_vertex(aim_point + Vector3.FORWARD * marker_radius)
	_marker_mesh.surface_add_vertex(aim_point + Vector3.BACK * marker_radius)


func _add_marker_height_line() -> void:
	if marker_height <= 0.0:
		return
	_marker_mesh.surface_add_vertex(aim_point)
	_marker_mesh.surface_add_vertex(aim_point + Vector3.UP * marker_height)


func _ensure_marker_node() -> void:
	if _marker_instance != null and is_instance_valid(_marker_instance):
		return
	_marker_instance = get_node_or_null(NodePath(String(AIM_MARKER_NODE_NAME))) as MeshInstance3D
	if _marker_instance == null:
		_marker_instance = MeshInstance3D.new()
		_marker_instance.name = String(AIM_MARKER_NODE_NAME)
		add_child(_marker_instance, false, INTERNAL_MODE_BACK)
	_marker_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_marker_instance.extra_cull_margin = 10000.0
	_marker_instance.mesh = _marker_mesh
	_update_marker_material()


func _update_marker_visibility() -> void:
	if _marker_instance != null:
		_marker_instance.visible = marker_visible and has_aim_point and enabled


func _update_marker_material() -> void:
	if _marker_material == null:
		_marker_material = StandardMaterial3D.new()
		_marker_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_marker_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_marker_material.albedo_color = _get_current_marker_color()
	_marker_material.no_depth_test = marker_on_top
	if _marker_instance != null:
		_marker_instance.material_override = _marker_material


func _get_current_marker_color() -> Color:
	if solve_ballistics and has_aim_point:
		return reachable_marker_color if has_reachable_solution else unreachable_marker_color
	return marker_color


func _get_launcher_key(launcher: Node) -> String:
	return str(launcher.get_path()) if launcher != null and launcher.is_inside_tree() else str(launcher.get_instance_id())
