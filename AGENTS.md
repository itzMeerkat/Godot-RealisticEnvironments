# AGENTS.md

Working rules for changing this project. Read the relevant addon `README.md`
before touching its code; this file only records what is easy to get wrong.

## Ground rules
- No compatibility shims: APIs, scenes, groups and uniforms may be renamed or
  deleted; update every caller and scene in the same change.
- Errors are production-grade. Anything a shipped game can hit (a missing or
  wrong node, bad configuration or data, a GPU resource or shader that fails,
  too many requests) is reported with `push_error` and the feature degrades or
  turns itself off; it never crashes or writes out of bounds. `assert()` is
  stripped from release builds: use it only for internal invariants the code
  itself guarantees. Resolve dependencies once (usually in `_ready`), not
  every frame, and model expected states ("no result yet", "disabled")
  explicitly. Compute features check `RenderingContext.failed` after building
  their resources.
- `docs/water-interaction-plan.md` and `docs/bow-wave-plan.md` are completed
  design records (their *Deferred verification* list is still open). The
  sections below describe the code as it is *today*.
- `README.md` → *Road to a commercial release* is the product roadmap.

## Project basics
- Godot 4.8, Forward+ (`project.godot` → `config/features`). Main scene:
  `res://demo/main.tscn`. There is no package manager, CI, formatter or test
  suite.
- Verify changes by running `demo/main.tscn` (or `demo/ocean_optics_debug.tscn`
  for shading work) in Godot 4.8 Forward+. Headless runs and the Compatibility
  renderer have no `RenderingDevice`; `OceanSystem` then reports an error and
  disables itself, so they can catch GDScript errors but not ocean regressions.
- GDScript warnings are on, addons included (`project.godot`
  `debug/gdscript/warnings/directory_rules`). Keep every script warning-free:
  rename locals that shadow members or base-class properties (`basis`,
  `position`, `scale`, `owner`, ...) and mark intended integer division with
  `@warning_ignore("integer_division")`. Type nodes by assignment
  (`@onready var x : Camera3D = $Camera3D`), not `as` (4.8 warns: `as` hides a
  wrong node as null). `tools/gd_lint.py` lists the
  warnings and errors of every script through a headless editor's language
  server.
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
- A body whose collision shape is scaled non-uniformly gets no usable inertia
  from Godot (inverse inertia 0: it cannot pitch or roll). The caravel's is, so
  `floating_box.tscn` sets `inertia` explicitly from the hull's size; do the
  same for any such boat. Check with
  `PhysicsServer3D.body_get_direct_state(rid).inverse_inertia`.
- No `/** ... */` doc comments in `.gdshader` / `.gdshaderinc` files; use `/*`
  or `//`. The Godot editor (measured on 4.7) extracts shader docs on every
  `Shader.get_shader_uniform_list()`, which made the water shader take 3.4 s per
  call and stalled the editor for ~13 s whenever the ocean node was selected.
- Debug helpers (probe debug draw, position trail, aim marker, health panel)
  are internal child nodes created at runtime. Never save them into a scene.

## Addon boundaries
- `*_system` addons never depend on each other directly. Code that more than
  one of them needs (RenderingDevice helpers, shared data types, contracts)
  goes into the shared core addon (`addons/core`, which depends on nothing);
  systems may depend on core only. Otherwise connect systems with signals,
  groups and duck-typed methods. `core` holds `WaterSurface` (+ its query
  types), `RenderingContext` and `HullSlicer` (see `addons/core/README.md`).
