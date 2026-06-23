@tool
class_name OceanSystem
extends MeshInstance3D
## Handles updating the displacement/normal maps for the water material as well as
## managing wave generation pipelines.

const WATER_MAT := preload('res://addons/ocean_system/mat_water.tres')
const EDITOR_WATER_PREVIEW_MESH := preload('res://addons/ocean_system/editor_water_preview_mesh.tres')
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
## Base deep-water tint before foam, reflections, and emission are added. This
## should usually stay dark and low-saturation because sky and sun lighting are
## layered on top by the shader.
@export_color_no_alpha var water_color : Color = Color(0.1, 0.15, 0.18) :
	set(value):
		water_color = value
		_set_water_shader_parameter(&'water_color', water_color)

## Albedo tint used where the compute-generated foam mask, manual foam sources,
## or hull cutout edge foam are visible. Slightly warm off-white values usually
## look more natural than pure white.
@export_color_no_alpha var foam_color : Color = Color(0.73, 0.67, 0.62) :
	set(value):
		foam_color = value
		_set_water_shader_parameter(&'foam_color', foam_color)

@export_group('Surface Shading')
## Amount of water_color that contributes to diffuse ALBEDO. Keep this low for
## realistic water because most visible brightness should come from reflection,
## sun glitter, scatter, and crest emission rather than matte diffuse color.
@export_range(0.0, 1.0, 0.01) var water_diffuse_strength := 0.08 :
	set(value):
		water_diffuse_strength = value
		_set_water_shader_parameter(&'water_diffuse_strength', water_diffuse_strength)
## Tint for broad sun-lit water-body scattering. This is added as radiance in
## the shader and is most visible at low angles or when looking away from the sun.
@export_color_no_alpha var water_scatter_color : Color = Color(0.045, 0.18, 0.20) :
	set(value):
		water_scatter_color = value
		_set_water_shader_parameter(&'water_scatter_color', water_scatter_color)
## PBR roughness for clear water before slope and distance adjustments. Lower
## values make sharper highlights and reflections; higher values look windier.
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
## PBR specular strength for clear water. Raise for stronger direct highlights;
## lower if reflections and glitter already make the surface too bright.
@export_range(0.0, 1.0, 0.01) var clear_specular := 0.25 :
	set(value):
		clear_specular = value
		_set_water_shader_parameter(&'clear_specular', clear_specular)
## PBR specular strength for foam-covered areas. Foam generally needs less
## specular than clear water to avoid a plastic look.
@export_range(0.0, 1.0, 0.01) var foam_specular := 0.08 :
	set(value):
		foam_specular = value
		_set_water_shader_parameter(&'foam_specular', foam_specular)
## How strongly wave slope increases material roughness before foam appears.
## Higher values make steep waves look broader and less mirror-smooth.
@export_range(0.0, 4.0, 0.01) var slope_roughness_strength := 0.55 :
	set(value):
		slope_roughness_strength = value
		_set_water_shader_parameter(&'slope_roughness_strength', slope_roughness_strength)
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
## with get_sun_direction(), get_sun_color(), get_sky_top_color(),
## get_sky_horizon_color(), and get_sun_visibility() can be used.
@export var sky_source_path : NodePath :
	set(value):
		sky_source_path = value
		sky_source = null
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
## Fallback direct sun color used for glitter, scatter, and crest glow when no
## sky source provides a sun color.
@export_color_no_alpha var manual_sun_color : Color = Color(1.0, 0.92, 0.72) :
	set(value):
		manual_sun_color = value
		_update_sky_lighting_shader_parameters()
## Fallback normalized sun direction in world space when no sky source provides
## one. The shader uses this for glitter direction and backlit crest masks.
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
## Overall strength of the procedural sky reflection. Increase for brighter open
## ocean reflections; decrease if the water looks too emissive or glassy.
@export_range(0.0, 2.0, 0.01) var sky_reflection_strength := 0.55 :
	set(value):
		sky_reflection_strength = value
		_set_water_shader_parameter(&'sky_reflection_strength', sky_reflection_strength)
## Fresnel exponent for procedural sky reflection. Higher values push reflection
## toward grazing view angles; lower values show more reflection from above.
@export_range(0.25, 8.0, 0.05) var sky_reflection_fresnel_power := 5.0 :
	set(value):
		sky_reflection_fresnel_power = value
		_set_water_shader_parameter(&'sky_reflection_fresnel_power', sky_reflection_fresnel_power)
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
## How much wave slope broadens the procedural reflection. Higher values make
## rough seas blur sky reflection more strongly.
@export_range(0.0, 2.0, 0.01) var sky_reflection_roughness_strength := 0.75 :
	set(value):
		sky_reflection_roughness_strength = value
		_set_water_shader_parameter(&'sky_reflection_roughness_strength', sky_reflection_roughness_strength)
## Extra reflection roughness added by far-ocean LOD. This softens distant sky
## reflection and helps hide high-frequency tiling near the horizon.
@export_range(0.0, 1.0, 0.01) var sky_reflection_far_roughness := 0.35 :
	set(value):
		sky_reflection_far_roughness = value
		_set_water_shader_parameter(&'sky_reflection_far_roughness', sky_reflection_far_roughness)
