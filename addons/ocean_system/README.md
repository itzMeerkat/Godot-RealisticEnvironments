# Ocean System

FFT-simulated ocean surface for Godot 4 Forward+. It generates wave
displacement/normal/foam maps with compute shaders, renders them on a CDLOD
quadtree mesh around the camera, and answers gameplay water-height queries on
the GPU.

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
| `submit_surface_query(owner: Object, points: PackedVector3Array)` | Queue points for this frame's GPU surface query. The latest submission per owner wins. |
| `get_surface_query_result(owner: Object) -> WaterSurfaceQueryResult` | Latest completed result for `owner`, or `null` before the first one arrives. |
| `release_surface_query(owner: Object)` | Forget an owner (call from `_exit_tree`). |
| `get_skipped_surface_query_dispatch_count()` | Frames whose dispatch waited because all readback slots were busy. |
| `add_water_impulse(position, radius, amplitude)` | Queue a splash in the interaction simulation (runtime, `interaction_enabled` only). |
| `time` | Ocean clock in seconds; compare with `WaterSurfaceQueryResult.dispatch_time`. |
| `water_level` | Still-water height used by the shader, queries, reflections and buoyancy. |
| `water_material` | Template material. The ocean renders with a private duplicate (`get_water_material()`), applied through the `RenderingServer` and never saved into the scene. |
| `get_wind_source()`, `get_external_wind_speed()`, `get_external_wind_direction()`, `should_use_external_wind()` | Resolved external wind. |
| `get_sky_source()` | Resolved sky node. |
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
- The interaction simulation's `η` is added outside hulls (see
  [Interaction simulation](#interaction-simulation-wakes)): wakes and splashes
  lift bodies without a hull footprint, while hulls feel only the incident
  (FFT) waves.

## Inspector groups

- **Material** — `water_material` template.
- **Wave Parameters / Surface Shading / Foam Shading** — water and foam colour,
  roughness, normal strength, bicubic normal filtering,
  `fragment_cascade_limit` (cascades sampled per pixel), `foam_intensity`,
  `foam_detail_texture` and `foam_detail_tile_size` (see Foam below).
- **Sky Reflection** — procedural sky reflection, `sun_specular_strength`, sun scatter;
  `manual_*` values are used when no sky source is set or the source lacks a
  value. A sky source with `get_cloud_cubemap()` (SkySystem) also puts its
  clouds into the reflection.
- **Crest Glow** — low-sun, back-lit tint on tall steep crests (artistic).
- **Planar Reflections** — mirrored-camera reflection of scene geometry,
  resolution, strength, and clipping of submerged pixels.
- **External Wind** — `use_external_wind`, `wind_source_path`.
- **`parameters`** — the ordered `Array[WaveCascadeParameters]` (at most 8).
- **Performance** — `simulation_map_size` (128–1024, default 512),
  `updates_per_second` (FFT updates per second, default 20; 0 = every frame).
- **Mesh** — `mesh_base_cell_size` (vertex spacing nearest the camera) and
  `mesh_extent` (radius of rendered water, default 7 km).
- **Far Ocean LOD** — distance fade of the sun scatter shading
  (`far_lod_start_distance`, blend distance, curve). Geometry, normals and
  foam are not faded: their mip chains filter them.

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
  terms (sky reflection, sun specular, crest masks, scatter, roughness, slope
  deviation, …). The
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
small `64 × 32` RGB16F image, treating the hull as mirror-symmetric about
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
- `add_water_impulse(position, radius, amplitude)` queues a splash.
- The water shader adds the simulated height, slope and foam.
- Surface queries include it outside hulls, so bodies without a hull footprint
  feel wakes and splashes.
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
  `1 − coverage`. Hulls feel the incident waves; their own radiation is
  approximated by `BuoyantBody.heave_damping`.
- **Step** (once per physics tick, from `OceanSystem._physics_process`, so each
  step sees exactly one new pose of every hull; stepping per frame made hull
  motion stutter into the forcing and ring at grid scale):
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
4. every `1 / updates_per_second` seconds, calls `WaveGenerator.update()` with
   the external wind;
5. advances `wave_blend_alpha` and dispatches the queued surface queries.

`_physics_process` steps the interaction simulation once per physics tick.

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
5. `mip_downsample` — builds the displacement and normal maps' mip chains
   (2×2 box filter per level). All channels average linearly, so at any level
   `z − |xy|²` of the normal map is the slope variance inside the texel.

Each pass reads what the previous one wrote, and dispatches inside one compute
list are not ordered, so every pass is followed by `compute_list_add_barrier`.
The FFT buffer has one region per spectrum slot rather than per layer, since
only one cascade is transformed per frame. Output maps are cleared to zero on
creation: until the second pass completes, the "previous" maps sampled by the
interaction simulation and surface queries have never been written.

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

CDLOD (Strugar, *Continuous Distance-Dependent Level of Detail*, 2010). The
ocean is a quadtree of nodes on a fixed world grid; every node is the same
16 × 16 quad grid, `mesh_base_cell_size × 16 × 2^level` meters wide. Each frame
`_update_lod_grid()` selects nodes around the active camera:

- start from top-level nodes covering `mesh_extent`;
- skip nodes outside `mesh_extent` or the camera frustum (bounds grown by
  `LOD_WAVE_MARGIN` for displaced waves);
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

### Water shader (`shaders/spatial/water.gdshader`)

Uses `world_vertex_coords`. The fragment stage discards water inside near
hulls, then samples normals/foam for up to `fragment_cascade_limit` cascades
with trilinear filtering at the mip covering the pixel footprint's area
(explicit LOD from derivatives taken before the discard; bicubic only under
magnification). A mip sized by the footprint's longer axis would count every
slope along a grazing footprint as round blur and turn the water milky.

Filtering averages small waves away, and the slopes it removed come back as
roughness: per cascade, `z − |xy|²` of the filtered sample is the unresolved
slope variance, scaled by `normal_scale²`, and the GGX alpha is
`sqrt(clear_roughness⁴ + Σ variance)` (Toksvig/LEAN). Up close the water is
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
0.35 at low coverage, 1 when dense). Debug view 15 shows the result.

