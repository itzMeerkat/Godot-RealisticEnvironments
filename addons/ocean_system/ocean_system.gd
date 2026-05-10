@tool
class_name OceanSystem
extends MeshInstance3D
## Handles updating the displacement/normal maps for the water material as well as
## managing wave generation pipelines.

const WATER_MAT := preload('res://addons/ocean_system/mat_water.tres')
const MAX_CASCADES := 8
const EXTERNAL_WIND_SPEED_DIRTY_THRESHOLD := 0.25
const EXTERNAL_WIND_DIRECTION_DIRTY_THRESHOLD := 2.0
const EXTERNAL_WIND_SPECTRUM_REFRESH_INTERVAL := 0.5

@export_group('Wave Parameters')
## Deep-water tint used before foam is blended in.
@export_color_no_alpha var water_color : Color = Color(0.1, 0.15, 0.18) :
	set(value):
		water_color = value
		_set_water_shader_parameter(&'water_color', water_color)

## Foam albedo tint used where the wave maps report whitecaps.
@export_color_no_alpha var foam_color : Color = Color(0.73, 0.67, 0.62) :
	set(value):
		foam_color = value
		_set_water_shader_parameter(&'foam_color', foam_color)

@export_group('Surface Shading')
## Roughness for clear water areas.
@export_range(0.0, 1.0, 0.01) var clear_roughness := 0.06 :
	set(value):
		clear_roughness = value
		_set_water_shader_parameter(&'clear_roughness', clear_roughness)
## Roughness for foam-covered areas.
@export_range(0.0, 1.0, 0.01) var foam_roughness := 0.24 :
	set(value):
		foam_roughness = value
		_set_water_shader_parameter(&'foam_roughness', foam_roughness)
## Specular intensity for clear water areas.
@export_range(0.0, 1.0, 0.01) var clear_specular := 0.85 :
	set(value):
		clear_specular = value
		_set_water_shader_parameter(&'clear_specular', clear_specular)
## Specular intensity for foam-covered areas.
@export_range(0.0, 1.0, 0.01) var foam_specular := 0.35 :
	set(value):
		foam_specular = value
		_set_water_shader_parameter(&'foam_specular', foam_specular)
## How strongly wave slope increases surface roughness.
@export_range(0.0, 4.0, 0.01) var slope_roughness_strength := 0.55 :
	set(value):
		slope_roughness_strength = value
		_set_water_shader_parameter(&'slope_roughness_strength', slope_roughness_strength)
## Overall strength of normal-map lighting. Lower values make the water calmer visually.
@export_range(0.0, 1.0, 0.01) var normal_strength := 1.0 :
	set(value):
		normal_strength = value
		_set_water_shader_parameter(&'normal_strength', normal_strength)
## Enables smoother but more expensive normal sampling for close wave detail.
@export var use_bicubic_normals := false :
	set(value):
		use_bicubic_normals = value
		_set_water_shader_parameter(&'use_bicubic_normals', use_bicubic_normals)
## Maximum number of cascades sampled in the fragment shader for foam and normals.
@export_range(1, 8, 1) var fragment_cascade_limit := 3 :
	set(value):
		fragment_cascade_limit = clampi(value, 1, MAX_CASCADES)
		_set_water_shader_parameter(&'fragment_cascade_limit', fragment_cascade_limit)

@export_group('Foam Shading')
## Multiplies the foam signal produced by the wave compute pass.
@export_range(0.0, 4.0, 0.01) var foam_intensity := 1.25 :
	set(value):
		foam_intensity = value
		_set_water_shader_parameter(&'foam_intensity', foam_intensity)
## Minimum foam signal required before foam appears.
@export_range(0.0, 2.0, 0.01) var foam_threshold := 0.05 :
	set(value):
		foam_threshold = value
		_set_water_shader_parameter(&'foam_threshold', foam_threshold)
## Width of the transition between clear water and foam.
@export_range(0.01, 2.0, 0.01) var foam_softness := 0.35 :
	set(value):
		foam_softness = value
		_set_water_shader_parameter(&'foam_softness', foam_softness)

