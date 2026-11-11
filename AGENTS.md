# AGENTS.md

Working rules for changing this project: only what is easy to get wrong. Read
the addon's `README.md` and the scripts' `##` doc comments before changing it.

## Ground rules
- No compatibility shims: rename or delete APIs, scenes, groups and uniforms
  freely, and update every caller and scene in the same change.
- Production-grade errors: anything a shipped game can hit (missing/wrong node,
  bad config or data, failed GPU resource or shader, too many requests) is
  reported with `push_error` and the feature degrades or disables itself; never
  crash or write out of bounds. `assert()` is stripped from release builds:
  only for internal invariants. Resolve dependencies once (usually `_ready`),
  model expected states ("no result yet", "disabled") explicitly, and check
  `GRERenderingContext.failed` after building compute resources.
- Editor setup mistakes also show as configuration warnings
  (`_get_configuration_warnings()`, refreshed by `update_configuration_warnings()`
  in the relevant setters): missing sources/paths, missing sky globals,
  `sea_level` ≠ `water_level`, camera far planes short of the horizon, missing
  input actions. Runtime-only nodes are `@tool` and
  return early from `_ready` in the editor with processing off.
- `docs/*-plan.md` are completed design records (their *Deferred verification*
  lists are still open).

## API conventions (frozen with 0.1)
- Public API = exported properties, signals, constants, enums and methods
  without a leading `_`, each with a `##` doc comment. Everything else is
  internal: `_` members, and the helper classes (`GREWaveGenerator`,
  `GREWaveCascadeState`, `GREOceanLodGrid`, `GREOceanSurfaceQueries`,
  `GREAtmosphereRenderer`, `GRECloudRenderer`, the compositor effects). Don't expose runtime state as public vars.
- Resources (`GREWaveSpectrum`, `GREWaveCascade`, `GRECloudPreset`) hold
  settings only, never simulation state, so one can be shared.
- Another system is referenced by a `*_source_path` / `*_path` NodePath; an
  empty path means "use own values" (no separate enable flag). Read it through
  its contract (`GREWindSource`, `GREWaterSurface`, the sky and light sources),
  never by type.
