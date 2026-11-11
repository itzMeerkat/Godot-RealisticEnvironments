# API review plan

Status: implemented · Written 2026-10-12 · Target: Godot 4.8 Forward+, version 0.1.0

A review of every open-source addon before the API is frozen for 0.1: remove
duplicated code paths and settings, keep runtime state out of the public
surface, and make the contracts between systems consistent. The conventions
it settled are in `AGENTS.md` (*API conventions*). Ground rules as before: no
compatibility shims; every caller and scene was updated in the same change.

## Changes

### Contracts

- **Wind:** the duck-typed wind contract had four readers (ocean, sky, debug
  panel, compass HUD), each with its own copy. It now lives in `gre_core`'s
  `GREWindSource` (`is_valid()`, `get_speed()`, `get_direction()`,
  `get_velocity()`, `direction_to_vector()`); `GREWindSystem` stays
  dependency-free.
- **Wind source selection:** `GREOceanSystem.use_external_wind` is gone: a
  non-empty `wind_source_path` means "follow it", as
  `GRESkySystem.cloud_wind_source_path` already worked. Invalid paths are errors
  and configuration warnings in both.
- **Sky source:** the `get_sky_top_color()` / `get_sky_horizon_color()` /
  `get_sky_ground_*()` getters and the same-name property fallbacks were never
  provided by `GRESkySystem`. The contract is now methods only:
  `get_sun_direction()`, `get_sun_visibility()` and the optional clouds,
  stars, planets and atmosphere; the gradient sky without an atmosphere comes
  from `manual_sky_top_color` / `manual_sky_horizon_color`. The contract is
  documented for users in the ocean README.

### Ocean

- **One sea height:** the mesh was drawn at the node's Y while queries,
  buoyancy, hulls and reflections used `water_level`, so moving the node split
  them. The shader now draws at the `water_level` uniform; the node's transform
  is ignored and warns unless at height 0, unrotated and unscaled.
- **Cascades:** `WaveCascadeParameters` → `GREWaveCascade`, a settings-only
  resource: `tile_length` (a float; non-square tiles were half-supported) and
  foam. Its runtime state (seed, clock, band, spectrum slots, crossfade, frame
  times) moved to the internal `GREWaveCascadeState`, owned by `GREOceanSystem`, so a
  cascade can be shared between oceans. `scale_changed` → the resource's
  `changed`.
- **One value each:** `displacement_scale` was per cascade but had to be equal
  on all (the spectrum is split by wavelength); it is now
  `GREWaveSpectrum.displacement_scale`. The per-cascade `normal_scale` and the
  global `normal_strength` multiplied the same slopes; one
  `GREOceanSystem.normal_scale` (0–2, 1 = physical) remains.
  `sky_reflection_enabled` duplicated `sky_reflection_strength` = 0 and is gone.
- **`GREWaveSpectrum` names:** `water_depth_meters` → `water_depth`,
  `wave_turn_rate_degrees_per_second` → `turn_rate`, the `spectrum_` prefix
  dropped from `direction_refresh_threshold`, `speed_refresh_threshold` and
  `blend_duration`.
- **Enums:** `reflection_mode` is `GREOceanSystem.ReflectionMode`
  (`SKY_ONLY`, `SCREEN_SPACE`, `PLANAR`), `shader_quality` is
  `GREOceanSystem.ShaderQuality` (`LOW`, `MEDIUM`, `HIGH`); saved values are
  unchanged. `simulation_map_size` rejects sizes without an FFT version.
- **Groups:** `water_level` first, then Waves (spectrum, cascades,
  wind_source_path), Water, Surface, Foam, Sky (with a Manual Sky subgroup),
  Reflections, Hull Cutouts, Interaction, Quality, Material.
- **Public surface:** `wave_generator`, `rng`, `time`, `wind_source`,
  `sky_source` and the four map textures are private.
  `get_wind_source()`, `get_sky_source()`, `get_external_wind_*()`,
  `should_use_external_wind()`, `get_water_surface()` (use
  `GREWaterSurface.find()`) and `get_skipped_surface_query_dispatch_count()` are
  gone; `get_surface_wind_speed/direction()` → `get_wind_speed()` /
  `get_wind_direction_degrees()`.
