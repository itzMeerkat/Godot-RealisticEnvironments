# AGENTS.md

Working rules for changing this project. Read the relevant addon `README.md`
before touching its code; this file only records what is easy to get wrong.

## Active plan
- `docs/water-interaction-plan.md` is the agreed plan for hull cutouts, the iWave
  interaction simulation and the performance work. Follow its ground rules (no
  compatibility shims, no guard code that hides errors).
  Sections below describe the code as it is *today* and change as phases land.

## Project basics
- Godot 4.7, Forward+ (`project.godot` → `config/features`). Main scene:
  `res://demo/main.tscn`. There is no package manager, CI, linter, formatter or
  test suite.
- Verify changes by running `demo/main.tscn` (or `demo/ocean_optics_debug.tscn`
  for shading work) in Godot 4.7 Forward+. Headless runs and the Compatibility
  renderer have no `RenderingDevice`; `OceanSystem` then silently skips wave
  generation, so they can catch GDScript errors but not ocean regressions.
- Reusable code lives in `addons/*`; demo glue in `systems/` and `demo/`.
  `*_plugin.gd` files are empty `EditorPlugin` stubs — all runtime types are
  registered through `class_name`.
- `.godot/`, `.import/`, `build/`, `export.cfg`, `export_presets.cfg`,
  `fft_wave.md` and `todo.md` are git-ignored local state; never treat them as
  sources of truth.

## Editing scenes and resources
- Keep `res://` paths and `uid://` values intact when hand-editing `.tscn` /
  `.tres`. Every script has a committed `.gd.uid` sidecar; move/rename it with
  the script, and commit the new one when adding a script.
- `demo/rowboat.tscn` (player boat) and `demo/floating_box.tscn` (caravel)
  inherit `addons/floating_boat_template/floating_boat.tscn` and override its
  nodes by path (`BuoyantBody`, `BuoyancyProbeVolume/GeneratedProbes`,
  `Hitboxes`, `Weapons`, `HullWaterFootprint`, `CameraTargets/*`), with
  `index` attributes matching the template's child order. Renaming or
  reordering template nodes breaks those overrides, `BuoyantBody.sinking_probe_paths`
  and `demo/main.gd` (`BuoyantBody`, `CameraTargets/*`).
- Buoyancy probes are generated **in the editor** and saved into the scene.
  Runtime generation is refused on purpose; a volume with no saved probes only
  warns. The template has no probes; each boat generates its own.
- No `/** ... */` doc comments in `.gdshader` / `.gdshaderinc` files; use `/*`
  or `//`. The Godot 4.7 editor extracts shader docs on every
  `Shader.get_shader_uniform_list()`, which made the water shader take 3.4 s per
  call and stalled the editor for ~13 s whenever the ocean node was selected.
- Debug helpers (probe debug draw, position trail, aim marker, health panel)
  are internal child nodes created at runtime. Never save them into a scene.

## Addon boundaries
- `ocean_system`, `sky_system`, `wind_system`, `hitbox_damage_system` and
  `projectile_launcher_system` have no dependencies on other addons. Keep it
  that way: connect them with signals, groups and duck-typed methods.
- `buoyancy_system` depends only on `ocean_system` (`OceanSystem`,
  `WaterSurfaceSample`). Damage-driven sinking is wired by connecting
  `HitboxHealthManager.group_destroyed` to
  `BuoyantBody._on_hitbox_group_destroyed` in the scene — do not add
  hitbox/projectile imports to buoyancy code.
