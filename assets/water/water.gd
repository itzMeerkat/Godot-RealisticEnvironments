@tool
class_name OceanSystem
extends MeshInstance3D
## Handles updating the displacement/normal maps for the water material as well as
## managing wave generation pipelines.

const WATER_MAT := preload('res://assets/water/mat_water.tres')
const SPRAY_MAT := preload('res://assets/water/mat_spray.tres')
const WATER_MESH_HIGH_PATH := 'res://assets/water/clipmap_high.obj'
const WATER_MESH_LOW_PATH := 'res://assets/water/clipmap_low.obj'

enum MeshQuality { LOW, HIGH }

@export_group('Wave Parameters')
@export_color_no_alpha var water_color : Color = Color(0.1, 0.15, 0.18) :
	set(value): water_color = value; RenderingServer.global_shader_parameter_set(&'water_color', water_color.srgb_to_linear())

@export_color_no_alpha var foam_color : Color = Color(0.73, 0.67, 0.62) :
	set(value): foam_color = value; RenderingServer.global_shader_parameter_set(&'foam_color', foam_color.srgb_to_linear())

## The parameters for wave cascades. Each parameter set represents one cascade.
## Recreates all compute piplines whenever a cascade is added or removed!
@export var parameters : Array[WaveCascadeParameters] :
	set(value):
		var new_size := len(value)
		# All below logic is basically just required for using in the editor!
		for i in range(new_size):
			# Ensure all values in the array have an associated cascade
			if not value[i]: value[i] = WaveCascadeParameters.new()
			if not value[i].is_connected(&'scale_changed', _update_scales_uniform):
				value[i].scale_changed.connect(_update_scales_uniform)
			value[i].spectrum_seed = Vector2i(rng.randi_range(-10000, 10000), rng.randi_range(-10000, 10000))
			value[i].time = 120.0 + PI*i # We make sure to choose a time offset such that cascades don't interfere!
		parameters = value
		_setup_wave_generator()
		_update_scales_uniform()

@export_group('Performance Parameters')
@export_enum('128x128:128', '256x256:256', '512x512:512', '1024x1024:1024') var map_size := 1024 :
	set(value):
		map_size = value
		_clear_height_cache()
		_setup_wave_generator()

@export var mesh_quality := MeshQuality.HIGH :
	set(value):
		mesh_quality = value
		_update_water_mesh()

@export_group('Generated Mesh')
@export var use_generated_mesh := true :
	set(value):
		use_generated_mesh = value
		_update_water_mesh()
## Generates the procedural mesh while editing. Keep this off when saving scenes
## to avoid serializing a large generated ArrayMesh into the .tscn file.
@export var preview_generated_mesh_in_editor := false :
	set(value):
		preview_generated_mesh_in_editor = value
		_update_water_mesh()
## Full side length of the highest-density center patch, in meters.
@export_range(16.0, 512.0, 1.0) var generated_inner_extent := 128.0 :
	set(value):
		generated_inner_extent = value
		_update_water_mesh()
@export_range(0.5, 16.0, 0.5) var generated_base_cell_size := 1.0 :
	set(value):
		generated_base_cell_size = value
		_update_water_mesh()
@export_range(0, 8, 1) var generated_ring_count := 2 :
	set(value):
		generated_ring_count = value
		_update_water_mesh()
@export_range(0.05, 1.0, 0.05) var generated_morph_width := 0.5 :
	set(value):
		generated_morph_width = value
		_update_water_mesh()
@export var follow_active_camera := true
@export_range(0.0, 64.0, 0.25) var follow_snap_size := 0.0
@export var follow_camera_in_editor := false

@export var sea_spray_enabled := true :
	set(value):
		sea_spray_enabled = value
		_update_sea_spray_visibility()

## How many times the wave simulation should update per second.
## Note: This doesn't reduce the frame stutter caused by FFT calculation, only
##       minimizes GPU time taken by it!
@export_range(0, 60) var updates_per_second := 20.0 :
	set(value):
		next_update_time = next_update_time - (1.0/(updates_per_second + 1e-10) - 1.0/(value + 1e-10))
		updates_per_second = value

