@tool
class_name OceanSystem
extends MeshInstance3D
## Handles updating the displacement/normal maps for the water material as well as
## managing wave generation pipelines.

const WATER_MAT := preload('res://addons/ocean_system/mat_water.tres')
const EDITOR_WATER_PREVIEW_MESH := preload('res://addons/ocean_system/editor_water_preview_mesh.tres')
const OCEAN_REFLECTION_RENDERER := preload('res://addons/ocean_system/ocean_reflection_renderer.gd')
const MAX_CASCADES := 8
const MAX_NEAR_HULLS := 8
## CDLOD mesh: every node is a LOD_GRID x LOD_GRID quad grid; a level-L node is
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
## The water is drawn on a sphere of this radius (meters) touching the camera's
## sea-level point (water.gdshader, EARTH_RADIUS), so it ends at a real horizon.
## Only the drawing: surface queries, buoyancy and the simulation stay flat.
const EARTH_RADIUS := 6371000.0
const SURFACE_QUERY_BYTES_PER_CASCADE := OceanSurfaceQueries.BYTES_PER_CASCADE
const WATER_DEBUG_VIEW_NORMAL := 0

@export_group('Material')
## Template for the water material. OceanSystem renders with a private duplicate
## (applied through the RenderingServer, never saved into the scene), so shader
## parameters set by this node never leak into the template or other oceans.
@export var water_material : ShaderMaterial = WATER_MAT :
	set(value):
		assert(value != null, "OceanSystem.water_material must be set.")
		water_material = value
		_material = null
		if is_node_ready():
			_apply_water_material()
			_push_all_shader_parameters()

@export_group('Wave Parameters')
## Light absorption of the water per color channel, in 1/m. Pure seawater is
## about (0.30, 0.056, 0.012); dissolved organic matter and algae add to it,
## turning clear blue water greener and darker. Sets the deep-water color and how
## light passing through thin wave crests is tinted.
@export var water_absorption := Vector3(0.45, 0.07, 0.03) :
	set(value):
		water_absorption = value
		_set_water_shader_parameter(&'water_absorption', water_absorption)
## Light scattering by particles (sediment, plankton) per color channel, in
## 1/m. More makes the water brighter and more turbid, and crests glow more.
@export var water_scattering := Vector3(0.03, 0.035, 0.04) :
	set(value):
		water_scattering = value
		_set_water_shader_parameter(&'water_scattering', water_scattering)
## How strongly particles scatter forward (Henyey-Greenstein g; ocean particles
## about 0.9). Higher concentrates the crest glow toward the light.
@export_range(0.0, 0.99, 0.01) var water_scattering_anisotropy := 0.85 :
	set(value):
		water_scattering_anisotropy = value
		_set_water_shader_parameter(&'water_scattering_anisotropy', water_scattering_anisotropy)

## Albedo of dense foam (wave, wake and hull edge foam). Foam is a near-neutral
## white scatterer (albedo about 0.8); the lights and sky tint it.
@export_color_no_alpha var foam_color : Color = Color(0.9, 0.92, 0.93) :
	set(value):
		foam_color = value
		_set_water_shader_parameter(&'foam_color', foam_color)

@export_group('Surface Shading')
## Roughness of ripples shorter than the smallest cascade. The shader widens it
## by the wave slopes a pixel cannot resolve, so distant water gets rougher on
## its own; this only sets how sharp the closest sun glints and reflections are.
@export_range(0.0, 1.0, 0.01) var clear_roughness := 0.10 :
	set(value):
		clear_roughness = value
		_set_water_shader_parameter(&'clear_roughness', clear_roughness)
## PBR roughness where foam is visible. Foam usually looks best rougher than
## clear water so it does not produce mirror-like highlights.
@export_range(0.0, 1.0, 0.01) var foam_roughness := 0.24 :
	set(value):
		foam_roughness = value
		_set_water_shader_parameter(&'foam_roughness', foam_roughness)
## Overall strength of normal-map lighting in the fragment shader. Lower values
## make the water calmer visually without changing mesh displacement or queries.
@export_range(0.0, 1.0, 0.01) var normal_strength := 1.0 :
	set(value):
		normal_strength = value
		_set_water_shader_parameter(&'normal_strength', normal_strength)
## Enables bicubic normal filtering for smoother close-up wave detail. This costs
## extra texture samples per cascade, so disable it for low-end presets.
@export var use_bicubic_normals := true :
	set(value):
		use_bicubic_normals = value
		_set_water_shader_parameter(&'use_bicubic_normals', use_bicubic_normals)
## Maximum number of cascades sampled per pixel for foam and normals. Reducing
## this can improve fragment performance while retaining vertex displacement.
@export_range(1, 8, 1) var fragment_cascade_limit := 3 :
	set(value):
		fragment_cascade_limit = clampi(value, 1, MAX_CASCADES)
		_set_water_shader_parameter(&'fragment_cascade_limit', fragment_cascade_limit)

@export_group('Sky Reflection')
## Optional sky source node. SkySystem exposes the expected getters, but any node
## with get_sun_direction(), get_sky_top_color(),
## get_sky_horizon_color(), and get_sun_visibility() can be used. Sources with a
## lighting_changed signal are read only when it fires; others every frame.
@export var sky_source_path : NodePath :
	set(value):
		sky_source_path = value
		if is_node_ready():
			_resolve_sky_source()
			_update_sky_lighting_shader_parameters()
## Fallback zenith sky color used when sky_source_path is empty or the source
## does not expose sky color data.
@export_color_no_alpha var manual_sky_top_color : Color = Color(0.12, 0.42, 0.78) :
	set(value):
		manual_sky_top_color = value
		_update_sky_lighting_shader_parameters()
## Fallback horizon sky color used by procedural reflections when no sky source
## provides a horizon color.
@export_color_no_alpha var manual_sky_horizon_color : Color = Color(0.58, 0.78, 0.94) :
	set(value):
		manual_sky_horizon_color = value
		_update_sky_lighting_shader_parameters()
## Fallback normalized sun direction in world space when no sky source provides
## one. The shader uses it for the sky reflection and the debug views.
@export var manual_sun_direction := Vector3(0.0, 0.2, -1.0) :
	set(value):
		manual_sun_direction = value
		_update_sky_lighting_shader_parameters()
## Fallback sun visibility from 0 to 1 when no sky source provides one. This lets
## manual scenes fade glitter and glow at night without a full SkySystem.
@export_range(0.0, 1.0, 0.01) var manual_sun_visibility := 1.0 :
	set(value):
		manual_sun_visibility = value
		_update_sky_lighting_shader_parameters()
## Enables procedural sky reflection radiance. This is separate from planar
## reflections and remains useful even when no reflected geometry is rendered.
@export var sky_reflection_enabled := true :
	set(value):
		sky_reflection_enabled = value
		_set_water_shader_parameter(&'sky_reflection_enabled', sky_reflection_enabled)
## Overall strength of the water's reflection (sky and planar). It is already
## weighted by Fresnel, so 1 is physical; the engine adds no sky reflection of its own.
@export_range(0.0, 2.0, 0.01) var sky_reflection_strength := 1.0 :
	set(value):
		sky_reflection_strength = value
		_set_water_shader_parameter(&'sky_reflection_strength', sky_reflection_strength)
## Base water reflectance at normal incidence. Real water is near 0.02; artistic
## values above that make reflections visible from more angles.
@export_range(0.0, 0.12, 0.001) var sky_reflection_f0 := 0.02 :
	set(value):
		sky_reflection_f0 = value
		_set_water_shader_parameter(&'sky_reflection_f0', sky_reflection_f0)
