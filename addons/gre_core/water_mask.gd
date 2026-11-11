@tool
class_name GREWaterMask
extends MeshInstance3D
## Keeps the water out of an open hull: an invisible lid over the hull's opening, and
## the water does not draw behind it (the lid marks those pixels in the stencil buffer
## with STENCIL_REFERENCE, which the water skips). Screen space, so a hull that widens
## above the waterline keeps the water around it.
##
## Place it on the hull, level, between the waterline and the gunwale (just below the
## gunwale is best: waves inside the hull above the lid still show), set hull_path and
## press Fit to Hull: the lid becomes the inside of the hull's outline at that height.
## Or set mesh to a flat lid of your own (local y = 0). The lid hides water only while
## the camera is above it. The editor shows it tinted.

## The stencil value the lid writes; the water skips pixels that hold it (stencil_mode
## in the water shaders: change both together).
const STENCIL_REFERENCE := 128
## Render priority of the lid: before the water's (mat_water.tres, -20) and the
## underwater view's (-21).
const RENDER_PRIORITY := -30
const _SHADER := preload("res://addons/gre_core/water_mask.gdshader")

## The hull's mesh for Fit to Hull: a MeshInstance3D, or any node whose MeshInstance3D
## descendants make up the hull (an imported model).
@export var hull_path : NodePath :
	set(value):
		hull_path = value
		update_configuration_warnings()
## How far (m) Fit to Hull pushes the lid's edge out into the hull's walls, so no water
## shows along them. Keep it below the walls' thickness; 0 for a hull of single faces.
@export_range(0.0, 0.2, 0.001, "or_greater", "suffix:m") var edge_margin := 0.02
## Slices the hull at this node's height and makes mesh the inside of its outline.
@export_tool_button("Fit to Hull", "MeshInstance3D") var fit_to_hull_action := fit_to_hull

static var _runtime_material : ShaderMaterial
static var _preview_material : ShaderMaterial


func _ready() -> void:
	var instance := get_instance()
	RenderingServer.instance_geometry_set_material_override(instance, _get_material(Engine.is_editor_hint()).get_rid())
	RenderingServer.instance_geometry_set_cast_shadows_setting(instance, RenderingServer.SHADOW_CASTING_SETTING_OFF)
	if not Engine.is_editor_hint() and mesh == null:
		push_error("GREWaterMask %s: no lid mesh (press Fit to Hull in the editor, or set mesh); water still shows in the hull." % get_path())


func _get_configuration_warnings() -> PackedStringArray:
	var warnings := PackedStringArray()
	if mesh == null:
		warnings.push_back("No lid yet: set hull_path and press Fit to Hull, or set mesh to a flat lid (local y = 0).")
	if not hull_path.is_empty() and get_node_or_null(hull_path) == null:
		warnings.push_back("hull_path does not point to a node.")
	if material_override != null:
		warnings.push_back("material_override is ignored: the lid draws with its own stencil material.")
	return warnings


## Makes mesh the lid: slices the meshes of hull_path at this node's local y = 0 and
## covers the inside of the hull's outline there, grown by edge_margin. With two skins
## (outer and inner) it covers the inner one; loops of seats or oars inside or outside
## it are ignored. Reports and keeps the old mesh when the slice has no closed outline.
func fit_to_hull() -> void:
	var hull := get_node_or_null(hull_path)
	if hull == null:
		push_error("GREWaterMask %s: hull_path does not point to a node." % get_path())
		return
	var loops := _slice_loops(hull)
	if loops.is_empty():
		push_error("GREWaterMask %s: the hull has no closed outline at this height; move the mask between the waterline and the gunwale." % get_path())
		return
	var outline := _pick_opening(loops)
	# Skins that cross (a solidified hull pinched to a point at bow and stern) slice into thin
	# bands along each wall, none around the opening. The slice's convex outline covers it
	# instead; it already reaches the outer skin, so it is not grown.
	var points := PackedVector2Array()
	for loop in loops:
		points.append_array(loop)
	var convex := Geometry2D.convex_hull(points)
	var crossed := _area(outline) < 0.5 * _area(convex)
	if crossed:
		outline = convex
		outline.remove_at(outline.size() - 1)  # convex_hull() repeats its first point
	if edge_margin > 0.0 and not crossed:
		var grown := Geometry2D.offset_polygon(outline, edge_margin)
		if not grown.is_empty():
			outline = grown[0]
	var indices := Geometry2D.triangulate_polygon(outline)
	if indices.is_empty():
		push_error("GREWaterMask %s: the hull's outline could not be triangulated." % get_path())
		return
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	for point in outline:
		vertices.push_back(Vector3(point.x, 0.0, point.y))
		normals.push_back(Vector3.UP)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_INDEX] = indices
	var lid := ArrayMesh.new()
	lid.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh = lid
	update_configuration_warnings()


