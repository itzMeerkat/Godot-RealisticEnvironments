@tool
class_name OceanSystem
extends MeshInstance3D
## Handles updating the displacement/normal maps for the water material as well as
## managing wave generation pipelines.

const WATER_MAT := preload('res://addons/ocean_system/mat_water.tres')
const OCEAN_REFLECTION_RENDERER := preload('res://addons/ocean_system/ocean_reflection_renderer.gd')
const MAX_CASCADES := 8
const MAX_HULL_CUTOUTS := 16
const MAX_MANUAL_FOAM_SOURCES := 96
const SURFACE_QUERY_WORKGROUP_SIZE := 64
const SURFACE_QUERY_BYTES_PER_POINT := 16
const SURFACE_QUERY_BYTES_PER_CASCADE := 32
const SURFACE_QUERY_BYTES_PER_SAMPLE := 48
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
@export var use_bicubic_normals := true :
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

@export_group('Planar Reflections')
## Renders a mirrored camera into a texture so floating objects can appear in the water.
@export var enable_planar_reflections := true :
	set(value):
		enable_planar_reflections = value
		_update_planar_reflection_settings()
## Maximum side length for the reflection texture after resolution_scale is applied.
@export_range(128, 4096, 1) var reflection_texture_size := 1024 :
	set(value):
		reflection_texture_size = value
		_update_planar_reflection_settings()
## Multiplier applied to the main viewport size when sizing the reflection texture.
@export_range(0.1, 1.0, 0.05) var reflection_resolution_scale := 0.5 :
	set(value):
		reflection_resolution_scale = value
		_update_planar_reflection_settings()
## Overall reflected color contribution.
@export_range(0.0, 1.0, 0.01) var reflection_strength := 0.42 :
	set(value):
		reflection_strength = value
		_update_planar_reflection_settings()
## UV perturbation from wave normals. Higher values make reflections more broken.
@export_range(0.0, 0.08, 0.001) var reflection_distortion := 0.018 :
	set(value):
		reflection_distortion = value
		_update_planar_reflection_settings()
## Larger values keep reflections strongest at grazing angles.
@export_range(0.25, 8.0, 0.05) var reflection_fresnel_power := 4.0 :
	set(value):
		reflection_fresnel_power = value
		_update_planar_reflection_settings()
## Visual layer assigned to this ocean so the reflection camera can exclude it.
@export_range(1, 20, 1) var reflection_water_layer := 20 :
	set(value):
		reflection_water_layer = value
		_update_planar_reflection_settings()
## Objects visible to the reflection camera. The water layer is always removed.
@export_flags_3d_render var reflection_cull_mask := 0xFFFFF :
	set(value):
		reflection_cull_mask = value
		_update_planar_reflection_settings()

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
@export_range(1.0, 512.0, 1.0) var far_low_frequency_tile_length := 32.0 :
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
var _has_wave_output := false
var _last_wave_output_time := 0.0
var _wave_blend_start_time := 0.0
var _wave_blend_duration := 1.0 / 60.0
var _surface_query_capacity := 0
var _surface_query_shader := RID()
var _surface_query_pipeline := RID()
var _surface_query_point_buffer
var _surface_query_cascade_buffer
var _surface_query_sample_buffer
var _surface_query_sets := {}
var _surface_query_queued_requests := {}
var _surface_query_pending_requests : Array[Dictionary] = []
var _surface_query_pending_points := PackedVector3Array()
var _surface_query_cached_results := {}
var _surface_query_has_pending_readback := false
var _surface_query_pending_draw_frame := -1
var _reflection_renderer : OceanReflectionRenderer

func _init() -> void:
	rng.set_seed(1234) # This seed gives big waves!

func _ready() -> void:
	process_priority = 100
	add_to_group(&"ocean_system")
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
	_update_hull_cutouts()
	_update_manual_foam_sources()
	_update_far_lod_shader_parameters()
	_update_water_mesh()
	_setup_planar_reflections()

func _process(delta : float) -> void:
	_update_follow_camera()
	if _reflection_renderer != null:
		_reflection_renderer.set_water_level(water_level)
	_update_hull_cutouts()
	_update_manual_foam_sources()
	_update_external_wind_state()
	# Update waves once every 1.0/updates_per_second.
	if updates_per_second == 0 or time >= next_update_time:
		var target_update_delta := 1.0 / (updates_per_second + 1e-10)
		var update_delta := delta if updates_per_second == 0 else target_update_delta + (time - next_update_time)
		next_update_time = time + target_update_delta
		_update_water(update_delta)
	time += delta
	_update_wave_blend_alpha()
	_dispatch_surface_query_requests()