- One value, one place: no export that must equal another export, and no
  export shadowing an engine property (e.g. an `Area3D`'s collision layers).
- Fixed choices are `enum`s (`GREOceanSystem.ReflectionMode`, `ShaderQuality`);
  values that are sizes stay `@export_enum` ints. Units go in the doc comment
  and hint (`"suffix:m"`, `"degrees"`); existing unit-suffixed names
  (`latitude_degrees`, `cycle_duration_seconds`, ...) stay.

## Project basics
- Godot 4.8, Forward+. Main scene `res://demo/main.tscn`. No package manager,
  CI, formatter or tests. Verify by running `demo/main.tscn` (or
  `demo/ocean_optics_debug.tscn` for shading). Headless/Compatibility runs have
  no `RenderingDevice`: they catch GDScript errors, not ocean regressions.
- Keep every script warning-free (warnings are on for addons too): rename
  locals that shadow members (`basis`, `position`, `scale`, `owner`, ...), mark
  intended integer division with `@warning_ignore("integer_division")`, type
  nodes by assignment (`@onready var x : Camera3D = $Camera3D`), not `as`.
  `tools/gd_lint.py` lists warnings via a headless editor's language server.
- Reusable code in `addons/*`; demo glue in `systems/` and `demo/`.
  `examples/` uses only the open-source addons (never `systems/`, `demo/`,
  projectile weapons or `gre_floating_boat_template`); its hull mesh comes from
  `tools/make_example_hull.py`.
- User docs are pairs: `README.md` (English) and `README.zh-CN.md`
  (Simplified Chinese) at the top level, in `examples/` and in each
  open-source addon. Each covers briefly how it works and how to use it;
  change both languages together.
- Names: addon folders start with `gre_` (Godot Realistic Environments) and
  every addon `class_name` with `GRE` (`GREOceanSystem`), so they can't clash
  with a user's project. Files, node names in scenes, groups, project settings,
  input actions, plugin display names and shader globals stay unprefixed.
- Runtime types use `class_name`, except internal `Node` helpers
  (`OceanReflectionRenderer`), which are preloaded so they stay out of the
  Create Node dialog; `*_plugin.gd` only set up the project via
  core's `GREProjectSetup`, adding missing settings and never changing existing
  ones. A new project requirement goes into the plugin plus a runtime check
  that reports it. `plugin.cfg` `script` paths are relative.
- `.godot/`, `.import/`, `build/`, `export*.cfg`, `fft_wave.md`, `todo.md` are
  ignored local state, never sources of truth.

## Scenes and resources
- Keep `res://` paths and `uid://` values intact in `.tscn`/`.tres`. Every
  script has a committed `.gd.uid`; move it with the script, commit new ones.
- `addons/gre_boat_template/boat.tscn` is the open-source boat.
  `addons/gre_floating_boat_template/floating_boat.tscn` (dev only) inherits it and
  adds `Weapons` at child index 2 (between `Hitboxes` and `CameraTargets`).
  `demo/rowboat.tscn` and `demo/floating_box.tscn` inherit that and override
  nodes by path with matching `index` attributes: renaming/reordering template
  nodes breaks them and `demo/main.gd`.
- Open hulls have a `GREWaterMask` (rowboat, example boat), its lid made by
  **Fit to Hull** and saved as a `.tres` next to the boat
  (`demo/rowboat_water_mask.tres`, `examples/assets/simple_hull_water_mask.tres`):
  redo it after changing the hull model.
- `boat.tscn`'s last child is `GREBuoyantBody`; inherited scenes override it by
  path. Each floater's `draft` matches its hull (`docs/buoyancy-and-interactive-waves-plan.md`
  lists them). The template body's `linear_damp_mode` is Replace, so Godot's
  default damping does not add to the water's drag.
- A non-uniformly scaled collision shape gives zero inverse inertia; set
  `inertia` explicitly (as `floating_box.tscn` does).
- No `/** */` doc comments in `.gdshader`/`.gdshaderinc` (editor extracts them
  on every uniform-list call; stalled the editor for seconds). Use `/*` or `//`.
- Debug helpers (trail, aim marker, health panel) and the
  starfield are internal runtime children; never save them into a scene.

## Addon boundaries
- `*_system` addons never depend on each other; shared code goes into `gre_core`
  (depends on nothing). Otherwise connect via signals, groups, duck typing.
- Water consumers use only `GREWaterSurface.find(node)`, never `GREOceanSystem`.
- Only `gre_ocean_environment` and `gre_boat_template` compose systems
  (`gre_floating_boat_template` adds weapons). `GREOceanEnvironment.sea_level` sets
  both `GREOceanSystem.water_level` and `GRESkySystem.sea_level`.
- `gre_projectile_launcher_system` and `gre_floating_boat_template` are dev/demo, not
  open source: leave them be, and keep other addons independent of them.
- Directions: degrees, 0 = +Z, 90 = +X. Only
  `GREWaveCascadeState._world_to_spectrum_direction` converts to the FFT's frame.

## Cross-system contracts (change both sides together)
- **Wind source:** `get_wind_speed()` + `get_wind_direction_degrees()`, or
  `wind_speed` / `wind_direction` properties. Read only through core's
  `GREWindSource` (`GREOceanSystem`, `GRESkySystem`, the demo HUD and panel).
