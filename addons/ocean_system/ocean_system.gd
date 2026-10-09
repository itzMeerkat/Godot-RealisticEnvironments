@tool
class_name OceanSystem
extends MeshInstance3D
## Handles updating the displacement/normal maps for the water material as well as
## managing wave generation pipelines.

const WATER_MAT := preload('res://addons/ocean_system/mat_water.tres')
const EDITOR_WATER_PREVIEW_MESH := preload('res://addons/ocean_system/editor_water_preview_mesh.tres')
const OCEAN_REFLECTION_RENDERER := preload('res://addons/ocean_system/ocean_reflection_renderer.gd')
const MAX_CASCADES := 8
## Point lights of the sky (the planets) the water reflects as glints; as MAX_SKY_POINTS in water.gdshader.
const MAX_SKY_POINTS := 8
## The glint pattern index wraps after this many patterns (about two weeks at 12 a second).
const GLITTER_PATTERN_PERIOD := 1 << 24
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
		if value == null:
			push_error("OceanSystem.water_material cannot be empty; keeping the current material.")
			return
		water_material = value
		_material = null
		_parameter_cache.clear()
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
## Roughness (perceptual) of water shorter than the smallest cascade in calm air.
## The wind adds the short waves' slopes on top (short_wave_slope_scale), and the
## shader widens it by the wave slopes a pixel cannot resolve, so distant water gets
## rougher on its own; this only sets how sharp the closest glints and reflections
## of a calm sea are.
@export_range(0.0, 1.0, 0.01) var clear_roughness := 0.03 :
	set(value):
		clear_roughness = value
		_update_micro_roughness()
## Scales the slope variance of the short (capillary and gravity-capillary) waves
## the wind raises, which the cascades do not draw: Cox and Munk's (1954) clean sea
## less their slick sea (whose oil film damps them), 0.00356 U - 0.005 for wind
## U (m/s), none below about 1.4 m/s. 1 is measured; 0 keeps clear_roughness at
## every wind.
@export_range(0.0, 2.0, 0.01, "or_greater") var short_wave_slope_scale := 1.0 :
	set(value):
		short_wave_slope_scale = value
		_update_micro_roughness()
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
## Simulation steps per second. 0 steps once per physics tick (every hull pose
## moves the water). A fixed rate decouples the cost from the physics rate: a game
## ticking at 120 Hz can simulate the water at 60 or 30. Use a divisor of the
## physics rate, so every step sees the same number of new hull poses (each step
## uses the latest ones); stable to ~5 steps a second at the default cell size.
@export_range(0.0, 240.0, 1.0) var interaction_steps_per_second := 0.0
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
## Ocean clock (s), advanced every frame; the waves drawn this frame are at this time.
var time := 0.0
var wind_source : Node
var sky_source : Node
## True when sky_source has no lighting_changed signal and must be read every frame.
var _sky_source_polled := false
## True while the sky source gives the camera's atmosphere (get_atmosphere_view_volumes()),
## whose observer is read every frame.
var _aerial_perspective_enabled := false
## Instance ids of the bodies that carry a footprint pushing water (_makes_waves()),
## built once per physics tick or frame (_wave_making_bodies_key).
var _wave_making_bodies := {}
var _wave_making_bodies_key := -1
## Last camera exposure sent to the water material (_update_scene_exposure()).
var _scene_exposure := 1.0
## Set by the sky source's lighting_changed signal.
var _sky_lighting_dirty := false