## Strength of sun glitter generated from wave normals. Increase for sharper,
## brighter sparkling highlights along the reflected sun path.
@export_range(0.0, 4.0, 0.01) var sun_glitter_strength := 0.42 :
	set(value):
		sun_glitter_strength = value
		_set_water_shader_parameter(&'sun_glitter_strength', sun_glitter_strength)
## Sharpness of sun glitter. Higher values create smaller, tighter glints;
## lower values create broader highlights.
@export_range(8.0, 512.0, 1.0) var sun_glitter_power := 64.0 :
	set(value):
		sun_glitter_power = value
		_set_water_shader_parameter(&'sun_glitter_power', sun_glitter_power)
## Extra glitter multiplier when the sun is low. Use this to emphasize sunrise
## and sunset sparkle without over-brightening midday water.
@export_range(0.0, 4.0, 0.01) var sun_glitter_low_sun_boost := 1.4 :
	set(value):
		sun_glitter_low_sun_boost = value
		_set_water_shader_parameter(&'sun_glitter_low_sun_boost', sun_glitter_low_sun_boost)
## Strength of broad sun-lit water scatter. This is a soft radiance term that
## helps backlit water read as translucent instead of only reflective.
@export_range(0.0, 2.0, 0.01) var sun_scatter_strength := 0.24 :
	set(value):
		sun_scatter_strength = value
		_set_water_shader_parameter(&'sun_scatter_strength', sun_scatter_strength)
## Minimum sun scatter before view-direction phase is applied. Raise for a more
## constant sun tint on clear water; lower for more directional scatter.
@export_range(0.0, 1.0, 0.01) var sun_scatter_base := 0.08 :
	set(value):
		sun_scatter_base = value
		_set_water_shader_parameter(&'sun_scatter_base', sun_scatter_base)
## View-sun phase exponent for scatter. Higher values concentrate scatter when
## looking more directly away from the sun.
@export_range(0.25, 8.0, 0.05) var sun_scatter_phase_power := 2.0 :
	set(value):
		sun_scatter_phase_power = value
		_set_water_shader_parameter(&'sun_scatter_phase_power', sun_scatter_phase_power)
## Normal alignment exponent for sun scatter. Higher values require wave normals
## to face the sun more directly before scatter appears.
@export_range(0.25, 4.0, 0.05) var sun_scatter_normal_power := 0.75 :
	set(value):
		sun_scatter_normal_power = value
		_set_water_shader_parameter(&'sun_scatter_normal_power', sun_scatter_normal_power)
## How wave micro-slope affects scatter strength. Higher values make choppy water
## show more sunlit body color and flatter water show less.
@export_range(0.0, 2.0, 0.01) var sun_scatter_slope_strength := 0.65 :
	set(value):
		sun_scatter_slope_strength = value
		_set_water_shader_parameter(&'sun_scatter_slope_strength', sun_scatter_slope_strength)
## Additional scatter multiplier across the far-ocean LOD fade. Raise to keep
## distant water luminous; lower if the horizon looks too bright.
@export_range(0.0, 2.0, 0.01) var sun_scatter_distance_strength := 0.25 :
	set(value):
		sun_scatter_distance_strength = value
		_set_water_shader_parameter(&'sun_scatter_distance_strength', sun_scatter_distance_strength)

@export_group('Crest Glow')
## Enables low-sun backlit crest glow. This is an artistic scattering effect that
## colors high, steep, backlit wave crests without changing wave physics.
@export var crest_glow_enabled := true :
	set(value):
		crest_glow_enabled = value
		_set_water_shader_parameter(&'crest_glow_enabled', crest_glow_enabled)
## Color tint for backlit crest glow before multiplying by sun color. Blue-green
## values suggest translucent seawater; warmer values suggest sunset glow.
@export_color_no_alpha var crest_glow_color : Color = Color(0.08, 0.58, 0.46) :
	set(value):
		crest_glow_color = value
		_set_water_shader_parameter(&'crest_glow_color', crest_glow_color)
## Overall strength of the crest glow mask. Raise to make the color visible on
## more crests; lower for a subtler transmission effect.
@export_range(0.0, 4.0, 0.01) var crest_glow_strength := 0.75 :
	set(value):
		crest_glow_strength = value
		_set_water_shader_parameter(&'crest_glow_strength', crest_glow_strength)
## HDR emission multiplier for crest glow. Increase when using bloom; keep low
## if crests should only tint rather than visibly emit light.
@export_range(0.0, 2.0, 0.01) var crest_glow_emission_strength := 0.35 :
	set(value):
		crest_glow_emission_strength = value
		_set_water_shader_parameter(&'crest_glow_emission_strength', crest_glow_emission_strength)
## World-space wave height where crest glow starts. Lower values include more
## waves; higher values restrict glow to taller crests.
@export_range(-2.0, 4.0, 0.01) var crest_height_start := 0.18 :
	set(value):
		crest_height_start = value
		_set_water_shader_parameter(&'crest_height_start', crest_height_start)
