# Ocean System

FFT-simulated ocean surface for Godot 4 Forward+. It generates wave
displacement/normal/foam maps with compute shaders, renders them on a CDLOD
quadtree mesh around the camera, and answers gameplay water-height queries on
the GPU.

Requires the `core` addon (`addons/core`).

## Quick start

1. Instance `ocean_system.tscn` (an `OceanSystem`, which is a `MeshInstance3D`).
   It ships with three cascades (128 m swell, 32 m waves, 8 m detail).
2. Optional: point `sky_source_path` at a `SkySystem` so reflections follow the
   time of day (the sun highlight follows the scene's DirectionalLight).
3. Optional: enable `use_external_wind` and point `wind_source_path` at a
   `WindSystem` (or any node with the wind contract, see below). With
   `use_external_wind` on, a missing wind source is an error.
4. Run with a `Camera3D` active. The mesh is built around it every frame from
   world-fixed nodes, so neither the waves nor the vertices slide. Only the
   node's height matters: don't rotate or scale the `OceanSystem`.

Without a `RenderingDevice` (Compatibility renderer, headless) the ocean reports
an error and disables itself.

## Public API (`OceanSystem`)

| Member | Purpose |
| --- | --- |
| `get_water_surface() -> WaterSurface` | The ocean's surface (queries and splashes), also registered for the node's `World3D`; `null` without a `RenderingDevice`. |
| `get_skipped_surface_query_dispatch_count()` | Frames whose dispatch waited because all readback slots were busy. |
| `time` | Ocean clock in seconds, advanced once per frame (the surface's `get_clock()`). |
| `water_level` | Still-water height used by the shader, queries, reflections and buoyancy. |
| `water_material` | Template material. The ocean renders with a private duplicate (`get_water_material()`), applied through the `RenderingServer` and never saved into the scene. |
| `get_wind_source()`, `get_external_wind_speed()`, `get_external_wind_direction()`, `should_use_external_wind()` | Resolved external wind. |
| `get_sky_source()` | Resolved sky node. |

### Water surface (`WaterSurface`, core addon)

Everything that floats on or disturbs the water uses the `WaterSurface`
contract from `addons/core`, never `OceanSystem` itself. The ocean registers
its surface (`OceanSurfaceQueries`) for its `World3D` on entering the tree, so
consumers find it in their own `_ready` with `WaterSurface.find(node)`.

| Member | Purpose |
| --- | --- |
| `submit_query(owner: Object, points: PackedVector3Array, body: PhysicsBody3D = null)` | Queue points for this frame's GPU surface query. The latest submission per owner wins. Heights leave the interaction simulation out when `body` (default: the owner's nearest `PhysicsBody3D`) makes waves itself. |
| `get_query_result(owner: Object) -> WaterSurfaceQueryResult` | Latest completed result for `owner`, or `null` before the first one arrives. |
| `get_query_age(result: WaterSurfaceQueryResult) -> float` | Ocean seconds from the result's dispatch to the caller's moment (the start of the current physics tick, or the frame), for `extrapolated_height()`. |
| `release_query(owner: Object)` | Forget an owner (call from `_exit_tree`). |
| `get_clock() -> float` | The ocean's `time`, the clock of `dispatch_time`. |
| `can_add_impulses()`, `add_impulse(position, radius, amplitude)` | Queue a splash in the interaction simulation (runtime, while it runs). |

`WaterSurfaceQueryResult` (RefCounted): `points` (as submitted for that
dispatch), `samples: Array[WaterSurfaceSample]` (`samples[i]` answers
`points[i]`), `dispatch_time` (ocean `time` at dispatch).

`WaterSurfaceSample` (RefCounted): `position` (query point), `height` (world Y
of the rendered surface over that point), `normal`, `displacement` (wave offset
of the surface point over the query point), `surface_velocity` (displacement
change per second: the water's velocity at the surface over the point),
`height_rate()` (the height's rate of change over the fixed point,
`w − u · ∇h` with `∇h = −normal.xz / normal.y`: the water there rises at
`surface_velocity.y` but also flows along the slope) and
`extrapolated_height(elapsed)` = `height + height_rate() × min(elapsed, 0.1 s)`.
The cap keeps frame hitches from extrapolating a wave's velocity across a
whole period.

### Query semantics

Queries are asynchronous (`OceanSurfaceQueries`):

- Each frame the ocean packs every owner's latest points into one compute
  dispatch and starts an asynchronous readback
  (`RenderingDevice.buffer_get_data_async`), so the CPU never waits on the GPU.
- Three readback slots rotate; if all are still in flight, that frame's
  queries stay queued for the next frame.
- A result arrives a few frames after its dispatch. Use
  `extrapolated_height(water.get_query_age(result))` to hide the latency. The
  ocean's `time` advances once per frame; in a physics tick the age is taken
  at the tick's start (`Engine.get_physics_frames()` and the interpolation
  fraction recorded when `time` advanced), so each of several ticks between
  two frames sees the water of its own moment.
- A result belongs to the point set of its dispatch. If the caller's point count
  changed since then, `result.points.size()` differs; don't index into it.
- Nothing is dispatched until the first FFT output exists, and never with zero
  cascades.
- `owner` must be stable (its instance id keys the cache) and must call
  `release_query()` when it stops querying.

Heights match the rendered mesh:

- The query uses the same per-cascade frame blending (maps A/B) and spectrum
  blending as the vertex shader; its velocity comes from the same frame pair.
- It undoes the horizontal "choppy" displacement: 3 fixed-point iterations find
  the source point whose displaced vertex lands on the query point.
- Normals come from central differences of the resulting height field (0.25 m
  step).
- The interaction simulation's `η` is added outside hulls (see
  [Interaction simulation](#interaction-simulation-wakes)), except for owners
  on a body that makes waves itself: `submit_query(owner, points, body)`
  leaves `η` out when `body` (default: the owner's nearest `PhysicsBody3D`)
  carries a `HullWaterFootprint` that pushes water. `η` is one summed field, so
  such a body cannot tell its own waves from others'; read back a few frames
  late, its own waves act as a lagging spring and drive it. Wave-making bodies
  feel the incident (FFT) waves only; bodies that make no waves (no footprint,
  or `wake_enabled` off) also ride wakes and splashes.

## Inspector groups

- **Material** — `water_material` template.
- **Wave Parameters / Surface Shading / Foam Shading** — the water's optical
  properties (`water_absorption`, `water_scattering`,
  `water_scattering_anisotropy`; see Lighting below), foam colour, roughness,
  normal strength, bicubic normal filtering,
  `fragment_cascade_limit` (cascades sampled per pixel), `foam_intensity`,
  `foam_detail_texture` and `foam_detail_tile_size` (see Foam below).
- **Sky Reflection** — procedural sky reflection, `sun_specular_strength`, sun
  glitter; `manual_*` values are used when no sky source is set or the source
  lacks a value. A sky source with `get_cloud_cubemap()` (SkySystem) also puts
  its clouds into the reflection, one with `get_star_cubemap()` its stars,
  one with `get_atmosphere_sky_volumes()`
  its atmosphere, and one with `get_atmosphere_view_volumes()` the air between
  the camera and the water (see Lighting below).
- **Planar Reflections** — mirrored-camera reflection of scene geometry,
  resolution, strength, and clipping of submerged pixels.
- **External Wind** — `use_external_wind`, `wind_source_path`.
- **`parameters`** — the ordered `Array[WaveCascadeParameters]` (at most 8).
- **Performance** — `shader_quality` (Low / Medium / High water shader, see
  Water shader below), `simulation_map_size` (128–1024, default 512),
  `max_wave_phase_step` (default 0.1: how far, as a share of its shortest
  wavelength, a cascade's waves may travel between FFT updates; sets each
  cascade's update rate).
- **Mesh** — `mesh_base_cell_size` (vertex spacing nearest the camera). The
  water is drawn on the earth's curve out to the horizon (see Mesh below), as
  far as the camera's far plane allows: keep that beyond the horizon (the demo
  cameras use 60 km). Nothing fades with distance: geometry, normals and foam
  are filtered by their mip chains.

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
- **Foam** — `whitecap` (Jacobian of the rendered surface below which foam
  forms), `foam_generation` (coverage per second per unit below it),
  `foam_lifetime` (seconds to fade to 1/e).

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
- **Shading debug** — the shader uniform `water_debug_view` (1–14) shows single
  terms unlit: 1 reflectance, 2 reflected sky, 3 sun specular, 4 crest light
  path, 5 crest scattering phase, 6 crest scattering (sun), 7 deep-water albedo,
  8 reflection direction, 9 roughness, 10 slope deviation, 11 foam,
  12 transmittance to the scene behind the surface, 13 refracted path through
  the water (/ 32 m), 14 refraction offset on screen (× 20), 15 caustic light
  factor (× 0.25). The ocean
  resets it to 0 on ready, so set it on the material at runtime.

## Hull cutouts

Setup:

1. Add a `HullWaterFootprint` rigidly to the ship, usually as a direct child of
   the body. The boat template already has one.
2. Set `bake_source_paths` to the hull mesh roots only; masts, sails and
   rigging would widen the cutout.
3. Save the scene, then press **Bake Profile**. It writes
   `<scene>_hull_profile.tres` next to the scene (or overwrites the current
   profile file) and assigns it. Save the scene again.

A footprint without a profile contributes nothing: it shows a configuration
warning in the editor and reports an error at runtime.

**`HullProfile`** stores the hull's inside in the footprint's local space as a
small `64 × 32` RGBA16F image, treating the hull as mirror-symmetric about
`center_x`:

- **R:** inner half-width over (length station, height).
- **G:** keel height over (length station, lateral offset). Used by the
  interaction simulation for hull draft.
- **B:** the station's top (its highest row with a non-zero width), as a
  height coordinate. Used by the cutout's height offset and the simulation's
  waterline width.

Profiles baked before the B channel existed must be re-baked (all layers of the
profile texture array share one format).

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
handles pitch and roll. Above a station's top (e.g. the gunwale) plus the
footprint's `cutout_height_offset`, water stays visible. Within the offset, the
width at the station's top is used, so a positive offset hides waves cresting
over a low hull (the rowboat uses 0.3 m); a negative one lets water in lower.

## Interaction simulation (wakes)

At runtime `OceanSystem` runs `WaterInteractionSim`, an iWave simulation
(Tessendorf, *Interactive Water Surfaces*, 2004), on a window around the
camera. By default the window is 512 × 512 cells of 0.5 m, so 256 m across.
1024 × 0.25 m keeps the window size and resolves small hulls (e.g. a
rowboat's bow) more smoothly, at about 4× the GPU time per step (measured
~0.1 ms vs ~0.26 ms per step on an RTX 4070 Ti) and 64 MB instead of 16 MB of
textures; the bow-wave height is the same.

What it produces:
- Hulls with a `HullWaterFootprint` push water, and moving, heaving or rolling
  hulls radiate Kelvin wakes and bow waves.
- `WaterSurface.add_impulse(position, radius, amplitude)` queues a splash: a
  Gaussian displacement added to both `η_n` and `η_{n−1}` (raised at rest, so
  the result does not depend on the tick length), which spreads as a ring.
- The water shader adds the simulated height, slope and foam.
- Surface queries include it outside hulls for bodies that make no waves
  themselves, so floating debris rides wakes and splashes.
- It does not run in the editor.

Settings: the **Interaction** export group (grid size, cell size, damping,
viscosity, gravity scale, absorbing border, foam) and each footprint's
**Wake** group (`wake_enabled`, `wake_strength`, `wake_edge_softness`,
`bow_wave_strength`, `bow_wave_max_rise`).

How it works:

- **State.** The simulation stores `η = h + p` per cell: the wave deviation from
  the hull-conforming rest state. `h` is the visible surface offset and `p` the
  hull's pressure head, i.e. its draft below the incident FFT surface, read from
  the profile's keel channel.
  - A hull at rest sits in equilibrium (`h = −p`, water pushed down to the hull
    bottom), so it makes no waves. Only *changes* of `p` radiate.
  - Ships entering the window or present at startup cause no transient.
- **Bow wave.** A pressure patch alone depresses the water under itself and
  radiates its first crest behind it; it cannot make a bow wave (see
  `docs/bow-wave-plan.md`). So `p` also carries the stagnation head: where the
  waterline wall moves into the water at normal speed `v_n`, water piles up by
  `bow_wave_strength · v_n² / 2g` (capped at `bow_wave_max_rise`). It enters
  `p` with a negative sign in a band two `wake_edge_softness` wide on both
  sides of the waterline, and the step turns its motion into the bow crest and
  divergent waves. `v_n` comes from the footprint's own velocity and angular
  velocity (tracked from its transform every physics tick, smoothed over
  0.1 s) and the waterline normal (the profile's half-width slope, or the
  bow/stern direction at the ends). Measured on still water: caravel at
  8 m/s +0.36 m at the stem (was −0.02), rowboat at 4 m/s +0.28 m (was 0.01).
- **Hull coverage.** Under a hull, `η` is mostly the water that hull radiated
  itself. Fed back into its own buoyancy after the query readback delay, it
  acts as a lagging spring and pumps energy into heave: boats on still water
  oscillated with growing amplitude. So the pressure pass also writes hull
  coverage (1 inside the waterline and up to one `wake_edge_softness` outside
  it, where edge probes sit, fading out by two), and queries weight `η` by
  `1 − coverage`. Coverage alone did not keep a hull's own `η` out of its
  buoyancy: the caravel's generated probes sit at its widest beam, about 1 m
  outside its waterline, and read up to 1.2 m of its own waves. So bodies that
  make waves now skip `η` entirely (see [Query semantics](#query-semantics));
  coverage still keeps the water under a hull from lifting anything else.
  Their own radiation is approximated by `BuoyantBody.vertical_water_drag`.
- **Step** (once per physics tick, from `OceanSystem._physics_process`, so each
  step sees exactly one new pose of every hull; stepping per frame made hull
  motion stutter into the forcing and ring at grid scale). Or at a fixed
  `interaction_steps_per_second`, to decouple the cost from the physics rate:
  pick a divisor of the physics rate (60 Hz ticks: 30, 20, 15) so every step
  sees the same number of new poses; each uses the latest ones. The scheme is
  stable to about 5 steps a second at the default cell size:
  1. `iwave_pressure` computes `p` for every cell covered by up to 32 nearby
     hulls, tapered to 0 at the waterline and over `wake_edge_softness` at the
     bow and stern (a hard end switched cells on and off as the hull crossed
     the grid), minus the bow-wave rise, plus hull coverage and the bow rise
     outside hulls (the bow-foam source), and packs `η` for the FFT.
  2. `iwave_fft` → `iwave_operator` → inverse `iwave_fft` applies iWave's
     vertical-derivative operator exactly in frequency space. Every wavenumber
     is multiplied by `g·|k|`, which is deep-water dispersion `ω² = g|k|`, the
     property that gives the ~19.5° Kelvin wedge. The 13×13 kernel from the
     paper cannot reproduce that at wake wavelengths (see the plan's Phase 3
     notes).
  3. `iwave_step` integrates with velocity damping and viscosity
     (`interaction_viscosity`, `ν·∇²` of the per-step change: damping ~ `νk²`,
     so grid-scale ripples die in a fraction of a second while wakes barely
     change), adds an absorbing border (`interaction_sponge_*`) so waves
     leaving the window are absorbed rather than wrapped, accumulates foam
     (steep waves, and `interaction_foam_bow_rate` × the bow rise outside
     hulls, where the cutout does not hide it), and writes the render texture
     `(h, η, foam, coverage)`.
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

1. selects the mesh's CDLOD nodes around the active camera (runtime only);
2. gathers near-camera hull cutouts into shader arrays;
3. pushes sky lighting when the sky source emitted `lighting_changed` (every
   frame for a source without that signal);
4. updates every cascade whose newest frame the display has reached
   (`_update_waves()`, see below);
5. pushes the per-cascade frame blend and dispatches the queued surface
   queries.

`_physics_process` steps the interaction simulation once per physics tick (or
at `interaction_steps_per_second`).

Dependencies (wind and sky source, RenderingDevice) are resolved once in
`_ready` and again only when their exports change. Exports set during scene
load only take effect in `_ready`, so the mesh and GPU resources are built
once.

### Compute pipeline (`wave_generator.gd`, `shaders/compute/`)

Long sessions: every wave's angular frequency is rounded to a multiple of
`2π / WaveGenerator.WAVE_REPEAT_SECONDS` (1000 s; Tessendorf's repeat time, an
error under 0.0032 rad/s), so the sea repeats exactly every 1000 s and the clock
reaches the GPU modulo that period, keeping float32 precision however long the
game runs (`OceanSystem.time` itself is a double).

Per cascade, per spectrum slot:

1. `spectrum_compute` — TMA spectrum (JONSWAP × Kitaigorodskii depth
   attenuation) with Hasselmann directional spreading, seeded per cascade. Only
   runs when the slot is dirty.
2. `spectrum_modulate` — advances the spectrum in time via the dispersion
   relation and writes the complex inputs of four IFFTs.
3. `fft_compute` → `transpose` → `fft_compute` — Stockham IFFT on rows, then on
   columns (butterfly factors are precomputed once by `fft_butterfly`). One
   workgroup transforms one row and is exactly one row wide: `fft_compute.glsl`
   has a `#[versions]` entry per map size (`size_128` … `size_1024`).
4. `fft_unpack` — writes the displacement map (xyz) and the normal map
   (height gradient, squared gradient, foam in alpha). The gradient is the slope of the
   displaced surface with the cascade's `displacement_scale` as choppiness:
   crests, where the surface is compressed, get steeper (at most 4×), troughs
   flatter. Foam is coverage (0–1): it grows where the Jacobian of that same
   rendered surface drops below `whitecap` (by `foam_generation` per second
   per unit below) and fades over `foam_lifetime`, reading the previous
   normal map across updates. The map is indexed by rest position, so foam
   stays with the water while its crest moves on.
5. `mip_chain` — builds the displacement and normal maps' mip chains (2×2 box
   filter per level), up to five levels per dispatch for both maps together:
   each 16 × 16 workgroup halves a 32 × 32 tile in shared memory (two
   dispatches and two barriers for a 512² map instead of 18 and 9). All
   channels average linearly, so at any level `z − |xy|²` of the normal map is
   the slope variance inside the texel.

Each pass reads what the previous one wrote, and dispatches inside one compute
list are not ordered, so every pass is followed by `compute_list_add_barrier`.
The FFT buffer has one region per spectrum slot rather than per layer, since
cascades are transformed one after another. Output maps are cleared to zero on
creation: until a cascade's second update, its other map (sampled with weight 0
by the interaction simulation and surface queries) was never written.

**Per-cascade update rates.** Frames between two FFT updates blend the two, and
blending frames whose waves moved far apart washes the ripples out and back
every update (a 20 Hz pulse on an 8 m tile's 3 cm waves, which move a third of
a wavelength in 50 ms). So each cascade updates on its own schedule
(`OceanSystem.get_cascade_update_interval()`): its shortest wave (two texels)
may travel `max_wave_phase_step` of its length at deep-water phase speed
`√(gλ/2π)`. With 512 maps that is about 18 Hz for a 128 m tile, 35 Hz for 32 m,
and every frame for 8 m (no blend).

A due cascade advances its clock and state (`WaveCascadeParameters.advance()`)
to one interval *ahead* of now, and `WaveGenerator.update_cascade()` computes
that frame; blending from its newest frame to that one then shows the waves at
the current time, with no lag. Each update propagates the active slot, plus the
pending slot while a crossfade runs; a slot's spectrum is regenerated from that
slot's own inputs only when it is dirty.

There are two fixed output arrays of each kind, A and B. A cascade writes into
whichever does not hold its newest frame (`cascade_newest_output`), so A and B
hold every cascade's two latest frames, in either order. Per cascade,
`OceanSystem._get_cascade_frame_blend()` gives the weight of B for the current
time and a factor turning `B − A` into a velocity; the water shader
(`wave_frame_blends`), the surface queries and the interaction simulation (the
cascade buffer's third vec4) all blend with it.

Texture arrays hold `cascades × 2` layers: an active and a pending spectrum per
cascade. `spectrum_blend_states[i]` is `[active layer, pending layer, active
weight, pending weight]`. The pending weight is exactly 0 outside a crossfade,
and the vertex shader, fragment shader and query shader all skip the pending
layer's texture reads in that case. Foam crossfades linearly (it is a
non-negative mask); displacement and normals use the equal-power weights.

`RenderingContext` (core addon) wraps the `RenderingDevice`: shader loading and
caching, buffers/textures, descriptor sets (bindings follow array order),
pipelines returned as callables, ownership of every resource (freed newest
first with the context), and exact-size push-constant packing.

### Mesh

CDLOD (Strugar, *Continuous Distance-Dependent Level of Detail*, 2010). The
ocean is a quadtree of nodes on a fixed world grid; every node is the same
16 × 16 quad grid, `mesh_base_cell_size × 16 × 2^level` meters wide. Each frame
`OceanLodGrid.update()` (`ocean_lod_grid.gd`) selects nodes around the active camera:

- start from top-level nodes covering the radius out to the horizon (below),
  capped by the camera's far plane;
- skip nodes outside that radius or the camera frustum (all planes but the
  far one; bounds grown by `LOD_WAVE_MARGIN` for displaced waves and lowered
  by the curvature). A child's bounds lie inside its parent's, so planes a
  parent is fully inside are not tested again below it;
- split a node while it comes within the next finer level's range
  (`range(L) = 3 × node size(L)`, 3D distance), else draw it.

All nodes are drawn as one multimesh (custom data: origin x, z, vertex spacing,
level; identity transforms), set as the instance's base through the
RenderingServer so nothing generated is saved. The editor keeps the preview
plane.

In the vertex shader, vertices morph with distance onto the next level's
lattice (odd vertices slide onto even neighbours between `0.66` of the way to
`range(L)` and `range(L)`), and on through up to two coarser levels. Positions
then depend only on the world position, so nodes of different levels meet
without cracks. The same continuous vertex spacing picks the displacement mip
(texels as wide as the spacing): coarse vertices read prefiltered waves instead
of aliasing them, and nothing slides because vertices never move with the
camera.

**Earth curvature.** The vertex shader lowers every vertex by `d² / 2R`
(`d` horizontal distance from the camera, `R` = `EARTH_RADIUS`, 6371 km), so the
water lies on a sphere touching the sea under the camera, and the fragment
shader tilts the normal by `d / R` to match. The sea then ends at a real
horizon, `√(2Rh)` away and `√(2h/R)` below eye level for a camera `h` above
the water (5 km at 2 m, 23 km at 40 m), with the sky behind it (SkySystem's
sky continues down to there, see its `sea_level`). The mesh radius is that
distance plus `√(2R · LOD_WAVE_MARGIN)`, how far beyond it a crest still
shows. Near the camera the drop is tiny (3 mm at 200 m, 8 cm at 1 km). Only
the drawing curves: `water_world_position`, surface queries, buoyancy,
hull cutouts, planar reflections and the interaction simulation stay flat,
so objects far away float slightly above the drawn sea (0.3 m at 2 km).

### Water shader (`shaders/spatial/water.gdshaderinc`)

The shader's code is `water.gdshaderinc`; `water.gdshader` (High),
`water_medium.gdshader` and `water_low.gdshader` include it with different
compile-time settings, and `OceanSystem.shader_quality` puts one of them on the
private material (only when `water_material` uses a stock variant). Medium
shortens the refraction search (16 + 4 steps instead of 32 + 6), the crest light
march (5 instead of 7) and the planar reflection search (2 instead of 3); Low
shortens them further (8 + 3, 4, 1) and compiles out caustics, the sun's glitter
and planet glints. Every variant has the same uniforms.

Uses `world_vertex_coords`. The fragment stage discards water inside near
hulls, then samples normals/foam for up to `fragment_cascade_limit` cascades
with trilinear filtering at the mip covering the pixel footprint's area
(explicit LOD from derivatives taken before the discard; bicubic only under
magnification). A mip sized by the footprint's longer axis would count every
slope along a grazing footprint as round blur and turn the water milky.

Filtering averages small waves away, and the slopes it removed come back as
roughness: per cascade, `z − |xy|²` of the filtered sample is the unresolved
slope variance, scaled by `normal_scale²`, and the GGX alpha is
`sqrt(micro⁴ + Σ variance)` (Toksvig/LEAN), where the micro-roughness `micro`
covers what no cascade draws: `clear_roughness` (calm water) plus the short
capillary and gravity-capillary waves the wind raises, whose slope variance
is Cox and Munk's (1954) clean sea less their slick sea (an oil film damps
exactly those waves), `0.00356 U − 0.005` for wind `U` m/s, none below
~1.4 m/s, times `short_wave_slope_scale` (`OceanSystem._update_micro_roughness()`,
from `get_surface_wind_speed()`). Calm water is glassy (sharp reflections, star
glints); a fresh breeze gives the broad, sparkling sun path Cox and Munk
photographed. Up close the water is
smooth and every resolved wave makes its own sharp glint; in the distance the
waves merge into a rough surface with a broad sun path. Two things raise
`z − |xy|²` without being unresolved slopes, and are left out: blending the
previous and current FFT frames (variance is taken per frame, then blended),
and bilinear interpolation between texels while a pixel covers less than a
texel (that slope change is drawn across pixels; variance counts from one
texel up). Both made near water rough and its reflections milky.

Foam: the wave foam coverage (summed over the sampled cascades, times
`foam_intensity`), the interaction simulation's wake foam and the hull edge
foam are combined by `max`. Coverage is revealed through
`foam_detail_texture`, a tiling pattern whose values are uniformly
distributed (`textures/generate_foam_detail.py`: soft patches textured by
bubble lace): foam shows where the pattern exceeds `1 − coverage`, so it covers
exactly `coverage` of the area, as patches that dissolve into lace as they thin.
Once the pattern's texels are smaller than a pixel its mips flatten toward
0.5, and plain coverage takes over (the mips of coverage are exact at any
distance, so foam needs no distance fade). Thin foam is translucent (opacity
0.35 at low coverage, 1 when dense). Debug view 11 shows the result.

Lighting:
- `light()` replaces Godot's per-light shading. It uses the light's color,
  energy and attenuation, so it follows the SkySystem's sun (altitude, clouds).
  - Water body: light refracted in and scattered back up, so it follows the
    light's height above the horizon, not the wave facet (Lambert on facets
    looked like shaded plastic). Its albedo comes from the optical properties:
    the remote-sensing reflectance of optically deep water,
    `rrs = 0.0949 u + 0.0794 u²` with `u = bb / (a + bb)` (Gordon et al. 1988),
    above the surface `Rrs = 0.52 rrs / (1 − 1.7 rrs)` (Lee et al. 1998), as an
    albedo `π Rrs` (`water_body_albedo()`). `a` is `water_absorption`; the
    backscattering `bb` is half the molecular scattering (Morel) plus 1.8 % of
    `water_scattering` (Petzold). It is scaled by `1 − Fresnel` relative to a
    view from above: only light the surface does not reflect gets in and out.
  - Crest scattering (`crest_scatter()`): light that crossed a wave crest and
    scatters once toward the eye, just under the surface. The view ray refracts
    through this face; the light enters through this face if it faces the
    light, else through the crest's far face (this face mirrored about the
    vertical). Particles scatter by Henyey–Greenstein
    (`water_scattering_anisotropy`), water molecules by Rayleigh. Along the view
    ray the light's path grows about as fast as the view ray goes in, so the
    in-scattering integrates to `σs p / (2 σt)`, attenuated by `exp(−σt d)` over
    the light's path `d` through the water, which `crest_light_path()` marches
    along the wave heightfield toward the light (7 steps doubling from 0.25 m).
    Through gentle faces, refraction bends both rays steeply down, so the
    scattering angle stays wide and the glow is faint; steep and breaking
    crests send light forward to the eye and glow, tinted by the absorption.
    Lit by the scene's lights (color, energy, shadows), added as specular light.
  - Foam: a bubble layer that scatters light through its volume: wrapped
    diffuse (facets turned from the light still get some) plus light shining
    through toward a viewer facing the light. Its albedo (`foam_color`,
    near-neutral white) is a little darker in the pattern's bubble cells.
  - A GGX highlight with the water's Fresnel (`sky_reflection_f0`), times
    `sun_specular_strength` and the clear-water mask.