## The generator's maps A and B (see WaveGenerator), bound to the water material.
var displacement_maps_a := Texture2DArrayRD.new()
var displacement_maps_b := Texture2DArrayRD.new()
var normal_maps_a := Texture2DArrayRD.new()
var normal_maps_b := Texture2DArrayRD.new()
var _material : ShaderMaterial
## Bound instead of the wave maps while there is no generator (_get_flat_wave_maps()).
var _flat_wave_maps : Texture2DArray
## Last value sent per shader parameter (_set_water_shader_parameter()).
var _parameter_cache := {}
var _surface_queries : OceanSurfaceQueries
## True once every cascade has a frame.
var _has_wave_output := false
## This frame's cascade records for the compute shaders (_pack_surface_query_cascades()),
## shared by the surface queries and the interaction simulation's ticks.
var _cascade_data := PackedByteArray()
## Per cascade: ocean time of its newest and of its previous frame, and how many
## frames it has computed (see _update_waves()).
var _cascade_frame_times := PackedFloat64Array()
var _cascade_previous_frame_times := PackedFloat64Array()
var _cascade_frame_counts := PackedInt32Array()
var _reflection_renderer : OceanReflectionRenderer
## The CDLOD mesh (runtime only; in the editor it only sends the uniforms) and the
## hull footprints' cutouts and simulation records.
var _lod_grid := OceanLodGrid.new(_set_water_shader_parameter)
var _hulls := OceanHulls.new(_set_water_shader_parameter)
## Null while interaction_enabled is off, in the editor, or before _ready.
var _interaction : WaterInteractionSim
var _interaction_texture := Texture2DRD.new()
## Simulation time not yet stepped (interaction_steps_per_second).
var _interaction_time_due := 0.0
func _init() -> void:
	rng.set_seed(1234) # This seed gives big waves!

# Registered on enter (before any _ready) so consumers find the surface in their own _ready.
func _enter_tree() -> void:
	if _surface_queries == null and RenderingServer.get_rendering_device() != null:
		_surface_queries = OceanSurfaceQueries.new(RenderingServer.get_rendering_device(), _makes_waves)
	if _surface_queries != null:
		WaterSurface.register(get_world_3d(), _surface_queries)

func _exit_tree() -> void:
	if _surface_queries != null:
		WaterSurface.unregister(get_world_3d(), _surface_queries)

func _ready() -> void:
	process_priority = 100
	if _surface_queries == null:
		push_error("OceanSystem needs a RenderingDevice (Forward+ or Mobile renderer). The ocean is disabled.")
		set_process(false)
		set_physics_process(false)
		return
	_apply_water_material()
	_resolve_wind_source()
	_resolve_sky_source()
	_setup_water_mesh()
	_setup_wave_generator()
	_setup_interaction()
	_push_all_shader_parameters()

func _process(delta : float) -> void:
	if not Engine.is_editor_hint():
		_lod_grid.update(get_viewport().get_camera_3d(), global_position, mesh_base_cell_size, get_path())
	_hulls.update(get_tree(), get_viewport().get_camera_3d(), hull_cutout_distance)
	if _sky_source_polled or _sky_lighting_dirty:
		_update_sky_lighting_shader_parameters()
	if _aerial_perspective_enabled:
		_set_water_shader_parameter(&'aerial_observer', sky_source.call(&'get_atmosphere_view_observer'))
	_update_scene_exposure()
	time += delta
	var pattern_time := time * sun_glitter_rate
	_set_water_shader_parameter(&'glitter_pattern', posmod(int(pattern_time), GLITTER_PATTERN_PERIOD))
	_set_water_shader_parameter(&'glitter_pattern_blend', pattern_time - floorf(pattern_time))
	_surface_queries.advance_clock(time, get_physics_process_delta_time())
	# No generator means no cascades: a flat ocean.
	if wave_generator != null:
		_update_waves(delta)
		_update_micro_roughness()
		_update_frame_blend_uniform()
		_cascade_data = _pack_surface_query_cascades()
	_dispatch_surface_queries()

## The interaction simulation steps with physics: one step per tick sees exactly
## one new pose of every hull, so hull motion reaches it without stutter.
func _physics_process(delta : float) -> void:
	if interaction_steps_per_second <= 0.0:
		_step_interaction(delta)
		return
	# A fixed rate: as many steps as have come due, but never more than two
	# steps' or ticks' worth at once (a hitch is not caught up).
	var step := 1.0 / interaction_steps_per_second
	_interaction_time_due = minf(_interaction_time_due + delta, 2.0 * maxf(step, delta))
	while _interaction_time_due >= step:
		_interaction_time_due -= step
		_step_interaction(step)