## World-space wave height where the crest height mask reaches full strength.
## Keep above crest_height_start for a smooth transition.
@export_range(-2.0, 6.0, 0.01) var crest_height_end := 0.85 :
	set(value):
		crest_height_end = value
		_set_water_shader_parameter(&'crest_height_end', crest_height_end)
## Wave slope where crest glow starts. Lower values include gentler waves; higher
## values restrict the effect to steep or breaking crests.
@export_range(0.0, 4.0, 0.01) var crest_slope_start := 0.18 :
	set(value):
		crest_slope_start = value
		_set_water_shader_parameter(&'crest_slope_start', crest_slope_start)
## Wave slope where the crest slope mask reaches full strength. Keep above
## crest_slope_start to avoid an abrupt glow cutoff.
@export_range(0.0, 8.0, 0.01) var crest_slope_end := 0.85 :
	set(value):
		crest_slope_end = value
		_set_water_shader_parameter(&'crest_slope_end', crest_slope_end)
## View-angle exponent for backlit crest glow. Higher values require the camera
## to look more directly against the sun to see the glow.
@export_range(0.1, 8.0, 0.05) var crest_back_view_power := 1.6 :
	set(value):
		crest_back_view_power = value
		_set_water_shader_parameter(&'crest_back_view_power', crest_back_view_power)
## Normal-angle exponent for backlit crest glow. Higher values require crests to
## be more strongly back-facing relative to the sun.
@export_range(0.1, 8.0, 0.05) var crest_back_normal_power := 1.25 :
	set(value):
		crest_back_normal_power = value
		_set_water_shader_parameter(&'crest_back_normal_power', crest_back_normal_power)
## Sun height where low-sun crest glow starts fading in. Values near 0 mean the
## effect begins around the horizon.
@export_range(-0.1, 1.0, 0.01) var crest_low_sun_start := 0.02 :
	set(value):
		crest_low_sun_start = value
		_set_water_shader_parameter(&'crest_low_sun_start', crest_low_sun_start)
## Sun height where low-sun crest glow is fully faded out. Lower this for glow
## only at sunrise/sunset; raise it for a broader daytime effect.
@export_range(-0.1, 1.0, 0.01) var crest_low_sun_end := 0.38 :
	set(value):
		crest_low_sun_end = value
		_set_water_shader_parameter(&'crest_low_sun_end', crest_low_sun_end)
## Debug visualization mode for water shading masks and reflection terms. Use
## Normal for gameplay; other modes help tune sky reflection, glitter, and glow.
@export_enum('Normal:0', 'Sky Reflection:1', 'Sky Color:2', 'Sun Glitter:3', 'Crest Height:4', 'Crest Slope:5', 'Crest Backlight:6', 'Crest Final:7', 'Reflection Direction Y:8', 'Reflection Roughness:9', 'Sun Scatter:10', 'Sun Scatter NoL:11', 'View Sun Phase:12', 'Micro Slope Energy:13') var water_debug_view := 0 :
	set(value):
		water_debug_view = value
		_set_water_shader_parameter(&'water_debug_view', water_debug_view)

@export_group('Foam Shading')
## Multiplies the foam signal produced by the wave compute pass before threshold
## and softness are applied. Raise for more whitecaps; lower for cleaner water.
@export_range(0.0, 4.0, 0.01) var foam_intensity := 1.25 :
	set(value):
		foam_intensity = value
		_set_water_shader_parameter(&'foam_intensity', foam_intensity)
## Minimum foam signal required before foam appears. Higher values keep only the
## strongest whitecaps; lower values show foam on gentler waves.
@export_range(0.0, 2.0, 0.01) var foam_threshold := 0.05 :
	set(value):
		foam_threshold = value
		_set_water_shader_parameter(&'foam_threshold', foam_threshold)
## Width of the transition between clear water and foam. Lower values create
## sharper foam edges; higher values make foam blend more softly.
@export_range(0.01, 2.0, 0.01) var foam_softness := 0.35 :
	set(value):
		foam_softness = value
		_set_water_shader_parameter(&'foam_softness', foam_softness)

@export_group('Planar Reflections')
## Renders a mirrored camera into a texture so dynamic scene geometry can appear
## reflected in the water. This is more expensive than procedural sky reflection
## and is created lazily only when enabled.
@export var enable_planar_reflections := true :
	set(value):
		enable_planar_reflections = value
		_update_planar_reflection_settings()
## Maximum side length for the planar reflection texture after resolution_scale
## is applied. Larger values sharpen reflected objects but add render cost.
@export_range(128, 4096, 1) var reflection_texture_size := 1024 :
	set(value):
		reflection_texture_size = value
		_update_planar_reflection_settings()
## Multiplier applied to the main viewport size when sizing the reflection
## texture. Lower values are faster; higher values reduce blur and aliasing.
@export_range(0.1, 1.0, 0.05) var reflection_resolution_scale := 0.5 :
	set(value):
		reflection_resolution_scale = value
		_update_planar_reflection_settings()