- `floating_boat_template` is the only place allowed to compose all systems.
- Cross-system contracts (change both sides together):
  - Wind source: `get_wind_speed()` + `get_wind_direction_degrees()`, or
    `wind_speed` / `wind_direction` properties.
  - Sky source: `get_sun_direction/sky_top_color/sky_horizon_color/
    sky_ground_horizon_color/sky_ground_bottom_color/sun_visibility()` or the
    same names as properties; missing values fall back to `manual_*` exports.
    A source with a `lighting_changed` signal is read only when it fires, so it
    must emit it after every lighting change; one without it is read every
    frame. Optional `get_cloud_cubemap()` returns a cubemap (rgb premultiplied
    cloud radiance, a opacity; `null` = no clouds) with a full mip chain, that
    the water composites into its sky reflection as `sky * (1 - a) + rgb`,
    reading the mip that matches its roughness. Optional
    `get_atmosphere_sky_volumes()` (`[transmittance, inscatter,
    inscatter_lobe]` `Texture3D`s for an observer on the sea, ray ends only;
    empty = no atmosphere) and `get_atmosphere_light()` (`Vector4`: toward the
    light, w the lobe's Henyey-Greenstein g) give the atmosphere the water
    puts over its sky reflection; a source must emit `lighting_changed` before
    freeing those textures.
  - Atmosphere globals: global shader uniforms `atmosphere_*` (declared in
    `project.godot` `[shader_globals]`, published by `SkySystem`, read through
    `sky_system/shaders/atmosphere.gdshaderinc`). Transparent materials that
    should be hazed include it and write `FOG = atmosphere_fog(...)`; only
    `sky_system` and `floating_boat_template` may include it.
  - Hull cutouts: `HullWaterFootprint` nodes (group `ocean_hull`) with a baked
    `HullProfile`. Profiles are editor-baked and saved as `.tres`; never
    hand-edit their image. At most 8 hulls near the camera are cut out.
    The same profile drives wakes: up to 32 footprints with `wake_enabled`
    inside the interaction window push water in the iWave simulation. A
    footprint tracks its own velocity and angular velocity from its transform
    (physics ticks) for the bow wave; its SimHull record is 36 floats
    (`WaterInteractionSim.FLOATS_PER_HULL`, `iwave_pressure.glsl`), change both
    together.
  - Splashes: `OceanSystem.add_water_impulse(position, radius, amplitude)`
    (runtime only, at most 64 per simulation step).
  - Recoil receivers: `apply_recoil(fire_direction, shot_data)`, called by a
    launcher for each of its `recoil_receiver_paths` (e.g. `CannonSlideRecoil`).
    Body recoil is applied by `ProjectileWeaponController` from the launchers'
    `fired` signal.
  - Projectiles are recognised by group `projectile` or a `launch()` method and
    carry `source_rigid_body_instance_id` metadata for own-shot filtering.
  - `FloatingBoat.player_controlled` gates the boat's drive input;
    `ProjectileWeaponController` aims and fires only while the nearest ancestor
    with `player_controlled` has it set (duck-typed, `controlled_property`).
- Direction convention everywhere: degrees, 0 = +Z, 90 = +X. The FFT works in a
  rotated frame; only `WaveCascadeParameters._world_wind_direction_to_spectrum_direction`
  converts between them.

## Ocean system invariants
- `OceanSystem` renders a CDLOD quadtree at runtime: one multimesh of 16 × 16
  grid nodes set as the instance base through the RenderingServer, selected
  every frame around the active camera (`_update_lod_grid`). The vertex shader
  morphs vertices onto coarser lattices; `LOD_RANGE_FACTOR` must stay above
  ~2.8 or nodes two levels apart touch and crack. The water is drawn on the
  earth's curve (`EARTH_RADIUS`, vertex drop `d²/2R`, normal tilted by `d/R`)
  out to the horizon, capped by the camera's far plane; keep the cameras' far
  planes beyond the horizon (the demo uses 60 km). Only the drawing curves:
  `water_world_position` and everything physical (queries, buoyancy, hulls,
  planar reflections, the simulation) stay flat. In the editor the ocean
  shows the shared `editor_water_preview_mesh.tres` instead. Never save a
  generated mesh into a scene, and don't rotate or scale the ocean node.
- `OceanSystem` renders with a private duplicate of `water_material`, applied
  via `RenderingServer.instance_geometry_set_material_override` (not the
  `material_override` property), in the editor too. Never set
  `material_override` on the ocean, and keep `mat_water.tres` free of runtime
  values (textures, arrays).
- Push constants are packed by `RenderingContext.create_push_constant()` at the
  exact byte size the shader declares (4 bytes per value, no 16-byte padding).
  Adding a push-constant field means editing the GLSL block and the packing
  array in the same order.
- Storage-image bindings are declared `readonly`/`writeonly`; descriptor sets in
  `wave_generator.gd` bind by array index, so the order passed to
  `create_descriptor_set()` must match the shader's binding numbers.
- `simulation_map_size` must be a power of two in 128–1024 (dispatch sizes divide
  by 16, 32 and 128; compute sampling wraps with a bit mask; `fft_compute.glsl`
  has one `#[versions]` entry per size, loaded with
  `RenderingContext.load_shader(path, version)`). At most 8
  cascades; each cascade owns two spectrum slots (active + pending) and
  crossfades every spectrum-input change through them. Only `tile_length`,
  cascade count and map size regenerate without a crossfade.
- Dispatches inside one compute list are not ordered: a pass that reads what an
  earlier pass in the same list wrote needs `compute_list_add_barrier` between
  them (`wave_generator.gd`, `water_interaction_sim.gd`). Every pass must set
  its push constant: a barrier re-applies the last one to the bound pipeline.
- Displacement and normal maps have full mip chains built by
  `mip_downsample.glsl` after each unpack. Normal maps are `(slope x, slope z,
  squared slope, foam)`; the water shader reads `z − |xy|²` as the unresolved
  slope variance and turns it into roughness. Keep every channel linearly
  averageable. Storage bindings use per-layer, single-mip 2D views
  (`create_texture_slice_view`; Godot does not expose mip views of whole
  arrays); compute shaders read displacement through samplers.
- Water lighting: `light()` does diffuse (water body by the light's height, not
  the facet; foam wrapped and transmitted), crest scattering and the sun's GGX
  highlight (lit by the scene's lights); sky and planar reflections are
  `EMISSION`. Water color and crest glow both come from the optical properties
  (`water_absorption`, `water_scattering`, `water_scattering_anisotropy`); don't
  add artistic tints or masks on top. The shader writes
  `SPECULAR = 0`; don't reintroduce engine specular, it doubles the sky
  reflection. Sky and planar reflections share one rough-surface Fresnel
  (`rough_fresnel`, from the same slope variance as the roughness); plain
  Schlick on the filtered normal turns distant water into a mirror. `normal_scale` 1 gives the spectrum's physical slopes; steeper
  normals make distant water look rough and dark.
- The spectrum is normalized to the JONSWAP height variance
  (`spectrum_compute.glsl`): `displacement_scale` 1 is the physical wave
  height for the wind and fetch. The demo exaggerates swell with ~2.
  Foam thresholds (`whitecap`) are Jacobians of the rendered surface
  (`displacement_scale` included), so whitecaps sit on the crests that look
  sharp; retune them when changing `displacement_scale`.
- Foam in the normal maps' alpha is coverage (0–1), averaged by the mips; the
  water shader reveals it through `foam_detail.png`, whose values must stay
  uniformly distributed (regenerate it with `generate_foam_detail.py`, which
  histogram-equalizes). Don't add distance fades to foam: the mips handle it.
- Surface queries are asynchronous: `submit_surface_query(owner, points)` every
  tick, `get_surface_query_result(owner)` returns the latest completed result
  (`null` at first), `release_surface_query(owner)` in `_exit_tree`. Results lag
  a few frames — extrapolate with `extrapolated_height()` — and belong to the
  point set of their dispatch.
- Cascades update at their own rates (`max_wave_phase_step`), each into
  whichever of the fixed output maps A/B does not hold its newest frame.
  Anything that samples wave displacement must match the vertex shader:
  per-cascade frame blend (weight of B, `OceanSystem._get_cascade_frame_blend()`;
  `wave_frame_blends` in the material, the cascade buffer's third vec4 in
  compute), spectrum blend by the weights in `spectrum_blend_states` (`.zw`),
  pending layer skipped when `.w == 0`. The cascade buffer is 48 bytes per
  cascade (`OceanSurfaceQueries.BYTES_PER_CASCADE`, `ocean_sampling.glslinc`);
  change both together.
  Compute shaders get this from `shaders/compute/ocean_sampling.glslinc`, and
  surface heights also invert the horizontal displacement. Queries read mip 0,
  which matches the mesh where its vertices are at least as dense as the
  texels; farther out the mesh shows prefiltered (smoothed) waves.
- Shared includes are not tracked by the importer: after editing
  `ocean_sampling.glslinc` reimport `surface_query.glsl` and
  `iwave_pressure.glsl`; after editing `iwave_common.glslinc` reimport every
  `iwave_*.glsl` that includes it. Touching the file is not enough (the
  importer compares content): delete its `.godot/imported/<name>-*` files.
- The interaction simulation (`WaterInteractionSim`) runs at runtime only, on
  its own `RenderingContext` on the main `RenderingDevice`. It simulates
  `η = h + p` (wave deviation from the hull-conforming rest state), not the raw
  height `h`. Its render texture is `(h, η, foam, hull coverage)`: the water
  shader adds `h` and foam; surface queries add `η · (1 − coverage)`, except
  for owners on a body that makes waves (a `PhysicsBody3D` carrying a
  footprint that pushes water; `OceanSystem.submit_surface_query`'s `body`).
  Those read the FFT waves only: `η` is one summed field, so a body cannot
  separate its own waves, and with the readback delay they make it oscillate
  by itself. Don't reintroduce a geometric own-wave mask for buoyancy (probes
  are not guaranteed to sit inside hull coverage). It steps once per
  physics tick (`OceanSystem._physics_process`). Its operator is an exact FFT
  of `g·|k|`; `interaction_grid_size` must stay a power of two (the FFT pass
  holds one 1024-wide line in shared memory).
- `HullProfile` images are RGB16F (half-width, keel, station top). Changing the
  channels means re-baking every profile: all layers of the profile texture
  array must share one format.
- Planar reflections force the water mesh onto render layer 20
  (`reflection_water_layer`); keep that layer reserved for water. The water
  samples `PlanarReflectionCaptureEffect.texture` (linear HDR, premultiplied,
  with mips) and `distance_texture` (surface distance from the mirrored camera,
  for finding where each pixel's reflected ray hits), not the SubViewport's
  tonemapped texture; both must be resized with the viewport (`set_size()`).
- A material keeps the RenderingServer RID of a texture parameter from when it
  was set. Swapping a `Texture2DRD`'s `texture_rd_rid` straight to a new RD
  texture keeps that RID (texture_replace); clearing it to `RID()` first frees
  it, and the material then samples a freed texture as white. Either swap
  without clearing (`PlanarReflectionCaptureEffect.set_size()`) or set the
  material parameter again afterwards (`OceanSystem._set_texture_rid()` users).
  The planar reflection got this wrong once: after every window resize the sea
  reflected solid white "geometry" instead of the sky.

## Sky and cloud invariants
- Clouds are rendered by `CloudRenderer` (owned by `SkySystem`, editor and
  runtime) into the upper half of a cubemap around the camera. Its consumers
  (sky shader, starfield, water) all composite `sky * (1 - a) + rgb`; change
  the encoding in all of them together. The mip chain is rebuilt every frame
  after the raymarch (`cloud_mip_downsample.glsl`, 2×2 box per face); the sky
  and starfield show mip 0, the water blurred mips, and the atmosphere's view
  pass a blurred mip toward the light to shade the atmosphere's light.
- The sky and starfield cloud uniforms (`clouds_enabled`, `cloud_cubemap`)
  are set only through `RenderingServer.material_set_param`, never
  `set_shader_parameter`, so the runtime texture is never saved into
  `materials/*.tres`. `SkySystem` re-sends them once per full cloud refresh,
  which is also what re-renders the sky radiance map.
- The sky shader must not read `POSITION` (or `TIME`): either makes Godot
  re-render the radiance map whenever the camera moves (REALTIME mode). The
  camera's altitude comes from `atmosphere_observer.w`; the `Sky` is in
  INCREMENTAL mode, and `SkySystem` asks for radiance refreshes itself
  (`_refresh_sky_radiance()`: lighting, cloud refreshes, camera altitude).
- The cloud weather map (r coverage, g type, b density) is written only by
  `cloud_weather.glsl` and only read by `cloud_raymarch.glsl`. Cloud motion
  and evolution belong in the producer; keep the raymarcher a pure reader.
- The baked noise is stretched to a uniform 0–1 range with percentile
  constants in `cloud_noise_bake.glsl`; recompute them when the noise changes,
  or coverage stops meaning "share of sky covered".
- `CloudPreset` fields must interpolate and be listed in
  `CloudPreset.BLENDED_PROPERTIES`.
- `CloudRenderer` push constants and its Params buffer follow the same exact
  packing rule as the ocean's; edit GLSL and GDScript packing together.
- Clouds assume the camera is below the cloud base (`CloudRenderer` clamps
  its altitude). After editing `cloud_noise.glslinc` reimport
  `cloud_noise_bake.glsl` and `cloud_weather.glsl`.

## Atmosphere invariants
- The atmosphere model (media, light, integration) lives only in
  `AtmosphereRenderer`'s compute passes (`sky_system/shaders/compute/
  atmosphere_transmittance.glsl`, `atmosphere_view.glsl`, shared code in
  `atmosphere_common.glslinc`). Consumers only sample the lookup textures; add
  new media (air, ozone, multiple scattering) there, never in a consumer. The
  one other copy of physics is `SkySystem._get_atmosphere_transmittance()`
  (the transmittance LUT's integral for the scene's lights): same steps.
- The view-volume layout (`atmosphere_view_uvw()`, slice distances) and the
  lobe's phase are copied in `atmosphere_common.glslinc`,
  `atmosphere.gdshaderinc` and the ocean's `water.gdshader`
  (`atmosphere_apply_to_sky()`, observer at altitude 0). Change them together.
  Consumers composite `background * transmittance + inscatter + lobe * phase`.
- The global uniforms' list (`SkySystem.GLOBAL_*`, `atmosphere.gdshaderinc`,
  `project.godot` `[shader_globals]`) changes in all three places together.
  Only the owning SkySystem (`_global_atmosphere_owner`) writes them.
- `AerialPerspectiveEffect` sits in `sky_system.tscn`'s WorldEnvironment
  compositor and has no exported state (SkySystem sets its parameters), so
  nothing runtime is saved. It runs before the transparent pass, blending
  into the multisampled colour buffer per sample when MSAA is on (writes to
  the resolved buffer before the transparent pass would be overwritten by its
  resolve). Transparent surfaces haze themselves (`atmosphere_fog()`); opaque
  materials must not write `FOG` or they are hazed twice. Keep Godot's
  Environment fog off.
- Haze settings are weather: `CloudPreset.haze_*`, listed in
  `BLENDED_PROPERTIES` (`haze_visibility` also in
  `GEOMETRIC_BLENDED_PROPERTIES`). `SkySystem.sea_level` must match the
  ocean's water height.
- After editing `atmosphere_common.glslinc` reimport
  `atmosphere_transmittance.glsl`, `atmosphere_view.glsl` and
  `aerial_perspective.glsl` (delete their `.godot/imported/<name>-*` files).

## Physics layers
- Layer 2 `Projectile`, layer 3 `Hitbox` (bit values 2 and 4). Launchers put
  projectiles on layer 2 with mask 4; hitboxes sit on layer 3 with mask 2.
  Projectiles do not collide with ship bodies.

## Known quirks (don't "fix" silently)
- `Projectile` treats a flat `waterline_y` plane as the sea surface, and
  `ProjectileWeaponController` aims at a flat `aim_plane_y` plane; neither uses
  wave height.
- In the input map, F is both `toggle_fullscreen` and `camera_move_down`, and C
  is both `cycle_camera_mode` and `toggle_camera_follow`.
- Unused but kept: `demo/player/camera.gd`, `systems/input/demo_input_actions.gd`.
- The rowboat's physical probes were raised by hand after generation (column
  top at y = 0.4, 0.85 m tall) to give reserve buoyancy up to the gunwale;
  regenerating them puts them back at `design_waterline_y`.