@export_group('External Wind')
## When enabled, cascades read speed and direction from wind_source_path.
@export var use_external_wind := false :
	set(value):
		use_external_wind = value
		_reset_external_wind_tracking()
		_mark_spectra_dirty()
## Optional node that exposes get_wind_speed/get_wind_direction_degrees or wind_speed/wind_direction.
@export var wind_source_path : NodePath :
	set(value):
		wind_source_path = value
		wind_source = null
		_reset_external_wind_tracking()
		_mark_spectra_dirty()

## Parameters for wave cascades. Each item represents one wave scale.
## Adding/removing cascades recreates the compute pipelines.
@export var parameters : Array[WaveCascadeParameters] :
	set(value):
		if parameters != null:
			for existing_param in parameters:
				if existing_param and existing_param.scale_changed.is_connected(_update_scales_uniform):
					existing_param.scale_changed.disconnect(_update_scales_uniform)

		var new_parameters := value
		if new_parameters.size() > MAX_CASCADES:
			push_warning("OceanSystem supports at most %d wave cascades. Extra cascades were ignored." % MAX_CASCADES)
			new_parameters.resize(MAX_CASCADES)

		var new_size := len(new_parameters)
		for i in range(new_size):
			# Inspector array slots can be empty; create a valid cascade resource.
			if not new_parameters[i]: new_parameters[i] = WaveCascadeParameters.new()
			if not new_parameters[i].is_connected(&'scale_changed', _update_scales_uniform):
				new_parameters[i].scale_changed.connect(_update_scales_uniform)
			# Offset cascade start times so layered waves are less likely to align.
			new_parameters[i].initialize_runtime_state(
				Vector2i(rng.randi_range(-10000, 10000), rng.randi_range(-10000, 10000)),
				120.0 + PI*i
			)
		parameters = new_parameters
		_setup_wave_generator()
		_update_scales_uniform()

@export_group('Performance Parameters')
## Resolution for each generated displacement/normal texture layer.
@export_enum('128x128:128', '256x256:256', '512x512:512', '1024x1024:1024') var map_size := 1024 :
	set(value):
		map_size = value
		_clear_height_cache()
		_setup_wave_generator()

@export_group('Mesh')
## Near-ocean radius in meters before optional far LOD rings begin.
@export_range(32.0, 4096.0, 1.0, "or_greater") var ocean_radius := 256.0 :
	set(value):
		ocean_radius = value
		_update_water_mesh()
## Full side length of the highest-density center patch, in meters.
@export_range(16.0, 512.0, 1.0) var generated_inner_extent := 128.0 :
	set(value):
		generated_inner_extent = value
		_update_water_mesh()
## Vertex spacing in meters for the highest-density center patch.
@export_range(0.5, 16.0, 0.5) var generated_base_cell_size := 1.0 :
	set(value):
		generated_base_cell_size = value
		_update_water_mesh()
## Number of progressively coarser near-ocean mesh rings.
@export_range(0, 8, 1) var generated_ring_count := 2 :
	set(value):
		generated_ring_count = value
		_update_water_mesh()
## Keeps the generated mesh centered around the active camera in XZ space.
@export var follow_active_camera := true
## Snaps follow movement to this grid size. Set to 0 for continuous following.
@export_range(0.0, 64.0, 0.25) var follow_snap_size := 0.0
## Allows camera-follow preview while running in the editor.
@export var follow_camera_in_editor := false

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
## Blends between previous and current wave maps to reduce low update-rate stutter.
@export var smooth_wave_interpolation := true
@export_group('Far Ocean LOD')
## Adds lower-density rings and fades out high-frequency detail in the distance.
@export var enable_far_lod := true :
	set(value):
		enable_far_lod = value
		_update_water_mesh()
		_update_far_lod_shader_parameters()
## Maximum radius of generated far-ocean geometry.
@export_range(256.0, 20000.0, 1.0, "or_greater") var far_lod_radius := 7000.0 :
	set(value):
		far_lod_radius = value
		_update_water_mesh()
		_update_far_lod_shader_parameters()