func _setup_wave_generator() -> void:
	if parameters.size() <= 0:
		_clear_wave_generator()
		return
	if RenderingServer.get_rendering_device() == null:
		_clear_wave_generator()
		return
	for param in parameters:
		if param:
			param.mark_all_spectra_dirty()

	_reset_surface_query_resources()
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
	_update_spectrum_blend_uniform()

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
	_update_spectrum_blend_uniform()

func _update_spectrum_blend_uniform() -> void:
	var cascade_count := mini(len(parameters), MAX_CASCADES)
	var spectrum_blend_states : PackedVector4Array; spectrum_blend_states.resize(cascade_count)
	for i in cascade_count:
		var params := parameters[i]
		if params == null:
			continue
		spectrum_blend_states[i] = params.get_spectrum_blend_state(i)
	_set_water_shader_parameter(&'spectrum_blend_states', spectrum_blend_states)

func _update_water(delta : float) -> void:
	if parameters.size() <= 0:
		return
	if wave_generator == null: _setup_wave_generator()
	if wave_generator == null:
		return
	wave_generator.update(delta, parameters, get_external_wind_speed(), get_external_wind_direction(), should_use_external_wind())
	_update_spectrum_blend_uniform()

func sample_water_surface(world_position: Vector3) -> WaterSurfaceSample:
	var points := PackedVector3Array()
	points.push_back(world_position)
	var samples := sample_water_surface_batch(points)
	if samples.is_empty():
		return null
	return samples[0]

func sample_water_surface_batch(points: PackedVector3Array, request_owner: Object = null) -> Array[WaterSurfaceSample]:
	if points.is_empty():
		return _empty_surface_samples()
	return _sample_water_surface_batch_gpu(points, request_owner)

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
	var speed_changed := absf(current_speed - _last_external_wind_speed) >= EXTERNAL_WIND_SPEED_DIRTY_THRESHOLD
	var direction_changed := _get_wrapped_degrees_delta(current_direction, _last_external_wind_direction) >= EXTERNAL_WIND_DIRECTION_DIRTY_THRESHOLD
	if not speed_changed and not direction_changed:
		return
	if time - _last_external_wind_spectrum_time < EXTERNAL_WIND_SPECTRUM_REFRESH_INTERVAL:
		return
	_last_external_wind_speed = current_speed
	_last_external_wind_direction = current_direction
	_last_external_wind_spectrum_time = time
	if speed_changed:
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
			params.mark_all_spectra_dirty()

func _clear_wave_generator() -> void:
	_reset_surface_query_resources()
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


func _setup_planar_reflections() -> void:
	if Engine.is_editor_hint():
		return
	if _reflection_renderer == null:
		_reflection_renderer = OCEAN_REFLECTION_RENDERER.new()
		_reflection_renderer.name = "OceanReflectionRenderer"
		add_child(_reflection_renderer)
	_reflection_renderer.setup(self, water_level)
	_update_planar_reflection_settings()


func _update_planar_reflection_settings() -> void:
	if _reflection_renderer != null:
		_reflection_renderer.enabled = enable_planar_reflections
		_reflection_renderer.texture_size = reflection_texture_size
		_reflection_renderer.resolution_scale = reflection_resolution_scale
		_reflection_renderer.reflection_strength = reflection_strength
		_reflection_renderer.reflection_distortion = reflection_distortion
		_reflection_renderer.fresnel_power = reflection_fresnel_power
		_reflection_renderer.water_layer = reflection_water_layer
		_reflection_renderer.reflection_cull_mask = reflection_cull_mask
		_reflection_renderer.setup(self, water_level)
		return
	_set_water_shader_parameter(&'planar_reflection_enabled', enable_planar_reflections)
	_set_water_shader_parameter(&'planar_reflection_strength', reflection_strength if enable_planar_reflections else 0.0)
	_set_water_shader_parameter(&'planar_reflection_distortion', reflection_distortion)
	_set_water_shader_parameter(&'planar_reflection_fresnel_power', reflection_fresnel_power)
	_set_water_shader_parameter(&'planar_reflection_plane_y', water_level)


