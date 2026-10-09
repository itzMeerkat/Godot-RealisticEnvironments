class_name OceanHulls
extends RefCounted
## OceanSystem's view of the HullWaterFootprint nodes (group ocean_hull): one texture
## array layer per distinct baked HullProfile, the nearest hulls' cutout uniforms for
## the water shader, and the SimHull records the interaction simulation reads
## (iwave_pressure.glsl).

const MAX_NEAR_HULLS := 8

## One layer per profile in use (null without footprints, or if building it failed).
var profiles_texture : Texture2DArray
## Sends a water shader parameter: OceanSystem._set_water_shader_parameter.
var _set_parameter : Callable
## Instance ids of the profiles in profiles_texture, in layer order.
var _profile_ids := PackedInt64Array()


func _init(set_parameter : Callable) -> void:
	_set_parameter = set_parameter


## Forgets what was sent, so the next update() sends everything again (a new material).
func reset() -> void:
	_profile_ids = PackedInt64Array()


## Collects the footprints in tree, keeps the profile array up to date and sends the
## cutouts of the MAX_NEAR_HULLS nearest within cutout_distance of camera (none
## without a camera).
func update(tree : SceneTree, camera : Camera3D, cutout_distance : float) -> void:
	var footprints : Array[HullWaterFootprint] = []
	for node in tree.get_nodes_in_group(&"ocean_hull"):
		var footprint := node as HullWaterFootprint
		# Footprints without a baked profile report their own error and contribute nothing.
		if footprint.profile != null:
			footprints.push_back(footprint)
	_update_profile_array(footprints)

	var near : Array[Dictionary] = []
	if camera != null:
		for footprint in footprints:
			if not footprint.cutout_enabled or not footprint.is_visible_in_tree():
				continue
			var sphere := footprint.get_world_bounding_sphere()
			var distance := maxf(camera.global_position.distance_to(Vector3(sphere.x, sphere.y, sphere.z)) - sphere.w, 0.0)
			if distance <= cutout_distance:
				near.push_back({"distance": distance, "footprint": footprint, "sphere": sphere})
		near.sort_custom(func(a : Dictionary, b : Dictionary) -> bool: return a["distance"] < b["distance"])

	var count := mini(near.size(), MAX_NEAR_HULLS)
	_set_parameter.call(&'near_hull_count', count)
	# The shader reads no hull data while the count is 0: keep the last arrays.
	if count == 0:
		return
	# Rows of each hull's world-to-local affine transform (xyz = basis row, w = origin).
	var rows_x := PackedVector4Array()
	var rows_y := PackedVector4Array()
	var rows_z := PackedVector4Array()
	var spheres := PackedVector4Array()
	var rects := PackedVector4Array()
	var params := PackedVector4Array()
	var top_offsets := PackedFloat32Array()
	rows_x.resize(MAX_NEAR_HULLS)
	rows_y.resize(MAX_NEAR_HULLS)
	rows_z.resize(MAX_NEAR_HULLS)
	spheres.resize(MAX_NEAR_HULLS)
	rects.resize(MAX_NEAR_HULLS)
	params.resize(MAX_NEAR_HULLS)
	top_offsets.resize(MAX_NEAR_HULLS)
	for i in count:
		var footprint : HullWaterFootprint = near[i]["footprint"]
		var sphere : Vector4 = near[i]["sphere"]
		var profile := footprint.profile
		var feather := footprint.cutout_feather
		var rows := world_to_local_rows(footprint)
		rows_x[i] = rows[0]
		rows_y[i] = rows[1]
		rows_z[i] = rows[2]
		# Grow the sphere by the feather so the edge-foam band is not culled.
		spheres[i] = Vector4(sphere.x, sphere.y, sphere.z, (sphere.w + feather) * (sphere.w + feather))
		rects[i] = Vector4(profile.min_z, profile.min_y, 1.0 / (profile.max_z - profile.min_z), 1.0 / (profile.max_y - profile.min_y))
		params[i] = Vector4(float(get_profile_layer(profile)), profile.center_x, feather, footprint.cutout_edge_foam)
		top_offsets[i] = footprint.cutout_height_offset / (profile.max_y - profile.min_y)
	_set_parameter.call(&'near_hull_world_to_local_x', rows_x)
	_set_parameter.call(&'near_hull_world_to_local_y', rows_y)
	_set_parameter.call(&'near_hull_world_to_local_z', rows_z)
	_set_parameter.call(&'near_hull_spheres', spheres)
	_set_parameter.call(&'near_hull_rects', rects)
	_set_parameter.call(&'near_hull_params', params)
	_set_parameter.call(&'near_hull_top_offsets', top_offsets)