## Multiplier for reflected horizon color. Raising it emphasizes the bright band
## near the horizon, especially in distant water.
@export_range(0.0, 3.0, 0.01) var sky_horizon_boost := 0.85 :
	set(value):
		sky_horizon_boost = value
		_set_water_shader_parameter(&'sky_horizon_boost', sky_horizon_boost)
## Multiplier on the sun's specular highlight (glints and the sun path). The
## highlight is lit by the scene's lights (color, energy), so 1 is physical.
@export_range(0.0, 4.0, 0.01) var sun_specular_strength := 1.0 :
	set(value):
		sun_specular_strength = value
		_set_water_shader_parameter(&'sun_specular_strength', sun_specular_strength)
## Facets per square meter that make up the sun glitter: the highlight breaks into
## glints of the few facets that point the sun at the eye, with the same mean
## brightness. Fewer facets give sparser, brighter glints; 0 is a smooth highlight.
@export_range(0.0, 10000000.0, 1000.0, "exp") var sun_glitter_density := 1000000.0 :
	set(value):
		sun_glitter_density = value
		_set_water_shader_parameter(&'sun_glitter_density', sun_glitter_density)
## Glitter patterns per second; consecutive patterns crossfade, so glints twinkle.
@export_range(0.0, 60.0, 0.5) var sun_glitter_rate := 12.0 :
	set(value):
		sun_glitter_rate = value
		_set_water_shader_parameter(&'sun_glitter_rate', sun_glitter_rate)

@export_group('Foam Shading')
## Multiplies the wave foam coverage the cascades produce (their whitecap,
## foam_generation and foam_lifetime). Raise for more whitecaps; lower for
## cleaner water.
@export_range(0.0, 4.0, 0.01) var foam_intensity := 1.0 :
	set(value):
		foam_intensity = value
		_set_water_shader_parameter(&'foam_intensity', foam_intensity)
## Pattern that reveals foam coverage as lace and bubbles: foam shows where the
## pattern exceeds 1 - coverage, so its values must be uniformly distributed
## (see textures/generate_foam_detail.py).
@export var foam_detail_texture : Texture2D = preload('res://addons/ocean_system/textures/foam_detail.png') :
	set(value):
		foam_detail_texture = value
		_set_water_shader_parameter(&'foam_detail', foam_detail_texture)
## World size in meters of one tile of foam_detail_texture.
@export_range(0.5, 64.0, 0.1, "or_greater") var foam_detail_tile_size := 3.0 :
	set(value):
		foam_detail_tile_size = value
		_set_water_shader_parameter(&'foam_detail_tile_size', foam_detail_tile_size)

@export_group('Planar Reflections')
## Renders a mirrored camera into a texture so dynamic scene geometry can appear
## reflected in the water. This is more expensive than procedural sky reflection
## and is created lazily only when enabled.
@export var enable_planar_reflections := true :
	set(value):
		enable_planar_reflections = value
		if is_node_ready(): _update_planar_reflection_settings()
## Maximum side length for the planar reflection texture after resolution_scale
## is applied. Larger values sharpen reflected objects but add render cost.
@export_range(128, 4096, 1) var reflection_texture_size := 1024 :
	set(value):
		reflection_texture_size = value
		if is_node_ready(): _update_planar_reflection_settings()
## Multiplier applied to the main viewport size when sizing the reflection
## texture. Lower values are faster; higher values reduce blur and aliasing.
@export_range(0.1, 1.0, 0.05) var reflection_resolution_scale := 0.5 :
	set(value):
		reflection_resolution_scale = value
		if is_node_ready(): _update_planar_reflection_settings()
## How much reflected scene geometry covers the sky reflection behind it (1 =
## fully, as in reality). Both share the water's Fresnel reflectance and
## sky_reflection_strength.
@export_range(0.0, 1.0, 0.01) var reflection_strength := 1.0 :
	set(value):
		reflection_strength = value
		if is_node_ready(): _update_planar_reflection_settings()
## Visual layer assigned to the ocean while planar reflections are active. The
## reflection camera removes this layer to avoid recursive water reflections.
@export_range(1, 20, 1) var reflection_water_layer := 20 :
	set(value):
		reflection_water_layer = value
		if is_node_ready(): _update_planar_reflection_settings()
## Render-layer mask for objects visible to the reflection camera. The configured
## water layer is always removed even if it is included here.
@export_flags_3d_render var reflection_cull_mask := 0xFFFFF :
	set(value):
		reflection_cull_mask = value
		if is_node_ready(): _update_planar_reflection_settings()
## Clips reflected pixels below the water plane using the reflection viewport's
## depth buffer. This keeps submerged/sinking objects out of planar reflections.
@export var reflection_clip_below_water := true :
	set(value):
		reflection_clip_below_water = value
		if is_node_ready(): _update_planar_reflection_settings()
## Extra distance below the water plane allowed before reflection pixels are
## clipped. Small positive values reduce flicker at waterline intersections.
@export_range(0.0, 1.0, 0.005) var reflection_clip_bias := 0.03 :
	set(value):
		reflection_clip_bias = value
		if is_node_ready(): _update_planar_reflection_settings()

@export_group('Hull Cutouts')
## Ships (HullWaterFootprint nodes) whose bounds come within this distance of the
## camera get water hidden inside their hull; at most 8, nearest first. Farther
## hulls are not cut out: their interior water is too small to see.
@export_range(0.0, 2000.0, 1.0, "or_greater") var hull_cutout_distance := 150.0

@export_group('Interaction')
## Runs the iWave interaction simulation on a window around the camera: hulls
## (HullWaterFootprint) push water and radiate wakes and bow waves. Runtime
## only; the editor shows the FFT ocean alone.
@export var interaction_enabled := true :
	set(value):
		interaction_enabled = value
		if is_node_ready():
			_setup_interaction()
## Simulation grid resolution. The window covers grid size x cell size meters.
@export_enum('256x256:256', '512x512:512', '1024x1024:1024') var interaction_grid_size := 512 :
	set(value):
		interaction_grid_size = value
		if is_node_ready():
			_setup_interaction()
## Meters per simulation cell. Smaller cells resolve shorter waves but shrink
## the window; waves shorter than about 4 cells are not represented.
@export_range(0.1, 4.0, 0.05, "or_greater") var interaction_cell_size := 0.5 :
	set(value):
		interaction_cell_size = value
		if is_node_ready():
			_setup_interaction()
## Velocity damping of simulated waves, in 1/s. Higher values make wakes fade sooner.
@export_range(0.0, 5.0, 0.01, "or_greater") var interaction_damping := 0.2 :
	set(value):
		interaction_damping = value
		_apply_interaction_settings()
## Multiplies gravity in the simulation (wave speed scales with its square root).
## 1 is physical deep-water dispersion.
@export_range(0.1, 4.0, 0.01) var interaction_gravity_scale := 1.0 :
	set(value):
		interaction_gravity_scale = value
		_apply_interaction_settings()
## Viscosity of simulated waves, in m^2/s. Damps short waves far more than long
## ones (rate ~ viscosity * k^2), smoothing grid-scale ripples while leaving
## wakes intact. Above ~3 at 60 physics ticks per second the step is unstable.
@export_range(0.0, 1.0, 0.005, "or_greater") var interaction_viscosity := 0.1 :
	set(value):
		interaction_viscosity = value
		_apply_interaction_settings()
## Width, in cells, of the absorbing border at the window edge. Waves fade out
## there instead of wrapping around; rendering fades over the band inside it.
@export_range(4.0, 128.0, 1.0) var interaction_sponge_cells := 24.0 :
	set(value):
		interaction_sponge_cells = value
		_apply_interaction_settings()