func _update_hull_cutouts() -> void:
	if not is_inside_tree():
		return

	var centers := PackedVector4Array()
	var axes := PackedVector4Array()
	var shapes := PackedVector4Array()
	var verticals := PackedVector4Array()
	var widths := PackedVector4Array()
	centers.resize(MAX_HULL_CUTOUTS)
	axes.resize(MAX_HULL_CUTOUTS)
	shapes.resize(MAX_HULL_CUTOUTS)
	verticals.resize(MAX_HULL_CUTOUTS)
	widths.resize(MAX_HULL_CUTOUTS)

	var cutout_count := 0
	for node in get_tree().get_nodes_in_group(&"water_hull_cutout"):
		var cutout := node as WaterHullCutout
		if cutout == null or not cutout.enabled or not _is_node_visible_in_tree(cutout):
			continue
		if cutout_count >= MAX_HULL_CUTOUTS:
			break

		var basis := cutout.global_transform.basis.orthonormalized()
		var right := basis.x
		var forward := basis.z
		centers[cutout_count] = Vector4(
			cutout.global_position.x,
			cutout.global_position.y,
			cutout.global_position.z,
			cutout.feather
		)
		axes[cutout_count] = Vector4(right.x, right.z, forward.x, forward.z)
		shapes[cutout_count] = Vector4(cutout.half_extents.x, cutout.half_extents.y, cutout.foam_amount, 0.0)
		verticals[cutout_count] = Vector4(-100000.0, 100000.0, 1.0, 0.0)
		widths[cutout_count] = Vector4(cutout.half_extents.x, cutout.half_extents.x, 0.0, 0.0)
		cutout_count += 1

	for node in get_tree().get_nodes_in_group(&"water_cutout_provider"):
		var cutout_provider := node as Node
		if cutout_provider == null or not bool(cutout_provider.get(&"enabled")) or not _is_node_visible_in_tree(cutout_provider) or not cutout_provider.has_method(&"get_exclusion_segments"):
			continue
		for segment in cutout_provider.get_exclusion_segments():
			if cutout_count >= MAX_HULL_CUTOUTS:
				break
			var center : Vector3 = segment["center"]
			var segment_right : Vector3 = segment["right"]
			var segment_forward : Vector3 = segment["forward"]
			var half_extents : Vector2 = segment["half_extents"]
			var half_widths : Vector2 = segment["half_widths"]
			centers[cutout_count] = Vector4(
				center.x,
				center.y,
				center.z,
				float(segment["feather"])
			)
			axes[cutout_count] = Vector4(segment_right.x, segment_right.z, segment_forward.x, segment_forward.z)
			shapes[cutout_count] = Vector4(half_extents.x, half_extents.y, float(segment["foam_amount"]), 1.0)
			widths[cutout_count] = Vector4(half_widths.x, half_widths.y, 0.0, 0.0)
			verticals[cutout_count] = Vector4(
				float(segment["min_y"]),
				float(segment["max_y"]),
				float(segment["height_feather"]),
				0.0
			)
			cutout_count += 1
		if cutout_count >= MAX_HULL_CUTOUTS:
			break

	_set_water_shader_parameter(&'hull_cutout_count', cutout_count)
	_set_water_shader_parameter(&'hull_cutout_centers', centers)
	_set_water_shader_parameter(&'hull_cutout_axes', axes)
	_set_water_shader_parameter(&'hull_cutout_shapes', shapes)
	_set_water_shader_parameter(&'hull_cutout_verticals', verticals)
	_set_water_shader_parameter(&'hull_cutout_widths', widths)


func _update_manual_foam_sources() -> void:
	if not is_inside_tree():
		return
	var sources := PackedVector4Array()
	var shapes := PackedVector4Array()
	sources.resize(MAX_MANUAL_FOAM_SOURCES)
	shapes.resize(MAX_MANUAL_FOAM_SOURCES)
	var source_count := 0
	for node in get_tree().get_nodes_in_group(&"manual_water_foam_source"):
		if source_count >= MAX_MANUAL_FOAM_SOURCES:
			break
		if node == null or not _is_node_visible_in_tree(node) or not node.has_method(&"get_manual_foam_sources"):
			continue
		var node_sources : Array = node.call(&"get_manual_foam_sources")
		for source in node_sources:
			if source_count >= MAX_MANUAL_FOAM_SOURCES:
				break
			var position : Vector3 = source.get("position", Vector3.ZERO)
			var radius := maxf(float(source.get("radius", 0.0)), 0.001)
			var amount := clampf(float(source.get("amount", source.get("foam", 0.0))), 0.0, 1.0)
			if amount <= 0.001:
				continue
			var direction : Vector3 = source.get("direction", Vector3.ZERO)
			direction.y = 0.0
			if direction.length_squared() > 0.0001:
				direction = direction.normalized()
			var half_length := maxf(float(source.get("length", 0.0)) * 0.5, 0.0)
			sources[source_count] = Vector4(position.x, position.z, radius, amount)
			shapes[source_count] = Vector4(direction.x, direction.z, half_length, 0.0)
			source_count += 1
	_set_water_shader_parameter(&'manual_foam_count', source_count)
	_set_water_shader_parameter(&'manual_foam_sources', sources)
	_set_water_shader_parameter(&'manual_foam_shapes', shapes)