## Number of extra low-density rings between ocean_radius and far_lod_radius.
@export_range(4, 96, 1) var far_lod_ring_count := 36 :
	set(value):
		far_lod_ring_count = value
		_update_water_mesh()
## Distance over which near detail fades into far-ocean shading.
@export_range(1.0, 4000.0, 1.0) var far_lod_blend_distance := 1400.0 :
	set(value):
		far_lod_blend_distance = value
		_update_far_lod_shader_parameters()
## Curve applied to the near-to-far LOD fade.
@export_range(0.25, 4.0, 0.01) var far_lod_curve := 1.8 :
	set(value):
		far_lod_curve = value
		_update_far_lod_shader_parameters()
## Cascades shorter than this tile length fade out in far LOD.
@export_range(1.0, 512.0, 1.0) var far_low_frequency_tile_length := 64.0 :
	set(value):
		far_low_frequency_tile_length = value
		_update_far_lod_shader_parameters()
## Minimum normal detail retained in the far ocean.
@export_range(0.0, 2.0, 0.01) var far_normal_strength := 0.14 :
	set(value):
		far_normal_strength = value
		_update_far_lod_shader_parameters()
## Foam multiplier retained in the far ocean.
@export_range(0.0, 1.0, 0.01) var far_foam_coverage := 0.24 :
	set(value):
		far_foam_coverage = value
		_update_far_lod_shader_parameters()
## Extra foam threshold applied with distance to avoid noisy horizon foam.
@export_range(0.0, 1.0, 0.01) var far_foam_threshold_boost := 0.2 :
	set(value):
		far_foam_threshold_boost = value
		_update_far_lod_shader_parameters()

var wave_generator : WaveGenerator :
	set(value):
		if wave_generator:
			wave_generator.queue_free()
		wave_generator = value
		if wave_generator:
			add_child(wave_generator)
var rng = RandomNumberGenerator.new()
var time := 0.0
var next_update_time := 0.0
var wind_source : Node
var _last_external_wind_speed := -1.0
var _last_external_wind_direction := -999999.0
var _last_external_wind_spectrum_time := -1.0e20

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
var _height_cache_refresh_pending := false

func _init() -> void:
	rng.set_seed(1234) # This seed gives big waves!

func _ready() -> void:
	process_priority = 100
	if not Engine.is_editor_hint():
		_ensure_unique_water_material()
	_resolve_wind_source()
	_set_water_shader_parameter(&'water_color', water_color)
	_set_water_shader_parameter(&'foam_color', foam_color)
	_set_water_shader_parameter(&'wave_blend_alpha', 1.0)
	_set_water_shader_parameter(&'clear_roughness', clear_roughness)
	_set_water_shader_parameter(&'foam_roughness', foam_roughness)
	_set_water_shader_parameter(&'clear_specular', clear_specular)
	_set_water_shader_parameter(&'foam_specular', foam_specular)
	_set_water_shader_parameter(&'slope_roughness_strength', slope_roughness_strength)
	_set_water_shader_parameter(&'normal_strength', normal_strength)
	_set_water_shader_parameter(&'use_bicubic_normals', use_bicubic_normals)
	_set_water_shader_parameter(&'fragment_cascade_limit', fragment_cascade_limit)
	_set_water_shader_parameter(&'foam_intensity', foam_intensity)
	_set_water_shader_parameter(&'foam_threshold', foam_threshold)
	_set_water_shader_parameter(&'foam_softness', foam_softness)
	_update_far_lod_shader_parameters()
	_update_water_mesh()

func _process(delta : float) -> void:
	_update_follow_camera()
	_update_external_wind_state()
	# Update waves once every 1.0/updates_per_second.
	if updates_per_second == 0 or time >= next_update_time:
		var target_update_delta := 1.0 / (updates_per_second + 1e-10)
		var update_delta := delta if updates_per_second == 0 else target_update_delta + (time - next_update_time)
		next_update_time = time + target_update_delta
		_update_water(update_delta)
	time += delta
	_update_wave_blend_alpha()