## Extra damping at the very edge of the window, in 1/s.
@export_range(0.0, 60.0, 0.1, "or_greater") var interaction_sponge_damping := 12.0 :
	set(value):
		interaction_sponge_damping = value
		_apply_interaction_settings()
## Foam generated per second by steep simulated waves and advancing hulls.
@export_range(0.0, 10.0, 0.01, "or_greater") var interaction_foam_grow := 1.5 :
	set(value):
		interaction_foam_grow = value
		_apply_interaction_settings()
## Exponential decay rate of simulated foam, in 1/s. Lower values leave longer wake trails.
@export_range(0.0, 10.0, 0.01, "or_greater") var interaction_foam_decay := 0.35 :
	set(value):
		interaction_foam_decay = value
		_apply_interaction_settings()
## Wave slope (rise over run) below which simulated waves make no foam.
@export_range(0.0, 2.0, 0.01) var interaction_foam_slope_threshold := 0.15 :
	set(value):
		interaction_foam_slope_threshold = value
		_apply_interaction_settings()
## Bow foam: foam source per meter of bow-wave rise just outside advancing
## hulls (see HullWaterFootprint.bow_wave_strength).
@export_range(0.0, 20.0, 0.01, "or_greater") var interaction_foam_bow_rate := 0.5 :
	set(value):
		interaction_foam_bow_rate = value
		_apply_interaction_settings()

@export_group('External Wind')
## When enabled, cascades read wind speed and direction from wind_source_path.
## Per-cascade wind_speed_multiplier and wind_direction_offset still apply.
## Switching it crossfades the cascades to the new wind like any other change.
@export var use_external_wind := false :
	set(value):
		use_external_wind = value
		if is_node_ready():
			_resolve_wind_source()
## Wind source node, required when use_external_wind is enabled. It must expose
## get_wind_speed() and get_wind_direction_degrees(), or wind_speed and
## wind_direction properties.
@export var wind_source_path : NodePath :
	set(value):
		wind_source_path = value
		if is_node_ready():
			_resolve_wind_source()

## Ordered list of wave cascades. Use long tile lengths for swell and short tile
## lengths for chop/detail. Adding or removing cascades recreates compute GPU
## resources; editing values inside a cascade usually only regenerates spectra.
@export var parameters : Array[WaveCascadeParameters] :
	set(value):
		for existing_param in parameters:
			if existing_param and existing_param.scale_changed.is_connected(_update_scales_uniform):
				existing_param.scale_changed.disconnect(_update_scales_uniform)

		var new_parameters := value
		if new_parameters.size() > MAX_CASCADES:
			push_error("OceanSystem supports at most %d wave cascades; the extra ones are dropped." % MAX_CASCADES)
			new_parameters.resize(MAX_CASCADES)

		var new_size := len(new_parameters)
		for i in range(new_size):
			# Inspector array slots start empty; give them a valid cascade resource.
			if not new_parameters[i]: new_parameters[i] = WaveCascadeParameters.new()
			if not new_parameters[i].is_connected(&'scale_changed', _update_scales_uniform):
				new_parameters[i].scale_changed.connect(_update_scales_uniform)
			# Offset cascade start times so layered waves are less likely to align.
			new_parameters[i].initialize_runtime_state(
				Vector2i(rng.randi_range(-10000, 10000), rng.randi_range(-10000, 10000)),
				120.0 + PI*i
			)
		parameters = new_parameters
		if is_node_ready():
			_setup_wave_generator()
		_update_scales_uniform()

@export_group('Performance Parameters')
## Resolution for each displacement/normal texture layer and FFT simulation.
## Cost scales roughly with resolution squared; 512 is much cheaper than 1024.
@export_enum('128x128:128', '256x256:256', '512x512:512', '1024x1024:1024') var simulation_map_size := 512 :
	set(value):
		simulation_map_size = value
		if is_node_ready():
			_setup_wave_generator()

@export_group('Mesh')
## Vertex spacing in meters of the finest mesh level, nearest the camera. Every
## level doubles it, about every 3 * 16 * spacing meters of distance. Smaller
## values give smoother near displacement but more vertices.
@export_range(0.25, 16.0, 0.25) var mesh_base_cell_size := 1.0

## How far, as a share of its shortest wavelength, a cascade's waves may travel
## between two FFT updates; frames in between blend the two. Each cascade gets
## its own rate from this (small tiles more often, up to every frame, which needs
## no blend). Blending frames whose waves moved too far washes the ripples out
## and back every update. Lower is smoother and costs more GPU time.
@export_range(0.02, 0.5, 0.01) var max_wave_phase_step := 0.1

@export_group('Water Queries')
## Still-water height in world units. Visual displacement, point queries, planar
## reflection plane height, and buoyancy samples all use this as the base level.
@export var water_level := 0.0 :
	set(value):
		water_level = value
		if is_node_ready(): _update_planar_reflection_settings()


var wave_generator : WaveGenerator :
	set(value):
		if wave_generator:
			wave_generator.queue_free()
		wave_generator = value
		if wave_generator:
			add_child(wave_generator)
var rng = RandomNumberGenerator.new()
var time := 0.0
var wind_source : Node
var sky_source : Node
## True when sky_source has no lighting_changed signal and must be read every frame.
var _sky_source_polled := false
## Set by the sky source's lighting_changed signal.
var _sky_lighting_dirty := false

## The generator's maps A and B (see WaveGenerator), bound to the water material.
var displacement_maps_a := Texture2DArrayRD.new()
var displacement_maps_b := Texture2DArrayRD.new()
var normal_maps_a := Texture2DArrayRD.new()
var normal_maps_b := Texture2DArrayRD.new()
var _material : ShaderMaterial
var _surface_queries : OceanSurfaceQueries
## True once every cascade has a frame.
var _has_wave_output := false
## Per cascade: ocean time of its newest and of its previous frame, and how many
## frames it has computed (see _update_waves()).
var _cascade_frame_times := PackedFloat64Array()
var _cascade_previous_frame_times := PackedFloat64Array()
var _cascade_frame_counts := PackedInt32Array()
var _reflection_renderer : OceanReflectionRenderer
var _hull_profiles : Texture2DArray
## Instance ids of the profiles in _hull_profiles, in layer order.
var _hull_profile_ids := PackedInt64Array()
## Null while interaction_enabled is off, in the editor, or before _ready.
var _interaction : WaterInteractionSim
var _interaction_texture := Texture2DRD.new()
## Runtime mesh (see _setup_water_mesh); unused in the editor.
var _lod_grid_mesh : ArrayMesh
var _lod_multimesh : RID
var _lod_buffer := PackedFloat32Array()
var _lod_uploaded_buffer := PackedFloat32Array()
var _lod_node_count := 0
## range(L) per level, and where morphing toward level L + 1 starts.
var _lod_ranges := PackedFloat32Array()
var _lod_morph_starts := PackedFloat32Array()
var _lod_top_level := 0
## mesh_base_cell_size the ranges were built for.
var _lod_ranges_key := 0.0
## Radius of the water drawn this frame (see _update_lod_grid()).
var _lod_radius := 0.0
var _lod_camera_position := Vector3.ZERO
var _lod_frustum : Array[Plane] = []

func _init() -> void:
	rng.set_seed(1234) # This seed gives big waves!

# Joined on enter (before any _ready) so consumers can find the ocean in their own _ready.
func _enter_tree() -> void:
	add_to_group(&"ocean_system")

