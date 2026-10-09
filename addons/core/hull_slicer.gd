class_name HullSlicer
extends RefCounted
## Editor-time mesh helpers for hull baking: gathers triangles from mesh
## instances and slices them with horizontal planes.

const EPSILON := 0.0001


## Every MeshInstance3D in root's subtree, root included.
static func collect_mesh_instances(root : Node) -> Array[MeshInstance3D]:
	var results : Array[MeshInstance3D] = []
	if root is MeshInstance3D:
		results.push_back(root)
	for child in root.get_children():
		results.append_array(collect_mesh_instances(child))
	return results


## All triangles of the given mesh instances, three vertices per triangle,
## transformed from world space by world_to_target (e.g. a node's
## global_transform.affine_inverse()).
static func collect_triangles(mesh_instances : Array[MeshInstance3D], world_to_target : Transform3D) -> PackedVector3Array:
	var triangles := PackedVector3Array()
	for mesh_instance in mesh_instances:
		var mesh := mesh_instance.mesh
		# An empty MeshInstance3D has no geometry to contribute.
		if mesh == null:
			continue
		var to_target := world_to_target * mesh_instance.global_transform
		for surface_index in mesh.get_surface_count():
			if mesh.surface_get_primitive_type(surface_index) != Mesh.PRIMITIVE_TRIANGLES:
				continue
			var arrays := mesh.surface_get_arrays(surface_index)
			var vertices : PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var indices : PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
			if indices.is_empty():
				for i in range(0, vertices.size() - 2, 3):
					triangles.push_back(to_target * vertices[i])
					triangles.push_back(to_target * vertices[i + 1])
					triangles.push_back(to_target * vertices[i + 2])
			else:
				for i in range(0, indices.size() - 2, 3):
					triangles.push_back(to_target * vertices[indices[i]])
					triangles.push_back(to_target * vertices[indices[i + 1]])
					triangles.push_back(to_target * vertices[indices[i + 2]])
	return triangles


## Intersects triangles with the plane y = height. Returns XZ segments as
## consecutive point pairs (a0, b0, a1, b1, ...).
static func slice(triangles : PackedVector3Array, height : float) -> PackedVector2Array:
	var segments := PackedVector2Array()
	for i in range(0, triangles.size() - 2, 3):
		var a := triangles[i]
		var b := triangles[i + 1]
		var c := triangles[i + 2]
		if minf(a.y, minf(b.y, c.y)) > height + EPSILON or maxf(a.y, maxf(b.y, c.y)) < height - EPSILON:
			continue
		var points : Array[Vector3] = []
		_add_edge_intersections(points, a, b, height)
		_add_edge_intersections(points, b, c, height)
		_add_edge_intersections(points, c, a, height)
		if points.size() < 2:
			continue
		var pair := _get_farthest_point_pair(points)
		if pair[0].distance_squared_to(pair[1]) <= EPSILON * EPSILON:
			continue
		segments.push_back(Vector2(pair[0].x, pair[0].z))
		segments.push_back(Vector2(pair[1].x, pair[1].z))
	return segments


static func _add_edge_intersections(points : Array[Vector3], a : Vector3, b : Vector3, height : float) -> void:
	var da := a.y - height
	var db := b.y - height
	if absf(da) <= EPSILON and absf(db) <= EPSILON:
		points.push_back(a)
		points.push_back(b)
		return
	if absf(da) <= EPSILON:
		points.push_back(a)
		return
	if absf(db) <= EPSILON:
		points.push_back(b)
		return
	if da * db > 0.0:
		return
	points.push_back(a.lerp(b, clampf(da / (da - db), 0.0, 1.0)))


static func _get_farthest_point_pair(points : Array[Vector3]) -> Array[Vector3]:
	var best_a := points[0]
	var best_b := points[1]
	var best_distance := best_a.distance_squared_to(best_b)
	for i in points.size():
		for j in range(i + 1, points.size()):
			var distance := points[i].distance_squared_to(points[j])
			if distance > best_distance:
				best_distance = distance
				best_a = points[i]
				best_b = points[j]
	return [best_a, best_b]
