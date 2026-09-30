# Ocean System

FFT-simulated ocean surface for Godot 4 Forward+. It generates wave
displacement/normal/foam maps with compute shaders, renders them on a
camera-following clipmap mesh, and answers gameplay water-height queries on the
GPU.

## Quick start

1. Instance `ocean_system.tscn` (an `OceanSystem`, which is a `MeshInstance3D`).
   It ships with three cascades (128 m swell, 32 m waves, 8 m detail).
2. Optional: point `sky_source_path` at a `SkySystem` so reflections and sun
   glitter follow the time of day.
3. Optional: enable `use_external_wind` and point `wind_source_path` at a
   `WindSystem` (or any node with the wind contract, see below). With
   `use_external_wind` on, a missing wind source is an error.
4. Run with a `Camera3D` active. The mesh follows the camera in XZ; wave
   sampling is world-space, so waves do not slide.

Without a `RenderingDevice` (Compatibility renderer, headless) the ocean reports
an error and disables itself.

## Public API (`OceanSystem`)

| Member | Purpose |
| --- | --- |
| `submit_surface_query(owner: Object, points: PackedVector3Array)` | Queue points for this frame's GPU surface query. The latest submission per owner wins. |
| `get_surface_query_result(owner: Object) -> WaterSurfaceQueryResult` | Latest completed result for `owner`, or `null` before the first one arrives. |
| `release_surface_query(owner: Object)` | Forget an owner (call from `_exit_tree`). |
| `get_skipped_surface_query_dispatch_count()` | Frames whose dispatch waited because all readback slots were busy. |
| `add_water_impulse(position, radius, amplitude)` | Queue a splash in the interaction simulation (runtime, `interaction_enabled` only). |
| `get_interaction_dropped_time()` | Simulated seconds skipped because frames needed more than `interaction_max_steps_per_frame` steps. |
| `time` | Ocean clock in seconds; compare with `WaterSurfaceQueryResult.dispatch_time`. |
| `water_level` | Still-water height used by the shader, queries, reflections and buoyancy. |
| `water_material` | Template material. The ocean renders with a private duplicate (`get_water_material()`), applied through the `RenderingServer` and never saved into the scene. |
| `get_wind_source()`, `get_external_wind_speed()`, `get_external_wind_direction()`, `should_use_external_wind()` | Resolved external wind. |
| `get_sky_source()`, `get_ocean_radius()` | Resolved sky node; near-mesh radius. |
| group `ocean_system` | Every instance joins it on entering the tree; `BuoyantBody` uses it for auto-discovery. |

`WaterSurfaceQueryResult` (RefCounted): `points` (as submitted for that
dispatch), `samples: Array[WaterSurfaceSample]` (`samples[i]` answers
`points[i]`), `dispatch_time` (ocean `time` at dispatch).

`WaterSurfaceSample` (RefCounted): `position` (query point), `height` (world Y
of the rendered surface over that point), `normal`, `displacement` (wave offset
of the surface point over the query point), `surface_velocity` (displacement
change per second), and `extrapolated_height(elapsed)` =
`height + surface_velocity.y × min(elapsed, 0.1 s)`. The cap keeps frame
hitches from extrapolating a wave's velocity across a whole period.

### Query semantics

Queries are asynchronous (`OceanSurfaceQueries`):

- Each frame the ocean packs every owner's latest points into one compute
  dispatch and starts an asynchronous readback
  (`RenderingDevice.buffer_get_data_async`), so the CPU never waits on the GPU.
- Three readback slots rotate; if all are still in flight, that frame's
  queries stay queued for the next frame.
- A result arrives a few frames after its dispatch. Use
  `extrapolated_height(ocean.time - result.dispatch_time)` to hide the latency.
- A result belongs to the point set of its dispatch. If the caller's point count
  changed since then, `result.points.size()` differs; don't index into it.
- Nothing is dispatched until the first FFT output exists, and never with zero
  cascades.
- `owner` must be stable (its instance id keys the cache) and must call
  `release_surface_query()` when it stops querying.