func _ready() -> void:
	process_priority = 100
	var device := RenderingServer.get_rendering_device()
	if device == null:
		push_error("OceanSystem needs a RenderingDevice (Forward+ or Mobile renderer). The ocean is disabled.")
		set_process(false)
		return
	_surface_queries = OceanSurfaceQueries.new(device)
	_apply_water_material()
	_resolve_wind_source()
	_resolve_sky_source()
	_setup_water_mesh()
	_setup_wave_generator()
	_setup_interaction()
	_push_all_shader_parameters()

func _process(delta : float) -> void:
	if not Engine.is_editor_hint():
		_update_lod_grid()
	_update_hull_cutouts()
	if _sky_source_polled or _sky_lighting_dirty:
		_update_sky_lighting_shader_parameters()
	time += delta
	# No generator means no cascades: a flat ocean.
	if wave_generator != null:
		_update_waves(delta)
		_update_frame_blend_uniform()
	_dispatch_surface_queries()

## The interaction simulation steps with physics: one step per tick sees exactly
## one new pose of every hull, so hull motion reaches it without stutter.
func _physics_process(delta : float) -> void:
	_step_interaction(delta)

## Pushes every shader parameter this node owns into the current water material.
func _push_all_shader_parameters() -> void:
	_set_water_shader_parameter(&'foam_color', foam_color)
	_set_water_shader_parameter(&'normal_strength', normal_strength)
	_set_water_shader_parameter(&'use_bicubic_normals', use_bicubic_normals)
	_set_water_shader_parameter(&'fragment_cascade_limit', fragment_cascade_limit)
	_set_water_shader_parameter(&'clear_roughness', clear_roughness)
	_set_water_shader_parameter(&'foam_roughness', foam_roughness)
	_set_water_shader_parameter(&'foam_intensity', foam_intensity)
	_set_water_shader_parameter(&'foam_detail', foam_detail_texture)
	_set_water_shader_parameter(&'foam_detail_tile_size', foam_detail_tile_size)
	_update_sky_shading_static_parameters()
	_update_sky_lighting_shader_parameters()
	_lod_ranges_key = 0.0
	_update_lod_ranges()
	_update_scales_uniform()
	_bind_wave_textures()
	_update_frame_blend_uniform()
	_hull_profile_ids = PackedInt64Array()
	_update_hull_cutouts()
	_update_planar_reflection_settings()
	_push_interaction_shader_parameters()

func _setup_wave_generator() -> void:
	_surface_queries.clear_uniform_set_cache()
	if _interaction != null:
		_interaction.clear_uniform_set_cache()
	_has_wave_output = false
	_cascade_frame_times.resize(parameters.size())
	_cascade_previous_frame_times.resize(parameters.size())
	_cascade_frame_counts.resize(parameters.size())
	_cascade_frame_counts.fill(0)
	if parameters.is_empty():
		wave_generator = null
		_set_texture_rid(displacement_maps_a, RID())
		_set_texture_rid(displacement_maps_b, RID())
		_set_texture_rid(normal_maps_a, RID())
		_set_texture_rid(normal_maps_b, RID())
		_bind_wave_textures()
		return
	for param in parameters:
		param.request_spectrum_reset()

	wave_generator = WaveGenerator.new()
	wave_generator.map_size = simulation_map_size
	wave_generator.init_gpu(parameters.size())

	_set_texture_rid(displacement_maps_a, wave_generator.descriptors[&'displacement_map_a'].rid)
	_set_texture_rid(displacement_maps_b, wave_generator.descriptors[&'displacement_map_b'].rid)
	_set_texture_rid(normal_maps_a, wave_generator.descriptors[&'normal_map_a'].rid)
	_set_texture_rid(normal_maps_b, wave_generator.descriptors[&'normal_map_b'].rid)
	_bind_wave_textures()
	_update_frame_blend_uniform()
	_update_spectrum_blend_uniform()

func _bind_wave_textures() -> void:
	_set_water_shader_parameter(&'num_cascades', parameters.size() if wave_generator != null else 0)
	_set_water_shader_parameter(&'displacements_a', displacement_maps_a)
	_set_water_shader_parameter(&'displacements_b', displacement_maps_b)
	_set_water_shader_parameter(&'normals_a', normal_maps_a)
	_set_water_shader_parameter(&'normals_b', normal_maps_b)

func _update_scales_uniform() -> void:
	var map_scales : PackedVector4Array; map_scales.resize(parameters.size())
	for i in parameters.size():
		var params := parameters[i]
		var uv_scale := Vector2.ONE / params.tile_length
		map_scales[i] = Vector4(uv_scale.x, uv_scale.y, params.displacement_scale, params.normal_scale)
	_set_water_shader_parameter(&'map_scales', map_scales)
	_update_spectrum_blend_uniform()

func _update_spectrum_blend_uniform() -> void:
	var spectrum_blend_states : PackedVector4Array; spectrum_blend_states.resize(parameters.size())
	for i in parameters.size():
		spectrum_blend_states[i] = parameters[i].get_spectrum_blend_state(i)
	_set_water_shader_parameter(&'spectrum_blend_states', spectrum_blend_states)

## Updates every cascade whose newest frame the display has reached. A cascade
## computes its next frame one update interval ahead of now, so blending from
## its newest frame to that one shows the waves at the current time.
func _update_waves(frame_delta : float) -> void:
	var external_speed := get_external_wind_speed() if use_external_wind else 0.0
	var external_direction := get_external_wind_direction() if use_external_wind else 0.0
	var all_have_frames := true
	for i in parameters.size():
		var count := _cascade_frame_counts[i]
		if count > 0 and time < _cascade_frame_times[i]:
			continue
		var interval := get_cascade_update_interval(parameters[i])
		if interval <= frame_delta:
			interval = 0.0 # Every frame: shown as computed, no blend.
		var frame_time := time + interval
		parameters[i].advance(frame_time - _cascade_frame_times[i] if count > 0 else 0.0, external_speed, external_direction, use_external_wind)
		wave_generator.update_cascade(i, parameters[i])
		_cascade_previous_frame_times[i] = _cascade_frame_times[i]
		_cascade_frame_times[i] = frame_time
		_cascade_frame_counts[i] = count + 1
	for count in _cascade_frame_counts:
		all_have_frames = all_have_frames and count > 0
	_has_wave_output = all_have_frames
	_update_spectrum_blend_uniform()

## Seconds between a cascade's FFT updates: its shortest wave (two texels) may
## travel max_wave_phase_step of its length, at deep-water phase speed
## sqrt(g lambda / 2 pi).
func get_cascade_update_interval(params : WaveCascadeParameters) -> float:
	var shortest_wavelength := 2.0 * minf(params.tile_length.x, params.tile_length.y) / simulation_map_size
	return max_wave_phase_step * sqrt(TAU * shortest_wavelength / WaveGenerator.G)

## Queues points for this frame's surface query. Call it every tick with the
## current points; the latest submission per owner wins. Owners must call
## release_surface_query() when they stop querying (e.g. in _exit_tree).
func submit_surface_query(owner: Object, points: PackedVector3Array) -> void:
	assert(owner != null, "Surface queries need a stable owner object.")
	_surface_queries.submit(owner.get_instance_id(), points)

## Latest completed query for owner, or null until the first readback arrives
## (a few frames after the first submit). The result's points may differ from
## the most recent submission; compare before using samples by index.
func get_surface_query_result(owner: Object) -> WaterSurfaceQueryResult:
	return _surface_queries.get_result(owner.get_instance_id())

func release_surface_query(owner: Object) -> void:
	_surface_queries.release(owner.get_instance_id())