@export_group('Water Queries')
## The still-water height in world units. Wave displacement is added on top.
@export var water_level := 0.0
## Enables a CPU-side height cache copied from the GPU displacement maps.
@export var enable_height_queries := false :
	set(value):
		enable_height_queries = value
		if not enable_height_queries:
			_clear_height_cache()
## How often the CPU-side height cache is refreshed. Querying cached heights is cheap;
## refreshing the cache can stall the GPU, so keep this lower than the render frame rate.
@export_range(0, 60) var height_query_updates_per_second := 5.0
@export_group('Visual Smoothing')
@export var smooth_wave_interpolation := true

var wave_generator : WaveGenerator :
	set(value):
		if wave_generator: wave_generator.queue_free()
		wave_generator = value
		add_child(wave_generator)
var rng = RandomNumberGenerator.new()
var time := 0.0
var next_update_time := 0.0

var displacement_maps := Texture2DArrayRD.new()
var normal_maps := Texture2DArrayRD.new()
var previous_displacement_maps := Texture2DArrayRD.new()
var previous_normal_maps := Texture2DArrayRD.new()
var _height_images : Array[Image] = []
var _previous_height_images : Array[Image] = []
var _next_height_query_update_time := 0.0
var _has_wave_output := false
var _last_wave_output_time := 0.0
var _wave_blend_start_time := 0.0
var _wave_blend_duration := 1.0 / 60.0

func _init() -> void:
	rng.set_seed(1234) # This seed gives big waves!

func _ready() -> void:
	process_priority = 100
	RenderingServer.global_shader_parameter_set(&'water_color', water_color.srgb_to_linear())
	RenderingServer.global_shader_parameter_set(&'foam_color', foam_color.srgb_to_linear())
	RenderingServer.global_shader_parameter_set(&'wave_blend_alpha', 1.0)
	_update_water_mesh()
	_update_sea_spray_visibility()

func _process(delta : float) -> void:
	_update_follow_camera()
	# Update waves once every 1.0/updates_per_second.
	if updates_per_second == 0 or time >= next_update_time:
		var target_update_delta := 1.0 / (updates_per_second + 1e-10)
		var update_delta := delta if updates_per_second == 0 else target_update_delta + (time - next_update_time)
		next_update_time = time + target_update_delta
		_update_water(update_delta)
	time += delta
	_update_wave_blend_alpha()

func _setup_wave_generator() -> void:
	if parameters.size() <= 0: return
	for param in parameters:
		param.should_generate_spectrum = true

	_clear_height_cache()
	wave_generator = WaveGenerator.new()
	wave_generator.map_size = map_size
	wave_generator.init_gpu(maxi(2, parameters.size())) # FIXME: This is needed because my RenderContext API sucks...
	wave_generator.output_maps_swapped.connect(_on_wave_output_maps_swapped)
	_has_wave_output = false

	_set_texture_rid(displacement_maps, wave_generator.descriptors[&'displacement_map'].rid)
	_set_texture_rid(normal_maps, wave_generator.descriptors[&'normal_map'].rid)
	_set_texture_rid(previous_displacement_maps, wave_generator.descriptors[&'previous_displacement_map'].rid)
	_set_texture_rid(previous_normal_maps, wave_generator.descriptors[&'previous_normal_map'].rid)

	RenderingServer.global_shader_parameter_set(&'num_cascades', parameters.size())
	RenderingServer.global_shader_parameter_set(&'displacements', displacement_maps)
	RenderingServer.global_shader_parameter_set(&'normals', normal_maps)
	RenderingServer.global_shader_parameter_set(&'previous_displacements', previous_displacement_maps)
	RenderingServer.global_shader_parameter_set(&'previous_normals', previous_normal_maps)
	RenderingServer.global_shader_parameter_set(&'wave_blend_alpha', 1.0)

func _update_scales_uniform() -> void:
	var map_scales : PackedVector4Array; map_scales.resize(len(parameters))
	for i in len(parameters):
		var params := parameters[i]
		var uv_scale := Vector2.ONE / params.tile_length
		map_scales[i] = Vector4(uv_scale.x, uv_scale.y, params.displacement_scale, params.normal_scale)
	# No global shader parameter for arrays :(
	_set_water_shader_parameter(&'map_scales', map_scales)
	SPRAY_MAT.set_shader_parameter(&'map_scales', map_scales)