## Overall dynamic reflection contribution. The shader still applies Fresnel and
## foam masking, so this controls maximum intensity rather than a flat opacity.
@export_range(0.0, 1.0, 0.01) var reflection_strength := 0.42 :
	set(value):
		reflection_strength = value
		_update_planar_reflection_settings()
## UV perturbation from wave normals. Higher values make reflected objects wobble
## and break up more; lower values keep reflections stable and mirror-like.
@export_range(0.0, 0.08, 0.001) var reflection_distortion := 0.018 :
	set(value):
		reflection_distortion = value
		_update_planar_reflection_settings()
## Fresnel exponent for planar reflections. Larger values keep reflections mostly
## at grazing angles; smaller values show them more from top-down views.
@export_range(0.25, 8.0, 0.05) var reflection_fresnel_power := 4.0 :
	set(value):
		reflection_fresnel_power = value
		_update_planar_reflection_settings()
## Visual layer assigned to the ocean while planar reflections are active. The
## reflection camera removes this layer to avoid recursive water reflections.
@export_range(1, 20, 1) var reflection_water_layer := 20 :
	set(value):
		reflection_water_layer = value
		_update_planar_reflection_settings()
## Render-layer mask for objects visible to the reflection camera. The configured
## water layer is always removed even if it is included here.
@export_flags_3d_render var reflection_cull_mask := 0xFFFFF :
	set(value):
		reflection_cull_mask = value
		_update_planar_reflection_settings()
## Clips reflected pixels below the water plane using the reflection viewport's
## depth buffer. This keeps submerged/sinking objects out of planar reflections.
@export var reflection_clip_below_water := true :
	set(value):
		reflection_clip_below_water = value
		_update_planar_reflection_settings()
## Extra distance below the water plane allowed before reflection pixels are
## clipped. Small positive values reduce flicker at waterline intersections.
@export_range(0.0, 1.0, 0.005) var reflection_clip_bias := 0.03 :
	set(value):
		reflection_clip_bias = value
		_update_planar_reflection_settings()

@export_group('External Wind')
## When enabled, cascades read wind speed and direction from wind_source_path.
## Per-cascade wind_speed_multiplier and wind_direction_offset still apply.
@export var use_external_wind := false :
	set(value):
		use_external_wind = value
		_reset_external_wind_tracking()
		_mark_spectra_dirty()
## Optional wind source node. It can expose get_wind_speed() and
## get_wind_direction_degrees(), or wind_speed and wind_direction properties.
@export var wind_source_path : NodePath :
	set(value):
		wind_source_path = value
		wind_source = null
		_reset_external_wind_tracking()
		_mark_spectra_dirty()

## Ordered list of wave cascades. Use long tile lengths for swell and short tile
## lengths for chop/detail. Adding or removing cascades recreates compute GPU
## resources; editing values inside a cascade usually only regenerates spectra.
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
## Resolution for each displacement/normal texture layer and FFT simulation.
## Cost scales roughly with resolution squared; 512 is much cheaper than 1024.
@export_enum('128x128:128', '256x256:256', '512x512:512', '1024x1024:1024') var map_size := 1024 :
	set(value):
		map_size = value
		_setup_wave_generator()

@export_group('Mesh')
## Radius in meters for the high-detail near-ocean mesh before optional far LOD
## rings begin. Increase for wider close water coverage; decrease for fewer verts.
@export_range(32.0, 4096.0, 1.0, "or_greater") var ocean_radius := 256.0 :
	set(value):
		ocean_radius = value
		_update_water_mesh()
## Full side length of the highest-density center patch, in meters. Larger values
## keep fine tessellation farther from the camera but increase vertex count.
@export_range(16.0, 512.0, 1.0) var generated_inner_extent := 128.0 :
	set(value):
		generated_inner_extent = value
		_update_water_mesh()
## Vertex spacing in meters for the highest-density center patch. Smaller values
## create smoother near displacement but can add many vertices.
@export_range(0.5, 16.0, 0.5) var generated_base_cell_size := 1.0 :
	set(value):
		generated_base_cell_size = value
		_update_water_mesh()
## Number of progressively coarser rings before the outer near-ocean radius.
## More rings preserve detail over distance; fewer rings reduce mesh complexity.
@export_range(0, 8, 1) var generated_ring_count := 2 :
	set(value):
		generated_ring_count = value
		_update_water_mesh()
## Keeps the generated water mesh centered around the active camera in XZ space.
## Wave sampling remains world-space stable, so this does not slide the waves.
@export var follow_active_camera := true
## Snaps camera-follow movement to this grid size in meters. Set to 0 for smooth
## continuous following; use snapping only if you need less frequent mesh motion.
@export_range(0.0, 64.0, 0.25) var follow_snap_size := 0.0
## Allows camera-follow behavior while running inside the editor. Keep disabled
## if editor camera movement should not reposition the water node.
@export var follow_camera_in_editor := false

## Target number of accepted wave simulation updates per second. Lower values
## reduce GPU FFT work; smooth_wave_interpolation hides the visual stepping.
## Set to 0 for uncapped updates.
@export_range(0, 60) var updates_per_second := 20.0 :
	set(value):
		next_update_time = next_update_time - (1.0/(updates_per_second + 1e-10) - 1.0/(value + 1e-10))
		updates_per_second = value