func _setup_wave_generator() -> void:
	if parameters.size() <= 0:
		_clear_wave_generator()
		return
	for param in parameters:
		if param:
			param.should_generate_spectrum = true

	_clear_height_cache()
	_height_cache_refresh_pending = false
	wave_generator = WaveGenerator.new()
	wave_generator.map_size = map_size
	# The output ping-pong path expects at least two texture-array layers.
	wave_generator.init_gpu(maxi(2, mini(parameters.size(), MAX_CASCADES)))
	wave_generator.output_maps_swapped.connect(_on_wave_output_maps_swapped)
	_has_wave_output = false

	_set_texture_rid(displacement_maps, wave_generator.descriptors[&'displacement_map'].rid)
	_set_texture_rid(normal_maps, wave_generator.descriptors[&'normal_map'].rid)
	_set_texture_rid(previous_displacement_maps, wave_generator.descriptors[&'previous_displacement_map'].rid)
	_set_texture_rid(previous_normal_maps, wave_generator.descriptors[&'previous_normal_map'].rid)

	_set_water_shader_parameter(&'num_cascades', parameters.size())
	_set_water_shader_parameter(&'displacements', displacement_maps)
	_set_water_shader_parameter(&'normals', normal_maps)
	_set_water_shader_parameter(&'previous_displacements', previous_displacement_maps)
	_set_water_shader_parameter(&'previous_normals', previous_normal_maps)
	_set_water_shader_parameter(&'wave_blend_alpha', 1.0)

func _update_scales_uniform() -> void:
	var cascade_count := mini(len(parameters), MAX_CASCADES)
	var map_scales : PackedVector4Array; map_scales.resize(cascade_count)
	for i in cascade_count:
		var params := parameters[i]
		if params == null:
			continue
		var uv_scale := Vector2.ONE / params.tile_length
		map_scales[i] = Vector4(uv_scale.x, uv_scale.y, params.displacement_scale, params.normal_scale)
	_set_water_shader_parameter(&'map_scales', map_scales)

func _update_water(delta : float) -> void:
	if parameters.size() <= 0:
		return
	if wave_generator == null: _setup_wave_generator()
	if wave_generator == null:
		return
	wave_generator.update(delta, parameters, get_external_wind_speed(), get_external_wind_direction(), should_use_external_wind())
	if enable_height_queries and (height_query_updates_per_second == 0 or time >= _next_height_query_update_time):
		var target_update_delta := 1.0 / (height_query_updates_per_second + 1e-10)
		_next_height_query_update_time = time + target_update_delta
		_height_cache_refresh_pending = true

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

func should_use_external_wind() -> bool:
	return use_external_wind and get_wind_source() != null

func get_wind_source() -> Node:
	if wind_source == null:
		_resolve_wind_source()
	return wind_source

func get_external_wind_speed() -> float:
	var external_wind := get_wind_source()
	if external_wind == null:
		return 0.0
	if external_wind.has_method(&'get_wind_speed'):
		return float(external_wind.call(&'get_wind_speed'))
	var value = external_wind.get(&'wind_speed')
	return 0.0 if value == null else float(value)

func get_external_wind_direction() -> float:
	var external_wind := get_wind_source()
	if external_wind == null:
		return 0.0
	if external_wind.has_method(&'get_wind_direction_degrees'):
		return float(external_wind.call(&'get_wind_direction_degrees'))
	var value = external_wind.get(&'wind_direction')
	return 0.0 if value == null else float(value)

func _resolve_wind_source() -> void:
	if wind_source_path.is_empty():
		return
	wind_source = get_node_or_null(wind_source_path)