## Pushes every shader parameter this node owns into the current water material.
func _push_all_shader_parameters() -> void:
	_set_water_shader_parameter(&'foam_color', foam_color)
	_set_water_shader_parameter(&'scene_exposure', _scene_exposure)
	_set_water_shader_parameter(&'normal_strength', normal_strength)
	_set_water_shader_parameter(&'use_bicubic_normals', use_bicubic_normals)
	_set_water_shader_parameter(&'fragment_cascade_limit', fragment_cascade_limit)
	_update_micro_roughness()
	_set_water_shader_parameter(&'foam_roughness', foam_roughness)
	_set_water_shader_parameter(&'foam_intensity', foam_intensity)
	_set_water_shader_parameter(&'foam_detail', foam_detail_texture)
	_set_water_shader_parameter(&'foam_detail_tile_size', foam_detail_tile_size)
	_update_sky_shading_static_parameters()
	_update_sky_lighting_shader_parameters()
	_lod_grid.set_cell_size(mesh_base_cell_size, true)
	_update_scales_uniform()
	_bind_wave_textures()
	_update_frame_blend_uniform()
	_hulls.reset()
	_hulls.update(get_tree(), get_viewport().get_camera_3d(), hull_cutout_distance)
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
		_clear_wave_generator()
		return
	for param in parameters:
		param.request_spectrum_reset()

	wave_generator = WaveGenerator.new()
	wave_generator.map_size = simulation_map_size
	wave_generator.init_gpu(parameters.size())
	if wave_generator.context.failed:
		push_error("OceanSystem: the wave generator's GPU resources failed; the ocean is flat.")
		_clear_wave_generator()
		return

	_set_texture_rid(displacement_maps_a, wave_generator.descriptors[&'displacement_map_a'].rid)
	_set_texture_rid(displacement_maps_b, wave_generator.descriptors[&'displacement_map_b'].rid)
	_set_texture_rid(normal_maps_a, wave_generator.descriptors[&'normal_map_a'].rid)
	_set_texture_rid(normal_maps_b, wave_generator.descriptors[&'normal_map_b'].rid)
	_bind_wave_textures()
	_update_frame_blend_uniform()
	_update_spectrum_blend_uniform()

## No cascades (or a failed generator): a flat ocean.
func _clear_wave_generator() -> void:
	wave_generator = null
	_set_texture_rid(displacement_maps_a, RID())
	_set_texture_rid(displacement_maps_b, RID())
	_set_texture_rid(normal_maps_a, RID())
	_set_texture_rid(normal_maps_b, RID())
	_bind_wave_textures()

func _bind_wave_textures() -> void:
	_set_water_shader_parameter(&'num_cascades', parameters.size() if wave_generator != null else 0)
	# Without a generator the material samples a flat placeholder array (an empty
	# Texture2DArrayRD falls back to a 2D texture, which the shader's arrays reject).
	var maps : Array[TextureLayered] = [displacement_maps_a, displacement_maps_b, normal_maps_a, normal_maps_b]
	if wave_generator == null:
		maps.fill(_get_flat_wave_maps())
	# Forced: the textures may hold new RenderingServer RIDs (_set_texture_rid()).
	_set_water_shader_parameter(&'displacements_a', maps[0], true)
	_set_water_shader_parameter(&'displacements_b', maps[1], true)
	_set_water_shader_parameter(&'normals_a', maps[2], true)
	_set_water_shader_parameter(&'normals_b', maps[3], true)

## A 1x1, one-layer texture array of zeros: flat water, no slopes, no foam.
func _get_flat_wave_maps() -> Texture2DArray:
	if _flat_wave_maps == null:
		var image := Image.create_empty(1, 1, false, Image.FORMAT_RGBAH)
		_flat_wave_maps = Texture2DArray.new()
		_flat_wave_maps.create_from_images([image])
	return _flat_wave_maps

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