- **Sky source** (documented for users in the ocean README):
  `get_sun_direction()`, `get_sun_visibility()` (methods only; missing ones fall
  back to `manual_*`; without an atmosphere the water reflects the
  `manual_sky_*` gradient). With a `lighting_changed` signal it is read only
  when that fires, so emit it after every lighting change and before freeing
  textures it handed out. Optional:
  - `get_cloud_cubemap()`: the clouds seen from the sea below the camera, rgb
    premultiplied cloud radiance at the cloud, a opacity, full mips; `null` =
    no clouds.
  - `get_star_cubemap()`, `get_star_basis()`, `get_star_radiance_scale()`: the
    water reflects them weighted by `1 − planar coverage` (the mirrored camera
    draws its own starfield), so stars never count twice.
  - `get_planet_directions()`, `get_planet_irradiance()` (≤
    `GREOceanSystem.MAX_SKY_POINTS`): glints on the water; the starfield omits
    planets for cameras below `sea_level`.
  - `get_atmosphere_sky_volumes()` + `get_atmosphere_light()`: the sky the
    water reflects (clouds composited inside the atmosphere).
    `get_atmosphere_view_volumes()`, `get_atmosphere_view_observer()` (read
    every frame), `get_atmosphere_view_max_distance()`: the water's own `FOG`.
  - `get_sky_irradiance()` (scene units, negative while unknown; read every
    frame): flat ambient light for the planar reflection's geometry, whose
    background must stay empty (no shared `Sky`); else the manual sky's middle.
  - `set_camera_underwater(bool)`: the ocean calls it as the camera goes under
    the waves or comes up; the volumetric clouds skip those frames (they would
    show through the far water's mesh gaps at the horizon).
- **Exposure:** a light source has `get_scene_illuminance()` (lux, negative
  while unknown) and `get_illuminance_unit_lux()`. `GREExposureController` writes
  `CameraAttributes.exposure_multiplier`; Godot applies it to lights,
  `EMISSION` and sky output, not unshaded `ALBEDO` or `FOG`. Systems writing
  their own light read the effective exposure each frame and store HDR
  textures pre-exposed; the sky shader and water divide by it again. Apply
  exposure nowhere else; keep physical light units off. Night tint and
  desaturation only via `GRENightVisionEffect`.
- **Atmosphere globals:** `atmosphere_*` global uniforms, declared in
  `project.godot` `[shader_globals]`, listed in `GREAtmosphereGlobals` and
  `atmosphere.gdshaderinc` (change all three together), written only by the
  owning `GRESkySystem`. Transparent materials haze themselves with
  `FOG = atmosphere_fog(...)`; only `gre_sky_system` includes it.
  Opaque materials must not write `FOG`. Environment fog stays off.
- **Water surface:** a simulation registers one `GREWaterSurface` per `World3D`
  in `_enter_tree` and unregisters in `_exit_tree`. `get_surface_drift()` is the
  drift that moves the foam (`GREOceanSystem._get_surface_drift()`, one place);
  `GREBuoyantBody` drags bodies along with it. Hulls report a `GREWaterDisturbance`
  every physics tick (`submit_disturbance()`, values copied; latest wins) and
  call `release_disturbance()` in `_exit_tree`.
- **Water mask:** a `GREWaterMask` lid writes stencil 128
  (`GREWaterMask.STENCIL_REFERENCE`, `water_mask.gdshader`) and every water tier
  (`water.gdshader`, `water_medium.gdshader`, `water_low.gdshader`) reads
  `stencil_mode read, compare_not_equal, 128`; change all together. The lid
  draws at render priority −30, before the underwater view (−21) and the
  water (−20), and discards while the camera is below its plane.
- **Weapons:** recoil receivers implement `apply_recoil(fire_direction,
  shot_data)`; projectiles are group `projectile` or have `launch()` and carry
  `source_rigid_body_instance_id` metadata. `player_controlled` gates boat
  drive and weapon input (`controlled_property`).

## Buoyancy invariants
- Bodies feel the interactive waves only by opting in
  (`set_query_wave_response()`, `GREBuoyantBody.wave_response`, default 0). Then
  `surface_query.glsl` reads `GREOceanInteraction.state_buffer` (h, dh/dt,
  soft-limited as drawn) and, inside a rim around the owner's own hull
  (`GREOceanSurfaceQueries._write_owner_record()`: the footprint grown by 30 % and
  at least 3 cells, stretched back along its motion through the water over half
  the period of a hull-length wave), interpolates from that rim. Never let a
  hull read the water it displaces: the bulge under it, smeared a cell or two,
  and the hollow behind it (without the stretch a circling boat's stern sank
  into it, lifting its propeller out). The previous system fed it back and
  bodies rocked harder and harder. `GREOceanSystem`'s camera point (the
  interaction owner) gets the drawn map instead, for the above/below test.