## Frames whose queries were delayed because all readback slots were busy.
func get_skipped_surface_query_dispatch_count() -> int:
	return _surface_queries.skipped_dispatch_count

func should_use_external_wind() -> bool:
	return use_external_wind

func get_wind_source() -> Node:
	return wind_source

func get_external_wind_speed() -> float:
	return _read_wind_value(&'get_wind_speed', &'wind_speed')

func get_external_wind_direction() -> float:
	return _read_wind_value(&'get_wind_direction_degrees', &'wind_direction')

func _read_wind_value(method: StringName, property: StringName) -> float:
	assert(wind_source != null, "OceanSystem has no wind source; set wind_source_path.")
	if wind_source.has_method(method):
		return float(wind_source.call(method))
	var value = wind_source.get(property)
	assert(value != null, "Wind source %s has neither %s() nor a %s property." % [wind_source.get_path(), method, property])
	return float(value)

func get_sky_source() -> Node:
	return sky_source

func get_water_material() -> ShaderMaterial:
	if _material == null:
		_material = water_material.duplicate()
	return _material

func _apply_water_material() -> void:
	RenderingServer.instance_geometry_set_material_override(get_instance(), get_water_material().get_rid())

## Queues a splash in the interaction simulation: a Gaussian bump of radius
## meters and amplitude meters at position, applied on the next step.
func add_water_impulse(position: Vector3, radius: float, amplitude: float) -> void:
	assert(_interaction != null, "add_water_impulse() needs interaction_enabled and only works at runtime.")
	_interaction.add_impulse(position, radius, amplitude)

func _setup_interaction() -> void:
	if _interaction != null:
		_interaction_texture.texture_rd_rid = RID()
		_interaction.release()
		_interaction = null
		# Query uniform sets that referenced the old render texture are freed with it.
		_surface_queries.clear_uniform_set_cache()
	# The simulation follows the game camera and does not run in the editor.
	if interaction_enabled and not Engine.is_editor_hint():
		_interaction = WaterInteractionSim.new(RenderingServer.get_rendering_device(), interaction_grid_size, interaction_cell_size)
		_apply_interaction_settings()
		_interaction_texture.texture_rd_rid = _interaction.render_texture
	_push_interaction_shader_parameters()

func _apply_interaction_settings() -> void:
	# Tunables are copied into the simulation when it exists (see _setup_interaction).
	if _interaction == null:
		return
	_interaction.damping = interaction_damping
	_interaction.viscosity = interaction_viscosity
	_interaction.gravity_scale = interaction_gravity_scale
	_interaction.sponge_cells = interaction_sponge_cells
	_interaction.sponge_damping = interaction_sponge_damping
	_interaction.foam_grow = interaction_foam_grow
	_interaction.foam_decay = interaction_foam_decay
	_interaction.foam_slope_threshold = interaction_foam_slope_threshold
	_interaction.foam_bow_rate = interaction_foam_bow_rate
	_set_water_shader_parameter(&'interaction_window', _get_interaction_window())

func _push_interaction_shader_parameters() -> void:
	_set_water_shader_parameter(&'interaction_enabled', _interaction != null)
	_set_water_shader_parameter(&'interaction_render', _interaction_texture)
	_set_water_shader_parameter(&'interaction_cell_size', interaction_cell_size)
	_set_water_shader_parameter(&'interaction_inv_extent', 1.0 / (float(interaction_grid_size) * interaction_cell_size))
	_set_water_shader_parameter(&'interaction_window', _get_interaction_window())

## (window center x, center z, fade start, fade end): rendering and queries fade
## the simulation out by Chebyshev distance from the center, ending where the
## absorbing border begins.
func _get_interaction_window() -> Vector4:
	if _interaction == null:
		return Vector4.ZERO
	var center := _interaction.get_window_center()
	var half_extent := _interaction.get_half_extent()
	var sponge_width := interaction_sponge_cells * interaction_cell_size
	return Vector4(center.x, center.y, half_extent - 2.0 * sponge_width, half_extent - sponge_width)

func _step_interaction(delta : float) -> void:
	# Disabled, or nothing to sample the incident waves from before the first FFT output.
	if _interaction == null or not _has_wave_output:
		return
	var camera := get_viewport().get_camera_3d()
	# The window follows the active camera; without one there is nothing to center on.
	if camera == null:
		return
	var hull_data := _pack_interaction_hulls(camera.global_position)
	var hull_profiles_rd := RenderingServer.texture_get_rd_texture(_hull_profiles.get_rid()) if _hull_profiles != null else RID()
	_interaction.step(
		delta,
		camera.global_position,
		hull_data,
		hull_data.size() / WaterInteractionSim.FLOATS_PER_HULL,
		_pack_surface_query_cascades(),
		parameters.size(),
		water_level,
		wave_generator.descriptors[&'displacement_map_a'].rid,
		wave_generator.descriptors[&'displacement_map_b'].rid,
		hull_profiles_rd
	)
	_set_water_shader_parameter(&'interaction_window', _get_interaction_window())

## SimHull records (see iwave_pressure.glsl) for up to WaterInteractionSim.MAX_HULLS
## wake-enabled hulls that reach into the simulation window, nearest first.
func _pack_interaction_hulls(camera_position : Vector3) -> PackedFloat32Array:
	var reach := _interaction.get_half_extent() * sqrt(2.0)
	var candidates : Array[Dictionary] = []
	for node in get_tree().get_nodes_in_group(&"ocean_hull"):
		var footprint := node as HullWaterFootprint
		# Footprints without a baked profile report their own error and contribute nothing.
		if footprint.profile == null or not footprint.wake_enabled or not footprint.is_visible_in_tree():
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
		for row in _get_world_to_local_rows(footprint):
			_append_vector4(data, row)
		_append_vector4(data, Vector4(sphere.x, sphere.z, sphere.w, sphere.y))
		_append_vector4(data, Vector4(profile.min_z, profile.min_y, 1.0 / (profile.max_z - profile.min_z), 1.0 / (profile.max_y - profile.min_y)))
		_append_vector4(data, Vector4(float(_hull_profile_ids.find(profile.get_instance_id())), profile.center_x, 1.0 / profile.max_half_width, 0.0))
		_append_vector4(data, Vector4(footprint.wake_strength, footprint.wake_edge_softness, footprint.bow_wave_strength, footprint.bow_wave_max_rise))
		_append_vector4(data, Vector4(center_velocity.x, center_velocity.y, center_velocity.z, 0.0))
		_append_vector4(data, Vector4(footprint.angular_velocity.x, footprint.angular_velocity.y, footprint.angular_velocity.z, 0.0))
	return data

## Rows of the footprint's world-to-local affine transform: xyz = basis row, w = origin.
func _get_world_to_local_rows(footprint : HullWaterFootprint) -> Array[Vector4]:
	var world_to_local := footprint.global_transform.affine_inverse()
	var basis := world_to_local.basis
	var origin := world_to_local.origin
	return [
		Vector4(basis.x.x, basis.y.x, basis.z.x, origin.x),
		Vector4(basis.x.y, basis.y.y, basis.z.y, origin.y),
		Vector4(basis.x.z, basis.y.z, basis.z.z, origin.z),
	]

func _append_vector4(data : PackedFloat32Array, value : Vector4) -> void:
	data.push_back(value.x)
	data.push_back(value.y)
	data.push_back(value.z)
	data.push_back(value.w)