## Wind (m/s) at the surface: the external source's, else the first cascade's.
func get_surface_wind_speed() -> float:
	if should_use_external_wind():
		return get_external_wind_speed()
	return parameters[0].wind_speed if not parameters.is_empty() and parameters[0] != null else 0.0


## The water's micro-roughness for the shader's clear_roughness: GGX alpha squared
## is the slope variance (both axes) of what the cascades do not draw, the calm
## clear_roughness plus the wind's short waves (short_wave_slope_scale).
func _update_micro_roughness() -> void:
	var short_wave_variance := maxf(0.00356 * get_surface_wind_speed() - 0.005, 0.0) * short_wave_slope_scale
	var alpha := sqrt(pow(clear_roughness, 4.0) + short_wave_variance)
	_set_water_shader_parameter(&'clear_roughness', sqrt(alpha))


## Updates every cascade whose newest frame the display has reached. A cascade
## computes its next frame one update interval ahead of now, so blending from
## its newest frame to that one shows the waves at the current time.
func _update_waves(frame_delta : float) -> void:
	var external := should_use_external_wind()
	var external_speed := get_external_wind_speed() if external else 0.0
	var external_direction := get_external_wind_direction() if external else 0.0
	var all_have_frames := true
	for i in parameters.size():
		var count := _cascade_frame_counts[i]
		if count > 0 and time < _cascade_frame_times[i]:
			continue
		var interval := get_cascade_update_interval(parameters[i])
		if interval <= frame_delta:
			interval = 0.0 # Every frame: shown as computed, no blend.
		var frame_time := time + interval
		parameters[i].advance(frame_time - _cascade_frame_times[i] if count > 0 else 0.0, external_speed, external_direction, external)
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

## The ocean's water surface (queries and impulses), also registered for this
## node's World3D (WaterSurface.find()). Null when the ocean has no RenderingDevice.
func get_water_surface() -> WaterSurface:
	return _surface_queries

## Frames whose queries were delayed because all readback slots were busy.
func get_skipped_surface_query_dispatch_count() -> int:
	return _surface_queries.skipped_dispatch_count

## use_external_wind with a valid wind source (an invalid one is reported when resolved).
func should_use_external_wind() -> bool:
	return use_external_wind and wind_source != null

func get_wind_source() -> Node:
	return wind_source

## 0 without a valid wind source.
func get_external_wind_speed() -> float:
	return _read_wind_value(&'get_wind_speed', &'wind_speed') if wind_source != null else 0.0

## 0 without a valid wind source.
func get_external_wind_direction() -> float:
	return _read_wind_value(&'get_wind_direction_degrees', &'wind_direction') if wind_source != null else 0.0

## The wind source has method() or property (checked by _resolve_wind_source()).
func _read_wind_value(method: StringName, property: StringName) -> float:
	if wind_source.has_method(method):
		return float(wind_source.call(method))
	return float(wind_source.get(property))

func get_sky_source() -> Node:
	return sky_source

func get_water_material() -> ShaderMaterial:
	if _material == null:
		_material = water_material.duplicate()
	return _material

func _apply_water_material() -> void:
	RenderingServer.instance_geometry_set_material_override(get_instance(), get_water_material().get_rid())