func _update_external_wind_state() -> void:
	if not should_use_external_wind():
		return
	var current_speed := get_external_wind_speed()
	var current_direction := get_external_wind_direction()
	if (
		absf(current_speed - _last_external_wind_speed) < EXTERNAL_WIND_SPEED_DIRTY_THRESHOLD
		and _get_wrapped_degrees_delta(current_direction, _last_external_wind_direction) < EXTERNAL_WIND_DIRECTION_DIRTY_THRESHOLD
	):
		return
	if time - _last_external_wind_spectrum_time < EXTERNAL_WIND_SPECTRUM_REFRESH_INTERVAL:
		return
	_last_external_wind_speed = current_speed
	_last_external_wind_direction = current_direction
	_last_external_wind_spectrum_time = time
	_mark_spectra_dirty()

func _reset_external_wind_tracking() -> void:
	_last_external_wind_speed = -1.0
	_last_external_wind_direction = -999999.0
	_last_external_wind_spectrum_time = -1.0e20

func _get_wrapped_degrees_delta(a : float, b : float) -> float:
	return absf(wrapf(a - b + 180.0, 0.0, 360.0) - 180.0)

func _mark_spectra_dirty() -> void:
	if parameters == null:
		return
	for params in parameters:
		if params:
			params.should_generate_spectrum = true

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
	_height_cache_refresh_pending = false

func _clear_wave_generator() -> void:
	_clear_height_cache()
	wave_generator = null
	_has_wave_output = false
	_last_wave_output_time = 0.0
	_wave_blend_start_time = 0.0
	_set_texture_rid(displacement_maps, RID())
	_set_texture_rid(normal_maps, RID())
	_set_texture_rid(previous_displacement_maps, RID())
	_set_texture_rid(previous_normal_maps, RID())
	_set_water_shader_parameter(&'num_cascades', 0)
	_set_water_shader_parameter(&'displacements', displacement_maps)
	_set_water_shader_parameter(&'normals', normal_maps)
	_set_water_shader_parameter(&'previous_displacements', previous_displacement_maps)
	_set_water_shader_parameter(&'previous_normals', previous_normal_maps)
	_set_water_shader_parameter(&'wave_blend_alpha', 1.0)

func _update_water_mesh() -> void:
	if Engine.is_editor_hint():
		mesh = null
		return

	mesh = _create_generated_clipmap_mesh()
	extra_cull_margin = _get_generated_mesh_half_extent()
	_update_far_lod_shader_parameters()

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
	var indices := PackedInt32Array()

	var radii := _build_circular_clipmap_radii()
	var radial_count := radii.size()
	var segment_count := _get_circular_clipmap_segment_count()

	vertices.push_back(Vector3.ZERO)
	normals.push_back(Vector3.UP)
	uvs.push_back(Vector2.ZERO)

	for radius_index in range(1, radial_count):
		var radius := radii[radius_index]
		for segment in range(segment_count):
			var angle := TAU * float(segment) / float(segment_count)
			var position := Vector3(cos(angle) * radius, 0.0, sin(angle) * radius)
			vertices.push_back(position)
			normals.push_back(Vector3.UP)
			uvs.push_back(Vector2(position.x, position.z))

	for segment in range(segment_count):
		var next_segment := (segment + 1) % segment_count
		indices.push_back(0)
		indices.push_back(1 + next_segment)
		indices.push_back(1 + segment)

	for radius_index in range(1, radial_count - 1):
		var row := 1 + (radius_index - 1) * segment_count
		var next_row := row + segment_count
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
	arrays[Mesh.ARRAY_INDEX] = indices

	var array_mesh := ArrayMesh.new()
	array_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return array_mesh