static func _get_material(preview : bool) -> ShaderMaterial:
	if preview and _preview_material == null:
		_preview_material = _create_material(true)
	elif not preview and _runtime_material == null:
		_runtime_material = _create_material(false)
	return _preview_material if preview else _runtime_material


static func _create_material(preview : bool) -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = _SHADER
	material.render_priority = RENDER_PRIORITY
	material.set_shader_parameter(&"preview", preview)
	return material


## The closed loops (this node's x, z) where the hull's triangles cross its y = 0 plane.
func _slice_loops(hull : Node) -> Array[PackedVector2Array]:
	var to_mask_space := global_transform.affine_inverse()
	var meshes : Array[MeshInstance3D] = []
	if hull is MeshInstance3D:
		meshes.push_back(hull)
	for child in hull.find_children("*", "MeshInstance3D", true, false):
		meshes.push_back(child)
	# Segment ends are matched by position, rounded to a tenth of a millimetre.
	var neighbours := {}  # Vector2i key -> Array of keys
	var positions := {}   # Vector2i key -> Vector2
	for mesh_instance in meshes:
		if mesh_instance.mesh == null:
			continue
		var to_mask := to_mask_space * mesh_instance.global_transform
		for surface in mesh_instance.mesh.get_surface_count():
			if mesh_instance.mesh.surface_get_primitive_type(surface) != Mesh.PRIMITIVE_TRIANGLES:
				continue
			var arrays := mesh_instance.mesh.surface_get_arrays(surface)
			var source : PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var points := PackedVector3Array()
			points.resize(source.size())
			for i in source.size():
				points[i] = to_mask * source[i]
			var indices : PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
			var count := indices.size() if not indices.is_empty() else points.size()
			for t in range(0, count - 2, 3):
				var a := points[indices[t] if not indices.is_empty() else t]
				var b := points[indices[t + 1] if not indices.is_empty() else t + 1]
				var c := points[indices[t + 2] if not indices.is_empty() else t + 2]
				var crossings := PackedVector2Array()
				for edge in [[a, b], [b, c], [c, a]]:
					var p : Vector3 = edge[0]
					var q : Vector3 = edge[1]
					if (p.y < 0.0) != (q.y < 0.0):
						var s := p.y / (p.y - q.y)
						crossings.push_back(Vector2(lerpf(p.x, q.x, s), lerpf(p.z, q.z, s)))
				if crossings.size() != 2:
					continue
				var key_a := Vector2i((crossings[0] * 10000.0).round())
				var key_b := Vector2i((crossings[1] * 10000.0).round())
				if key_a == key_b:
					continue
				positions[key_a] = crossings[0]
				positions[key_b] = crossings[1]
				neighbours.get_or_add(key_a, []).push_back(key_b)
				neighbours.get_or_add(key_b, []).push_back(key_a)
	# Walk the segments into loops; chains that do not close (holes in the mesh) are dropped.
	var loops : Array[PackedVector2Array] = []
	var visited := {}
	for start : Vector2i in neighbours:
		if visited.has(start):
			continue
		var loop := PackedVector2Array()
		var previous := start
		var current := start
		var closed := false
		while true:
			visited[current] = true
			loop.push_back(positions[current])
			var next := previous
			for candidate : Vector2i in neighbours[current]:
				if candidate != previous and (not visited.has(candidate) or (candidate == start and loop.size() > 2)):
					next = candidate
					break
			if next == start:
				closed = true
				break
			if next == previous or visited.has(next):
				break
			previous = current
			current = next
		if closed and loop.size() >= 3:
			loops.push_back(loop)
	return loops


## The hull's opening among the loops: the largest loop inside the outermost one that
## covers at least half its area (the inner skin), else the outermost loop itself.
func _pick_opening(loops : Array[PackedVector2Array]) -> PackedVector2Array:
	var outer := loops[0]
	for loop in loops:
		if _area(loop) > _area(outer):
			outer = loop
	var opening := outer
	var opening_area := 0.0
	for loop in loops:
		if loop == outer:
			continue
		var area := _area(loop)
		if area >= 0.5 * _area(outer) and area > opening_area and Geometry2D.is_point_in_polygon(loop[0], outer):
			opening = loop
			opening_area = area
	return opening


static func _area(loop : PackedVector2Array) -> float:
	var twice := 0.0
	for i in loop.size():
		var p := loop[i]
		var q := loop[(i + 1) % loop.size()]
		twice += p.x * q.y - q.x * p.y
	return absf(twice) * 0.5
