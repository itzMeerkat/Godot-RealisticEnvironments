@tool
class_name FarOcean
extends MeshInstance3D

const MAX_CASCADES := 8

@export_range(32.0, 2000.0, 1.0) var inner_radius := 150.0 :
	set(value):
		inner_radius = value
		_update_mesh()
		_update_material_parameters()
@export_range(128.0, 20000.0, 1.0, "or_greater") var outer_radius := 7000.0 :
	set(value):
		outer_radius = value
		_update_mesh()
		_update_material_parameters()
@export_range(8, 256, 1) var radial_segments := 128 :
	set(value):
		radial_segments = value
		_update_mesh()
@export_range(1, 64, 1) var ring_segments := 18 :
	set(value):
		ring_segments = value
		_update_mesh()
@export_range(0.0, 1000.0, 1.0) var inner_fade_width := 96.0 :
	set(value):
		inner_fade_width = value
		_update_material_parameters()
@export_range(256.0, 20000.0, 1.0, "or_greater") var horizon_fade_start := 5200.0 :
	set(value):
		horizon_fade_start = value
		_update_material_parameters()
@export_range(256.0, 20000.0, 1.0, "or_greater") var horizon_fade_end := 6800.0 :
	set(value):
		horizon_fade_end = value
		_update_material_parameters()
@export_group("Surface")
@export_range(0.0, 4.0, 0.01) var displacement_strength := 1.0 :
	set(value):
		displacement_strength = value
		_update_material_parameters()
@export_range(0.0, 2.0, 0.01) var normal_strength := 0.42 :
	set(value):
		normal_strength = value
		_update_material_parameters()
@export_range(0.0, 1.0, 0.01) var roughness := 0.65 :
	set(value):
		roughness = value
		_update_material_parameters()
@export_range(0.0, 1.0, 0.01) var horizon_brightness := 0.04 :
	set(value):
		horizon_brightness = value
		_update_material_parameters()
@export_range(0.0, 1.0, 0.01) var specular_strength := 0.55 :
	set(value):
		specular_strength = value
		_update_material_parameters()
@export_group("Distance LOD")
@export_range(1.0, 512.0, 1.0) var low_frequency_tile_length := 64.0 :
	set(value):
		low_frequency_tile_length = value
		_update_material_parameters()
@export_range(1.0, 4000.0, 1.0) var lod_blend_distance := 1200.0 :
	set(value):
		lod_blend_distance = value
		_update_material_parameters()
@export_range(0.25, 4.0, 0.01) var lod_curve := 1.7 :
	set(value):
		lod_curve = value
		_update_material_parameters()
@export_range(0.0, 1.0, 0.01) var far_swell_visibility := 0.52 :
	set(value):
		far_swell_visibility = value
		_update_material_parameters()
@export_range(0.0, 1.0, 0.01) var far_wave_contrast := 0.28 :
	set(value):
		far_wave_contrast = value
		_update_material_parameters()
@export_range(0.0, 1.0, 0.01) var far_foam_coverage := 0.36 :
	set(value):
		far_foam_coverage = value
		_update_material_parameters()
@export_range(0.0, 1.0, 0.01) var far_foam_threshold_boost := 0.18 :
	set(value):
		far_foam_threshold_boost = value
		_update_material_parameters()
@export_group("Ocean State Link")
@export var ocean_path : NodePath :
	set(value):
		ocean_path = value
		_ocean = null
		_sync_linked_radius(true)
		_update_ocean_state()
@export var link_ocean_radius := true :
	set(value):
		link_ocean_radius = value
		_sync_linked_radius(true)
@export_range(0.0, 1000.0, 1.0) var ocean_overlap := 96.0 :
	set(value):
		ocean_overlap = value
		_sync_linked_radius(true)
@export var use_ocean_state := true :
	set(value):
		use_ocean_state = value
		_update_ocean_state()
@export_range(0.1, 60.0, 0.1, "or_greater") var reference_wind_speed := 15.0 :
	set(value):
		reference_wind_speed = value
		_update_ocean_state()
@export_range(0.0, 3.0, 0.01) var sea_state_influence := 1.0 :
	set(value):
		sea_state_influence = value
		_update_material_parameters()
@export_range(0.0, 2.0, 0.01) var manual_sea_state := 0.0 :
	set(value):
		manual_sea_state = value
		_update_material_parameters()

var _ocean : Node
var _resolved_sea_state := 0.0
var _effective_inner_radius := 150.0