func _is_node_visible_in_tree(node: Node) -> bool:
	if node is Node3D:
		return (node as Node3D).is_visible_in_tree()
	if node is CanvasItem:
		return (node as CanvasItem).is_visible_in_tree()
	return true


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

func _sample_water_surface_batch_gpu(points: PackedVector3Array, request_owner: Object = null) -> Array[WaterSurfaceSample]:
	_read_surface_query_results_if_ready()
	var owner_key := _get_surface_query_owner_key(request_owner)
	_surface_query_queued_requests[owner_key] = {
		"points": points,
	}
	var cached_samples : Array[WaterSurfaceSample] = _surface_query_cached_results.get(owner_key, _empty_surface_samples())
	if cached_samples.size() != points.size():
		return _empty_surface_samples()
	return cached_samples


func _get_surface_query_owner_key(request_owner: Object) -> int:
	return 0 if request_owner == null else request_owner.get_instance_id()


func _dispatch_surface_query_requests() -> void:
	_read_surface_query_results_if_ready()
	if _surface_query_has_pending_readback or _surface_query_queued_requests.is_empty():
		return
	if wave_generator == null or wave_generator.context == null:
		if parameters.size() > 0:
			_setup_wave_generator()
	if wave_generator == null or wave_generator.context == null:
		return

	var total_count := 0
	for request in _surface_query_queued_requests.values():
		var request_points : PackedVector3Array = request.get("points", PackedVector3Array())
		total_count += request_points.size()
	if total_count <= 0:
		_surface_query_queued_requests.clear()
		return
	if not _ensure_surface_query_resources(total_count):
		return

	var combined_points := PackedVector3Array()
	combined_points.resize(total_count)
	var dispatch_requests : Array[Dictionary] = []
	var offset := 0
	for owner_key in _surface_query_queued_requests.keys():
		var request : Dictionary = _surface_query_queued_requests[owner_key]
		var request_points : PackedVector3Array = request.get("points", PackedVector3Array())
		var count := request_points.size()
		if count <= 0:
			continue
		for i in count:
			combined_points[offset + i] = request_points[i]
		dispatch_requests.push_back({
			"owner_key": int(owner_key),
			"offset": offset,
			"count": count,
		})
		offset += count
	if offset <= 0:
		_surface_query_queued_requests.clear()
		return
	if offset != total_count:
		combined_points.resize(offset)
		total_count = offset

	var context := wave_generator.context
	var device := context.device
	var point_data := _pack_surface_query_points(combined_points)
	var cascade_data := _pack_surface_query_cascades()
	device.buffer_update(_surface_query_point_buffer.rid, 0, point_data.size(), point_data)
	device.buffer_update(_surface_query_cascade_buffer.rid, 0, cascade_data.size(), cascade_data)

	var current_displacement_rid : RID = wave_generator.descriptors[&'displacement_map'].rid
	var previous_displacement_rid : RID = wave_generator.descriptors[&'previous_displacement_map'].rid
	var uniform_set := _get_surface_query_uniform_set(current_displacement_rid, previous_displacement_rid)
	if not uniform_set.is_valid():
		return

	var groups := int(ceil(float(total_count) / float(SURFACE_QUERY_WORKGROUP_SIZE)))
	var compute_list := context.compute_list_begin()
	device.compute_list_bind_compute_pipeline(compute_list, _surface_query_pipeline)
	device.compute_list_bind_uniform_set(compute_list, uniform_set, 0)
	device.compute_list_set_push_constant(
		compute_list,
		RenderingContext.create_push_constant([
			total_count,
			mini(parameters.size(), MAX_CASCADES),
			map_size,
			water_level,
			_get_wave_blend_alpha(),
			maxf(_wave_blend_duration, 1.0 / 60.0),
			0.25,
			0.0,
		]),
		32
	)
	device.compute_list_dispatch(compute_list, groups, 1, 1)
	context.compute_list_end()

	if device != RenderingServer.get_rendering_device():
		context.submit()
		context.sync()
		var byte_count := total_count * SURFACE_QUERY_BYTES_PER_SAMPLE
		var sample_data : PackedByteArray = device.buffer_get_data(_surface_query_sample_buffer.rid, 0, byte_count)
		_store_surface_query_results(combined_points, dispatch_requests, sample_data)
		_surface_query_queued_requests.clear()
		return

	_surface_query_pending_points = combined_points
	_surface_query_pending_requests = dispatch_requests
	_surface_query_pending_draw_frame = Engine.get_frames_drawn()
	_surface_query_has_pending_readback = true
	_surface_query_queued_requests.clear()