- Sun glitter (`glitter_scale()`, after Zirr & Kaplanyan 2016 and Deliot &
  Belcour 2023): the GGX highlight is the mean over many tiny facets
  (`sun_glitter_density` per m²). World cells about a pixel wide, on the rest
  grid so they ride with the water, draw a Poisson count of facets aligned with
  the light's disk (share from the GGX distribution), and the highlight is
  scaled by count / mean: the same mean, broken into glints. Two cell levels
  blend with the footprint, and patterns change `sun_glitter_rate` times a
  second with a crossfade, so glints twinkle. Their clock is `OceanSystem`'s
  (double precision; `glitter_pattern`, `glitter_pattern_blend`), not `TIME`,
  which wraps every hour.
- `SPECULAR` is 0, which turns off the engine's sky reflection; the shader
  adds its own as `EMISSION`: procedural sky reflection (Fresnel, blurred by
  the same roughness: the clear sky averaged over the reflection lobe, angular
  deviation `σ = √2 α` per axis, by the 4-point Gaussian cubature at `±√2 σ`
  along the elevation and the azimuth; clouds from the cloud cubemap's mip
  whose blur matches the lobe) and planar reflection.
- Planets (`sky_point_glints()`): a sky source with `get_planet_directions()` and
  `get_planet_irradiance()` gives up to `MAX_SKY_POINTS` point lights. Each is
  reflected like the sun's highlight (specular BRDF, the sun's glitter cells),
  dimmed by the sea-level transmittance and the clouds; skipped while too faint
  for the exposure. Venus in the dusk lays a glitter path.