func _update_water(delta : float) -> void:
	if wave_generator == null: _setup_wave_generator()
	wave_generator.update(delta, parameters)
	if enable_height_queries and (height_query_updates_per_second == 0 or time >= _next_height_query_update_time):
		var target_update_delta := 1.0 / (height_query_updates_per_second + 1e-10)
		_next_height_query_update_time = time + target_update_delta
		refresh_height_cache()

func get_water_height(world_position: Vector3) -> float:
	var t := _get_ocean_time()
	var height := water_level
	for i in mini(parameters.size(), _height_images.size()):
		height += _sample_wave_height(i, world_position, t)
	return height

func get_water_normal(world_position: Vector3) -> Vector3:
	var e := 0.25
	var h_l := get_water_height(world_position + Vector3(-e, 0, 0))
	var h_r := get_water_height(world_position + Vector3( e, 0, 0))
	var h_b := get_water_height(world_position + Vector3(0, 0, -e))
	var h_f := get_water_height(world_position + Vector3(0, 0,  e))
	return Vector3(h_l - h_r, 2.0 * e, h_b - h_f).normalized()

func refresh_height_cache() -> void:
	if not wave_generator or not wave_generator.context: return
	var displacement_rid : RID = wave_generator.descriptors[&'displacement_map'].rid
	if not displacement_rid.is_valid(): return

	_height_images.clear()
	var device := wave_generator.context.device
	_height_images = _read_height_images(device, displacement_rid)
	_previous_height_images = _read_height_images(device, wave_generator.descriptors[&'previous_displacement_map'].rid)

func _get_ocean_time() -> float:
	return time

func _sample_wave_height(cascade_index: int, world_position: Vector3, _ocean_time: float) -> float:
	if cascade_index >= _height_images.size(): return 0.0
	var image := _height_images[cascade_index]
	if image == null or image.is_empty(): return 0.0

	var params := parameters[cascade_index]
	var uv := Vector2(world_position.x / params.tile_length.x, world_position.z / params.tile_length.y)
	var displacement := _sample_image_bilinear(image, uv).g
	if cascade_index < _previous_height_images.size():
		var previous_image := _previous_height_images[cascade_index]
		if previous_image != null and not previous_image.is_empty():
			var previous_displacement := _sample_image_bilinear(previous_image, uv).g
			displacement = lerpf(previous_displacement, displacement, _get_wave_blend_alpha())
	return displacement * params.displacement_scale

func _sample_image_bilinear(image: Image, uv: Vector2) -> Color:
	var width := image.get_width()
	var height := image.get_height()
	if width <= 0 or height <= 0: return Color.BLACK

	var x := fposmod(uv.x, 1.0) * width
	var y := fposmod(uv.y, 1.0) * height
	var x0 := int(floor(x)) % width
	var y0 := int(floor(y)) % height
	var x1 := (x0 + 1) % width
	var y1 := (y0 + 1) % height
	var fx: float = x - floor(x)
	var fy : float = y - floor(y)

	var c00 := image.get_pixel(x0, y0)
	var c10 := image.get_pixel(x1, y0)
	var c01 := image.get_pixel(x0, y1)
	var c11 := image.get_pixel(x1, y1)
	return c00.lerp(c10, fx).lerp(c01.lerp(c11, fx), fy)

func _clear_height_cache() -> void:
	_height_images.clear()
	_previous_height_images.clear()
	_next_height_query_update_time = 0.0

func _update_sea_spray_visibility() -> void:
	var sea_spray := get_node_or_null(^"WaterSprayEmitter")
	if sea_spray:
		sea_spray.visible = sea_spray_enabled
		sea_spray.process_mode = Node.PROCESS_MODE_INHERIT if sea_spray_enabled else Node.PROCESS_MODE_DISABLED
		if sea_spray is GPUParticles3D:
			sea_spray.emitting = sea_spray_enabled