@export_group('Water Queries')
## Still-water height in world units. Visual displacement, point queries, planar
## reflection plane height, and buoyancy samples all use this as the base level.
@export var water_level := 0.0 :
	set(value):
		water_level = value
		_update_planar_reflection_settings()
@export_group('Visual Smoothing')
## Blends between previous and current wave output maps. This reduces visible
## stutter when updates_per_second is below the render frame rate.
@export var smooth_wave_interpolation := true
@export_group('Far Ocean LOD')
## Adds lower-density far rings and fades high-frequency normals/foam with
## distance. Disable for small contained water areas or debugging near mesh only.
@export var enable_far_lod := true :
	set(value):
		enable_far_lod = value
		_update_water_mesh()
		_update_far_lod_shader_parameters()
## Maximum radius of generated far-ocean geometry in meters. Large values can
## reach the horizon but increase mesh bounds and culling area.
@export_range(256.0, 20000.0, 1.0, "or_greater") var far_lod_radius := 7000.0 :
	set(value):
		far_lod_radius = value
		_update_water_mesh()
		_update_far_lod_shader_parameters()
## Number of extra low-density rings between ocean_radius and far_lod_radius.
## More rings improve horizon shape; fewer rings reduce vertex count.
@export_range(4, 96, 1) var far_lod_ring_count := 36 :
	set(value):
		far_lod_ring_count = value
		_update_water_mesh()
## Distance over which near detail fades into far-ocean shading. Larger values
## make the transition gradual; smaller values make far simplification start fast.
@export_range(1.0, 4000.0, 1.0) var far_lod_blend_distance := 1400.0 :
	set(value):
		far_lod_blend_distance = value
		_update_far_lod_shader_parameters()
## Curve exponent applied to the near-to-far LOD fade. Higher values preserve
## near detail longer before rolling off toward the far ocean.
@export_range(0.25, 4.0, 0.01) var far_lod_curve := 1.8 :
	set(value):
		far_lod_curve = value
		_update_far_lod_shader_parameters()
## Tile length threshold used to decide which cascades count as low frequency in
## far LOD. Cascades shorter than this fade out more strongly with distance.
@export_range(1.0, 512.0, 1.0) var far_low_frequency_tile_length := 32.0 :
	set(value):
		far_low_frequency_tile_length = value
		_update_far_lod_shader_parameters()
## Minimum normal strength retained in far-ocean shading. Raise if distant water
## looks too flat; lower if the horizon looks noisy or shimmery.
@export_range(0.0, 2.0, 0.01) var far_normal_strength := 0.14 :
	set(value):
		far_normal_strength = value
		_update_far_lod_shader_parameters()
## Foam multiplier retained in the far ocean. Lower values suppress noisy horizon
## foam; higher values keep distant whitecaps visible.
@export_range(0.0, 1.0, 0.01) var far_foam_coverage := 0.24 :
	set(value):
		far_foam_coverage = value
		_update_far_lod_shader_parameters()
## Extra foam edge softness added with distance. Raise to smooth distant foam;
## lower if far whitecaps become too broad or faded.
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
var sky_source : Node
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
var _hull_cutout_centers := PackedVector4Array()
var _hull_cutout_axes := PackedVector4Array()
var _hull_cutout_shapes := PackedVector4Array()
var _hull_cutout_verticals := PackedVector4Array()
var _hull_cutout_widths := PackedVector4Array()
var _last_hull_cutout_count := -1
var _last_hull_cutout_centers := PackedVector4Array()
var _last_hull_cutout_axes := PackedVector4Array()
var _last_hull_cutout_shapes := PackedVector4Array()
var _last_hull_cutout_verticals := PackedVector4Array()
var _last_hull_cutout_widths := PackedVector4Array()
var _manual_foam_sources := PackedVector4Array()
var _manual_foam_shapes := PackedVector4Array()
var _last_manual_foam_count := -1
var _last_manual_foam_sources := PackedVector4Array()
var _last_manual_foam_shapes := PackedVector4Array()
var _last_wave_blend_alpha_sent := -1.0

func _init() -> void:
	rng.set_seed(1234) # This seed gives big waves!

func _ready() -> void:
	process_priority = 100
	add_to_group(&"ocean_system")
	if not Engine.is_editor_hint():
		_ensure_unique_water_material()
	_resolve_wind_source()
	_resolve_sky_source()
	_set_water_shader_parameter(&'water_color', water_color)
	_set_water_shader_parameter(&'foam_color', foam_color)
	_set_wave_blend_alpha(1.0)
	_set_water_shader_parameter(&'water_diffuse_strength', water_diffuse_strength)
	_set_water_shader_parameter(&'water_scatter_color', water_scatter_color)
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
	_update_sky_shading_static_parameters()
	_update_sky_lighting_shader_parameters()
	_update_hull_cutouts()
	_update_manual_foam_sources()
	_update_far_lod_shader_parameters()
	_update_water_mesh()
	_update_planar_reflection_settings()