func _read_surface_query_results_if_ready() -> void:
	if not _surface_query_has_pending_readback or _surface_query_sample_buffer == null:
		return
	if wave_generator == null or wave_generator.context == null:
		return
	var device := wave_generator.context.device
	if device == RenderingServer.get_rendering_device() and Engine.get_frames_drawn() <= _surface_query_pending_draw_frame:
		return
	var byte_count := _surface_query_pending_points.size() * SURFACE_QUERY_BYTES_PER_SAMPLE
	var sample_data : PackedByteArray = device.buffer_get_data(_surface_query_sample_buffer.rid, 0, byte_count)
	_store_surface_query_results(_surface_query_pending_points, _surface_query_pending_requests, sample_data)
	_surface_query_has_pending_readback = false
	_surface_query_pending_points.clear()
	_surface_query_pending_requests.clear()


func _store_surface_query_results(points: PackedVector3Array, requests: Array[Dictionary], data: PackedByteArray) -> void:
	var samples := _unpack_surface_query_samples(points, data)
	if samples.size() != points.size():
		return
	for request in requests:
		var owner_key := int(request.get("owner_key", 0))
		var offset := int(request.get("offset", 0))
		var count := int(request.get("count", 0))
		var owner_samples : Array[WaterSurfaceSample] = []
		for i in count:
			owner_samples.push_back(samples[offset + i])
		_surface_query_cached_results[owner_key] = owner_samples


func _ensure_surface_query_resources(point_count : int) -> bool:
	if point_count <= 0:
		return false
	if wave_generator == null or wave_generator.context == null:
		return false
	if not wave_generator.descriptors.has(&'displacement_map') or wave_generator.descriptors[&'displacement_map'] == null or not wave_generator.descriptors[&'displacement_map'].rid.is_valid():
		return false
	if not wave_generator.descriptors.has(&'previous_displacement_map') or wave_generator.descriptors[&'previous_displacement_map'] == null or not wave_generator.descriptors[&'previous_displacement_map'].rid.is_valid():
		return false

	var context := wave_generator.context
	if not _surface_query_shader.is_valid():
		_surface_query_shader = context.load_shader('res://addons/ocean_system/shaders/compute/surface_query.glsl')
	if not _surface_query_pipeline.is_valid():
		_surface_query_pipeline = context.deletion_queue.push(context.device.compute_pipeline_create(_surface_query_shader))
	if point_count <= _surface_query_capacity and _surface_query_point_buffer != null:
		return true

	var capacity := _get_surface_query_capacity(point_count)
	_surface_query_capacity = capacity
	_surface_query_point_buffer = context.create_storage_buffer(capacity * SURFACE_QUERY_BYTES_PER_POINT)
	_surface_query_cascade_buffer = context.create_storage_buffer(MAX_CASCADES * SURFACE_QUERY_BYTES_PER_CASCADE)
	_surface_query_sample_buffer = context.create_storage_buffer(capacity * SURFACE_QUERY_BYTES_PER_SAMPLE)
	_surface_query_sets.clear()
	_surface_query_has_pending_readback = false
	return true

func _get_surface_query_capacity(point_count : int) -> int:
	var capacity := SURFACE_QUERY_WORKGROUP_SIZE
	while capacity < point_count:
		capacity *= 2
	return capacity