func _update_water_mesh() -> void:
	if Engine.is_editor_hint() and use_generated_mesh and not preview_generated_mesh_in_editor:
		mesh = null
		_set_water_shader_parameter(&'enable_geometry_morph', false)
		return

	if use_generated_mesh:
		mesh = _create_generated_clipmap_mesh()
		_set_water_shader_parameter(&'enable_geometry_morph', true)
		_set_water_shader_parameter(&'generated_clipmap_extent', _get_generated_mesh_half_extent())
	else:
		mesh = load(WATER_MESH_HIGH_PATH if mesh_quality == MeshQuality.HIGH else WATER_MESH_LOW_PATH)
		_set_water_shader_parameter(&'enable_geometry_morph', false)

func _update_follow_camera() -> void:
	if not follow_active_camera:
		return
	if Engine.is_editor_hint() and not follow_camera_in_editor:
		return
	var viewport := get_viewport()
	if viewport == null:
		return
	var camera := viewport.get_camera_3d()
	if camera == null:
		return

	var target_x := camera.global_position.x
	var target_z := camera.global_position.z
	if follow_snap_size > 0.0:
		target_x = roundf(target_x / follow_snap_size) * follow_snap_size
		target_z = roundf(target_z / follow_snap_size) * follow_snap_size

	var target_position := global_position
	target_position.x = target_x
	target_position.z = target_z
	global_position = target_position

func _create_generated_clipmap_mesh() -> ArrayMesh:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)

	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var uv2s := PackedVector2Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()

	var base_cell := generated_base_cell_size
	var inner_half := generated_inner_extent * 0.5
	_append_clipmap_grid(vertices, normals, uvs, uv2s, colors, indices, Rect2(Vector2(-inner_half, -inner_half), Vector2(generated_inner_extent, generated_inner_extent)), base_cell, 0.0, 1.0, false)

	for ring in range(generated_ring_count):
		var ring_inner_half := inner_half * pow(2.0, ring)
		var ring_outer_half := inner_half * pow(2.0, ring + 1)
		var cell_size := base_cell * pow(2.0, ring + 1)
		var ring_width := ring_outer_half - ring_inner_half
		var morph_width := maxf(ring_width * generated_morph_width, cell_size)
		var morph_start := maxf(ring_inner_half, ring_outer_half - morph_width)
		var morph_end := ring_outer_half

		_append_clipmap_grid(vertices, normals, uvs, uv2s, colors, indices, Rect2(Vector2(-ring_outer_half, -ring_outer_half), Vector2(ring_outer_half * 2.0, ring_width)), cell_size, morph_start, morph_end, true)
		_append_clipmap_grid(vertices, normals, uvs, uv2s, colors, indices, Rect2(Vector2(-ring_outer_half, ring_inner_half), Vector2(ring_outer_half * 2.0, ring_width)), cell_size, morph_start, morph_end, true)
		_append_clipmap_grid(vertices, normals, uvs, uv2s, colors, indices, Rect2(Vector2(-ring_outer_half, -ring_inner_half), Vector2(ring_width, ring_inner_half * 2.0)), cell_size, morph_start, morph_end, true)
		_append_clipmap_grid(vertices, normals, uvs, uv2s, colors, indices, Rect2(Vector2(ring_inner_half, -ring_inner_half), Vector2(ring_width, ring_inner_half * 2.0)), cell_size, morph_start, morph_end, true)

	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_TEX_UV2] = uv2s
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = indices

	var array_mesh := ArrayMesh.new()
	array_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return array_mesh