func _update_sky_shading_static_parameters() -> void:
	_set_water_shader_parameter(&'water_absorption', water_absorption)
	_set_water_shader_parameter(&'water_scattering', water_scattering)
	_set_water_shader_parameter(&'water_scattering_anisotropy', water_scattering_anisotropy)
	_set_water_shader_parameter(&'sky_reflection_enabled', sky_reflection_enabled)
	_set_water_shader_parameter(&'sky_reflection_strength', sky_reflection_strength)
	_set_water_shader_parameter(&'sky_reflection_f0', sky_reflection_f0)
	_set_water_shader_parameter(&'sky_horizon_boost', sky_horizon_boost)
	_set_water_shader_parameter(&'sun_specular_strength', sun_specular_strength)
	_set_water_shader_parameter(&'sun_glitter_density', sun_glitter_density)
	_set_water_shader_parameter(&'sun_glitter_rate', sun_glitter_rate)
	_set_water_shader_parameter(&'water_debug_view', WATER_DEBUG_VIEW_NORMAL)

func _update_sky_lighting_shader_parameters() -> void:
	_sky_lighting_dirty = false
	var sun_direction := _get_sky_vector(&'get_sun_direction', &'sun_direction', manual_sun_direction)
	assert(sun_direction.length_squared() > 0.0001, "Sun direction must be non-zero.")
	sun_direction = sun_direction.normalized()
	_set_water_shader_parameter(&'sky_sun_direction', sun_direction)
	_set_water_shader_parameter(&'sky_top_color', _get_sky_color(&'get_sky_top_color', &'sky_top_color', manual_sky_top_color))
	_set_water_shader_parameter(&'sky_horizon_color', _get_sky_color(&'get_sky_horizon_color', &'sky_horizon_color', manual_sky_horizon_color))
	_set_water_shader_parameter(&'sky_ground_horizon_color', _get_sky_color(&'get_sky_ground_horizon_color', &'sky_ground_horizon_color', manual_sky_horizon_color.darkened(0.25)))
	_set_water_shader_parameter(&'sky_ground_bottom_color', _get_sky_color(&'get_sky_ground_bottom_color', &'sky_ground_bottom_color', manual_sky_top_color.darkened(0.55)))
	_set_water_shader_parameter(&'sky_sun_visibility', _get_sky_float(&'get_sun_visibility', &'sun_visibility', manual_sun_visibility))
	# Optional: a sky source without clouds simply lacks the method.
	var cloud_cubemap : Texture = sky_source.call(&'get_cloud_cubemap') if sky_source != null and sky_source.has_method(&'get_cloud_cubemap') else null
	_set_water_shader_parameter(&'sky_clouds_enabled', cloud_cubemap != null)
	_set_water_shader_parameter(&'sky_cloud_cubemap', cloud_cubemap)
	# Optional haze over the sea, put over the reflected sky; a source without it
	# lacks the methods.
	var has_haze := sky_source != null and sky_source.has_method(&'get_haze_density')
	_set_water_shader_parameter(&'sky_haze_density', float(sky_source.call(&'get_haze_density')) if has_haze else 0.0)
	if has_haze:
		_set_water_shader_parameter(&'sky_haze_scale_height', float(sky_source.call(&'get_haze_scale_height')))
		_set_water_shader_parameter(&'sky_haze_anisotropy', float(sky_source.call(&'get_haze_anisotropy')))
		_set_water_shader_parameter(&'sky_haze_light_direction', sky_source.call(&'get_haze_light_direction'))
		var light_color : Color = sky_source.call(&'get_haze_light_color')
		var ambient_color : Color = sky_source.call(&'get_haze_ambient_color')
		_set_water_shader_parameter(&'sky_haze_light_color', Vector3(light_color.r, light_color.g, light_color.b))
		_set_water_shader_parameter(&'sky_haze_ambient_color', Vector3(ambient_color.r, ambient_color.g, ambient_color.b))

# The sky source is duck-typed and may provide only some values; missing ones
# fall back to the manual_* exports.
func _get_sky_vector(method: StringName, property: StringName, fallback: Vector3) -> Vector3:
	if sky_source == null:
		return fallback
	if sky_source.has_method(method):
		return sky_source.call(method)
	var property_value = sky_source.get(property)
	return property_value if property_value is Vector3 else fallback

func _get_sky_color(method: StringName, property: StringName, fallback: Color) -> Color:
	if sky_source == null:
		return fallback
	if sky_source.has_method(method):
		return sky_source.call(method)
	var property_value = sky_source.get(property)
	return property_value if property_value is Color else fallback

func _get_sky_float(method: StringName, property: StringName, fallback: float) -> float:
	if sky_source == null:
		return fallback
	if sky_source.has_method(method):
		return float(sky_source.call(method))
	var property_value = sky_source.get(property)
	return float(property_value) if property_value != null else fallback

func _resolve_wind_source() -> void:
	wind_source = null if wind_source_path.is_empty() else get_node(wind_source_path)
	if use_external_wind and wind_source == null:
		push_error("OceanSystem.use_external_wind is enabled but wind_source_path is empty: %s" % get_path())

func _resolve_sky_source() -> void:
	# A freed source was disconnected by the engine.
	if is_instance_valid(sky_source) and sky_source.has_signal(&'lighting_changed') and sky_source.is_connected(&'lighting_changed', _on_sky_lighting_changed):
		sky_source.disconnect(&'lighting_changed', _on_sky_lighting_changed)
	sky_source = null if sky_source_path.is_empty() else get_node(sky_source_path)
	var signals_changes := sky_source != null and sky_source.has_signal(&'lighting_changed')
	_sky_source_polled = sky_source != null and not signals_changes
	if signals_changes:
		sky_source.connect(&'lighting_changed', _on_sky_lighting_changed)

func _on_sky_lighting_changed() -> void:
	_sky_lighting_dirty = true

## The editor shows the shared preview plane. At runtime the ocean is a CDLOD
## quadtree of grid nodes drawn as one multimesh, set directly as this instance's
## base through the RenderingServer, so no generated mesh is ever saved.
func _setup_water_mesh() -> void:
	if Engine.is_editor_hint():
		mesh = EDITOR_WATER_PREVIEW_MESH
		extra_cull_margin = maxf(256.0, EDITOR_WATER_PREVIEW_MESH.size.length() * 0.5)
		return
	_lod_grid_mesh = _create_lod_grid_mesh()
	_lod_multimesh = RenderingServer.multimesh_create()
	RenderingServer.multimesh_set_mesh(_lod_multimesh, _lod_grid_mesh.get_rid())
	RenderingServer.multimesh_allocate_data(_lod_multimesh, MAX_LOD_NODES, RenderingServer.MULTIMESH_TRANSFORM_3D, false, true)
	RenderingServer.multimesh_set_visible_instances(_lod_multimesh, 0)
	RenderingServer.instance_set_base(get_instance(), _lod_multimesh)
	_lod_buffer.resize(MAX_LOD_NODES * LOD_INSTANCE_FLOATS)
	# Identity instance transforms (the shader places the vertices): 3x4 rows.
	for i in MAX_LOD_NODES:
		_lod_buffer[i * LOD_INSTANCE_FLOATS] = 1.0
		_lod_buffer[i * LOD_INSTANCE_FLOATS + 5] = 1.0
		_lod_buffer[i * LOD_INSTANCE_FLOATS + 10] = 1.0

## LOD_GRID x LOD_GRID quads; UV holds the lattice coordinates (0..LOD_GRID).
func _create_lod_grid_mesh() -> ArrayMesh:
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

