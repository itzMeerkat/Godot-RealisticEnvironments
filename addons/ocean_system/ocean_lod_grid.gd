class_name OceanLodGrid
extends RefCounted
## OceanSystem's runtime mesh: a CDLOD quadtree of LOD_GRID x LOD_GRID grid nodes,
## drawn as one multimesh set directly as the ocean instance's base through the
## RenderingServer (no generated mesh is ever saved), selected every frame around the
## active camera. The vertex shader places and morphs the vertices (water.gdshader).

## Every node is a LOD_GRID x LOD_GRID quad grid; a level-L node is
## (mesh_base_cell_size * LOD_GRID * 2^L) meters wide.
const LOD_GRID := 16
## range(L) = LOD_RANGE_FACTOR * node size(L): level-L vertices morph onto the
## level L + 1 lattice up to that camera distance. Above ~2.8 a node never
## borders one two levels coarser, which the shader's morph relies on.
const LOD_RANGE_FACTOR := 3.0
## Morphing toward the next level starts this far between range(L - 1) and range(L).
const LOD_MORPH_START := 0.66
const MAX_LOD_LEVELS := 16
const MAX_LOD_NODES := 1024
## 3x4 transform + custom data per multimesh instance.
const LOD_INSTANCE_FLOATS := 16
## Room for displaced waves around a node, for frustum culling (m).
const LOD_WAVE_MARGIN := 12.0
## Frustum planes the node selection tests (all but the far plane).
const LOD_FRUSTUM_PLANES := 5

## Sends a water shader parameter: OceanSystem._set_water_shader_parameter.
var _set_parameter : Callable
var _grid_mesh : ArrayMesh
var _multimesh : RID
var _buffer := PackedFloat32Array()
var _uploaded_buffer := PackedFloat32Array()
var _node_count := 0
## range(L) per level, and where morphing toward level L + 1 starts.
var _ranges := PackedFloat32Array()
var _morph_starts := PackedFloat32Array()
var _top_level := 0
## mesh_base_cell_size the ranges were built for.
var _cell_size := 0.0
## The inputs of the last selection (update()).
var _selection_key := []
## Set once the node budget was exceeded, so it is reported once.
var _budget_reported := false
## This frame's selection inputs as plain floats (_select_node() reads them a few
## thousand times a frame).
var _camera_x := 0.0
var _camera_z := 0.0
var _water_y := 0.0
## Camera height above the water, squared.
var _height_squared := 0.0
var _radius_squared := 0.0
## The camera's frustum planes except the far one (nothing within the drawn radius
## reaches it): normal xyz, d (outward).
var _planes := PackedFloat32Array()


func _init(set_parameter : Callable) -> void:
	_set_parameter = set_parameter


## Creates the multimesh and makes it the base of instance (the ocean's).
func attach(instance : RID) -> void:
	_grid_mesh = _create_grid_mesh()
	_multimesh = RenderingServer.multimesh_create()
	RenderingServer.multimesh_set_mesh(_multimesh, _grid_mesh.get_rid())
	RenderingServer.multimesh_allocate_data(_multimesh, MAX_LOD_NODES, RenderingServer.MULTIMESH_TRANSFORM_3D, false, true)
	RenderingServer.multimesh_set_visible_instances(_multimesh, 0)
	RenderingServer.instance_set_base(instance, _multimesh)
	_buffer.resize(MAX_LOD_NODES * LOD_INSTANCE_FLOATS)
	# Identity instance transforms (the shader places the vertices): 3x4 rows.
	for i in MAX_LOD_NODES:
		_buffer[i * LOD_INSTANCE_FLOATS] = 1.0
		_buffer[i * LOD_INSTANCE_FLOATS + 5] = 1.0
		_buffer[i * LOD_INSTANCE_FLOATS + 10] = 1.0


## Frees the multimesh (the instance's base).
func release() -> void:
	if _multimesh.is_valid():
		RenderingServer.free_rid(_multimesh)
		_multimesh = RID()


## Rebuilds the level ranges for cell_size (when it changed or force) and sends them.
func set_cell_size(cell_size : float, force := false) -> void:
	if cell_size == _cell_size and not force:
		return
	_cell_size = cell_size
	var base_range := LOD_RANGE_FACTOR * cell_size * LOD_GRID
	_ranges.resize(MAX_LOD_LEVELS)
	_morph_starts.resize(MAX_LOD_LEVELS)
	for level in MAX_LOD_LEVELS:
		var level_range := base_range * float(1 << level)
		var previous_range := 0.0 if level == 0 else _ranges[level - 1]
		_ranges[level] = level_range
		_morph_starts[level] = lerpf(previous_range, level_range, LOD_MORPH_START)
	_set_parameter.call(&'lod_grid_enabled', _multimesh.is_valid())
	_set_parameter.call(&'lod_ranges', _ranges)
	_set_parameter.call(&'lod_morph_starts', _morph_starts)
	_set_parameter.call(&'lod_top_level', _top_level)