- Stars (`sample_stars()`): with a sky source that has `get_star_cubemap()`,
  `get_star_basis()` and `get_star_radiance_scale()` (SkySystem), the
  reflected sky gets the stars from the cubemap's mip that matches the lobe,
  dimmed by the atmosphere's transmittance to the ray's end and hidden by the
  clouds. Where the planar reflection covers the reflected ray its mirrored
  camera draws the starfield sharp, so the cubemap only fills in the rest
  (weight `1 − coverage`). By day (scene radiance scale times exposure below
  1e-4) the lookup is skipped. The reflection keeps the stars' light; on
  rough water it is spread over the reflection lobe and too faint to see,
  and only calm, glassy water (little wind, see the micro-roughness above)
  shows star glints.
- Atmosphere (`atmosphere_sea_lookup()`): with a sky source that has
  `get_atmosphere_sky_volumes()` and `get_atmosphere_light()` (SkySystem), the
  reflected clear sky is the atmosphere's, seen from the sea surface: a lookup
  of the source's sea-level view volumes (two slices: at the cloud base and at
  the ray's end; `inscatter + lobe * phase`). The clouds sit inside it: the air
  up to their base in front, the rest of the sky through their gaps. The
  texture layout is the sky system's `atmosphere_view_uvw()` for an observer
  at altitude 0; change both together. Without an atmosphere the sky is the
  gradient of the `sky_*` colours.