- `GREBuoyantBody` reports its hull every tick: a superellipse fitted to the
  collision shapes' outline (`_exponent_for_area_share()`), depth = `draft` +
  the waterline plane's mean depth (relative to the water, so riding the swell
  makes no waves), the water's velocity under it plus the drift.
- Visual, not physical: one placement knob, `draft` (no volumes or densities).
  Probe lift is `share × weight / N × (1 + depth / draft)`; the shares balance
  about the centre of mass (`_balance_probes()`), so every body rests level at
  `draft`, and the lift acts no lower than the centre of mass, so no body
  capsizes. Keep both.
- Depth uses the body's pose this tick; only the water height is delayed
  (extrapolated by query age and moved along the sample's slope to the
  probe's current position). Damping and drag are relative to the water:
  `height_rate()` along the probe's path, `surface_velocity` plus the drift.

## Ocean invariants
- CDLOD: one multimesh of 16 × 16 nodes set via the RenderingServer, selected
  per frame (`GREOceanLodGrid.update()`). `LOD_RANGE_FACTOR` must stay above ~2.8
  or levels crack. Only the drawing curves with the earth (`EARTH_RADIUS`);
  queries and reflections stay flat. Keep
  camera far planes past the horizon (demo: 60 km). The editor shows
  `editor_water_preview_mesh.tres`. Never save a generated mesh. The water is
  drawn at `water_level` (the `water_level` uniform), whatever the node's
  transform: one height for drawing, queries and reflections.
- Shader code lives in `water.gdshaderinc`; `water.gdshader`,
  `water_medium.gdshader`, `water_low.gdshader` only set defines. All variants
  keep identical uniforms (compile features out, not uniforms). Water optics,
  wave sampling, caustic focusing and the underwater light are in
  `ocean_common.gdshaderinc`, shared with `underwater.gdshader` (the internal
  full-screen view shown while the camera is below the waves, drawn one render
  priority before the water); both declare its uniforms under the water's names and
  GREOceanSystem sets every water parameter on both.
- The ocean renders with a private duplicate of `water_material` via
  `instance_geometry_set_material_override`. Never set `material_override`;
  keep `mat_water.tres` free of runtime values.
- Push constants (`GRERenderingContext.create_push_constant()`) are packed at the
  shader's exact size, 4 bytes per value, no padding: edit GLSL and packing
  together. Same for `GRECloudRenderer`'s push constants and Params buffer, and
  `GREVolumetricCloudEffect`'s Frame buffer (`cloud_screen_common.glslinc`).
- Storage images are `readonly`/`writeonly`; descriptor sets bind by array
  index, so order matches binding numbers.
- One `GREWaveSpectrum` (`GREOceanSystem.spectrum`: wind, fetch, depth, shape,
  `displacement_scale`, response) feeds every cascade; a `GREWaveCascade` holds
  only its tile and foam. Each cascade's runtime state (seed, clock, band,
  spectrum slots, frame times) is a `GREWaveCascadeState` owned by `GREOceanSystem`,
  index-aligned with `cascades`. The cascades split the spectrum by wavelength
  (`GREOceanSystem._update_spectrum_bands()`, run on tile, cascade-list and
  map-size changes; `wavenumber_band` → `spectrum_compute.glsl`): a cascade
  draws waves up to tile / 6, the next larger one the longer. Keep tiles
  non-commensurate (default 250 / 37 / 9).