Heights match the rendered mesh:

- The query uses the same previous/current and spectrum blending as the vertex
  shader.
- It undoes the horizontal "choppy" displacement: 3 fixed-point iterations find
  the source point whose displaced vertex lands on the query point.
- Normals come from central differences of the resulting height field (0.25 m
  step).
- The interaction simulation's `η` is added (see
  [Interaction simulation](#interaction-simulation-wakes)). Wakes and splashes
  lift bodies, but a hull's own rest depression does not.

## Inspector groups

- **Material** — `water_material` template.
- **Wave Parameters / Surface Shading / Foam Shading** — water and foam colour,
  roughness/specular, normal strength, bicubic normal filtering,
  `fragment_cascade_limit` (cascades sampled per pixel), foam intensity /
  threshold / softness.
- **Sky Reflection** — procedural sky reflection, sun glitter, sun scatter;
  `manual_*` values are used when no sky source is set or the source lacks a
  value.
- **Crest Glow** — low-sun, back-lit tint on tall steep crests (artistic).
- **Planar Reflections** — mirrored-camera reflection of scene geometry,
  resolution, strength, distortion, and clipping of submerged pixels.
- **External Wind** — `use_external_wind`, `wind_source_path`.
- **`parameters`** — the ordered `Array[WaveCascadeParameters]` (at most 8).
- **Performance** — `simulation_map_size` (128–1024), `updates_per_second`
  (FFT updates per second, default 20; 0 = every frame).
- **Mesh** — `ocean_radius`, `mesh_inner_extent`, `mesh_base_cell_size`,
  `mesh_ring_count`, camera following and snapping.
- **Far Ocean LOD** — extra coarse rings out to `far_lod_radius` (default 7 km)
  and distance fades for normals, foam and short-wavelength cascades.

## Wave cascades (`WaveCascadeParameters`)

Each cascade is one FFT tile that repeats every `tile_length` metres. Use long
tiles for swell and short tiles for chop. Per cascade:

- **Scale** — `tile_length`, `displacement_scale` (mesh height), `normal_scale`
  (lighting/foam only).
- **Wind** — local `wind_speed` / `wind_direction` (used when external wind is
  off), or `wind_speed_multiplier` / `wind_direction_offset` applied to the
  external wind. The wave direction turns gradually toward the wind at
  `wave_turn_rate_degrees_per_second` (or an automatic rate that is slower for
  longer tiles).
- **Spectrum** — `fetch_length` (km), `water_depth_meters`, `swell`, `spread`,
  `detail`.
- **Spectrum Refresh** — when to regenerate and how long to crossfade (below).
- **Foam** — `whitecap` (steepness threshold), `foam_amount` (growth vs. decay).

**Spectrum crossfades.**
- Each cascade has two spectrum slots, and each slot remembers the inputs it was
  generated from (wind speed, direction, fetch, depth, swell, spread, detail).
- On every wave update the cascade compares its target inputs with the active
  slot. It starts a crossfade when:
  - direction moved ≥ `spectrum_direction_refresh_threshold`, or
  - wind speed moved ≥ `spectrum_speed_refresh_threshold`, or
  - any other input changed at all.
- The crossfade generates the target into the pending slot and fades it in over
  `spectrum_blend_duration`, using equal-power weights (cos/sin) so the wave
  height stays constant. Changes arriving mid-fade are picked up once it ends.
- Changing `tile_length`, the number of cascades or `simulation_map_size`
  regenerates spectra immediately, without a crossfade (the latter two also
  rebuild all GPU resources).
## Surface extras

- **Hull cutouts** — hide water that would show inside a ship's hull. See
  [Hull cutouts](#hull-cutouts) below.
- **Wake foam** — comes from the interaction simulation (see
  [Interaction simulation](#interaction-simulation-wakes)); there is no
  scripted foam API.
- **Shading debug** — the shader uniform `water_debug_view` (1–13) shows single
  terms (sky reflection, glitter, crest masks, scatter, roughness, …). The
  ocean resets it to 0 on ready, so set it on the material at runtime.

## Hull cutouts

Setup:

1. Add a `HullWaterFootprint` rigidly to the ship, usually as a direct child of
   the body. The boat template already has one.
2. Set `bake_source_paths` to the hull mesh roots only; masts, sails and
   rigging would widen the cutout.
3. Save the scene, then toggle **Editor Bake Profile**. It writes
   `<scene>_hull_profile.tres` next to the scene (or overwrites the current
   profile file) and assigns it. Save the scene again.

A footprint without a profile contributes nothing: it shows a configuration
warning in the editor and reports an error at runtime.

**`HullProfile`** stores the hull's inside in the footprint's local space as a
small `64 × 32` RG16F image, treating the hull as mirror-symmetric about
`center_x`:

- **R:** inner half-width over (length station, height).
- **G:** keel height over (length station, lateral offset). Used by the
  interaction simulation for hull draft.

**Baking.** `HullSlicer` slices the hull triangles with 32 horizontal planes and
records the widest crossing at each of 64 length stations, minus `bake_inset`.

**Each frame**, `OceanSystem`:

1. collects the footprints in group `ocean_hull`;
2. keeps those whose bounding sphere comes within `hull_cutout_distance`
   (default 150 m) of the camera, at most 8, nearest first;
3. uploads their world-to-hull transforms, bounding spheres, profile rectangles
   and layer indices (`near_hull_*` uniforms);
4. rebuilds one `Texture2DArray` layer per distinct profile, only when the set
   of profiles changes.

Farther hulls get no cutout: the water inside them is too small to see.

**In the fragment shader**, for each near hull:

1. Reject by bounding sphere (grown by the feather).
2. Transform the water-surface point into hull space and look up the half-width
   at its (z, y).
3. Discard where `|x − center_x| < half_width`.
4. Add `cutout_edge_foam` in a `cutout_feather`-wide band just outside.

The test runs on the water-surface point itself, so it is view-independent and
handles pitch and roll. Above the hull, or where the profile width is 0, water
stays visible (e.g. waves over the deck).

## Interaction simulation (wakes)

At runtime `OceanSystem` runs `WaterInteractionSim`, an iWave simulation
(Tessendorf, *Interactive Water Surfaces*, 2004), on a window around the
camera. By default the window is 512 × 512 cells of 0.5 m, so 256 m across.

What it produces:
- Hulls with a `HullWaterFootprint` push water, and moving, heaving or rolling
  hulls radiate Kelvin wakes and bow waves.
- `add_water_impulse(position, radius, amplitude)` queues a splash.
- The water shader adds the simulated height, slope and foam.
- Surface queries include it, so buoyancy feels other ships' wakes.
- It does not run in the editor.

Settings: the **Interaction** export group (grid size, cell size, damping,
gravity scale, step rate, absorbing border, foam) and each footprint's
**Wake** group (`wake_enabled`, `wake_strength`, `wake_edge_softness`).

How it works:

- **State.** The simulation stores `η = h + p` per cell: the wave deviation from
  the hull-conforming rest state. `h` is the visible surface offset and `p` the
  hull's pressure head, i.e. its draft below the incident FFT surface, read from
  the profile's keel channel.
  - A hull at rest sits in equilibrium (`h = −p`, water pushed down to the hull
    bottom), so it makes no waves. Only *changes* of `p` radiate.
  - Ships entering the window or present at startup cause no transient.
  - Queries use `η` (not `h`), so a ship never loses buoyancy to its own rest
    depression.
- **Step** (fixed rate, several per frame if needed):
  1. `iwave_pressure` computes `p` for every cell covered by up to 32 nearby
     hulls, tapered to 0 at the waterline, and packs `η` for the FFT.
  2. `iwave_fft` → `iwave_operator` → inverse `iwave_fft` applies iWave's
     vertical-derivative operator exactly in frequency space. Every wavenumber
     is multiplied by `g·|k|`, which is deep-water dispersion `ω² = g|k|`, the
     property that gives the ~19.5° Kelvin wedge. The 13×13 kernel from the
     paper cannot reproduce that at wake wavelengths (see the plan's Phase 3
     notes).
  3. `iwave_step` integrates with velocity damping, adds an absorbing border
     (`interaction_sponge_*`) so waves leaving the window are absorbed rather
     than wrapped, accumulates foam (steep waves, rising pressure at the bow),
     and writes the render texture `(h, η, foam)`.
- **Moving window.** The window follows the camera with wrap-around addressing:
  world cell `c` lives at texel `c mod N`. Moving never copies data;
  `iwave_scroll` only clears cells that entered. The FFT's periodicity matches
  this wrap-around mapping.
- **Sampling.** The water material samples the render texture with repeat
  addressing, displacing vertices at their already-displaced XZ. Rendering and
  queries fade the simulation out over the band inside the absorbing border.

Known limits:
- A hull that suddenly stops forcing makes a burst of waves: it left the 32
  nearest, was freed, or `wake_enabled` was switched off.
- Hulls outside the window make no waves.

## How it works

### Frame flow (`ocean_system.gd`)

`_process` (priority 100):

1. follows the camera;
2. gathers near-camera hull cutouts into shader arrays;
3. pushes sky lighting when the sky source emitted `lighting_changed` (every
   frame for a source without that signal);
4. every `1 / updates_per_second` seconds, calls `WaveGenerator.update()` with
   the external wind;
5. advances `wave_blend_alpha`, steps the interaction simulation and
   dispatches the queued surface queries.

Dependencies (wind and sky source, RenderingDevice) are resolved once in
`_ready` and again only when their exports change. Exports set during scene
load only take effect in `_ready`, so the mesh and GPU resources are built
once.

### Compute pipeline (`wave_generator.gd`, `shaders/compute/`)

Per cascade, per spectrum slot:

1. `spectrum_compute` — TMA spectrum (JONSWAP × Kitaigorodskii depth
   attenuation) with Hasselmann directional spreading, seeded per cascade. Only
   runs when the slot is dirty.
2. `spectrum_modulate` — advances the spectrum in time via the dispersion
   relation and writes the complex inputs of four IFFTs.
3. `fft_compute` → `transpose` → `fft_compute` — Stockham IFFT on rows, then on
   columns (butterfly factors are precomputed once by `fft_butterfly`).
4. `fft_unpack` — writes the displacement map (xyz) and the normal map
   (height gradient, `dhx/dx`, foam in alpha). Foam appears where the
   displacement Jacobian drops below `whitecap`; it reads the previous normal
   map so it accumulates (`foam_grow_rate`) and decays (`foam_decay_rate`)
   across updates.

`update()` advances every cascade's clock, direction and crossfade state
(`WaveCascadeParameters.advance()`), then schedules one cascade per frame to
spread GPU cost. Each cascade propagates its active slot, plus the pending slot
while a crossfade runs; a slot's spectrum is regenerated from that slot's own
inputs only when it is dirty. When all cascades are done the two output texture
arrays swap (ping-pong) and `output_maps_swapped` fires. `OceanSystem` then
binds current + previous maps and ramps `wave_blend_alpha` 0→1 over the measured
update interval, so a 20 Hz simulation still animates smoothly.

Texture arrays hold `cascades × 2` layers: an active and a pending spectrum per
cascade. `spectrum_blend_states[i]` is `[active layer, pending layer, active
weight, pending weight]`. The pending weight is exactly 0 outside a crossfade,
and the vertex shader, fragment shader and query shader all skip the pending
layer's texture reads in that case. Foam crossfades linearly (it is a
non-negative mask); displacement and normals use the equal-power weights.

`rendering/render_context.gd` (`RenderingContext`) wraps the `RenderingDevice`:
shader loading and caching, buffers/textures, descriptor sets (bindings follow
array order), pipelines returned as callables, a deletion queue that frees
everything on teardown, and exact-size push-constant packing.

### Mesh

`_create_generated_clipmap_mesh()` builds concentric rings: a dense centre
(`mesh_base_cell_size` spacing out to `mesh_inner_extent / 2`), then
`mesh_ring_count` bands doubling the spacing, then coarse spacing to
`ocean_radius`, then (with far LOD) `far_lod_ring_count` rings eased out to
`far_lod_radius`. The vertex shader samples displacements in world space, and
fades out short-wavelength cascades with distance.

### Water shader (`shaders/spatial/water.gdshader`)

Uses Godot's built-in PBR lighting with `world_vertex_coords`. The fragment
stage discards water inside near hulls, samples normals/foam for up to
`fragment_cascade_limit` cascades (bicubic or bilinear), combines FFT foam,
interaction foam and cutout edge foam, then adds emission terms: procedural sky
reflection (Fresnel, roughness-broadened), planar reflection, GGX-shaped sun
glitter, sun scatter and crest glow.

### Planar reflections

`OceanReflectionRenderer` (created as a child once reflections are enabled,
never in the editor; configured through `apply()`) renders a `SubViewport`
from a camera mirrored across `water_level`, sharing the main `World3D`. The
water mesh is moved to `reflection_water_layer` (default 20) and that layer is
removed from the reflection camera's cull mask. `PlanarReflectionClipEffect`, a
`CompositorEffect` on that camera, clears pixels whose reconstructed world Y is
below the water plane so sinking objects don't reflect. The water shader
projects into the reflection texture with `planar_reflection_view_projection`.

### Surface query (`ocean_surface_queries.gd`, `shaders/compute/surface_query.glsl`)

`OceanSurfaceQueries` owns three query slots (point, cascade and sample buffers
plus cached uniform sets), and the shader and pipeline, directly on the main
`RenderingDevice`:

- A dispatch goes into an idle slot, and its readback callback, deferred to the
  main thread, marks the slot idle again.
- Buffers grow in powers of two, only on an idle slot.
- Uniform sets that referenced displacement textures of a rebuilt wave
  generator are freed by the device along with those textures. The cache is
  simply cleared.

The shader runs one thread per point and writes height, displacement, normal
and velocity (48 bytes per sample). Displacement sampling lives in
`shaders/compute/ocean_sampling.glslinc`, shared through `#include`. It covers:

- the cascade buffer and displacement-image declarations;
- bilinear filtering with the same texel-centre convention as the hardware
  sampler;
- previous/current and spectrum blending;
- horizontal-displacement inversion.

Godot doesn't track include dependencies: reimport `surface_query.glsl` after
editing the include.

## Files

| File | Role |
| --- | --- |
| `ocean_system.gd` / `.tscn` | `OceanSystem` node and default setup |
| `wave_generator.gd` | `WaveGenerator` compute pipeline |
| `wave_cascade_parameters.gd` | `WaveCascadeParameters` resource |
| `ocean_surface_queries.gd` | `OceanSurfaceQueries` async query batching and readback |
| `water_surface_query_result.gd`, `water_surface_sample.gd` | Query result types |
| `rendering/render_context.gd` | `RenderingContext` RenderingDevice helper |
| `ocean_reflection_renderer.gd`, `planar_reflection_clip_effect.gd` | Planar reflections |
| `hull_water_footprint.gd`, `hull_profile.gd`, `hull_slicer.gd` | Hull footprints, baked profiles, and the triangle slicer (also used by `BuoyancyProbeVolume`) |
| `water_interaction_sim.gd` | `WaterInteractionSim` iWave simulation around the camera |
| `shaders/compute/iwave_*.glsl`, `iwave_common.glslinc` | Interaction passes: scroll, impulse, pressure, FFT, operator, step |
| `shaders/compute/*.glsl` | Spectrum, FFT, unpack, transpose, surface query |
| `shaders/compute/ocean_sampling.glslinc` | Shared displacement sampling for compute shaders |
| `shaders/spatial/water.gdshader`, `mat_water.tres` | Water shader and default material template (no runtime values stored) |
| `editor_water_preview_mesh.tres` | Plane shown in the editor instead of the generated mesh |