func _ready() -> void:
	process_priority = 110
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_resolve_ocean()
	_sync_ocean_position()
	_sync_linked_radius(true)
	_update_ocean_state()
	_update_mesh()
	_update_material_parameters()


func _process(_delta : float) -> void:
	_sync_ocean_position()
	_sync_linked_radius()
	_update_ocean_state()


func _sync_ocean_position() -> void:
	var ocean := _get_ocean()
	if ocean == null:
		return

	var target_position := global_position
	target_position.x = ocean.global_position.x
	target_position.z = ocean.global_position.z
	global_position = target_position


func _update_mesh() -> void:
	if not is_inside_tree():
		return
	mesh = _create_ring_mesh()


func _create_ring_mesh() -> ArrayMesh:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)

	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()

	var safe_inner := maxf(_get_effective_inner_radius(), 1.0)
	var safe_outer := maxf(outer_radius, safe_inner + 1.0)
	var ring_count := maxi(1, ring_segments)
	var segment_count := maxi(8, radial_segments)

	for ring in range(ring_count + 1):
		var t := float(ring) / float(ring_count)
		var eased_t := t * t
		var radius := lerpf(safe_inner, safe_outer, eased_t)
		for segment in range(segment_count):
			var angle := TAU * float(segment) / float(segment_count)
			var position := Vector3(cos(angle) * radius, 0.0, sin(angle) * radius)
			vertices.push_back(position)
			normals.push_back(Vector3.UP)
			uvs.push_back(Vector2(position.x, position.z))
			colors.push_back(Color(t, 0.0, 0.0, 1.0))

	for ring in range(ring_count):
		var row := ring * segment_count
		var next_row := (ring + 1) * segment_count
		for segment in range(segment_count):
			var next_segment := (segment + 1) % segment_count
			var a := row + segment
			var b := row + next_segment
			var c := next_row + segment
			var d := next_row + next_segment
			indices.push_back(a)
			indices.push_back(b)
			indices.push_back(c)
			indices.push_back(b)
			indices.push_back(d)
			indices.push_back(c)

	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = indices

	var array_mesh := ArrayMesh.new()
	array_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return array_mesh


func _update_material_parameters() -> void:
	var shader_material := material_override as ShaderMaterial
	if shader_material == null:
		return
	shader_material.set_shader_parameter(&"inner_radius", _get_effective_inner_radius())
	shader_material.set_shader_parameter(&"inner_fade_width", inner_fade_width)
	shader_material.set_shader_parameter(&"horizon_fade_start", horizon_fade_start)
	shader_material.set_shader_parameter(&"horizon_fade_end", horizon_fade_end)
	shader_material.set_shader_parameter(&"displacement_strength", displacement_strength)
	shader_material.set_shader_parameter(&"normal_strength", normal_strength)
	shader_material.set_shader_parameter(&"roughness", roughness)
	shader_material.set_shader_parameter(&"horizon_brightness", horizon_brightness)
	shader_material.set_shader_parameter(&"specular_strength", specular_strength)
	shader_material.set_shader_parameter(&"low_frequency_tile_length", low_frequency_tile_length)
	shader_material.set_shader_parameter(&"lod_blend_distance", lod_blend_distance)
	shader_material.set_shader_parameter(&"lod_curve", lod_curve)
	shader_material.set_shader_parameter(&"far_swell_visibility", far_swell_visibility)
	shader_material.set_shader_parameter(&"far_wave_contrast", far_wave_contrast)
	shader_material.set_shader_parameter(&"far_foam_coverage", far_foam_coverage)
	shader_material.set_shader_parameter(&"far_foam_threshold_boost", far_foam_threshold_boost)
	shader_material.set_shader_parameter(&"sea_state", _get_effective_sea_state())
	shader_material.set_shader_parameter(&"sea_state_influence", sea_state_influence)
	_sync_ocean_material_parameters(shader_material)


func _update_ocean_state() -> void:
	_resolved_sea_state = _sample_ocean_sea_state() if use_ocean_state else manual_sea_state
	_update_material_parameters()


func _sample_ocean_sea_state() -> float:
	var ocean := _get_ocean()
	if ocean == null:
		return manual_sea_state

	var wind_speed := 0.0
	if ocean.has_method(&"should_use_external_wind") and bool(ocean.call(&"should_use_external_wind")) and ocean.has_method(&"get_external_wind_speed"):
		wind_speed = float(ocean.call(&"get_external_wind_speed"))
	else:
		wind_speed = _estimate_ocean_wind_speed(ocean)

	var displacement_factor := _estimate_ocean_displacement_factor(ocean)
	var wind_factor := wind_speed / maxf(reference_wind_speed, 0.001)
	return clampf(wind_factor * 0.75 + displacement_factor * 0.25, 0.0, 2.0)