Lighting:
- `light()` replaces Godot's per-light shading. It uses the light's color,
  energy and attenuation, so it follows the SkySystem's sun (altitude, clouds).
  - Water body: light refracted in and scattered back up, so it follows the
    light's height above the horizon, not the wave facet (Lambert on facets
    looked like shaded plastic). Its albedo (`water_color` ×
    `water_diffuse_strength`) is scaled by `1 − Fresnel`: only light the surface
    does not reflect gets in and out.
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
  second with a crossfade, so glints twinkle.
- `SPECULAR` is 0, which turns off the engine's sky reflection; the shader
  adds its own as `EMISSION`: procedural sky reflection (Fresnel, blurred by
  the same roughness; the sky gradient over three directions, clouds from the
  cloud cubemap's mip whose blur matches the reflection lobe), planar
  reflection, sun scatter and crest glow.
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
and velocity (48 bytes per sample). Displacement sampling lives in
`shaders/compute/ocean_sampling.glslinc`, shared through `#include`. It covers:

- the cascade buffer and displacement texture declarations (sampled through a
  repeat, linear sampler at mip 0: the same hardware bilinear filtering as the
  vertex shader);
- previous/current and spectrum blending;
- horizontal-displacement inversion.

Godot doesn't track include dependencies: reimport `surface_query.glsl` and
`iwave_pressure.glsl` after editing the include (delete their
`.godot/imported/<name>-*` files; the importer compares content, not dates).

## Files

| File | Role |
| --- | --- |
| `ocean_system.gd` / `.tscn` | `OceanSystem` node and default setup |
| `wave_generator.gd` | `WaveGenerator` compute pipeline |
| `wave_cascade_parameters.gd` | `WaveCascadeParameters` resource |
| `ocean_surface_queries.gd` | `OceanSurfaceQueries` async query batching and readback |
| `water_surface_query_result.gd`, `water_surface_sample.gd` | Query result types |
| `rendering/render_context.gd` | `RenderingContext` RenderingDevice helper |
| `ocean_reflection_renderer.gd`, `planar_reflection_capture_effect.gd` | Planar reflections |
| `textures/foam_detail.png`, `textures/generate_foam_detail.py` | Foam pattern and its generator |
| `hull_water_footprint.gd`, `hull_profile.gd`, `hull_slicer.gd` | Hull footprints, baked profiles, and the triangle slicer (also used by `BuoyancyProbeVolume`) |
| `water_interaction_sim.gd` | `WaterInteractionSim` iWave simulation around the camera |
| `shaders/compute/iwave_*.glsl`, `iwave_common.glslinc` | Interaction passes: scroll, impulse, pressure, FFT, operator, step |
| `shaders/compute/*.glsl` | Spectrum, FFT, unpack, normal mip chain, transpose, surface query |
| `shaders/compute/ocean_sampling.glslinc` | Shared displacement sampling for compute shaders |
| `shaders/spatial/water.gdshader`, `mat_water.tres` | Water shader and default material template (no runtime values stored) |
| `editor_water_preview_mesh.tres` | Plane shown in the editor instead of the generated mesh |