## Selects the nodes around camera over water at water_position (the ocean's origin)
## and uploads them as multimesh instances (custom data: node origin x, z, vertex
## spacing, level). owner_path names the ocean in errors.
func update(camera : Camera3D, water_position : Vector3, cell_size : float, owner_path : NodePath) -> void:
	# No active camera yet (e.g. while a scene is loading): draw nothing.
	if camera == null:
		RenderingServer.multimesh_set_visible_instances(_multimesh, 0)
		_selection_key = []
		return
	set_cell_size(cell_size)
	# Camera.get_frustum() order: near, far, left, top, right, bottom.
	var frustum := camera.get_frustum()
	var camera_position := camera.global_position
	# Same view and water as last frame: the selection would be the same.
	var selection_key := [frustum, camera_position, water_position.y, cell_size]
	if selection_key == _selection_key:
		return
	_selection_key = selection_key
	_camera_x = camera_position.x
	_camera_z = camera_position.z
	_water_y = water_position.y
	_height_squared = (camera_position.y - _water_y) * (camera_position.y - _water_y)
	frustum = frustum.duplicate()
	frustum.remove_at(1)
	_planes.resize(LOD_FRUSTUM_PLANES * 4)
	for i in LOD_FRUSTUM_PLANES:
		var plane := frustum[i]
		_planes[i * 4] = plane.normal.x
		_planes[i * 4 + 1] = plane.normal.y
		_planes[i * 4 + 2] = plane.normal.z
		_planes[i * 4 + 3] = plane.d
	_node_count = 0
	# Out to the horizon: the farthest point of the sphere visible from the camera's
	# height, plus how far beyond it a wave crest LOD_WAVE_MARGIN high still shows.
	# Nothing past the far plane is drawn anyway.
	var height := maxf(camera_position.y - _water_y, 0.0)
	var radius := minf(sqrt(2.0 * OceanSystem.EARTH_RADIUS * height) + sqrt(2.0 * OceanSystem.EARTH_RADIUS * LOD_WAVE_MARGIN), camera.far)
	_radius_squared = radius * radius
	var new_top_level := _get_top_level(radius)
	if new_top_level != _top_level:
		_top_level = new_top_level
		_set_parameter.call(&'lod_top_level', _top_level)
	var top_size := cell_size * LOD_GRID * float(1 << _top_level)
	var first := ((Vector2(camera_position.x, camera_position.z) - Vector2.ONE * radius) / top_size).floor()
	var root_count := int(ceil(2.0 * radius / top_size)) + 1
	for iz in root_count:
		for ix in root_count:
			_select_node((first.x + ix) * top_size, (first.y + iz) * top_size, top_size, _top_level, (1 << LOD_FRUSTUM_PLANES) - 1, owner_path)
	if _buffer != _uploaded_buffer:
		RenderingServer.multimesh_set_buffer(_multimesh, _buffer)
		_uploaded_buffer = _buffer.duplicate()
	RenderingServer.multimesh_set_visible_instances(_multimesh, _node_count)
	# Instance transforms are identity, so culling needs explicit bounds, in the ocean's
	# local space (it is never rotated or scaled).
	var center := camera_position - water_position
	var drop := radius * radius * 0.5 / OceanSystem.EARTH_RADIUS
	RenderingServer.multimesh_set_custom_aabb(_multimesh, AABB(Vector3(center.x - radius, -LOD_WAVE_MARGIN - drop, center.z - radius), Vector3(2.0 * radius, 2.0 * LOD_WAVE_MARGIN + drop, 2.0 * radius)))


## LOD_GRID x LOD_GRID quads; UV holds the lattice coordinates (0..LOD_GRID).
static func _create_grid_mesh() -> ArrayMesh:
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()
	for z in LOD_GRID + 1:
		for x in LOD_GRID + 1:
			vertices.push_back(Vector3(x, 0.0, z))
			normals.push_back(Vector3.UP)
			uvs.push_back(Vector2(x, z))
	for z in LOD_GRID:
		for x in LOD_GRID:
			var a := z * (LOD_GRID + 1) + x
			var b := a + 1
			var c := a + LOD_GRID + 1
			var d := c + 1
			indices.append_array([a, b, c, b, d, c])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	var grid_mesh := ArrayMesh.new()
	grid_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return grid_mesh