- **Internals:** `GREWaveGenerator` is a `RefCounted` (it was a hidden child node);
  `OceanReflectionRenderer` is preloaded without a `class_name` (out of the
  Create Node dialog), is an internal child, and sends its uniforms through the
  ocean's cached setter instead of around it. Disabled oceans (no
  `RenderingDevice`) no longer reach GPU code from setters.

### Sky

- The mesh billboard sun and moon (`render_bodies_in_sky`,
  `follow_active_camera`, `celestial_visual_distance`, the `SunVisual` /
  `MoonVisual` nodes, `celestial_disk.gdshader` and its material) duplicated
  the sky shader's disks, which are hazed and sit behind the clouds; removed.
- `get_time_of_day()` duplicated `time_of_day`; removed.
- Exports regrouped: `sea_level` first, Astronomy, Lights, Night Sky, Clouds.

### Wind

- `get_base_wind_speed()` (= `wind_speed`) and `get_wind_direction_radians()`
  removed, `get_gust_offset()` made private. `wind_system.tscn` (a scene of one
  scripted node) removed.

### Buoyancy

- The three generate functions were copies; one
  `generate_probes(physical := true, fx := true)` remains, behind the same
  three buttons. Mesh collection reuses `HullSlicer.collect_mesh_instances()`;
  probes are created and recognised by type instead of by script resource.
- Names: `BuoyancyProbeNode.max_submerged_volume_cubic_meters` → `volume`,
  `*_water_drag_multiplier` → `*_drag_multiplier`;
  `generated_probe_volume_cubic_meters` → `generated_probe_volume`. The
  generation defaults are one **New Probes** subgroup.
- `debug_enabled` is off by default (every shipped scene turned it off).
- The resolved `GREWaterSurface` (`water`) is private in `GREBuoyantBody` and
  `BowSpray`; the `apply_forces` doc now says it also stops sampling.

### Hitbox damage

- Hitboxes found their manager three ways (manager registration,
  `manager_path`, a search of every ancestor's subtree). Now: `manager_path`,
  else the nearest manager ancestor, resolved once, with a configuration
  warning (the hitbox is `@tool`). `refresh_hitboxes()` and `set_manager()` are
  gone.
- `configure_collision_layers`, `hitbox_collision_layer` and
  `projectile_collision_mask` shadowed the `Area3D`'s own layer and mask; the
  scenes now set those directly.
- `group_max_health` no longer carries a `"default"` entry next to
  `default_group_max_health`; `should_ignore_projectile()` lost its unused
  argument.

## Considered and kept

- **Unit-suffixed names** (`latitude_degrees`, `cycle_duration_seconds`,
  `max_roll_degrees`, ...): renaming them all is churn without a behaviour
  gain; new names carry units in hints instead.
- **`GREBuoyantBody._on_hitbox_group_destroyed`** stays the documented connection
  target (Godot's handler naming).
- **Separate exposure reads** in `GREOceanSystem` and `GRESkySystem` (three lines
  each), and `GREOceanSurfaceQueries` managing its own RIDs (its buffers grow).
- **`manual_sky_*` gradient:** still the sky of an ocean without an atmosphere
  source.
- **Probe editor visuals** are saved into scenes as the probes' mesh and
  material (pre-existing; a gizmo or RenderingServer instance would avoid it).

## Verification

- `tools/gd_lint.py`: 0 diagnostics in 67 scripts.
- `demo/main.tscn`, `demo/ocean_optics_debug.tscn` and the three examples run
  600 frames with no errors; frames of the examples rendered with
  `--write-movie` show waves, foam, hull cutout and bodies floating on the drawn
  surface.
- A runtime script exercised map-size and cascade-list rebuilds, enum setters,
  removing the wind source, moving `sea_level` (queries follow) and impulses.

### Deferred verification

- Two runs of `demo/main.tscn` right after the reimport segfaulted on exit with
  no script error; 28 later runs (cold and warm shader cache) and the `HEAD`
  baseline (14 runs) did not. Watch for crashes on quit.
- The editor workflows (Generate buttons, Bake Profile, adding cascades in the
  inspector) were not clicked through.