func _process(delta : float) -> void:
	_update_follow_camera()
	_update_hull_cutouts()
	_update_manual_foam_sources()
	_update_external_wind_state()
	_update_sky_lighting_shader_parameters()
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
	_set_wave_blend_alpha(1.0)
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

func sample_water_surface(world_position: Vector3, request_owner: Object) -> WaterSurfaceSample:
	var points := PackedVector3Array()
	points.push_back(world_position)
	var samples := sample_water_surface_batch(points, request_owner)
	if samples.is_empty():
		return null
	return samples[0]

func sample_water_surface_batch(points: PackedVector3Array, request_owner: Object) -> Array[WaterSurfaceSample]:
	if points.is_empty():
		return _empty_surface_samples()
	if request_owner == null:
		push_warning("sample_water_surface_batch() requires a stable request_owner so async GPU query results cannot overwrite each other.")
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

func get_sky_source() -> Node:
	if sky_source == null:
		_resolve_sky_source()
	return sky_source

func _update_sky_shading_static_parameters() -> void:
	_set_water_shader_parameter(&'water_diffuse_strength', water_diffuse_strength)
	_set_water_shader_parameter(&'water_scatter_color', water_scatter_color)
	_set_water_shader_parameter(&'sky_reflection_enabled', sky_reflection_enabled)
	_set_water_shader_parameter(&'sky_reflection_strength', sky_reflection_strength)
	_set_water_shader_parameter(&'sky_reflection_fresnel_power', sky_reflection_fresnel_power)
	_set_water_shader_parameter(&'sky_reflection_f0', sky_reflection_f0)
	_set_water_shader_parameter(&'sky_horizon_boost', sky_horizon_boost)
	_set_water_shader_parameter(&'sky_reflection_roughness_strength', sky_reflection_roughness_strength)
	_set_water_shader_parameter(&'sky_reflection_far_roughness', sky_reflection_far_roughness)
	_set_water_shader_parameter(&'sun_glitter_strength', sun_glitter_strength)
	_set_water_shader_parameter(&'sun_glitter_power', sun_glitter_power)
	_set_water_shader_parameter(&'sun_glitter_low_sun_boost', sun_glitter_low_sun_boost)
	_set_water_shader_parameter(&'sun_scatter_strength', sun_scatter_strength)
	_set_water_shader_parameter(&'sun_scatter_base', sun_scatter_base)
	_set_water_shader_parameter(&'sun_scatter_phase_power', sun_scatter_phase_power)
	_set_water_shader_parameter(&'sun_scatter_normal_power', sun_scatter_normal_power)
	_set_water_shader_parameter(&'sun_scatter_slope_strength', sun_scatter_slope_strength)
	_set_water_shader_parameter(&'sun_scatter_distance_strength', sun_scatter_distance_strength)
	_set_water_shader_parameter(&'crest_glow_enabled', crest_glow_enabled)
	_set_water_shader_parameter(&'crest_glow_color', crest_glow_color)
	_set_water_shader_parameter(&'crest_glow_strength', crest_glow_strength)
	_set_water_shader_parameter(&'crest_glow_emission_strength', crest_glow_emission_strength)
	_set_water_shader_parameter(&'crest_height_start', crest_height_start)
	_set_water_shader_parameter(&'crest_height_end', crest_height_end)
	_set_water_shader_parameter(&'crest_slope_start', crest_slope_start)
	_set_water_shader_parameter(&'crest_slope_end', crest_slope_end)
	_set_water_shader_parameter(&'crest_back_view_power', crest_back_view_power)
	_set_water_shader_parameter(&'crest_back_normal_power', crest_back_normal_power)
	_set_water_shader_parameter(&'crest_low_sun_start', crest_low_sun_start)
	_set_water_shader_parameter(&'crest_low_sun_end', crest_low_sun_end)
	_set_water_shader_parameter(&'water_debug_view', water_debug_view)

func _update_sky_lighting_shader_parameters() -> void:
	var sun_direction := _get_sky_vector(&'get_sun_direction', &'sun_direction', manual_sun_direction)
	if sun_direction.length_squared() < 0.0001:
		sun_direction = Vector3(0.0, 0.2, -1.0)
	sun_direction = sun_direction.normalized()
	_set_water_shader_parameter(&'sky_sun_direction', sun_direction)
	_set_water_shader_parameter(&'sky_sun_color', _get_sky_color(&'get_sun_color', &'sun_color', manual_sun_color))
	_set_water_shader_parameter(&'sky_top_color', _get_sky_color(&'get_sky_top_color', &'sky_top_color', manual_sky_top_color))
	_set_water_shader_parameter(&'sky_horizon_color', _get_sky_color(&'get_sky_horizon_color', &'sky_horizon_color', manual_sky_horizon_color))
	_set_water_shader_parameter(&'sky_ground_horizon_color', _get_sky_color(&'get_sky_ground_horizon_color', &'sky_ground_horizon_color', manual_sky_horizon_color.darkened(0.25)))
	_set_water_shader_parameter(&'sky_ground_bottom_color', _get_sky_color(&'get_sky_ground_bottom_color', &'sky_ground_bottom_color', manual_sky_top_color.darkened(0.55)))
	_set_water_shader_parameter(&'sky_sun_visibility', _get_sky_float(&'get_sun_visibility', &'sun_visibility', manual_sun_visibility))