func _setup_interaction() -> void:
	if _interaction != null:
		_interaction_texture.texture_rd_rid = RID()
		_interaction.release()
		_interaction = null
		_surface_queries.interaction = null
		# Query uniform sets that referenced the old render texture are freed with it.
		_surface_queries.clear_uniform_set_cache()
	# The simulation follows the game camera and does not run in the editor.
	if interaction_enabled and not Engine.is_editor_hint():
		if interaction_grid_size not in [256, 512, 1024] or interaction_cell_size <= 0.0:
			push_error("OceanSystem %s: interaction_grid_size must be 256, 512 or 1024 and interaction_cell_size positive; the interaction simulation is off." % get_path())
		else:
			_interaction = WaterInteractionSim.new(RenderingServer.get_rendering_device(), interaction_grid_size, interaction_cell_size)
			if _interaction.has_failed():
				push_error("OceanSystem %s: the interaction simulation's GPU resources failed; it is off." % get_path())
				_interaction.release()
				_interaction = null
	if _interaction != null:
		_apply_interaction_settings()
		_interaction_texture.texture_rd_rid = _interaction.render_texture
		_surface_queries.interaction = _interaction
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
	# Forced: the texture's RID changes when the simulation is rebuilt.
	_set_water_shader_parameter(&'interaction_render', _interaction_texture, true)
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
	var hull_data := _hulls.pack_interaction_hulls(get_tree(), camera.global_position, _interaction.get_half_extent() * sqrt(2.0))
	var hull_profiles_rd := RenderingServer.texture_get_rd_texture(_hulls.profiles_texture.get_rid()) if _hulls.profiles_texture != null else RID()
	@warning_ignore("integer_division")
	_interaction.step(
		delta,
		camera.global_position,
		hull_data,
		hull_data.size() / WaterInteractionSim.FLOATS_PER_HULL,
		_cascade_data,
		parameters.size(),
		water_level,
		wave_generator.descriptors[&'displacement_map_a'].rid,
		wave_generator.descriptors[&'displacement_map_b'].rid,
		hull_profiles_rd
	)
	_set_water_shader_parameter(&'interaction_window', _get_interaction_window())

## Whether body carries a footprint that pushes water. Every query owner asks every
## tick, so the bodies are collected once per physics tick (or frame, outside physics).
func _makes_waves(body : PhysicsBody3D) -> bool:
	if body == null or _interaction == null:
		return false
	var key := Engine.get_physics_frames() if Engine.is_in_physics_frame() else -1 - Engine.get_process_frames()
	if key != _wave_making_bodies_key:
		_wave_making_bodies_key = key
		_wave_making_bodies.clear()
		for node in get_tree().get_nodes_in_group(&"ocean_hull"):
			var footprint := node as HullWaterFootprint
			var footprint_body := OceanSurfaceQueries.find_physics_body(footprint)
			if OceanHulls.pushes_water(footprint) and footprint_body != null:
				_wave_making_bodies[footprint_body.get_instance_id()] = true
	return _wave_making_bodies.has(body.get_instance_id())

func _update_sky_shading_static_parameters() -> void:
	_set_water_shader_parameter(&'water_absorption', water_absorption)
	_set_water_shader_parameter(&'water_scattering', water_scattering)
	_set_water_shader_parameter(&'water_scattering_anisotropy', water_scattering_anisotropy)
	_set_water_shader_parameter(&'sky_reflection_enabled', sky_reflection_enabled)
	_set_water_shader_parameter(&'sky_reflection_strength', sky_reflection_strength)
	_set_water_shader_parameter(&'sky_reflection_f0', sky_reflection_f0)
	_set_water_shader_parameter(&'sun_specular_strength', sun_specular_strength)
	_set_water_shader_parameter(&'sun_glitter_density', sun_glitter_density)
	_set_water_shader_parameter(&'sun_glitter_rate', sun_glitter_rate)
	_set_water_shader_parameter(&'water_debug_view', WATER_DEBUG_VIEW_NORMAL)