func _estimate_ocean_wind_speed(ocean : Node) -> float:
	var params = ocean.get(&"parameters")
	if params == null:
		return 0.0

	var total := 0.0
	var count := 0
	for param in params:
		if param == null:
			continue
		var wind_speed_value = param.get(&"wind_speed")
		var wind_multiplier_value = param.get(&"wind_speed_multiplier")
		var wind_speed := 0.0 if wind_speed_value == null else float(wind_speed_value)
		var wind_multiplier := 1.0 if wind_multiplier_value == null else float(wind_multiplier_value)
		total += wind_speed * wind_multiplier
		count += 1
	return 0.0 if count == 0 else total / float(count)


func _estimate_ocean_displacement_factor(ocean : Node) -> float:
	var params = ocean.get(&"parameters")
	if params == null:
		return 0.0

	var total := 0.0
	var count := 0
	for param in params:
		if param == null:
			continue
		var displacement_value = param.get(&"displacement_scale")
		total += 1.0 if displacement_value == null else float(displacement_value)
		count += 1
	return 0.0 if count == 0 else total / float(count)


func _sync_ocean_material_parameters(shader_material : ShaderMaterial) -> void:
	var map_scales := PackedVector4Array()
	map_scales.resize(MAX_CASCADES)

	var ocean := _get_ocean()
	if ocean == null:
		shader_material.set_shader_parameter(&"map_scales", map_scales)
		return

	var params = ocean.get(&"parameters")
	if params != null:
		for i in mini(params.size(), MAX_CASCADES):
			var param = params[i]
			if param == null:
				continue
			var tile_length_value = param.get(&"tile_length")
			var displacement_scale_value = param.get(&"displacement_scale")
			var normal_scale_value = param.get(&"normal_scale")
			var tile_length := Vector2.ONE
			if tile_length_value is Vector2:
				tile_length = tile_length_value
			elif tile_length_value is Vector2i:
				tile_length = Vector2(tile_length_value)
			var displacement_scale := 0.0 if displacement_scale_value == null else float(displacement_scale_value)
			var normal_scale := 0.0 if normal_scale_value == null else float(normal_scale_value)
			tile_length.x = maxf(tile_length.x, 0.001)
			tile_length.y = maxf(tile_length.y, 0.001)
			var uv_scale := Vector2.ONE / tile_length
			map_scales[i] = Vector4(uv_scale.x, uv_scale.y, displacement_scale, normal_scale)
	shader_material.set_shader_parameter(&"map_scales", map_scales)

	var foam_intensity_value = ocean.get(&"foam_intensity")
	var foam_threshold_value = ocean.get(&"foam_threshold")
	var foam_softness_value = ocean.get(&"foam_softness")
	if foam_intensity_value != null:
		shader_material.set_shader_parameter(&"foam_intensity", float(foam_intensity_value))
	if foam_threshold_value != null:
		shader_material.set_shader_parameter(&"foam_threshold", float(foam_threshold_value))
	if foam_softness_value != null:
		shader_material.set_shader_parameter(&"foam_softness", float(foam_softness_value))


func _get_ocean() -> Node:
	if _ocean == null:
		_resolve_ocean()
	return _ocean


func _resolve_ocean() -> void:
	if ocean_path.is_empty() or not is_inside_tree():
		return
	_ocean = get_node_or_null(ocean_path)


func _get_effective_sea_state() -> float:
	return _resolved_sea_state if use_ocean_state else manual_sea_state


func _sync_linked_radius(force_update := false) -> void:
	var next_inner_radius := _get_linked_inner_radius()
	if not force_update and is_equal_approx(next_inner_radius, _effective_inner_radius):
		return
	_effective_inner_radius = next_inner_radius
	_update_mesh()
	_update_material_parameters()


func _get_linked_inner_radius() -> float:
	if not link_ocean_radius:
		return inner_radius
	var ocean := _get_ocean()
	if ocean == null:
		return inner_radius
	var radius := 0.0
	if ocean.has_method(&"get_ocean_radius"):
		radius = float(ocean.call(&"get_ocean_radius"))
	else:
		var value = ocean.get(&"ocean_radius")
		radius = inner_radius if value == null else float(value)
	return maxf(1.0, radius - ocean_overlap)


func _get_effective_inner_radius() -> float:
	return _effective_inner_radius if link_ocean_radius else inner_radius