func _get_sky_vector(method: StringName, property: StringName, fallback: Vector3) -> Vector3:
	var source := get_sky_source()
	if source != null:
		if source.has_method(method):
			var method_value = source.call(method)
			if method_value is Vector3:
				return method_value
		var property_value = source.get(property)
		if property_value is Vector3:
			return property_value
	return fallback

func _get_sky_color(method: StringName, property: StringName, fallback: Color) -> Color:
	var source := get_sky_source()
	if source != null:
		if source.has_method(method):
			var method_value = source.call(method)
			if method_value is Color:
				return method_value
		var property_value = source.get(property)
		if property_value is Color:
			return property_value
	return fallback

func _get_sky_float(method: StringName, property: StringName, fallback: float) -> float:
	var source := get_sky_source()
	if source != null:
		if source.has_method(method):
			var method_value = source.call(method)
			if method_value != null:
				return float(method_value)
		var property_value = source.get(property)
		if property_value != null:
			return float(property_value)
	return fallback

func _resolve_wind_source() -> void:
	if wind_source_path.is_empty():
		return
	wind_source = get_node_or_null(wind_source_path)

func _resolve_sky_source() -> void:
	if sky_source_path.is_empty() or not is_inside_tree():
		return
	sky_source = get_node_or_null(sky_source_path)

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
	_set_wave_blend_alpha(1.0)

func _update_water_mesh() -> void:
	if Engine.is_editor_hint():
		mesh = EDITOR_WATER_PREVIEW_MESH
		extra_cull_margin = maxf(256.0, EDITOR_WATER_PREVIEW_MESH.size.length() * 0.5)
		_update_far_lod_shader_parameters()
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


func _ensure_planar_reflection_renderer() -> bool:
	if Engine.is_editor_hint() or not is_inside_tree():
		return false
	if _reflection_renderer == null:
		_reflection_renderer = OCEAN_REFLECTION_RENDERER.new()
		_reflection_renderer.name = "OceanReflectionRenderer"
		add_child(_reflection_renderer)
	_reflection_renderer.setup(self, water_level)
	return true


func _update_planar_reflection_settings() -> void:
	if enable_planar_reflections and _reflection_renderer == null:
		_ensure_planar_reflection_renderer()
	if _reflection_renderer != null:
		_reflection_renderer.enabled = enable_planar_reflections
		_reflection_renderer.texture_size = reflection_texture_size
		_reflection_renderer.resolution_scale = reflection_resolution_scale
		_reflection_renderer.reflection_strength = reflection_strength
		_reflection_renderer.reflection_distortion = reflection_distortion
		_reflection_renderer.fresnel_power = reflection_fresnel_power
		_reflection_renderer.water_layer = reflection_water_layer
		_reflection_renderer.reflection_cull_mask = reflection_cull_mask
		_reflection_renderer.clip_below_water = reflection_clip_below_water
		_reflection_renderer.clip_bias = reflection_clip_bias
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

	_ensure_hull_cutout_arrays()

	var cutout_count := 0
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
			_hull_cutout_centers[cutout_count] = Vector4(
				center.x,
				center.y,
				center.z,
				float(segment["feather"])
			)
			_hull_cutout_axes[cutout_count] = Vector4(segment_right.x, segment_right.z, segment_forward.x, segment_forward.z)
			_hull_cutout_shapes[cutout_count] = Vector4(half_extents.x, half_extents.y, float(segment["foam_amount"]), 1.0)
			_hull_cutout_widths[cutout_count] = Vector4(half_widths.x, half_widths.y, 0.0, 0.0)
			_hull_cutout_verticals[cutout_count] = Vector4(
				float(segment["min_y"]),
				float(segment["max_y"]),
				float(segment["height_feather"]),
				0.0
			)
			cutout_count += 1
		if cutout_count >= MAX_HULL_CUTOUTS:
			break

	if not _hull_cutout_uniforms_changed(cutout_count):
		return
	_set_water_shader_parameter(&'hull_cutout_count', cutout_count)
	_set_water_shader_parameter(&'hull_cutout_centers', _hull_cutout_centers)
	_set_water_shader_parameter(&'hull_cutout_axes', _hull_cutout_axes)
	_set_water_shader_parameter(&'hull_cutout_shapes', _hull_cutout_shapes)
	_set_water_shader_parameter(&'hull_cutout_verticals', _hull_cutout_verticals)
	_set_water_shader_parameter(&'hull_cutout_widths', _hull_cutout_widths)
	_store_last_hull_cutout_uniforms(cutout_count)