- `simulation_map_size`: power of two, 128–1024 (`fft_compute.glsl` has one
  `#[versions]` entry per size). ≤ 8 cascades, each with active + pending
  spectrum slots crossfading every input change; only `tile_length`, cascade
  count and map size regenerate without crossfade.
- Dispatches in one compute list are unordered: put
  `compute_list_add_barrier` between dependent passes, and set every pass's
  push constant (a barrier re-applies the last one).
- Displacement/normal maps have full mips (`mip_chain.glsl`). Normal maps are
  `(slope x, slope z, squared slope, foam)`; `z − |xy|²` is slope variance
  → roughness. Keep every channel linearly averageable. Storage bindings use
  per-layer single-mip views; compute shaders read displacement via samplers.
- Lighting: `light()` does body diffuse (by light height), crest scattering
  and the sun's GGX; sky and planar reflections are `EMISSION`. Colour comes
  only from `water_absorption`, `water_scattering`,
  `water_scattering_anisotropy`: no artistic tints. `SPECULAR = 0` (engine
  specular doubles the sky). Reflections share one rough-surface Fresnel
  (`rough_fresnel`), never plain Schlick. `GREOceanSystem.normal_scale` 1 =
  physical slopes (one value for every cascade).
- Transparency: water is in the transparent pass; light from behind goes into
  `EMISSION` (no `ALPHA`) via `underwater_transmittance()`, albedo scaled by
  `1 − transmittance` (same transmittance). Keep `depth_draw_always`,
  `cast_shadow` off and `mat_water.tres` `render_priority` below every other
  transparent material, except the underwater view (one below) and
  `GREWaterMask` lids (−30, they must draw first). Caustics only in the water
  (`caustic_light()`).
- `GREWaveSpectrum.displacement_scale` 1 = physical JONSWAP height (the demo uses
  1; higher makes waves steeper than water allows and over-stiff boats capsize).
  `whitecap` thresholds include it (default 0.8 for 1); retune them together. Foam is coverage averaged by
  mips: no distance fades. `foam_detail.png` must stay uniformly distributed
  (regenerate with `generate_foam_detail.py`).
- Surface queries are async: `submit_query` every tick, `get_query_result`
  (null at first), `release_query` in `_exit_tree`. Extrapolate with
  `extrapolated_height(water.get_query_age(result))`, never
  `get_clock() - dispatch_time`. Results belong to their dispatch's points.
- Anything sampling wave displacement must match the vertex shader:
  per-cascade A/B frame blend (`GREOceanSystem._get_cascade_frame_blend()`),
  spectrum blend weights (`spectrum_blend_states.zw`, skip pending when
  `.w == 0`). Cascade buffer = 12 floats/cascade
  (`GREOceanSurfaceQueries.FLOATS_PER_CASCADE`, `GREOceanSystem._update_cascade_uniforms()`,
  `ocean_sampling.glslinc`). Queries read mip 0 and invert horizontal
  displacement.