## The layer of profile in profiles_texture, or -1.
func get_profile_layer(profile : HullProfile) -> int:
	return _profile_ids.find(profile.get_instance_id())


## SimHull records (iwave_pressure.glsl, WaterInteractionSim.FLOATS_PER_HULL each) of up
## to WaterInteractionSim.MAX_HULLS wake-enabled hulls in tree within reach (m,
## horizontally) of camera_position, nearest first.
func pack_interaction_hulls(tree : SceneTree, camera_position : Vector3, reach : float) -> PackedFloat32Array:
	var candidates : Array[Dictionary] = []
	for node in tree.get_nodes_in_group(&"ocean_hull"):
		var footprint := node as HullWaterFootprint
		if not pushes_water(footprint):
			continue
		var sphere := footprint.get_world_bounding_sphere()
		var distance := Vector2(sphere.x - camera_position.x, sphere.z - camera_position.z).length() - sphere.w
		if distance <= reach:
			candidates.push_back({"distance": distance, "footprint": footprint, "sphere": sphere})
	candidates.sort_custom(func(a : Dictionary, b : Dictionary) -> bool: return a["distance"] < b["distance"])

	var data := PackedFloat32Array()
	for i in mini(candidates.size(), WaterInteractionSim.MAX_HULLS):
		var footprint : HullWaterFootprint = candidates[i]["footprint"]
		var sphere : Vector4 = candidates[i]["sphere"]
		var profile := footprint.profile
		var center := Vector3(sphere.x, sphere.y, sphere.z)
		var center_velocity := footprint.get_point_velocity(center)
		for row in world_to_local_rows(footprint):
			_append_vector4(data, row)
		_append_vector4(data, Vector4(sphere.x, sphere.z, sphere.w, sphere.y))
		_append_vector4(data, Vector4(profile.min_z, profile.min_y, 1.0 / (profile.max_z - profile.min_z), 1.0 / (profile.max_y - profile.min_y)))
		_append_vector4(data, Vector4(float(get_profile_layer(profile)), profile.center_x, 1.0 / profile.max_half_width, 0.0))
		_append_vector4(data, Vector4(footprint.wake_strength, footprint.wake_edge_softness, footprint.bow_wave_strength, footprint.bow_wave_max_rise))
		_append_vector4(data, Vector4(center_velocity.x, center_velocity.y, center_velocity.z, 0.0))
		_append_vector4(data, Vector4(footprint.angular_velocity.x, footprint.angular_velocity.y, footprint.angular_velocity.z, 0.0))
	return data


## Whether a footprint forces the interaction simulation (when near enough).
## Footprints without a baked profile report their own error and contribute nothing.
static func pushes_water(footprint : HullWaterFootprint) -> bool:
	return footprint.profile != null and footprint.wake_enabled and footprint.is_visible_in_tree()


## Rows of the footprint's world-to-local affine transform: xyz = basis row, w = origin.
static func world_to_local_rows(footprint : HullWaterFootprint) -> Array[Vector4]:
	var world_to_local := footprint.global_transform.affine_inverse()
	var inverse_basis := world_to_local.basis
	var origin := world_to_local.origin
	return [
		Vector4(inverse_basis.x.x, inverse_basis.y.x, inverse_basis.z.x, origin.x),
		Vector4(inverse_basis.x.y, inverse_basis.y.y, inverse_basis.z.y, origin.y),
		Vector4(inverse_basis.x.z, inverse_basis.y.z, inverse_basis.z.z, origin.z),
	]


## Keeps one texture-array layer per distinct HullProfile in use. Rebuilt only
## when the set of profiles changes (a re-bake creates a new profile resource).
func _update_profile_array(footprints : Array[HullWaterFootprint]) -> void:
	var profiles : Array[HullProfile] = []
	var ids := PackedInt64Array()
	for footprint in footprints:
		if not ids.has(footprint.profile.get_instance_id()):
			profiles.push_back(footprint.profile)
			ids.push_back(footprint.profile.get_instance_id())
	if ids == _profile_ids:
		return
	_profile_ids = ids
	if profiles.is_empty():
		profiles_texture = null
	else:
		var images : Array[Image] = []
		for profile in profiles:
			images.push_back(profile.image)
		profiles_texture = Texture2DArray.new()
		var error := profiles_texture.create_from_images(images)
		if error != OK:
			# Cutouts and wakes read layer 0 of an empty array: nothing is cut out.
			push_error("OceanSystem: building the hull profile texture array failed (%s); re-bake the profiles." % error_string(error))
			profiles_texture = null
	_set_parameter.call(&'hull_profiles', profiles_texture)


static func _append_vector4(data : PackedFloat32Array, value : Vector4) -> void:
	data.push_back(value.x)
	data.push_back(value.y)
	data.push_back(value.z)
	data.push_back(value.w)