func _update_sky_lighting_shader_parameters() -> void:
	_sky_lighting_dirty = false
	var sun_direction := _get_sky_vector(&'get_sun_direction', &'sun_direction', manual_sun_direction)
	if sun_direction.length_squared() <= 0.0001:
		push_error("OceanSystem %s: the sun direction is zero; using straight up." % get_path())
		sun_direction = Vector3.UP
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
	# Optional stars: a cubemap, the rotation into its frame (it turns with the sky) and
	# the scale of its values to scene radiance.
	var star_cubemap : Texture = sky_source.call(&'get_star_cubemap') if sky_source != null and sky_source.has_method(&'get_star_cubemap') else null
	_set_water_shader_parameter(&'sky_stars_enabled', star_cubemap != null)
	_set_water_shader_parameter(&'sky_star_cubemap', star_cubemap)
	if star_cubemap != null:
		_set_water_shader_parameter(&'sky_star_basis', sky_source.call(&'get_star_basis'))
		_set_water_shader_parameter(&'sky_star_radiance_scale', sky_source.call(&'get_star_radiance_scale'))
	# Optional point lights (the planets), reflected as glints; at most MAX_SKY_POINTS.
	var point_directions := PackedVector3Array()
	var point_irradiance := PackedVector3Array()
	if sky_source != null and sky_source.has_method(&'get_planet_directions') and sky_source.has_method(&'get_planet_irradiance'):
		point_directions = sky_source.call(&'get_planet_directions')
		point_irradiance = sky_source.call(&'get_planet_irradiance')
		if point_directions.size() != point_irradiance.size():
			push_error("OceanSystem %s: the sky source's planet directions and irradiance differ in length; no planet glints." % get_path())
			point_directions.clear()
	var point_count := mini(point_directions.size(), MAX_SKY_POINTS)
	_set_water_shader_parameter(&'sky_point_count', point_count)
	if point_count > 0:
		_set_water_shader_parameter(&'sky_point_directions', point_directions.slice(0, point_count))
		_set_water_shader_parameter(&'sky_point_irradiance', point_irradiance.slice(0, point_count))
	# Optional atmosphere between the sea and the reflected sky; a source without one
	# lacks the method or returns no volumes.
	var volumes : Array = sky_source.call(&'get_atmosphere_sky_volumes') if sky_source != null and sky_source.has_method(&'get_atmosphere_sky_volumes') else []
	_set_water_shader_parameter(&'sky_atmosphere_enabled', not volumes.is_empty())
	_set_water_shader_parameter(&'sky_atmosphere_transmittance', volumes[0] if not volumes.is_empty() else null)
	_set_water_shader_parameter(&'sky_atmosphere_inscatter', volumes[1] if not volumes.is_empty() else null)
	_set_water_shader_parameter(&'sky_atmosphere_inscatter_lobe', volumes[2] if not volumes.is_empty() else null)
	if not volumes.is_empty():
		_set_water_shader_parameter(&'sky_atmosphere_light', sky_source.call(&'get_atmosphere_light'))
	# Optional atmosphere between the camera and the water. The water is transparent,
	# drawn after the sky's aerial perspective, so it hazes itself (FOG).
	var view_volumes : Array = sky_source.call(&'get_atmosphere_view_volumes') if sky_source != null and sky_source.has_method(&'get_atmosphere_view_volumes') else []
	_aerial_perspective_enabled = not view_volumes.is_empty()
	_set_water_shader_parameter(&'aerial_perspective_enabled', _aerial_perspective_enabled)
	_set_water_shader_parameter(&'aerial_transmittance', view_volumes[0] if _aerial_perspective_enabled else null)
	_set_water_shader_parameter(&'aerial_inscatter', view_volumes[1] if _aerial_perspective_enabled else null)
	_set_water_shader_parameter(&'aerial_inscatter_lobe', view_volumes[2] if _aerial_perspective_enabled else null)
	if _aerial_perspective_enabled:
		_set_water_shader_parameter(&'aerial_max_distance', sky_source.call(&'get_atmosphere_view_max_distance'))
		_set_water_shader_parameter(&'aerial_observer', sky_source.call(&'get_atmosphere_view_observer'))

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

## Cascades use their own wind while there is no valid source.
func _resolve_wind_source() -> void:
	wind_source = null if wind_source_path.is_empty() else get_node_or_null(wind_source_path)
	if wind_source != null:
		for value in [[&'get_wind_speed', &'wind_speed'], [&'get_wind_direction_degrees', &'wind_direction']]:
			if not wind_source.has_method(value[0]) and wind_source.get(value[1]) == null:
				push_error("OceanSystem %s: wind source %s has neither %s() nor a %s property; ignored." % [get_path(), wind_source_path, value[0], value[1]])
				wind_source = null
				break
	if use_external_wind and wind_source == null:
		push_error("OceanSystem %s: use_external_wind is enabled but there is no valid wind source (wind_source_path); the cascades use their own wind." % get_path())