- Interactive waves (`GREOceanInteraction`, visual only): one step per physics
  tick in `GREOceanSystem._physics_process` (`process_physics_priority` 100,
  after the bodies report; also saved in `ocean_system.tscn`, as
  `process_priority` is: a value only code sets becomes an override the
  editor saves into every instance). A world-locked window centred on
  the camera, with no lead toward where it looks (turning the camera swung it,
  clearing and fading foam): cell c is texel c mod map size,
  sampled with repeat wrapping at rest positions (`UV`); moving the window
  clears only the cells it enters, and a damped border keeps waves off the
  FFT's periodic seam. A hull's source is `T_now − T_previous`, the previous
  footprint moved with the water (first sighting or a jump starts over, no
  wave). The FFT buffer holds an input and an output half; pass order: source,
  forward FFT, evolve (exact dispersion with the spectrum's `water_depth`),
  inverse FFT, two output passes, mips. Keep the dispersion exact: a spatial
  kernel cannot draw a Kelvin wake (plan, Phase 0.1). `interaction_fade()` in
  `water.gdshaderinc` is copied in `surface_query.glsl`
  (`GREOceanSurfaceQueries.INTERACTION_FADE_START`); change both. Water debug
  views 16, 17, 18 show its height, slopes and foam.
- Wake foam (`interaction_foam.glsl`): coverage in two halves of a buffer
  (read one step, written the next), moved by the surface drift in whole
  cells (never resampled: no blur), the remainder an offset the foam pass and
  the water apply (`get_foam_offset()`, `interaction_foam_offset`; without
  it the foam jumped a cell at a time), and faded by `FOAM_LIFETIME`. A hull holds
  coverage by its speed through the water (`_hull_foam()`, the record's fifth
  vec4), not by its draft (that saturated big hulls); crest foam grows toward
  `CREST_FOAM_MAX_COVERAGE`. Keep both well below 1 so the foam stays lace.
  The water adds it to `foam_signal` before `foam_intensity`. `mip_chain.glsl`
  filters both maps in one dispatch (z: waves, foam).
- `fft_compute.glsl` (`buffer_slot, spectrum_count, direction`) and
  `transpose.glsl` (`buffer_slot, spectrum_count`) serve `GREWaveGenerator`
  (4 spectra, inverse) and `GREOceanInteraction` (1, forward and inverse).
- Includes aren't tracked by the importer: after editing an include, delete
  `.godot/imported/<name>-*` of every shader using it (touching is not
  enough). `ocean_sampling.glslinc` → `surface_query.glsl`;
  `interaction_common.glslinc` → `interaction_source.glsl`,
  `interaction_output.glsl`, `interaction_foam.glsl`, `surface_query.glsl`;
  `atmosphere_common.glslinc` → `atmosphere_*.glsl`, `aerial_perspective.glsl`,
  `cloud_raymarch.glsl`, `cloud_trace.glsl`;
  `cloud_noise.glslinc` → `cloud_noise_bake.glsl`, `cloud_weather.glsl`;
  `cloud_common.glslinc` → `cloud_raymarch.glsl`, `cloud_trace.glsl`;
  `cloud_screen_common.glslinc` → `cloud_trace.glsl`, `cloud_reconstruct.glsl`,
  `cloud_composite.glsl` (which also includes `atmosphere_common.glslinc`).
- Planar reflections reserve render layer 20 (`reflection_water_layer`) for
  water. The water samples `GREPlanarReflectionCaptureEffect.texture` and
  `distance_texture` (resize both via `set_size()`), not the SubViewport.
  The mirrored camera has physics interpolation off (it is mirrored every
  frame; interpolating again lagged it).
- Texture RIDs: a material keeps the RID set on it. Swap a `Texture2DRD`'s
  `texture_rd_rid` directly (never clear to `RID()` first, which frees it →
  white), or re-set the parameter with `_set_water_shader_parameter(..., force)`
  (it skips unchanged values). Getting this wrong made reflections white after
  window resizes.

## Sky invariants
- The clouds are a real volume the camera can fly through: one density field and
  light model (`cloud_common.glslinc`, cloud altitudes above `sea_level`, any
  observer altitude), marched three ways. Change the encoding (rgb premultiplied
  radiance at the cloud, a opacity) everywhere together:
  - `GREVolumetricCloudEffect` (in `sky_system.tscn`'s compositor, after the
    transparent pass, no exported state): the camera's view, traced on a
    half-size buffer (a quarter of it per frame), reprojected by cloud distance
    and composited inside the atmosphere in front of each pixel's surface.
    History and upsampling match pixels by scene distance (moving objects, MSAA
    edges); the buffers live in the viewport's render buffers.
  - `GRECloudRenderer.sea_cubemap`: seen from the sea below the camera (observer
    clamped under the base): the water's reflection, the atmosphere's cloud
    shadows and dome light, the mirrored camera's starfield.
  - `GRECloudRenderer.camera_cubemap`: seen from the camera, all faces: the sky's
    radiance map (`AT_CUBEMAP_PASS`) and the camera's light meter.
  With the effect present the sky and starfield leave the camera's own view to
  it (`screen_clouds`).
- Sky/starfield cloud uniforms go only through
  `RenderingServer.material_set_param`, never `set_shader_parameter`.
- The sky shader must not read `POSITION` or `TIME` (forces radiance re-renders);
  the `Sky` is INCREMENTAL and `GRESkySystem._refresh_sky_radiance()` refreshes it.
  A running day cycle updates the whole sky every frame (stepped updates
  showed in twilight); a stopped clock costs none. `set_moment()` drives it
  from an outside clock.
- The weather map is written only by `cloud_weather.glsl`; the raymarchers are
  pure readers. Its `a` channel warps the shape noise so its tiles do not line up. Noise percentile constants in `cloud_noise_bake.glsl` must be
  recomputed when the noise changes.
- `GRECloudPreset` fields interpolate and are listed in `BLENDED_PROPERTIES`
  (`haze_visibility` also in `GEOMETRIC_BLENDED_PROPERTIES`).
- Keep `rendering/anti_aliasing/quality/use_debanding` on (night skies band).
- Stars are physical light (magnitude → lux, × exposure in the shader): no
  visibility curves, twilight fades or moon washout. `starfield.gdshader`
  writes `POSITION` on the far plane; take `abs()` of the projection's `[1][1]`.
  `bright_star_catalog.tres` and `milky_way.exr` are generated by `tools/`; the
  Milky Way holds only stars fainter than V = 8, keep the catalog within that.
- Sky colour is spectral: 16 wavelengths turned into linear sRGB by the CIE
  observer (`ATMOSPHERE_SPECTRUM_TO_RGB`). The transmittance LUT stores optical depths
  at 550 nm (air, transport haze, ozone), read through
  `atmosphere_light_optical_depth()` / `atmosphere_light_transmittance()`; the
  tables are copied in `GRESkySystem` (change both). View-volume lookups stay on their
  own side of the horizon (`atmosphere_view_v()` and its copies).
- The sun and moon disks get their light above the atmosphere; the view volume
  dims them (never pre-dim them). Disks are drawn from their true positions
  through unrefracted, per-colour view rays (green flash).
- The atmosphere model lives only in `GREAtmosphereRenderer`'s compute passes;
  consumers only sample. The one CPU copy is
  `GRESkySystem._get_atmosphere_transmittance()` (same constants). Don't add sky
  gradients, ambient terms, light colour curves or night gating: sun and moon
  colours come only from transmittance, and both bodies light the atmosphere.
- The view-volume layout (`atmosphere_view_uvw()`, slices) and lobe phase are
  copied in `atmosphere_common.glslinc`, `atmosphere.gdshaderinc` and the
  water shader; change together. Consumers composite
  `background * transmittance + inscatter + lobe * phase`.
- Atmosphere and cloud outputs are pre-exposed; the sky shader divides by
  `atmosphere_exposure`, and once more in `AT_CUBEMAP_PASS` (Godot 4.8 exposes
  the radiance map twice).
- `GREAerialPerspectiveEffect` (in `sky_system.tscn`'s compositor, no exported
  state) runs before the transparent pass, per sample with MSAA.

## Physics layers
- Layer 2 `Projectile`, layer 3 `Hitbox`. Projectiles: layer 2, mask 4;
  hitboxes: layer 3, mask 2. Projectiles don't collide with ships.

## Known quirks (don't "fix" silently)
- `GREProjectile` uses a flat `waterline_y` and `GREProjectileWeaponController` a
  flat `aim_plane_y`; neither uses wave height.
- F is both `toggle_fullscreen` and `camera_move_down`; C is both
  `cycle_camera_mode` and `toggle_camera_follow`.