func _get_surface_query_uniform_set(current_displacement_rid : RID, previous_displacement_rid : RID) -> RID:
	var key := "%s:%s" % [str(current_displacement_rid), str(previous_displacement_rid)]
	if _surface_query_sets.has(key):
		return _surface_query_sets[key]
	var device := wave_generator.context.device
	var uniforms : Array[RDUniform] = []
	_add_surface_query_uniform(uniforms, 0, _surface_query_point_buffer.type, [_surface_query_point_buffer.rid])
	_add_surface_query_uniform(uniforms, 1, _surface_query_cascade_buffer.type, [_surface_query_cascade_buffer.rid])
	_add_surface_query_uniform(uniforms, 2, _surface_query_sample_buffer.type, [_surface_query_sample_buffer.rid])
	_add_surface_query_uniform(uniforms, 3, wave_generator.descriptors[&'displacement_map'].type, [current_displacement_rid])
	_add_surface_query_uniform(uniforms, 4, wave_generator.descriptors[&'previous_displacement_map'].type, [previous_displacement_rid])
	var uniform_set := wave_generator.context.deletion_queue.push(device.uniform_set_create(uniforms, _surface_query_shader, 0))
	_surface_query_sets[key] = uniform_set
	return uniform_set


func _add_surface_query_uniform(uniforms: Array[RDUniform], binding: int, uniform_type: RenderingDevice.UniformType, ids: Array[RID]) -> void:
	var uniform := RDUniform.new()
	uniform.binding = binding
	uniform.uniform_type = uniform_type
	for id in ids:
		uniform.add_id(id)
	uniforms.push_back(uniform)

func _pack_surface_query_points(points: PackedVector3Array) -> PackedByteArray:
	var data := PackedByteArray()
	data.resize(points.size() * SURFACE_QUERY_BYTES_PER_POINT)
	for i in points.size():
		var offset := i * SURFACE_QUERY_BYTES_PER_POINT
		var point := points[i]
		data.encode_float(offset, point.x)
		data.encode_float(offset + 4, point.y)
		data.encode_float(offset + 8, point.z)
		data.encode_float(offset + 12, 0.0)
	return data

func _pack_surface_query_cascades() -> PackedByteArray:
	var data := PackedByteArray()
	data.resize(MAX_CASCADES * SURFACE_QUERY_BYTES_PER_CASCADE)
	for i in mini(parameters.size(), MAX_CASCADES):
		var params := parameters[i]
		if params == null:
			continue
		var uv_scale := Vector2.ONE / params.tile_length
		var blend_state := params.get_spectrum_blend_state(i)
		var offset := i * SURFACE_QUERY_BYTES_PER_CASCADE
		data.encode_float(offset, uv_scale.x)
		data.encode_float(offset + 4, uv_scale.y)
		data.encode_float(offset + 8, params.displacement_scale)
		data.encode_float(offset + 12, params.normal_scale)
		data.encode_float(offset + 16, blend_state.x)
		data.encode_float(offset + 20, blend_state.y)
		data.encode_float(offset + 24, blend_state.z)
		data.encode_float(offset + 28, 0.0)
	return data

func _unpack_surface_query_samples(points: PackedVector3Array, data: PackedByteArray) -> Array[WaterSurfaceSample]:
	if data.size() < points.size() * SURFACE_QUERY_BYTES_PER_SAMPLE:
		return _empty_surface_samples()

	var samples : Array[WaterSurfaceSample] = []
	samples.resize(points.size())
	for i in points.size():
		var offset := i * SURFACE_QUERY_BYTES_PER_SAMPLE
		var sample := WaterSurfaceSample.new()
		sample.position = points[i]
		sample.displacement = Vector3(
			data.decode_float(offset),
			data.decode_float(offset + 4),
			data.decode_float(offset + 8)
		)
		sample.height = data.decode_float(offset + 12)
		sample.normal = Vector3(
			data.decode_float(offset + 16),
			data.decode_float(offset + 20),
			data.decode_float(offset + 24)
		)
		sample.surface_velocity = Vector3(
			data.decode_float(offset + 32),
			data.decode_float(offset + 36),
			data.decode_float(offset + 40)
		)
		samples[i] = sample
	return samples


func _empty_surface_samples() -> Array[WaterSurfaceSample]:
	var samples : Array[WaterSurfaceSample] = []
	return samples


func _reset_surface_query_resources() -> void:
	_surface_query_capacity = 0
	_surface_query_shader = RID()
	_surface_query_pipeline = RID()
	_surface_query_point_buffer = null
	_surface_query_cascade_buffer = null
	_surface_query_sample_buffer = null
	_surface_query_sets.clear()
	_surface_query_queued_requests.clear()
	_surface_query_pending_requests.clear()
	_surface_query_pending_points.clear()
	_surface_query_cached_results.clear()
	_surface_query_has_pending_readback = false
	_surface_query_pending_draw_frame = -1

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