- Aerial perspective (`aerial_perspective_fog()`): the sky system hazes the
  opaque scene before the transparent pass, so the water, drawn after it,
  hazes itself as other transparent surfaces do. With a sky source that has
  `get_atmosphere_view_volumes()`, `get_atmosphere_view_observer()` and
  `get_atmosphere_view_max_distance()` (SkySystem), it writes `FOG` from the
  camera's view volume at the drawn (curved) surface point: Godot blends the
  lit colour toward the in-scatter by the mean transmittance (exact for grey
  haze), stored pre-exposed like the colour buffer. The volumes are re-read on
  `lighting_changed`, the observer every frame. Its layout is the sky
  system's `atmosphere_view_uvw()` (zenith squeezed toward the observer's
  horizon, slices by the square root of the distance); change both together.
  The scene seen through the water is already hazed over its whole distance,
  so the air between the camera and the surface is applied to it twice; that
  air is metres thick where the water is clear enough to see through.
- Transparency and refraction: the shader reads the opaque scene
  (`hint_screen_texture`, linear HDR and exposed, with mips; `hint_depth_texture`),
  which puts it in Godot's transparent pass. It writes no `ALPHA`: what lies
  behind is added to `EMISSION` itself, so the order of overlapping water
  fragments does not matter, and `depth_draw_always` keeps it in the depth
  buffer for the transparent materials drawn after it (`mat_water.tres`
  `render_priority` -20 draws it before the sky's transparent disks and stars
  at -5 and -10 and everything at 0). The view ray refracts through the shaded
  normal (`WATER_IOR`); `find_refracted_scene()` marches it in view space
  along its image on the screen (32 steps growing quadratically from the
  surface, depth interpolated perspective-correctly) up to the distance light
  still comes back from. Where the ray goes from in front of the underwater
  scene to behind it, a bisection finds the transition: just behind the
  surface there means it passes through it (a screen point and its depth are
  one point); far behind means it went behind an object and continues hidden.
  So does a ray whose transition sees the far background at its near end and
  the object at its far end: it slipped behind the object's edge instead of
  crossing its surface (which happens inside the silhouette); counting those
  as hits drew a dotted outline of the object around its hidden region.
  Scene above the water (higher than the surface point) or sky is nothing the
  ray can meet. A hidden ray that finds nothing afterwards meets what the
  screen does not show, and the scene where it was last seen (3 px off the
  object's silhouette) stands in. A ray that leaves the screen or finds
  nothing meets a level bottom at the depth of the last scene it passed over;
  its screen point is then kept on the screen by letting the offset use at
  most half the room toward the edge (no folding onto the edge). Where the
  straight-through scene is sky, the water is deep. The scene is read at a mip that matches the spread the
  unresolved slopes give the refracted rays (`√2 σ (1 − 1/n)` per metre).
  `underwater_transmittance()` attenuates it over the refracted path by the
  beam attenuation `a + b` and over the point's depth below the surface by the
  downwelling light's `K_d = (a + bb) / 0.8` (Kirk; the scene's lights know
  nothing of the water), times `1 − Fresnel` and `1 − foam`. The water body's
  albedo is scaled by `1 − transmittance`, so shallow water fades into the
  deep-water colour with depth. The ocean casts no shadows (`cast_shadow` off
  in `ocean_system.tscn`): the light under the surface is the `K_d` term. Only
  opaque geometry shows through; other transparent objects under the surface
  are hidden by the water's depth.