func _update_manual_foam_sources() -> void:
	if not is_inside_tree():
		return
	_ensure_manual_foam_arrays()
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
			_manual_foam_sources[source_count] = Vector4(position.x, position.z, radius, amount)
			_manual_foam_shapes[source_count] = Vector4(direction.x, direction.z, half_length, 0.0)
			source_count += 1
	if not _manual_foam_uniforms_changed(source_count):
		return
	_set_water_shader_parameter(&'manual_foam_count', source_count)
	_set_water_shader_parameter(&'manual_foam_sources', _manual_foam_sources)
	_set_water_shader_parameter(&'manual_foam_shapes', _manual_foam_shapes)
	_store_last_manual_foam_uniforms(source_count)


func _ensure_hull_cutout_arrays() -> void:
	if _hull_cutout_centers.size() == MAX_HULL_CUTOUTS:
		return
	_hull_cutout_centers.resize(MAX_HULL_CUTOUTS)
	_hull_cutout_axes.resize(MAX_HULL_CUTOUTS)
	_hull_cutout_shapes.resize(MAX_HULL_CUTOUTS)
	_hull_cutout_verticals.resize(MAX_HULL_CUTOUTS)
	_hull_cutout_widths.resize(MAX_HULL_CUTOUTS)
	_last_hull_cutout_count = -1


func _hull_cutout_uniforms_changed(cutout_count : int) -> bool:
	return (
		cutout_count != _last_hull_cutout_count
		or _hull_cutout_centers != _last_hull_cutout_centers
		or _hull_cutout_axes != _last_hull_cutout_axes
		or _hull_cutout_shapes != _last_hull_cutout_shapes
		or _hull_cutout_verticals != _last_hull_cutout_verticals
		or _hull_cutout_widths != _last_hull_cutout_widths
	)


func _store_last_hull_cutout_uniforms(cutout_count : int) -> void:
	_last_hull_cutout_count = cutout_count
	_last_hull_cutout_centers = _copy_vector4_array(_hull_cutout_centers)
	_last_hull_cutout_axes = _copy_vector4_array(_hull_cutout_axes)
	_last_hull_cutout_shapes = _copy_vector4_array(_hull_cutout_shapes)
	_last_hull_cutout_verticals = _copy_vector4_array(_hull_cutout_verticals)
	_last_hull_cutout_widths = _copy_vector4_array(_hull_cutout_widths)


func _ensure_manual_foam_arrays() -> void:
	if _manual_foam_sources.size() == MAX_MANUAL_FOAM_SOURCES:
		return
	_manual_foam_sources.resize(MAX_MANUAL_FOAM_SOURCES)
	_manual_foam_shapes.resize(MAX_MANUAL_FOAM_SOURCES)
	_last_manual_foam_count = -1


func _manual_foam_uniforms_changed(source_count : int) -> bool:
	return (
		source_count != _last_manual_foam_count
		or _manual_foam_sources != _last_manual_foam_sources
		or _manual_foam_shapes != _last_manual_foam_shapes
	)


func _store_last_manual_foam_uniforms(source_count : int) -> void:
	_last_manual_foam_count = source_count
	_last_manual_foam_sources = _copy_vector4_array(_manual_foam_sources)
	_last_manual_foam_shapes = _copy_vector4_array(_manual_foam_shapes)


func _copy_vector4_array(source : PackedVector4Array) -> PackedVector4Array:
	var copy := PackedVector4Array()
	copy.resize(source.size())
	for i in source.size():
		copy[i] = source[i]
	return copy


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

func _sample_water_surface_batch_gpu(points: PackedVector3Array, request_owner: Object) -> Array[WaterSurfaceSample]:
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
	return request_owner.get_instance_id()


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
			water_level,
			_get_wave_blend_alpha(),
			maxf(_wave_blend_duration, 1.0 / 60.0),
			0.25,
		]),
		24
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
		_set_wave_blend_alpha(0.0 if smooth_wave_interpolation else 1.0)
	else:
		_set_texture_rid(previous_displacement_maps, current_displacement)
		_set_texture_rid(previous_normal_maps, current_normal)
		_has_wave_output = true
		_wave_blend_start_time = time
		_set_wave_blend_alpha(1.0)
	_last_wave_output_time = time
	_set_water_shader_parameter(&'displacements', displacement_maps)
	_set_water_shader_parameter(&'normals', normal_maps)
	_set_water_shader_parameter(&'previous_displacements', previous_displacement_maps)
	_set_water_shader_parameter(&'previous_normals', previous_normal_maps)

func _update_wave_blend_alpha() -> void:
	_set_wave_blend_alpha(_get_wave_blend_alpha())

func _get_wave_blend_alpha() -> float:
	if not smooth_wave_interpolation or not _has_wave_output:
		return 1.0
	return clampf((time - _wave_blend_start_time) / maxf(_wave_blend_duration, 1e-5), 0.0, 1.0)


func _set_wave_blend_alpha(value : float) -> void:
	if is_equal_approx(_last_wave_blend_alpha_sent, value):
		return
	_last_wave_blend_alpha_sent = value
	_set_water_shader_parameter(&'wave_blend_alpha', value)

func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		displacement_maps.texture_rd_rid = RID()
		normal_maps.texture_rd_rid = RID()
		previous_displacement_maps.texture_rd_rid = RID()
		previous_normal_maps.texture_rd_rid = RID()