func _append_clipmap_grid(vertices: PackedVector3Array, normals: PackedVector3Array, uvs: PackedVector2Array, uv2s: PackedVector2Array, colors: PackedColorArray, indices: PackedInt32Array, rect: Rect2, cell_size: float, morph_start: float, morph_end: float, enable_morph: bool) -> void:
	var min_x := rect.position.x
	var min_z := rect.position.y
	var max_x := rect.position.x + rect.size.x
	var max_z := rect.position.y + rect.size.y
	var cells_x := maxi(1, int(round((max_x - min_x) / cell_size)))
	var cells_z := maxi(1, int(round((max_z - min_z) / cell_size)))
	var actual_cell_x := (max_x - min_x) / cells_x
	var actual_cell_z := (max_z - min_z) / cells_z
	var start_index := vertices.size()
	var row_size := cells_x + 1
	var extent := _get_generated_mesh_half_extent()
	var morph_color := Color(morph_start / extent, morph_end / extent, 1.0 if enable_morph else 0.0, 1.0)

	for z_i in range(cells_z + 1):
		var z := min_z + z_i * actual_cell_z
		for x_i in range(cells_x + 1):
			var x := min_x + x_i * actual_cell_x
			var target_cell := cell_size * 2.0
			var target := Vector2(round(x / target_cell) * target_cell, round(z / target_cell) * target_cell)
			vertices.push_back(Vector3(x, 0.0, z))
			normals.push_back(Vector3.UP)
			uvs.push_back(Vector2(x, z))
			uv2s.push_back(target)
			colors.push_back(morph_color)

	for z_i in range(cells_z):
		for x_i in range(cells_x):
			var a := start_index + z_i * row_size + x_i
			var b := a + 1
			var c := a + row_size
			var d := c + 1
			indices.push_back(a)
			indices.push_back(b)
			indices.push_back(c)
			indices.push_back(b)
			indices.push_back(d)
			indices.push_back(c)

func _get_generated_mesh_half_extent() -> float:
	return generated_inner_extent * 0.5 * pow(2.0, generated_ring_count)

func _set_water_shader_parameter(parameter: StringName, value: Variant) -> void:
	WATER_MAT.set_shader_parameter(parameter, value)
	if material_override is ShaderMaterial and material_override != WATER_MAT:
		(material_override as ShaderMaterial).set_shader_parameter(parameter, value)

func _read_height_images(device: RenderingDevice, texture_rid: RID) -> Array[Image]:
	var images : Array[Image] = []
	if not texture_rid.is_valid(): return images
	for i in parameters.size():
		var data := device.texture_get_data(texture_rid, i)
		if data.is_empty(): continue
		images.push_back(Image.create_from_data(map_size, map_size, false, Image.FORMAT_RGBAH, data))
	return images

func _set_texture_rid(texture: Texture2DArrayRD, rid: RID) -> void:
	texture.texture_rd_rid = RID()
	texture.texture_rd_rid = rid

func _on_wave_output_maps_swapped(current_displacement: RID, previous_displacement: RID, current_normal: RID, previous_normal: RID) -> void:
	_set_texture_rid(displacement_maps, current_displacement)
	_set_texture_rid(normal_maps, current_normal)
	if _has_wave_output:
		_set_texture_rid(previous_displacement_maps, previous_displacement)
		_set_texture_rid(previous_normal_maps, previous_normal)
		_wave_blend_duration = maxf(time - _last_wave_output_time, 1.0 / 60.0)
		_wave_blend_start_time = time
		RenderingServer.global_shader_parameter_set(&'wave_blend_alpha', 0.0 if smooth_wave_interpolation else 1.0)
	else:
		_set_texture_rid(previous_displacement_maps, current_displacement)
		_set_texture_rid(previous_normal_maps, current_normal)
		_has_wave_output = true
		_wave_blend_start_time = time
		RenderingServer.global_shader_parameter_set(&'wave_blend_alpha', 1.0)
	_last_wave_output_time = time
	RenderingServer.global_shader_parameter_set(&'displacements', displacement_maps)
	RenderingServer.global_shader_parameter_set(&'normals', normal_maps)
	RenderingServer.global_shader_parameter_set(&'previous_displacements', previous_displacement_maps)
	RenderingServer.global_shader_parameter_set(&'previous_normals', previous_normal_maps)

func _update_wave_blend_alpha() -> void:
	RenderingServer.global_shader_parameter_set(&'wave_blend_alpha', _get_wave_blend_alpha())

func _get_wave_blend_alpha() -> float:
	if not smooth_wave_interpolation or not _has_wave_output:
		return 1.0
	return clampf((time - _wave_blend_start_time) / maxf(_wave_blend_duration, 1e-5), 0.0, 1.0)

func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		displacement_maps.texture_rd_rid = RID()
		normal_maps.texture_rd_rid = RID()
		previous_displacement_maps.texture_rd_rid = RID()
		previous_normal_maps.texture_rd_rid = RID()