func _build_circular_clipmap_radii() -> PackedFloat32Array:
	var radii := PackedFloat32Array()
	radii.push_back(0.0)

	var base_cell := maxf(generated_base_cell_size, 0.1)
	var inner_radius := generated_inner_extent * 0.5
	var outer_radius := maxf(ocean_radius, inner_radius)
	var current_radius := 0.0

	for band in range(generated_ring_count + 1):
		var band_outer := minf(inner_radius * pow(2.0, band), outer_radius)
		var cell_size := base_cell * pow(2.0, band)
		while current_radius + cell_size < band_outer - 0.001:
			current_radius += cell_size
			radii.push_back(current_radius)
		if radii[radii.size() - 1] < band_outer - 0.001:
			current_radius = band_outer
			radii.push_back(current_radius)

	var outer_cell_size := base_cell * pow(2.0, generated_ring_count + 1)
	while current_radius + outer_cell_size < outer_radius - 0.001:
		current_radius += outer_cell_size
		radii.push_back(current_radius)

	if radii[radii.size() - 1] < outer_radius - 0.001:
		radii.push_back(outer_radius)

	if enable_far_lod:
		var far_radius := maxf(far_lod_radius, outer_radius)
		var far_ring_count := maxi(far_lod_ring_count, 1)
		for i in range(1, far_ring_count + 1):
			var t := float(i) / float(far_ring_count)
			var eased_t := t * t
			var radius := lerpf(outer_radius, far_radius, eased_t)
			if radius > radii[radii.size() - 1] + 0.001:
				radii.push_back(radius)

	return radii

func _get_circular_clipmap_segment_count() -> int:
	var base_cell := maxf(generated_base_cell_size, 0.1)
	var inner_radius := maxf(generated_inner_extent * 0.5, base_cell)
	var target_count := int(ceil(TAU * inner_radius / base_cell))
	return clampi(target_count, 32, 1024)

func _get_generated_mesh_half_extent() -> float:
	var near_extent := maxf(ocean_radius, generated_inner_extent * 0.5)
	return maxf(near_extent, far_lod_radius) if enable_far_lod else near_extent

func get_ocean_radius() -> float:
	return maxf(ocean_radius, generated_inner_extent * 0.5)

func _update_far_lod_shader_parameters() -> void:
	_set_water_shader_parameter(&'enable_far_lod', enable_far_lod)
	_set_water_shader_parameter(&'near_ocean_radius', get_ocean_radius())
	_set_water_shader_parameter(&'far_lod_radius', _get_generated_mesh_half_extent())
	_set_water_shader_parameter(&'far_lod_blend_distance', far_lod_blend_distance)
	_set_water_shader_parameter(&'far_lod_curve', far_lod_curve)
	_set_water_shader_parameter(&'far_low_frequency_tile_length', far_low_frequency_tile_length)
	_set_water_shader_parameter(&'far_normal_strength', far_normal_strength)
	_set_water_shader_parameter(&'far_foam_coverage', far_foam_coverage)
	_set_water_shader_parameter(&'far_foam_threshold_boost', far_foam_threshold_boost)

func _set_water_shader_parameter(parameter: StringName, value: Variant) -> void:
	if material_override is ShaderMaterial:
		(material_override as ShaderMaterial).set_shader_parameter(parameter, value)
	else:
		WATER_MAT.set_shader_parameter(parameter, value)

func _ensure_unique_water_material() -> void:
	if material_override is ShaderMaterial:
		material_override = (material_override as ShaderMaterial).duplicate()
	else:
		material_override = WATER_MAT.duplicate()

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
		_set_water_shader_parameter(&'wave_blend_alpha', 0.0 if smooth_wave_interpolation else 1.0)
	else:
		_set_texture_rid(previous_displacement_maps, current_displacement)
		_set_texture_rid(previous_normal_maps, current_normal)
		_has_wave_output = true
		_wave_blend_start_time = time
		_set_water_shader_parameter(&'wave_blend_alpha', 1.0)
	_last_wave_output_time = time
	_set_water_shader_parameter(&'displacements', displacement_maps)
	_set_water_shader_parameter(&'normals', normal_maps)
	_set_water_shader_parameter(&'previous_displacements', previous_displacement_maps)
	_set_water_shader_parameter(&'previous_normals', previous_normal_maps)
	if _height_cache_refresh_pending and enable_height_queries:
		refresh_height_cache()
		_height_cache_refresh_pending = false

func _update_wave_blend_alpha() -> void:
	_set_water_shader_parameter(&'wave_blend_alpha', _get_wave_blend_alpha())

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