## Splits a node while it comes within the next finer level's range. A node may
## end up drawn at a finer level than its distance needs; its vertices are then
## fully morphed, which matches the coarser neighbours exactly.
##
## Runs for a few hundred nodes every frame, so it works on plain floats.
## plane_mask holds the frustum planes the node's bounds may still cross: a
## child's bounds lie inside its parent's, so planes the parent is fully inside
## are skipped for all its descendants.
func _select_node(origin_x : float, origin_z : float, size : float, level : int, plane_mask : int, owner_path : NodePath) -> void:
	var nearest_dx := clampf(_camera_x, origin_x, origin_x + size) - _camera_x
	var nearest_dz := clampf(_camera_z, origin_z, origin_z + size) - _camera_z
	var nearest_horizontal_squared := nearest_dx * nearest_dx + nearest_dz * nearest_dz
	if nearest_horizontal_squared > _radius_squared:
		return
	if plane_mask != 0:
		# Bounds lowered by the curvature between the node's nearest and farthest
		# points (the shader's earth_curvature_drop()).
		var farthest_x := maxf(absf(_camera_x - origin_x), absf(_camera_x - origin_x - size))
		var farthest_z := maxf(absf(_camera_z - origin_z), absf(_camera_z - origin_z - size))
		var min_x := origin_x - LOD_WAVE_MARGIN
		var max_x := origin_x + size + LOD_WAVE_MARGIN
		var min_y := _water_y - LOD_WAVE_MARGIN - (farthest_x * farthest_x + farthest_z * farthest_z) * 0.5 / OceanSystem.EARTH_RADIUS
		var max_y := _water_y + LOD_WAVE_MARGIN - nearest_horizontal_squared * 0.5 / OceanSystem.EARTH_RADIUS
		var min_z := origin_z - LOD_WAVE_MARGIN
		var max_z := origin_z + size + LOD_WAVE_MARGIN
		for plane in LOD_FRUSTUM_PLANES:
			if plane_mask & (1 << plane) == 0:
				continue
			var i := plane * 4
			var normal_x := _planes[i]
			var normal_y := _planes[i + 1]
			var normal_z := _planes[i + 2]
			var d := _planes[i + 3]
			# Planes point outward: the corner least along the normal is the
			# innermost, the one most along it the outermost.
			var innermost := normal_x * (max_x if normal_x < 0.0 else min_x) + normal_y * (max_y if normal_y < 0.0 else min_y) + normal_z * (max_z if normal_z < 0.0 else min_z)
			if innermost > d:
				return
			var outermost := normal_x * (min_x if normal_x < 0.0 else max_x) + normal_y * (min_y if normal_y < 0.0 else max_y) + normal_z * (min_z if normal_z < 0.0 else max_z)
			if outermost <= d:
				plane_mask &= ~(1 << plane)
	# The shader measures morph distances to the undisplaced vertex; this is the
	# nearest such point of the node, so it never overestimates them.
	if level > 0:
		var finer_range := _ranges[level - 1]
		if nearest_horizontal_squared + _height_squared < finer_range * finer_range:
			var half := size * 0.5
			_select_node(origin_x, origin_z, half, level - 1, plane_mask, owner_path)
			_select_node(origin_x + half, origin_z, half, level - 1, plane_mask, owner_path)
			_select_node(origin_x, origin_z + half, half, level - 1, plane_mask, owner_path)
			_select_node(origin_x + half, origin_z + half, half, level - 1, plane_mask, owner_path)
			return
	if _node_count >= MAX_LOD_NODES:
		# The rest of the frame's nodes are dropped (holes in the far water).
		if not _budget_reported:
			_budget_reported = true
			push_error("OceanSystem %s: more than %d LOD nodes needed; raise mesh_base_cell_size or lower the camera's far plane." % [owner_path, MAX_LOD_NODES])
		return
	var offset := _node_count * LOD_INSTANCE_FLOATS + 12
	_buffer[offset] = origin_x
	_buffer[offset + 1] = origin_z
	_buffer[offset + 2] = size / LOD_GRID
	_buffer[offset + 3] = level
	_node_count += 1


## The coarsest level whose range covers the radius.
func _get_top_level(radius : float) -> int:
	var base_range := LOD_RANGE_FACTOR * _cell_size * LOD_GRID
	var level := 0
	while base_range * float(1 << level) < radius and level < MAX_LOD_LEVELS - 1:
		level += 1
	return level