- Caustics (`caustic_light()`): everything under the water is seen through it,
  so the water lights it. Refraction turns a slope `s` into a ray deviation
  `k s` (`k = 1 − cos i / (n cos t)`), so after a path `D` the sun's light
  that entered at `x` lands at `x + D (t0 − k s(x))`, and the irradiance there
  is scaled by `1 / det(I − D k H)`, `H` the height's Hessian (differenced from
  the slope maps; the singularity softened by `CAUSTIC_SOFTENING`). Light
  reaching a point comes from a surface patch `r = D k σ` wide, `σ` the
  deviation of the slopes of waves shorter than `r` (the mips' variance, found
  by fixed-point iteration): those waves focus far above it and their light
  arrives mixed, so `H` is filtered at `r`, the sun disk's blur over the path,
  or the pixel's footprint, whichever is widest. Rough seas therefore show
  broad patches and calm ones a sharp network. Only the direct sun is
  redistributed: the scene behind is multiplied by `1 + share (focus − 1)`
  (mean 1), `share` from a clear sky's direct share (0.8), the sun's
  visibility, the beam not scattered on the way down, and how much the surface
  faces the light (`hint_normal_roughness_texture`). Shadows are unknown to
  the water: a shadowed surface below still shows the pattern, at its dimmer
  brightness. Debug view 15 shows the factor (× 0.25).