## Selects the CDLOD nodes around the active camera and uploads them as multimesh
## instances (custom data: node origin x, z, vertex spacing, level).
func _update_lod_grid() -> void:
	var camera := get_viewport().get_camera_3d()
	# No active camera yet (e.g. while a scene is loading): draw nothing.
	if camera == null:
		RenderingServer.multimesh_set_visible_instances(_lod_multimesh, 0)
		return
	_update_lod_ranges()
	_lod_camera_position = camera.global_position
	_lod_frustum = camera.get_frustum()
	_lod_node_count = 0
	# Out to the horizon: the farthest point of the sphere visible from the camera's
	# height, plus how far beyond it a wave crest LOD_WAVE_MARGIN high still shows.
	# Nothing past the far plane is drawn anyway.
	var height := maxf(_lod_camera_position.y - global_position.y, 0.0)
	_lod_radius = minf(sqrt(2.0 * EARTH_RADIUS * height) + sqrt(2.0 * EARTH_RADIUS * LOD_WAVE_MARGIN), camera.far)
	var top_level := _get_lod_top_level(_lod_radius)
	if top_level != _lod_top_level:
		_lod_top_level = top_level
		_set_water_shader_parameter(&'lod_top_level', _lod_top_level)
	var top_size := mesh_base_cell_size * LOD_GRID * float(1 << _lod_top_level)
	var first := ((Vector2(_lod_camera_position.x, _lod_camera_position.z) - Vector2.ONE * _lod_radius) / top_size).floor()
	var root_count := int(ceil(2.0 * _lod_radius / top_size)) + 1
	for iz in root_count:
		for ix in root_count:
			_select_lod_node((first + Vector2(ix, iz)) * top_size, _lod_top_level)
	if _lod_buffer != _lod_uploaded_buffer:
		RenderingServer.multimesh_set_buffer(_lod_multimesh, _lod_buffer)
		_lod_uploaded_buffer = _lod_buffer.duplicate()
	RenderingServer.multimesh_set_visible_instances(_lod_multimesh, _lod_node_count)
	# Instance transforms are identity, so culling needs explicit bounds (local space).
	var center := to_local(_lod_camera_position)
	var drop := _get_curvature_drop(_lod_radius)
	RenderingServer.multimesh_set_custom_aabb(_lod_multimesh, AABB(Vector3(center.x - _lod_radius, -LOD_WAVE_MARGIN - drop, center.z - _lod_radius), Vector3(2.0 * _lod_radius, 2.0 * LOD_WAVE_MARGIN + drop, 2.0 * _lod_radius)))

## Splits a node while it comes within the next finer level's range. A node may
## end up drawn at a finer level than its distance needs; its vertices are then
## fully morphed, which matches the coarser neighbours exactly.
func _select_lod_node(origin : Vector2, level : int) -> void:
	var size := mesh_base_cell_size * LOD_GRID * float(1 << level)
	var camera_xz := Vector2(_lod_camera_position.x, _lod_camera_position.z)
	var nearest := Vector2(clampf(camera_xz.x, origin.x, origin.x + size), clampf(camera_xz.y, origin.y, origin.y + size))
	var nearest_horizontal := nearest.distance_to(camera_xz)
	if nearest_horizontal > _lod_radius:
		return
	# Lowered by the curvature between the node's nearest and farthest points.
	var farthest := Vector2(maxf(absf(camera_xz.x - origin.x), absf(camera_xz.x - origin.x - size)), maxf(absf(camera_xz.y - origin.y), absf(camera_xz.y - origin.y - size)))
	var top := global_position.y + LOD_WAVE_MARGIN - _get_curvature_drop(nearest_horizontal)
	var bottom := global_position.y - LOD_WAVE_MARGIN - _get_curvature_drop(farthest.length())
	var bounds := AABB(Vector3(origin.x - LOD_WAVE_MARGIN, bottom, origin.y - LOD_WAVE_MARGIN), Vector3(size + 2.0 * LOD_WAVE_MARGIN, top - bottom, size + 2.0 * LOD_WAVE_MARGIN))
	if not _is_in_lod_frustum(bounds):
		return
	# The shader measures morph distances to the undisplaced vertex; this is the
	# nearest such point of the node, so it never overestimates them.
	var nearest_distance := _lod_camera_position.distance_to(Vector3(nearest.x, global_position.y, nearest.y))
	if level > 0 and nearest_distance < _lod_ranges[level - 1]:
		var half := size * 0.5
		for child in 4:
			_select_lod_node(origin + Vector2(child & 1, child >> 1) * half, level - 1)
		return
	assert(_lod_node_count < MAX_LOD_NODES, "Ocean LOD node budget exceeded; raise mesh_base_cell_size or lower the camera's far plane.")
	var offset := _lod_node_count * LOD_INSTANCE_FLOATS + 12
	_lod_buffer[offset] = origin.x
	_lod_buffer[offset + 1] = origin.y
	_lod_buffer[offset + 2] = size / LOD_GRID
	_lod_buffer[offset + 3] = level
	_lod_node_count += 1

func _is_in_lod_frustum(bounds : AABB) -> bool:
	for plane in _lod_frustum:
		# The AABB corner farthest along the plane's normal (planes point outward).
		var corner := bounds.position + Vector3(
			bounds.size.x if plane.normal.x < 0.0 else 0.0,
			bounds.size.y if plane.normal.y < 0.0 else 0.0,
			bounds.size.z if plane.normal.z < 0.0 else 0.0)
		if plane.is_point_over(corner):
			return false
	return true

## How far below the camera's tangent plane the drawn water is at a horizontal
## distance (meters), as the shader's earth_curvature_drop().
func _get_curvature_drop(distance : float) -> float:
	return distance * distance * 0.5 / EARTH_RADIUS

## The coarsest level whose range covers the radius.
func _get_lod_top_level(radius : float) -> int:
	var base_range := LOD_RANGE_FACTOR * mesh_base_cell_size * LOD_GRID
	var level := 0
	while base_range * float(1 << level) < radius:
		level += 1
	assert(level < MAX_LOD_LEVELS, "Too many ocean LOD levels for the camera's far plane / mesh_base_cell_size.")
	return level

## Rebuilds the level ranges when mesh_base_cell_size changed.
func _update_lod_ranges() -> void:
	if mesh_base_cell_size == _lod_ranges_key:
		return
	_lod_ranges_key = mesh_base_cell_size
	var base_range := LOD_RANGE_FACTOR * mesh_base_cell_size * LOD_GRID
	_lod_ranges.resize(MAX_LOD_LEVELS)
	_lod_morph_starts.resize(MAX_LOD_LEVELS)
	for level in MAX_LOD_LEVELS:
		var level_range := base_range * float(1 << level)
		var previous_range := 0.0 if level == 0 else _lod_ranges[level - 1]
		_lod_ranges[level] = level_range
		_lod_morph_starts[level] = lerpf(previous_range, level_range, LOD_MORPH_START)
	_push_lod_grid_shader_parameters()

func _push_lod_grid_shader_parameters() -> void:
	_set_water_shader_parameter(&'lod_grid_enabled', not Engine.is_editor_hint())
	_set_water_shader_parameter(&'lod_ranges', _lod_ranges)
	_set_water_shader_parameter(&'lod_morph_starts', _lod_morph_starts)
	_set_water_shader_parameter(&'lod_top_level', _lod_top_level)

