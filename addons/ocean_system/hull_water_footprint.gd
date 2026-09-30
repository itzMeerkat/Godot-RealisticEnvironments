@tool
class_name HullWaterFootprint
extends Node3D
## Tells OceanSystem where a hull is. Place it rigidly on the ship (usually as a
## direct child of the body) and bake a HullProfile from the hull meshes. The
## ocean hides water inside the hull for ships near the camera, and the hull
## pushes water in the interaction simulation (wakes).
##
## A footprint without a profile contributes nothing; it reports a
## configuration warning in the editor and an error at runtime.

const PROFILE_SUFFIX := "_hull_profile.tres"

## Baked hull shape in this node's local space.
@export var profile : HullProfile :
	set(value):
		profile = value
		update_configuration_warnings()

@export_group("Cutout")
## Hides water inside the hull when this ship is near the camera.
@export var cutout_enabled := true
## Width in meters of the foam band just outside the hull where water meets it.
@export_range(0.0, 4.0, 0.01, "or_greater") var cutout_feather := 0.6
## Foam strength of that band. Hides the hard edge of the cutout.
@export_range(0.0, 1.0, 0.01) var cutout_edge_foam := 0.6

@export_group("Wake")
## Pushes water in the interaction simulation: moving, heaving or rolling
## hulls radiate waves (Kelvin wake, bow wave). A hull at rest makes none.
@export var wake_enabled := true
## Scales the hull's pressure head (its draft below the wave surface). 1 is the
## physical draft; lower it for smaller wakes.
@export_range(0.0, 4.0, 0.01, "or_greater") var wake_strength := 1.0
## Distance inside the waterline over which the pressure fades in, in meters.
## Softer edges avoid short-wavelength ringing around the hull.
@export_range(0.0, 10.0, 0.01, "or_greater") var wake_edge_softness := 0.75

@export_group("Bake")
## Hull mesh roots to bake from. Use only the hull (no masts, sails or rigging):
## anything included widens the cutout.
@export var bake_source_paths : Array[NodePath] = []
## Shrinks the baked half-widths so the cutout stays inside the hull shell.
@export_range(0.0, 2.0, 0.01, "or_greater") var bake_inset := 0.08
## Editor action: bakes the profile from bake_source_paths and saves it as
## <scene>_hull_profile.tres next to the edited scene (or over the current profile file).
@export var editor_bake_profile := false :
	set(value):
		if value:
			bake_profile()


func _enter_tree() -> void:
	add_to_group(&"ocean_hull")


func _exit_tree() -> void:
	remove_from_group(&"ocean_hull")


func _ready() -> void:
	if profile == null and not Engine.is_editor_hint():
		push_error("HullWaterFootprint %s has no HullProfile; bake one in the editor." % get_path())


func _get_configuration_warnings() -> PackedStringArray:
	if profile == null:
		return PackedStringArray(["No HullProfile. Set bake_source_paths to the hull meshes and toggle Editor Bake Profile."])
	return PackedStringArray()


## World-space bounding sphere of the profile: xyz = center, w = radius.
func get_world_bounding_sphere() -> Vector4:
	var bounds := profile.get_local_bounds()
	var center := global_transform * bounds.get_center()
	var scale := global_transform.basis.get_scale()
	var radius := bounds.size.length() * 0.5 * maxf(scale.x, maxf(scale.y, scale.z))
	return Vector4(center.x, center.y, center.z, radius)


func bake_profile() -> void:
	assert(Engine.is_editor_hint(), "Hull profiles can only be baked in the editor.")
	if bake_source_paths.is_empty():
		push_error("HullWaterFootprint %s: set bake_source_paths to the hull meshes before baking." % get_path())
		return
	var mesh_instances : Array[MeshInstance3D] = []
	for path in bake_source_paths:
		mesh_instances.append_array(HullSlicer.collect_mesh_instances(get_node(path)))
	if mesh_instances.is_empty():
		push_error("HullWaterFootprint %s: bake_source_paths contain no MeshInstance3D." % get_path())
		return

	var start_usec := Time.get_ticks_usec()
	var triangles := HullSlicer.collect_triangles(mesh_instances, global_transform.affine_inverse())
	var baked := HullProfile.build(triangles, bake_inset)
	var path := _get_profile_save_path()
	baked.take_over_path(path)
	var error := ResourceSaver.save(baked, path)
	assert(error == OK, "Saving %s failed: %s" % [path, error_string(error)])
	profile = baked
	Engine.get_singleton(&"EditorInterface").get_resource_filesystem().update_file(path)
	print("HullWaterFootprint baked %d triangles into %s in %.1f ms. Save the scene to keep the reference." % [
		triangles.size() / 3, path, float(Time.get_ticks_usec() - start_usec) / 1000.0])


func _get_profile_save_path() -> String:
	if profile != null and profile.resource_path.begins_with("res://") and not profile.resource_path.contains("::"):
		return profile.resource_path
	var scene_path := get_tree().edited_scene_root.scene_file_path
	assert(not scene_path.is_empty(), "Save the scene before baking a hull profile.")
	return scene_path.get_basename() + PROFILE_SUFFIX