- Exposure: Godot exposes `EMISSION` by the camera's exposure
  (`CameraAttributes.exposure_multiplier`, the camera's or else the world's),
  but the sky source's clouds and atmosphere and the planar reflection are
  stored already exposed. The water sums its reflections exposed (the gradient
  sky is multiplied up) and divides `EMISSION` by `scene_exposure`, which
  `OceanSystem` sets every frame from the active camera.
- Reflections use one reflectance: Fresnel averaged over the same slopes as the
  roughness (Bruneton et al. 2010, mean normal plus slope deviation
  `alpha / √2`). Schlick on the filtered normal would make distant water a
  mirror at grazing angles; the unresolved facets there tilt toward the viewer
  and reflect much less. Rays reflected below the horizon are mirrored back up
  (the next wave would send them there).

### Planar reflections

`OceanReflectionRenderer` (created as a child once reflections are enabled,
never in the editor; configured through `apply()`) renders a `SubViewport`
from a camera mirrored across `water_level`, sharing the main `World3D`. The
water mesh is moved to `reflection_water_layer` (default 20) and that layer is
removed from the reflection camera's cull mask. `PlanarReflectionCaptureEffect`,
a `CompositorEffect` on that camera, copies its color after the transparent
pass (linear HDR, before tonemapping; the background is cleared to zero, so
rgb is premultiplied by coverage a) into its own texture, clearing pixels whose
reconstructed world Y is below the water plane so sinking objects don't
reflect, then builds that texture's mip chain. It also writes each pixel's
distance from the mirrored camera to `distance_texture` (0 = no geometry). The
renderer sizes both to the viewport (`set_size()`) and hands them to the water,
never the viewport's tonemapped output.