- Water consumers (`buoyancy_system`, the template's `BowSpray`) use only
  `WaterSurface.find(node)`, never `OceanSystem`. Damage-driven sinking is
  wired by connecting `HitboxHealthManager.group_destroyed` to
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
    cloud radiance as seen at the cloud, a opacity; `null` = no clouds) with a
    full mip chain, read at the mip that matches the water's roughness.
    Optional `get_star_cubemap()` (rgb star radiance in cd/m² above the
    atmosphere, mip chain; `null` = no stars), `get_star_basis()` (world
    direction into the cubemap's frame; it turns with the sky) and
    `get_star_radiance_scale()` (cubemap value to unexposed scene radiance)
    give the stars the water reflects, dimmed by the sea-level transmittance
    and behind the clouds. Where the planar reflection covers the reflected
    ray, the mirrored camera's own starfield brings them instead (the cubemap
    is weighted by `1 − coverage`), so stars are never counted twice.
    Optional `get_planet_directions()` (world) and `get_planet_irradiance()`
    (rgb scene irradiance above the atmosphere, unexposed; same length, at most
    `OceanSystem.MAX_SKY_POINTS`) are point lights the water reflects as
    glints (specular BRDF and glitter, like the sun); the starfield leaves the
    planets out for cameras below `sea_level`, so the planar reflection does not
    show them a second time.
    Optional `get_atmosphere_sky_volumes()` (`[transmittance, inscatter,
    inscatter_lobe]` `Texture3D`s for an observer on the sea, two slices: at
    the cloud base and at the ray's end; empty = no atmosphere) and
    `get_atmosphere_light()` (`Vector4`: toward the light, w the lobe's
    Henyey-Greenstein g) give the sky the water reflects: the clouds inside
    the atmosphere, `L_c + T_c * cloud + (1 - a) * (L_end - L_c)`, or
    `sky * (1 - a) + cloud` over the gradient without one. A source must emit
    `lighting_changed` before freeing those textures. Optional
    `get_atmosphere_view_volumes()` (the same three volumes for the active
    camera, refilled every frame; empty = no atmosphere),
    `get_atmosphere_view_observer()` (`Vector4`: the camera position they were
    built for this frame, w its altitude as used; the ocean reads it every
    frame) and `get_atmosphere_view_max_distance()` give the air between the
    camera and the water, which the water applies itself as `FOG` (it is
    transparent, drawn after `AerialPerspectiveEffect`). The clouds and the
    in-scatter are stored pre-exposed (see Exposure below).
  - Exposure: a light source has `get_scene_illuminance()` (lux on a level
    surface at the active camera, negative while unknown) and
    `get_illuminance_unit_lux()` (lux of the scene's irradiance 1);
    `ExposureController` writes `CameraAttributes.exposure_multiplier`. Godot
    applies that before rendering (lights, `EMISSION`, the sky's output; not
    unshaded `ALBEDO` or `FOG`), so anything that writes its own light
    matches it: every system reads the effective exposure itself (the
    camera's attributes, else the world's) each frame and stores its HDR
    textures pre-exposed. `SkySystem` scales the key light of its compute
    passes by it (and publishes `atmosphere_exposure`); the sky shader and
    the water divide what Godot exposes again. Don't apply exposure anywhere
    else, and keep physical light units off. `ExposureController` also adds a
    `NightVisionEffect` (rod vision: per-pixel desaturation and blue shift
    below ~3 cd/m²) to its target's compositor at runtime; don't add other
    night tints or desaturation in materials.
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
  - Water surface: `WaterSurface` (core). A simulation registers one per
    `World3D` in `_enter_tree` (before any consumer's `_ready`) and
    unregisters in `_exit_tree`; `OceanSystem` registers its
    `OceanSurfaceQueries`. Splashes: `add_impulse(position, radius,
    amplitude)` while `can_add_impulses()` (at most 64 per simulation step).
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
- The water is transparent: it reads the screen and depth textures, so Godot
  draws it in the transparent pass. Light from behind the surface goes into
  `EMISSION` (no `ALPHA`), attenuated by `underwater_transmittance()`, and the
  body albedo is scaled by `1 − transmittance`; keep both on the same
  transmittance. Keep `depth_draw_always`, the ocean's `cast_shadow` off and
  `mat_water.tres` `render_priority` below every other transparent material.
  Caustics multiply that transmitted light (`caustic_light()`, mean 1): don't
  add caustics to other materials (they would double).
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
- Surface queries are asynchronous: `submit_query(owner, points)` every
  tick, `get_query_result(owner)` returns the latest completed result
  (`null` at first), `release_query(owner)` in `_exit_tree`. Results lag
  a few frames — extrapolate with
  `extrapolated_height(water.get_query_age(result))`, never with
  `get_clock() - dispatch_time` (wrong in physics ticks) — and belong to the
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
  footprint that pushes water; `WaterSurface.submit_query`'s `body`).
  Those read the FFT waves only: `η` is one summed field, so a body cannot
  separate its own waves, and with the readback delay they make it oscillate
  by itself. Don't reintroduce a geometric own-wave mask for buoyancy (probes
  are not guaranteed to sit inside hull coverage). It steps once per
  physics tick (`OceanSystem._physics_process`). Its operator is an exact FFT
  of `g·|k|`; `interaction_grid_size` must stay a power of two (the FFT pass
  holds one 1024-wide line in shared memory).
- `HullProfile` images are RGBA16F (half-width, keel, station top; a unused):
  GPUs sample four-channel half floats directly, three-channel ones get padded
  on the CPU at every load. Changing the channels means re-baking every
  profile: all layers of the profile texture array must share one format.
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
  `OceanSystem._set_water_shader_parameter()` skips values equal to the last
  one sent, so re-binding such a texture needs its `force` argument.
  The planar reflection got this wrong once: after every window resize the sea
  reflected solid white "geometry" instead of the sky.

## Sky and cloud invariants
- Clouds are rendered by `CloudRenderer` (owned by `SkySystem`, editor and
  runtime) into the upper half of a cubemap around the camera, as seen at the
  cloud (no atmosphere in front). Its consumers (sky shader, starfield, water)
  all composite it inside the atmosphere (`atmosphere_sky_with_clouds()`; the
  starfield only fades by `1 - a`); change the encoding in all of them
  together. Its ambient light is the atmosphere's (`sky_ambient_buffer`). The mip chain is rebuilt every frame
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

- Keep `rendering/anti_aliasing/quality/use_debanding` on. Night and twilight
  skies are smooth gradients only a few 8-bit codes deep (the Rayleigh minimum
  90° from the moon); without dithering they band into contours whose darkest
  step reads as a dark disk in the sky.

## Star invariants
- Stars are physical light: `SkySystem` turns each `StarCatalog` magnitude into
  lux above the atmosphere (tied to the sun's magnitude and
  `SOLAR_ILLUMINANCE_LUX`) and the starfield shader multiplies it by the
  exposure itself (unlit `ALBEDO` is not exposed). Don't add visibility curves,
  twilight fades or moon washout: the exposure and the atmosphere's
  transmittance do that.
- The starfield is an internal child of `SkySystem` with a generated mesh and a
  duplicated material; never save it (or a mesh/material of it) into a scene.
- `starfield.gdshader` writes `POSITION` itself: stars sit on the far plane
  (clip z = 0, reversed z) behind every surface, and each quad's size is in
  pixels. Godot's Vulkan projection has a negative `[1][1]`: take `abs()` when
  deriving pixel sizes from it.
- `stars/bright_star_catalog.tres` is generated by `tools/bake_star_catalog.py`
  and `stars/milky_way.exr` by `tools/bake_milky_way.py`; never hand-edit them.
  The Milky Way map holds only stars fainter than V = 8, so the two add up
  without counting a star twice; keep the catalog at or below that limit.
- The Milky Way is part of space in `sky.gdshader` (behind the atmosphere and
  the clouds) and is baked into the star cubemap for the water; airglow is
  emission in `atmosphere_view.glsl` (a shell at 90 km, packed into the view
  pass's push-constant padding: `AtmosphereRenderer.airglow_radiance`).

## Atmosphere invariants
- The atmosphere model (media, light, integration) lives only in
  `AtmosphereRenderer`'s compute passes (`sky_system/shaders/compute/
  atmosphere_transmittance.glsl`, `atmosphere_multiple_scattering.glsl`,
  `atmosphere_view.glsl`, `atmosphere_ambient.glsl`, shared code in
  `atmosphere_common.glslinc`). Consumers only sample the lookup textures; add
  new media there, never in a consumer. The one other copy of physics is
  `SkySystem._get_atmosphere_transmittance()` (the transmittance LUT's
  integral on the CPU, for the scene's lights, the sky's disks and the
  clouds' light): same media constants and steps, but the whole haze (the direct
  beam; the passes' transport haze drops the haze lobe's forward peak,
  `atmosphere_haze_transport_share()`, delta-Eddington, and the glow it
  scatters reaches the scene through the sky). Light and view rays cross
  every medium. The whole sky (blue sky, twilight, ground below the horizon)
  is the atmosphere's; don't add sky colour gradients or ambient terms.
- The sun's and moon's light colours come only from that transmittance (white
  above the atmosphere, `SOLAR_ENERGY`, `MOON_ENERGY`, both physical); don't
  reintroduce colour gradients, energy curves or night gating for them. Night
  visibility is the exposure controller's job. Both bodies light the
  atmosphere (`atmosphere_view.glsl`: the key light with the haze's lobe, the
  secondary without it); switching to a single light makes twilight drop
  several hundred times at the switch.
- The view-volume layout (`atmosphere_view_uvw()`, slice distances) and the
  lobe's phase are copied in `atmosphere_common.glslinc`,
  `atmosphere.gdshaderinc` and the ocean's `water.gdshader`
  (`atmosphere_sea_lookup()`, observer at altitude 0; `aerial_perspective_fog()`,
  the camera's volume). Change them together.
  Consumers composite `background * transmittance + inscatter + lobe * phase`.
- Exposure: everything the atmosphere passes and the clouds output (in-scatter,
  sky light buffers, cloud radiance) is pre-exposed. The sky shader divides by
  `atmosphere_exposure`, and once more in its radiance-map pass
  (`AT_CUBEMAP_PASS`): Godot 4.8 renders the radiance map exposed and then
  exposes the light it gives again (measured: ×X² without the fix). The
  aerial perspective and `FOG` use the volumes as they are.
  `SkySystem._sky_irradiance` (the light meter's sky part, read back with
  `buffer_get_data_async`) divides by the exposure of its frame.
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
  `atmosphere_transmittance.glsl`, `atmosphere_multiple_scattering.glsl`,
  `atmosphere_view.glsl`, `atmosphere_ambient.glsl` and
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