func _update_planar_reflection_settings() -> void:
	# Reflections never render in the editor, and the renderer is only created once enabled.
	if Engine.is_editor_hint() or (_reflection_renderer == null and not enable_planar_reflections):
		_set_water_shader_parameter(&'planar_reflection_enabled', false)
		_set_water_shader_parameter(&'planar_reflection_strength', 0.0)
		_set_water_shader_parameter(&'planar_reflection_plane_y', water_level)
		return
	if _reflection_renderer == null:
		_reflection_renderer = OCEAN_REFLECTION_RENDERER.new()
		_reflection_renderer.name = "OceanReflectionRenderer"
		add_child(_reflection_renderer)
	_reflection_renderer.enabled = enable_planar_reflections
	_reflection_renderer.texture_size = reflection_texture_size
	_reflection_renderer.resolution_scale = reflection_resolution_scale
	_reflection_renderer.reflection_strength = reflection_strength
	_reflection_renderer.water_layer = reflection_water_layer
	_reflection_renderer.reflection_cull_mask = reflection_cull_mask
	_reflection_renderer.clip_below_water = reflection_clip_below_water
	_reflection_renderer.clip_bias = reflection_clip_bias
	_reflection_renderer.apply(self, water_level)


func _update_hull_cutouts() -> void:
	var footprints : Array[HullWaterFootprint] = []
	for node in get_tree().get_nodes_in_group(&"ocean_hull"):
		var footprint := node as HullWaterFootprint
		# Footprints without a baked profile report their own error and contribute nothing.
		if footprint.profile != null:
			footprints.push_back(footprint)
	_update_hull_profile_array(footprints)

	var near : Array[Dictionary] = []
	var camera := get_viewport().get_camera_3d()
	# Without an active camera there is no "near"; nothing is cut out.
	if camera != null:
		for footprint in footprints:
			if not footprint.cutout_enabled or not footprint.is_visible_in_tree():
				continue
			var sphere := footprint.get_world_bounding_sphere()
			var distance := maxf(camera.global_position.distance_to(Vector3(sphere.x, sphere.y, sphere.z)) - sphere.w, 0.0)
			if distance <= hull_cutout_distance:
				near.push_back({"distance": distance, "footprint": footprint, "sphere": sphere})
		near.sort_custom(func(a : Dictionary, b : Dictionary) -> bool: return a["distance"] < b["distance"])

	var count := mini(near.size(), MAX_NEAR_HULLS)
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
		var rows := _get_world_to_local_rows(footprint)
		rows_x[i] = rows[0]
		rows_y[i] = rows[1]
		rows_z[i] = rows[2]
		# Grow the sphere by the feather so the edge-foam band is not culled.
		spheres[i] = Vector4(sphere.x, sphere.y, sphere.z, (sphere.w + feather) * (sphere.w + feather))
		rects[i] = Vector4(profile.min_z, profile.min_y, 1.0 / (profile.max_z - profile.min_z), 1.0 / (profile.max_y - profile.min_y))
		params[i] = Vector4(float(_hull_profile_ids.find(profile.get_instance_id())), profile.center_x, feather, footprint.cutout_edge_foam)
		top_offsets[i] = footprint.cutout_height_offset / (profile.max_y - profile.min_y)
	_set_water_shader_parameter(&'near_hull_count', count)
	_set_water_shader_parameter(&'near_hull_world_to_local_x', rows_x)
	_set_water_shader_parameter(&'near_hull_world_to_local_y', rows_y)
	_set_water_shader_parameter(&'near_hull_world_to_local_z', rows_z)
	_set_water_shader_parameter(&'near_hull_spheres', spheres)
	_set_water_shader_parameter(&'near_hull_rects', rects)
	_set_water_shader_parameter(&'near_hull_params', params)
	_set_water_shader_parameter(&'near_hull_top_offsets', top_offsets)


## Keeps one texture-array layer per distinct HullProfile in use. Rebuilt only
## when the set of profiles changes (a re-bake creates a new profile resource).
func _update_hull_profile_array(footprints : Array[HullWaterFootprint]) -> void:
	var profiles : Array[HullProfile] = []
	var ids := PackedInt64Array()
	for footprint in footprints:
		if not ids.has(footprint.profile.get_instance_id()):
			profiles.push_back(footprint.profile)
			ids.push_back(footprint.profile.get_instance_id())
	if ids == _hull_profile_ids:
		return
	_hull_profile_ids = ids
	if profiles.is_empty():
		_hull_profiles = null
	else:
		var images : Array[Image] = []
		for profile in profiles:
			images.push_back(profile.image)
		_hull_profiles = Texture2DArray.new()
		var error := _hull_profiles.create_from_images(images)
		assert(error == OK, "Building the hull profile texture array failed: %s" % error_string(error))
	_set_water_shader_parameter(&'hull_profiles', _hull_profiles)


func _set_water_shader_parameter(parameter: StringName, value: Variant) -> void:
	get_water_material().set_shader_parameter(parameter, value)


func _dispatch_surface_queries() -> void:
	# Nothing to sample until the first FFT output exists (or ever, with no cascades).
	if not _has_wave_output:
		return
	_surface_queries.dispatch(
		wave_generator.descriptors[&'displacement_map_a'].rid,
		wave_generator.descriptors[&'displacement_map_b'].rid,
		_pack_surface_query_cascades(),
		parameters.size(),
		water_level,
		time,
		_interaction.render_texture if _interaction != null else RID(),
		_get_interaction_window(),
		interaction_cell_size
	)


func _pack_surface_query_cascades() -> PackedByteArray:
	var data := PackedByteArray()
	data.resize(MAX_CASCADES * SURFACE_QUERY_BYTES_PER_CASCADE)
	for i in parameters.size():
		var params := parameters[i]
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
		data.encode_float(offset + 28, blend_state.w)
		var frame_blend := _get_cascade_frame_blend(i)
		data.encode_float(offset + 32, frame_blend.x)
		data.encode_float(offset + 36, frame_blend.y)
	return data

func _set_texture_rid(texture: Texture2DArrayRD, rid: RID) -> void:
	texture.texture_rd_rid = RID()
	texture.texture_rd_rid = rid

## Per cascade: x = weight of map B (A gets the rest) at the current time, y =
## factor (1/s) turning B - A into a velocity. The water shader, surface queries
## and the interaction simulation all blend with it.
func _get_cascade_frame_blend(cascade_index : int) -> Vector4:
	var count := _cascade_frame_counts[cascade_index]
	if count == 0:
		return Vector4.ZERO
	var newest_weight := 1.0
	var rate := 0.0
	var span := _cascade_frame_times[cascade_index] - _cascade_previous_frame_times[cascade_index]
	# A first frame has nothing to blend from; neither has a paused clock.
	if count > 1 and span > 0.0:
		newest_weight = clampf((time - _cascade_previous_frame_times[cascade_index]) / span, 0.0, 1.0)
		rate = 1.0 / span
	if wave_generator.cascade_newest_output[cascade_index] == 1:
		return Vector4(newest_weight, rate, 0.0, 0.0)
	return Vector4(1.0 - newest_weight, -rate, 0.0, 0.0)

func _update_frame_blend_uniform() -> void:
	var frame_blends : PackedVector4Array; frame_blends.resize(parameters.size())
	for i in parameters.size():
		frame_blends[i] = _get_cascade_frame_blend(i) if wave_generator != null else Vector4.ZERO
	_set_water_shader_parameter(&'wave_frame_blends', frame_blends)

func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		displacement_maps_a.texture_rd_rid = RID()
		displacement_maps_b.texture_rd_rid = RID()
		normal_maps_a.texture_rd_rid = RID()
		normal_maps_b.texture_rd_rid = RID()
		# Null when interaction is off, in the editor, or the ocean was disabled.
		if _interaction != null:
			_interaction_texture.texture_rd_rid = RID()
			_interaction.release()
		# Null when the ocean was disabled for lack of a RenderingDevice.
		if _surface_queries != null:
			_surface_queries.retire()
		# Only created at runtime.
		if _lod_multimesh.is_valid():
			RenderingServer.free_rid(_lod_multimesh)