The water shader reflects the view ray about each pixel's own wave normal and
finds what that ray hits: starting with the ray's end at infinity, it projects
the end with `planar_reflection_view_projection`, reads the stored distance of
the surface seen there, and moves the end to that surface's distance along the
ray (three steps). A texel with no geometry sends the ray on to the sky. This
is what makes the reflection follow the waves; a flat mirror would put every
reflection directly below its object. It then reads the mip whose blur matches
the reflection lobe (the reflected rays' spread `√2·alpha`, scaled by the hit's
distance from the water over its distance from the mirrored camera, over
`planar_reflection_texel_angle`), and composites `sky · (1 − a) + rgb` with the
same Fresnel as the sky.

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
and velocity (48 bytes per sample). Points are uploaded as the bytes of a
`PackedVector3Array` (tightly packed xyz floats, no per-point packing on the
CPU). Owners whose heights add the interaction simulation (decided per owner in
`submit_query`) are placed first, and the push constant's
`interaction_point_count` marks where they end. Displacement sampling lives in
`shaders/compute/ocean_sampling.glslinc`, shared through `#include`. It covers:

- the cascade buffer and displacement texture declarations (sampled through a
  repeat, linear sampler at mip 0: the same hardware bilinear filtering as the
  vertex shader);
- per-cascade frame (maps A/B) and spectrum blending, and the velocity from
  the frame pair;