func _resolve_sky_source() -> void:
	# A freed source was disconnected by the engine.
	if is_instance_valid(sky_source) and sky_source.has_signal(&'lighting_changed') and sky_source.is_connected(&'lighting_changed', _on_sky_lighting_changed):
		sky_source.disconnect(&'lighting_changed', _on_sky_lighting_changed)
	sky_source = null if sky_source_path.is_empty() else get_node_or_null(sky_source_path)
	if sky_source == null and not sky_source_path.is_empty():
		push_error("OceanSystem %s: sky_source_path %s not found; using the manual sky values." % [get_path(), sky_source_path])
	var signals_changes := sky_source != null and sky_source.has_signal(&'lighting_changed')
	_sky_source_polled = sky_source != null and not signals_changes
	if signals_changes:
		sky_source.connect(&'lighting_changed', _on_sky_lighting_changed)

func _on_sky_lighting_changed() -> void:
	_sky_lighting_dirty = true

## The editor shows the shared preview plane. At runtime the ocean is a CDLOD
## quadtree of grid nodes (OceanLodGrid) drawn as one multimesh, set directly as this
## instance's base through the RenderingServer, so no generated mesh is ever saved.
func _setup_water_mesh() -> void:
	if Engine.is_editor_hint():
		mesh = EDITOR_WATER_PREVIEW_MESH
		extra_cull_margin = maxf(256.0, EDITOR_WATER_PREVIEW_MESH.size.length() * 0.5)
		return
	_lod_grid.attach(get_instance())

func _update_planar_reflection_settings() -> void:
	# Reflections never render in the editor, and the renderer is only created once enabled.
	if Engine.is_editor_hint() or (_reflection_renderer == null and not enable_planar_reflections):
		_set_water_shader_parameter(&'planar_reflection_enabled', false)
		_set_water_shader_parameter(&'planar_reflection_strength', 0.0)
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


## The water sums its reflections pre-exposed (the sky source's textures and the planar
## reflection are stored that way) and divides EMISSION by the camera's exposure.
func _update_scene_exposure() -> void:
	var camera := get_viewport().get_camera_3d()
	var attributes : CameraAttributes = camera.attributes if camera and camera.attributes else get_world_3d().camera_attributes
	var exposure := attributes.exposure_multiplier if attributes else 1.0
	if exposure != _scene_exposure:
		_scene_exposure = exposure
		_set_water_shader_parameter(&'scene_exposure', exposure)


## Sends value unless it equals the last value sent (many parameters are pushed
## every frame but rarely change). force re-sends it, e.g. a texture whose
## RenderingServer RID changed.
func _set_water_shader_parameter(parameter: StringName, value: Variant, force := false) -> void:
	if not force and _parameter_cache.has(parameter):
		var previous : Variant = _parameter_cache[parameter]
		if typeof(previous) == typeof(value) and previous == value:
			return
	# Arrays are copied: a caller may edit its array in place and send it again.
	_parameter_cache[parameter] = value.duplicate() if value is Array or typeof(value) >= TYPE_PACKED_BYTE_ARRAY else value
	get_water_material().set_shader_parameter(parameter, value)


func _dispatch_surface_queries() -> void:
	# Nothing to sample until the first FFT output exists (or ever, with no cascades).
	if not _has_wave_output:
		return
	_surface_queries.dispatch(
		wave_generator.descriptors[&'displacement_map_a'].rid,
		wave_generator.descriptors[&'displacement_map_b'].rid,
		_cascade_data,
		parameters.size(),
		water_level,
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
		# The multimesh exists at runtime only.
		_lod_grid.release()
