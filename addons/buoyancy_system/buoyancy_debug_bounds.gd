@tool
class_name BuoyancyDebugBounds
extends MeshInstance3D
## Always-visible wire bounds for buoyancy demos/debugging.

@export var size := Vector3.ONE :
	set(value):
		size = Vector3(maxf(value.x, 0.001), maxf(value.y, 0.001), maxf(value.z, 0.001))
		_rebuild_mesh()

@export var color := Color(1.0, 0.85, 0.15, 1.0) :
	set(value):
		color = value
		_update_material()


func _ready() -> void:
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	extra_cull_margin = 10000.0
	_rebuild_mesh()
	_update_material()


func _rebuild_mesh() -> void:
	var half := size * 0.5
	var corners := [
		Vector3(-half.x, -half.y, -half.z),
		Vector3( half.x, -half.y, -half.z),
		Vector3( half.x, -half.y,  half.z),
		Vector3(-half.x, -half.y,  half.z),
		Vector3(-half.x,  half.y, -half.z),
		Vector3( half.x,  half.y, -half.z),
		Vector3( half.x,  half.y,  half.z),
		Vector3(-half.x,  half.y,  half.z),
	]
	var edges := [
		Vector2i(0, 1), Vector2i(1, 2), Vector2i(2, 3), Vector2i(3, 0),
		Vector2i(4, 5), Vector2i(5, 6), Vector2i(6, 7), Vector2i(7, 4),
		Vector2i(0, 4), Vector2i(1, 5), Vector2i(2, 6), Vector2i(3, 7),
	]

	var immediate := ImmediateMesh.new()
	immediate.surface_begin(Mesh.PRIMITIVE_LINES)
	for edge in edges:
		immediate.surface_add_vertex(corners[edge.x])
		immediate.surface_add_vertex(corners[edge.y])
	immediate.surface_end()
	mesh = immediate


func _update_material() -> void:
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = color
	material.no_depth_test = true
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material_override = material