- horizontal-displacement inversion.

Normals come from the rendered surface's tangents at the surface point over the
query point: the displaced positions of its rest neighbours ±0.25 m in X/Z (no
inversion needed; heights at world offsets would need four), plus the
simulation's slope where it is included. They are the geometry's, not the
shading's: the slope maps hold the waves' physical slope (`normal_scale`), while
`displacement_scale` steepens only the geometry.

Godot doesn't track include dependencies: reimport `surface_query.glsl` and
`iwave_pressure.glsl` after editing the include (delete their
`.godot/imported/<name>-*` files; the importer compares content, not dates).

## Files

| File | Role |
| --- | --- |
| `ocean_system.gd` / `.tscn` | `OceanSystem` node and default setup |
| `ocean_lod_grid.gd` | `OceanLodGrid`: the runtime CDLOD multimesh and its node selection |
| `ocean_hulls.gd` | `OceanHulls`: hull profile texture array, near-hull cutouts, SimHull records |
| `wave_generator.gd` | `WaveGenerator` compute pipeline |
| `wave_cascade_parameters.gd` | `WaveCascadeParameters` resource |
| `ocean_surface_queries.gd` | `OceanSurfaceQueries`: the ocean's `WaterSurface`, async query batching and readback |
| `ocean_reflection_renderer.gd`, `planar_reflection_capture_effect.gd` | Planar reflections |
| `textures/foam_detail.png`, `textures/generate_foam_detail.py` | Foam pattern and its generator |
| `hull_water_footprint.gd`, `hull_profile.gd` | Hull footprints and baked profiles (sliced with core's `HullSlicer`) |
| `water_interaction_sim.gd` | `WaterInteractionSim` iWave simulation around the camera |
| `shaders/compute/iwave_*.glsl`, `iwave_common.glslinc` | Interaction passes: scroll, impulse, pressure, FFT, operator, step |
| `shaders/compute/*.glsl` | Spectrum, FFT, unpack, normal mip chain, transpose, surface query |
| `shaders/compute/ocean_sampling.glslinc` | Shared displacement sampling for compute shaders |
| `shaders/spatial/water.gdshaderinc`, `water.gdshader`, `water_medium.gdshader`, `water_low.gdshader`, `mat_water.tres` | Water shader (body and its High / Medium / Low variants) and default material template (no runtime values stored) |
| `editor_water_preview_mesh.tres` | Plane shown in the editor instead of the generated mesh |
