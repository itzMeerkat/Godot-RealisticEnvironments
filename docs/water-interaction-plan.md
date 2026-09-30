# Water Interaction & Performance Plan

Status: Phases 1–3 done; Phases 4–5 implemented · Written 2026-09-29 · Target: Godot 4.7 Forward+

This is the reference plan for three pieces of work:

1. Cutting water out of ship hulls, in detail, only for ships near the camera.
2. Ship–water interaction waves using an **iWave** simulation.
3. The improvements found while reviewing the code.

It is ordered as phases. Each phase ends in a runnable state and updates the
affected `README.md` files and `AGENTS.md`.

## Ground rules

- **No compatibility layer.** APIs, scenes, groups and uniforms may be renamed
  or deleted. Update every caller and scene in the same change instead of
  keeping shims or aliases.
- **No guard code that hides errors.** Required dependencies are resolved once
  (usually in `_ready`) and checked with `assert()` / `push_error()`. They are
  not re-resolved every frame behind `if x == null: return`. States that are
  expected, such as "no query result yet" or "feature disabled", are modelled
  explicitly (a `null` result that is documented, an `enabled` flag) and handled
  on purpose by the caller. Every file this plan touches is brought in line.
  Example: `OceanSystem` without a `RenderingDevice` is a configuration error
  and must `push_error`, not silently skip wave generation.
- **Addon boundaries stay.** `ocean_system` owns the water, hull profiles and the
  interaction simulation. `projectile_launcher_system` and
  `hitbox_damage_system` still import nothing from other addons.
  `floating_boat_template` composes everything.
- **No benchmark scene or test runs at this stage.** Checks that need a running
  Godot are collected in [Deferred verification](#deferred-verification) for
  later.
- **Out of scope for now:** projectiles and aiming keep using the flat sea plane
  (`Projectile.waterline_y`, `ProjectileAimController.aim_plane_y`).

## Phase overview

| Phase | Content | Depends on |
| --- | --- | --- |
| 1 | Quick wins: async queries, displacement-inverted queries, fewer texture reads, crossfades, editor material | — |
| 2 | `HullProfile` bake and near-camera hull cutout | 1.2 (shared sampling include) |
| 3 | iWave interaction simulation (waves, pressure, foam) | 1, 2 |
| 4 | Replace manual foam with simulation foam | 3 |
| 5 | Buoyancy CPU cleanup | 1.1 |

---

## Phase 1 — Quick wins

### 1.1 Asynchronous surface-query readback

**Problem.** `OceanSystem._read_surface_query_results_if_ready`
(`ocean_system.gd:1395`) calls `RenderingDevice.buffer_get_data` on the main
device almost every frame. That call is expected to flush the device and make
the CPU wait for the GPU.

**Change.**
- Replace it with `RenderingDevice.buffer_get_data_async(buffer, callback,
  offset, size)` (Godot ≥ 4.4).
- Keep a ring of 3 **query slots**. Each slot owns its point, cascade and sample
  buffers, its cached uniform sets (one per ping-pong displacement pair), the
  requests it carries, and a state (`IDLE` / `IN_FLIGHT`).
- Each frame, dispatch the queued requests into an idle slot, then call
  `buffer_get_data_async`. The callback unpacks the samples, stores them per
  owner, and marks the slot idle. If no slot is idle, the frame dispatches
  nothing; that is normal back-pressure, counted in a stats field.
- Buffers grow only on an idle slot. The old buffer is freed right away, which
  needs a `RenderingContext.free_rid(rid)` helper that also removes it from the
  deletion queue.
- Delete the separate-device branch (`device != RenderingServer.get_rendering_device()`).
  `WaveGenerator` always uses the main device.

**New API** (replaces `sample_water_surface_batch` / `sample_water_surface`):

```gdscript
func submit_surface_query(owner: Object, points: PackedVector3Array) -> void
func get_surface_query_result(owner: Object) -> WaterSurfaceQueryResult  # null until the first result for owner
func release_surface_query(owner: Object) -> void                       # owners call this in _exit_tree
```

`WaterSurfaceQueryResult` (RefCounted): `points` (the submitted positions),
`samples: Array[WaterSurfaceSample]`, `dispatch_time` (ocean `time` when
dispatched). A `null` owner is an `assert`. `release_surface_query` fixes the
current leak, where `_surface_query_cached_results` never forgets an owner.

**Latency.** Results arrive about 2–3 frames after dispatch.
`WaterSurfaceSample` gets `extrapolated_height(now: float, dispatch_time: float)`,
which returns `height + surface_velocity.y * (now - dispatch_time)`. Consumers
use it for force calculations.

**Consumers.** `BuoyantBody` submits every physics tick and reads the latest
result. If `result.points.size()` differs from the current probe count (a probe
was toggled), it skips forces for that tick. That is explicit handling, and it
is documented in the buoyancy README.

### 1.2 Undo horizontal displacement in queries

**Problem.** The mesh moves each vertex by the full displacement `D(x)`,
including the horizontal "choppy" part. The query samples `D(p).y` at the query
point `p` (`surface_query.glsl`, `sample_height`). That is the height of the
vertex that *started* at `p`, not the surface that is drawn over `p`. On choppy
seas, boats float against a surface up to a displacement-width away.

**Change.**
- Add the shared include `shaders/compute/ocean_sampling.glsl`. It holds the
  cascade struct, bilinear layer sampling, the previous/current and
  active/pending blending, and:
  ```glsl
  // Find x such that x + D.xz(x) = p, then return the displacement there.
  vec3 sample_displacement_inverted(vec2 p) {
      vec2 x = p;
      for (int i = 0; i < 3; ++i) x = p - sample_total_displacement(x).xz;
      return sample_total_displacement(x);
  }
  ```
- In `surface_query.glsl`:
  - height = `water_level + inverted.y`;
  - normals from central differences of inverted heights (5 inversions per
    point; point counts are small);
  - velocity evaluated at the converged `x`.
- The include is reused by the Phase 3 pressure pass. Check first that
  `RDShaderFile` import resolves `#include "ocean_sampling.glsl"`. If it does
  not, the plan changes to a build step that concatenates the files. Copying the
  code by hand into each shader is not allowed.

### 1.3 Skip the pending-spectrum samples when no blend is running

The vertex shader (`water.gdshader:180-190`), fragment shader (`:340-350`) and
query shader always sample both the active and the pending spectrum layers.
With bicubic normals that is about 60 texture reads per pixel for 3 cascades,
and half of them get weight 0 almost all the time. Wrap the pending reads in
`if (blend_weights.y > 0.0)`. This branch is the same for every pixel, so it
costs nothing when no blend runs.

### 1.4 Equal-power crossfade between spectrum slots

Mixing two independent wave fields linearly at 50% drops the height by about
30%, so the sea looks calmer during direction blends. `spectrum_blend_states`
changes from `[active_layer, pending_layer, alpha, 0]` to
`[active_layer, pending_layer, w_active, w_pending]`, with
`w_active = cos(t·π/2)` and `w_pending = sin(t·π/2)` computed on the CPU. The
shader, query and pressure pass compute `active * w.x + pending * w.y`. The
previous↔current FFT blend (`wave_blend_alpha`) stays linear, because both
sides are the same field at nearby times.

### 1.5 Crossfade every spectrum change, including wind speed

**Problem.**
- A change in external wind speed (≥ 0.25 m/s, at most every 0.5 s) regenerates
  the *active* spectrum instantly (`ocean_system.gd:880`). Gusts cause repeated
  visible jumps.
- Both slots are generated with the same wind speed (`wave_generator.gd:103`),
  so a speed crossfade is impossible today.

**Change.**
- `WaveCascadeParameters` keeps a spectrum-input snapshot for each slot: wind
  speed, direction, fetch, depth, swell, spread, detail. `WaveGenerator` reads
  the snapshot for the slot it generates.
- Each update, the cascade compares its *target* inputs (from exports plus
  external wind) with the active snapshot. If any input passes its threshold
  (direction ≥ `spectrum_direction_refresh_threshold`; speed ≥
  `spectrum_speed_refresh_threshold`, default 0.25 m/s; any inspector-edited
  value), it writes the target into the pending snapshot, marks the pending slot
  dirty and starts a blend lasting `spectrum_blend_duration`. Changes that
  arrive during a blend are picked up once the blend finishes.
- Direction still turns gradually, rate-limited as today, before being
  compared.
- Delete `OceanSystem._update_external_wind_state` and its
  `EXTERNAL_WIND_*` constants. Cascades now own the change detection.
- `mark_all_spectra_dirty` is only used for reseeding (a change in cascade
  count or map size).

### 1.6 Keep the water material out of shared resources

In the editor, `OceanSystem` writes shader parameters straight into
`mat_water.tres` (`ocean_system.gd:1264`), because the scene's
`material_override` *is* that resource.

**Change.**
- Remove `material_override` from `ocean_system.tscn`.
- Add `@export var water_material: ShaderMaterial = preload(mat_water.tres)`.
  `OceanSystem` builds `_material = water_material.duplicate()` on first use
  and applies it with `RenderingServer.instance_geometry_set_material_override(get_instance(), _material.get_rid())`,
  which is not saved into the scene.
- Add `get_water_material() -> ShaderMaterial`. `OceanReflectionRenderer` uses
  it instead of reading `water.material_override`.

### Phase 1 implementation notes (2026-09-29)

Done as planned, with these differences:

- **Query code has its own class.** It lives in `OceanSurfaceQueries`
  (`ocean_surface_queries.gd`), which uses the main `RenderingDevice` directly
  and owns its buffers. `RenderingContext.free_rid` was therefore not needed.
  Uniform sets that referenced a rebuilt generator's textures are freed by the
  device along with those textures; the cache is just cleared.
- **Readback callbacks are deferred** to the main thread (`call_deferred`). A
  lambda keeps the query object alive until the callback runs.
- **Shared include is `ocean_sampling.glslinc`.** The extension keeps Godot from
  importing it as a standalone shader. `#include` support in `RDShaderFile` is
  assumed from the engine source and is still unverified at runtime.
- **The compute bilinear sampler now uses the hardware texel-centre convention**
  (`uv·N − 0.5`). Before, it was offset by half a texel from what the vertex
  shader renders. Wrapping uses a power-of-two mask, because GLSL `%` is
  undefined for negative values.
- **`mat_water.tres` was reset** to shader + `render_priority`. It had
  accumulated runtime arrays and textures from editor sessions.
  `ocean_system.tscn` no longer sets `material_override`.
- **Lifecycle:**
  - `OceanSystem` joins group `ocean_system` in `_enter_tree`, so bodies earlier
    in tree order find it in their `_ready`.
  - Exports set during scene load no longer rebuild the mesh or generator
    repeatedly; `_ready` builds once.
  - The reflection renderer is configured through `apply()`.
- **Guard cleanup in touched files:**
  - `BuoyantBody` resolves its body and ocean once (asserted) and its volumes
    once (error when none).
  - `OceanSystem` resolves wind and sky once. A missing wind source with
    `use_external_wind` is an error. A missing `RenderingDevice` is an error and
    disables the node.
  - More than 8 cascades is an error.
- **New scripts have no `.uid` sidecars yet.** Opening the project in the editor
  generates them; commit them with the next change.

---

## Phase 2 — Hull profiles and near-camera cutout

### 2.1 `HullProfile` resource (`ocean_system`)

A baked description of the hull's inside, in the local space of the node that
owns it. Ships are treated as mirror-symmetric about `center_x`.

| Field | Meaning |
| --- | --- |
| `image: Image` | `FORMAT_RGH`, `Z_SAMPLES × PROFILE_SAMPLES` (64 × 32, the same for every profile). **R** = half-width at (z, y): the hull's inner half-width at length station z and height y, 0 above the deck or below the keel. **G** = keel height at (z, \|x\|): the lowest local y inside the hull at station z and lateral offset \|x\| (x in `[0, max_half_width]`), or +∞ (large value) outside the hull. |
| `min_z`, `max_z`, `min_y`, `max_y` | Area the R channel covers |
| `max_half_width` | Scale of G's x axis |
| `center_x` | Mirror plane |

G is derived from R at bake time, not sliced separately: for each (z, x),
take the smallest y where `R(z, y) ≥ x`.

### 2.2 `HullWaterFootprint` node (`ocean_system`)

A `Node3D` placed rigidly on the hull and added to group `ocean_hull`. It is
the only way a ship talks to the water shader and the simulation.

- Exports: `profile: HullProfile`, `cutout_enabled`, `cutout_feather` (m),
  `cutout_edge_foam`, `wake_enabled`, `wake_strength` (pressure scale, 1 = draft
  in metres), `wake_edge_softness` (cells).
- **Bake (editor only):**
  - exports `bake_source_paths: Array[NodePath]` (hull meshes only, no masts or
    rigging), `bake_inset` (m), and the action toggle `editor_bake_profile`;
  - baking slices the source triangles at `PROFILE_SAMPLES` heights (reusing the
    triangle–plane intersection now in
    `BuoyancyProbeVolume._build_waterline_segments`, moved into a shared
    `HullSlicer` script in `ocean_system`), then records the maximum
    |x − center_x| at each station, minus the inset;
  - it saves `<scene_name>_hull_profile.tres` next to the scene with
    `ResourceSaver` and assigns it;
  - a missing source path or an empty slice set is a `push_error`.
- The bounding sphere is derived from the profile bounds and cached.

### 2.3 Cutout selection on the CPU (`OceanSystem`)

Each `_process`:

1. Collect every `HullWaterFootprint` in group `ocean_hull` that has
   `cutout_enabled` and is visible in the tree.
2. Keep those whose bounding sphere lies within `hull_cutout_distance` of the
   camera (new export, default 150 m, measured to the sphere surface). Sort by
   distance and keep at most `MAX_NEAR_HULLS = 8`.
3. Upload (only when changed):

| Uniform | Type | Content |
| --- | --- | --- |
| `near_hull_count` | int | |
| `near_hull_world_to_local[8]` | mat4 | `footprint.global_transform.affine_inverse()` |
| `near_hull_sphere[8]` | vec4 | centre xyz, radius² |
| `near_hull_rect[8]` | vec4 | `min_z`, `min_y`, `1/(max_z-min_z)`, `1/(max_y-min_y)` |
| `near_hull_params[8]` | vec4 | profile layer, `center_x`, feather, edge foam |
| `hull_profiles` | sampler2DArray | every registered profile, one layer each |

`hull_profiles` is rebuilt with `Texture2DArray.create_from_images` only when
the *set* of profile resources changes. Every profile shares the same
dimensions (checked with `assert`).

Ships further away than `hull_cutout_distance` get no cutout. At that distance
the water inside a hull is hidden by the deck and too small to see.

### 2.4 Fragment test (`water.gdshader`)

Replaces the trapezoid loop:

```glsl
float hull_edge_foam = 0.0;
for (int i = 0; i < near_hull_count; ++i) {
    vec3 d = water_world_position - near_hull_sphere[i].xyz;
    if (dot(d, d) > near_hull_sphere[i].w) continue;               // far from this ship
    vec3 p = (near_hull_world_to_local[i] * vec4(water_world_position, 1.0)).xyz;
    vec2 uv = (p.zy - near_hull_rect[i].xy) * near_hull_rect[i].zw;
    if (any(lessThan(uv, vec2(0.0))) || any(greaterThan(uv, vec2(1.0)))) continue;
    vec4 hp = near_hull_params[i];
    float half_w = texture(hull_profiles, vec3(uv, hp.x)).r;
    float sdf = abs(p.x - hp.y) - half_w;                          // < 0 means inside the hull
    if (sdf < 0.0) discard;
    hull_edge_foam = max(hull_edge_foam, (1.0 - smoothstep(0.0, hp.z, sdf)) * hp.w);
}
```

The `continue`s are the near-ship culling from the shader side, not error
guards. The test runs on the water-surface point itself, so it gives the same
answer from any camera angle and handles pitch and roll through the full
transform. Water above the deck (profile width 0) stays visible, which is
correct for green water.

### 2.5 Removals and scene updates

- Delete `WaterCutoutTrapezoid`, `WaterCutoutHullLOD`, group
  `water_cutout_provider`, and every `hull_cutout_*` uniform and array.
- Add a `HullWaterFootprint` to `floating_boat.tscn`. Bake the caravel profile
  in `demo/floating_box.tscn` and the buoy profile in `demo/buoy.tscn` (buoy:
  wake only, no cutout).

### Phase 2 implementation notes (2026-09-29)

Done as planned, with these differences:

- **`center_x` is not an export.** It is derived at bake time from the centre of
  the hull triangles' bounds.
- **Baking lives in `HullProfile.build()`**, a static builder;
  `HullWaterFootprint.bake_profile()` gathers the triangles and saves the
  result.
- **"No hull" in the G channel is `max_y`, not +∞.** Linear filtering then
  gives a smooth zero draft at the hull edge in Phase 3's pressure pass.
- **The hull transform goes up as three row arrays**
  (`near_hull_world_to_local_x/y/z`, `vec4` each) instead of `mat4[]`. Packed
  `vec4` arrays are the uniform-array format this shader already uses.
- **The per-pixel profile lookup uses `textureLod`**, because it sits in
  divergent control flow.
- **Footprints without a profile** are skipped by the ocean. The footprint
  itself reports the problem: a configuration warning in the editor and an
  error at runtime.
- **Wake exports and the buoy's footprint are deferred to Phase 3**, where they
  are first used.
- **The caravel profile must be baked in the editor.**
  `demo/floating_box.tscn` already has `bake_source_paths` set to the hull.
  Open that scene, save it, toggle *Editor Bake Profile* on `HullWaterFootprint`,
  then save again. This writes `demo/floating_box_hull_profile.tres`.

---

## Phase 3 — iWave interaction simulation

Reference: J. Tessendorf, *Interactive Water Surfaces*, Game Programming Gems 4
(2004). iWave uses a convolution kernel that approximates the deep-water
dispersion relation, so Kelvin wakes (~19.5° half-angle), bow waves and
dispersive rings come out of the simulation instead of being scripted.

### 3.1 Structure

- `addons/ocean_system/interaction/water_interaction_sim.gd`
  (`WaterInteractionSim`, created and owned by `OceanSystem` and sharing
  `WaveGenerator.context`, so its textures live on the main `RenderingDevice`
  and can be sampled by the water material through `Texture2DRD`).
- Compute shaders in `addons/ocean_system/shaders/compute/interaction/`:

| Shader | Role |
| --- | --- |
| `iwave_kernel.glsl` | One-time: builds the 13×13 kernel into a storage buffer |
| `iwave_scroll.glsl` | Clears cells that entered the grid after the camera moved |
| `iwave_pressure.glsl` | Writes the hull pressure field for this step |
| `iwave_impulse.glsl` | Adds queued point impulses (splashes) |
| `iwave_step.glsl` | Propagation, damping, sponge, foam; writes the render texture |

- `OceanSystem` exports (group "Interaction"): `interaction_enabled`,
  `interaction_grid_size` (256/512/1024, default 512), `interaction_cell_size`
  (default 0.5 m → 256 m window), `interaction_damping` (α, 1/s),
  `interaction_gravity_scale` (calibration, see 3.9), `interaction_step_rate`
  (default 60 Hz), `interaction_max_steps_per_frame` (default 4),
  `interaction_sponge_cells` (default 24), foam grow/decay/threshold.

### 3.2 Textures and grid mapping

| Texture | Format | Content |
| --- | --- | --- |
| `state[2]` (ping-pong) | `R32G32_SFLOAT` storage | `h(t)`, `h(t−Δt)` |
| `pressure` | `R32_SFLOAT` storage | pressure head `p` (m) this step |
| `render` | `R16G16B16A16_SFLOAT` storage + sampling | `h`, `p`, foam, unused |
| `foam_state[2]` | `R16_SFLOAT` storage (ping-pong) | foam accumulation |

**Toroidal (wrap-around) mapping.** World cell `c = floor(xz / cell_size)`
lives at texel `c mod N`. The window is centred on the camera and snapped to
whole cells. Cells never get copied when the camera moves. `iwave_scroll`
clears texels whose world cell under the new origin was outside the old window.
The water material samples `render` with `repeat_enable, filter_linear` at
`uv = world_xz / (N·cell_size)`, so hardware wrapping matches the mapping.

**Sponge and fade.** Inside `interaction_sponge_cells` of the window edge,
damping ramps up to a strong value so outgoing waves are absorbed instead of
wrapping to the other side. Rendering and queries multiply by the same edge
fade, a shared function
`interaction_fade(world_xz, window_center, half_extent)`.

### 3.3 Kernel

`G(r) = Σₙ qₙ² · e^(−σ qₙ²) · J₀(qₙ r) · Δq / G₀`, with `qₙ = nΔq`,
`Δq = 0.001`, `n = 1…10000`, `σ = 1`, `P = 6` (13×13 taps),
`G₀ = Σₙ qₙ² e^(−σ qₙ²) Δq`. Computed once by `iwave_kernel.glsl` (one thread
per tap, J₀ from the standard polynomial approximation).

After that, subtract the mean so `Σ G = 0`. Otherwise the kernel's DC response
makes the whole grid drift up or down.

### 3.4 Step

With `Δt = 1 / interaction_step_rate`, `g' = 9.81 · interaction_gravity_scale / cell_size`
(the kernel works in cell units), and `α` the damping including the sponge:

```
h_next = [ h·(2 − αΔt) − h_prev − g'·Δt²·(G ∗ (h + p)) ] / (1 + αΔt)
```

- `iwave_step.glsl` uses a 16×16 workgroup and loads a 28×28 tile (6-cell
  halo) of `h + p` into shared memory, then convolves from shared memory.
- Stability: the scheme needs `ω_max·Δt < 2` with `ω_max² ≈ g'·π`. For 0.5 m
  cells at 60 Hz, `ω_max·Δt ≈ 0.13`, far inside the limit.
- Frame loop: accumulate delta, run whole steps (at most
  `interaction_max_steps_per_frame`), and drop the remaining time when capped.
  That is a deliberate time-dilation policy and is counted in stats.
- Each step writes `render = (h_next, p, foam, 0)`.

### 3.5 Ship forcing through a pressure field

Each hull acts as a surface-pressure disturbance: linear ship-wave theory treats
a ship as a moving pressure distribution, which produces the Kelvin pattern.
The pressure head is the hull's draft *below the incident-wave surface*:

- `iwave_pressure.glsl` runs one thread per cell. It loops over the sim hulls
  (every `HullWaterFootprint` with `wake_enabled` whose sphere overlaps the
  window; storage buffer, `MAX_SIM_HULLS = 32`), skipping with a sphere test.
- For a hull covering the cell:
  1. find the incident surface height `y_s` at the cell centre from the FFT
     field, using `sample_displacement_inverted` from `ocean_sampling.glsl`;
  2. transform the surface point `(x, y_s, z)` into hull space;
  3. read `keel = G(profile, z, |x − center_x|)`;
  4. `draft = max(y_s_local − keel, 0)`;
  5. `p += wake_strength · draft · edge_taper`, where `edge_taper` smooths the
     last `wake_edge_softness` cells inside the waterline using the R channel's
     distance to the edge. Without it, the sharp hull edge causes ringing.
- In equilibrium, `G ∗ (h + p) = 0` gives `h ≈ −p` under a stationary hull
  (water pushed down to the hull bottom, no waves). A moving, heaving or
  rolling hull radiates waves. No obstruction mask is needed.

### 3.6 Point impulses

`OceanSystem.add_water_impulse(position: Vector3, radius: float, amplitude: float)`
queues a Gaussian added to `h` (not `h_prev`), which acts as an instant velocity
kick. Up to 64 per step go into a storage buffer; `iwave_impulse.glsl` applies
them before the step. More than 64 in one step is an `assert` in debug builds.
Nothing calls it yet; it is the hook for splashes (e.g. projectile impacts)
later.

### 3.7 Rendering (`water.gdshader`)

- Vertex: after the FFT displacement, sample `render.r` at the **displaced**
  `VERTEX.xz`, multiply by the fade, and add it to `VERTEX.y`. The simulation is
  world-space at final surface positions, which matches the query in 3.8.
- Fragment: take the slope `∂h/∂x, ∂h/∂z` from 4 central-difference taps of
  `render.r`, with the fade applied. Add it to the `gradient` sum
  (`water.gdshader:351`) in the same convention as the FFT normal maps. Add
  `render.b` (simulation foam) to `foam_signal`.
- The near-hull cutout (Phase 2) hides the pushed-down water under hulls.

### 3.8 Queries

`surface_query.glsl` also binds `render` and adds `(h + p) · fade` at `p`
(after inverting the FFT displacement). Using `h + p` instead of `h` removes a
ship's own static depression, so it does not lose its buoyancy through
feedback. Radiated waves, including other ships' wakes and its own bow wave,
still affect it. The push constant grows (window centre, `1/(N·cell_size)`,
fade parameters); follow the exact-byte-size packing rule.

### 3.9 Foam

In `iwave_step.glsl`:

```
foam_next = foam·exp(−decay·Δt) + grow·Δt·( max(|∇h| − steep_threshold, 0) + k_p·max(∂p/∂t, 0) )
```

The foam is fixed in world space, so a ship leaves a fading wake trail and the
bow, where the pressure rises as the hull pushes into new water, foams by itself.

### 3.10 Gravity scale default

The iWave kernel normalisation means `g'` is not guaranteed to give physical
wave speeds. Until the calibration in
[Deferred verification](#deferred-verification) is run,
`interaction_gravity_scale` defaults to 1.0 and is tuned by eye.

### Phase 3 implementation notes (2026-09-30)

Implemented; not yet run in Godot. Differences from the plan above:

- **No 13×13 kernel; the operator is applied exactly through an FFT.** The
  kernel's frequency response, evaluated for 3.3's parameters, does not follow
  `√(g|k|)` at wake wavelengths (a few metres to tens of metres at 0.5 m cells),
  and after subtracting the mean for 3.3's DC fix it turns negative at high
  `|k|`, which makes the step unstable. Each step instead does
  FFT → multiply by `g·|k|/N²` → inverse FFT (`iwave_fft.glsl`, a shared-memory
  radix-2 pass over rows or columns, and `iwave_operator.glsl`). That is the
  exact deep-water dispersion, so `interaction_gravity_scale` = 1 should give
  physical wave speeds; the calibration in Deferred verification still
  applies. It costs four FFT passes plus the operator per step. There is no
  `iwave_kernel.glsl`.
- **The simulated quantity is `η = h + p`, not `h`.** The equation
  `h'' + αh' = −L(h + p)` becomes, for `η`, an equation whose forcing is only
  the change of `p` over time:
  `η' = [η(2+αΔt) − η₋ − Δt²Lη + p₊(1+αΔt) − p(2+αΔt) + p₋] / (1+αΔt)`.
  A hull at rest therefore makes no waves and needs no settling time. The state
  texture is `rgba32f (η, η₋, p, p₋)`.
- **Pressure history sentinel.** Cells with no history (startup, or scrolled
  into the window) store `p = −1e30` (`IWAVE_NO_PRESSURE` in
  `iwave_common.glslinc`); the step treats that as "unchanged", so a ship
  entering the window, or present at startup, causes no burst.
- **Damping acts on velocity** (`αh'`, the `(1+αΔt)` form), matching the
  equation above; 3.4's `h·(2 − αΔt)` form was not used.
- **Render texture is `(h, η, foam)`** with `h = η − p`. There are no
  `foam_state` textures: foam lives in the render texture's B channel and is
  read back by the next step. The water shader adds `h` and foam; queries add
  `η` (the "`h + p`" of 3.8). Foam uses the slope of `η`, so the static edge of
  a hull's depression does not foam.
- **File layout.** Shaders sit flat in `shaders/compute/` with an `iwave_`
  prefix (`iwave_common.glslinc`, `iwave_scroll`, `iwave_impulse`,
  `iwave_pressure`, `iwave_fft`, `iwave_operator`, `iwave_step`); the script is
  `addons/ocean_system/water_interaction_sim.gd`.
- **The simulation owns its own `RenderingContext`** on the main
  `RenderingDevice` instead of sharing `WaveGenerator.context`, so a wave
  generator rebuild does not free it. Pressure-pass uniform sets reference the
  generator's displacement textures and are dropped via
  `clear_uniform_set_cache()` when the generator is rebuilt.
- **Only runs at runtime**, not in the editor preview.
- **Hull records.** `OceanSystem` packs up to 32 wake-enabled footprints whose
  bounding sphere reaches the window (`half_extent·√2`) as 28-float records:
  world-to-local rows, profile layer, bounds, strength and edge softness.
- **Surface-query push constant** is 48 bytes (12 values: the old fields plus
  window centre, fade start/end and cell size).
- **`demo/buoy.tscn`** has a wake-only `HullWaterFootprint`
  (`cutout_enabled = false`). Its profile must be baked in the editor like the
  caravel's (writes `demo/buoy_hull_profile.tres`).
- `RenderingContext.create_texture` now takes `data : Array` (one
  `PackedByteArray` per layer); the typed-array parameter rejected literals.

---

## Phase 4 — Retire manual foam

- Delete `BoatWaterInteractor`, `BoatWakeTrail`, group
  `manual_water_foam_source`, `MAX_MANUAL_FOAM_SOURCES`, the `manual_foam_*`
  uniforms, and `sample_manual_foam` together with its per-pixel loop over up to
  96 sources (`water.gdshader:149`).
- `FloatingDebugBody.player_controlled` only toggles `boat_controller`.
- Bow foam and wakes now come from 3.9.

### Phase 4 implementation notes (2026-09-30)

Done as planned. Also removed: the `BoatWaterInteractor` / `BoatWakeTrail`
nodes from `floating_boat.tscn` and their overrides in `demo/floating_box.tscn`
(later root-child `index` values there shifted down), and the now-redundant
foam merge inside the shader's cascade loop. Every boat with a baked,
wake-enabled footprint now makes foam, not only the player's.

---

## Phase 5 — Buoyancy CPU cleanup

- `BuoyantBody` resolves its body, ocean and volumes in `_ready` and asserts
  them. The per-tick re-resolution is removed.
- Probe data is cached as packed arrays when volumes are collected (probe
  nodes, max volumes, heights, drag multipliers). Each tick only fills a
  reusable `PackedVector3Array` of world positions. No per-tick
  `Array[Dictionary]`.
- Probe states become a reused `BuoyancyProbeState` RefCounted per probe,
  updated in place, instead of a new `Dictionary` per probe per tick. Signals
  pass the state object. Consumers (`BuoyantSinkingMonitor`) are updated.
- `_queue_debug_rebuild` is only called when `debug_enabled`.
- `OceanSystem._update_sky_lighting_shader_parameters` reads the sky once per
  frame into a cached struct. It no longer calls 7 duck-typed getters, each of
  which recomputes the astronomy.

### Phase 5 implementation notes (2026-09-30)

- **Ownership of states.** `BuoyancyProbeVolume` creates the
  `BuoyancyProbeState`s (it knows the thresholds) and keeps them per probe;
  `BuoyantBody` caches them together with body-space probe positions and packed
  per-probe data, and updates them in place. The volume no longer has
  `update_probe_state`, sample-point dictionaries, contact signals or
  `get_total_max_submerged_volume`; it emits `probes_changed` instead, and the
  body rebuilds its cache on it. Signals are `probe_entered_water(state)` /
  `probe_exited_water(state)` on `BuoyantBody`.
- **Stale results.** A cache rebuild records `ocean.time` and re-submits the
  new points (or releases the query when no probe is left); results dispatched
  at or before that time are ignored, and a size mismatch after that is an
  assert.
- **No more silent threshold fixes.** Contact probes use their own thresholds
  and physical probes their volume's; `enter <= exit` is an assert
  (`BuoyancyFxProbeNode.get_*_depth_threshold()` fallbacks removed).
- **`BuoyantSinkingMonitor`** also resolves its nodes and sinking probes once in
  `_ready` with asserts; the per-tick re-resolution and null checks are gone.
- **Sky.** Instead of a cached struct in `OceanSystem`, `SkySystem` caches its
  lighting state when an input changes (getters return the cache) and updates
  once per frame when the day cycle advances three properties at once. The
  ocean re-reads the sky only on `lighting_changed`; a sky source without that
  signal is still read every frame.
- The gravity setting is read once in `_ready`; forward/right axes once per
  tick instead of per probe.

---

## API and file changes summary

| Removed | Replaced by |
| --- | --- |
| `sample_water_surface_batch`, `sample_water_surface` | `submit_surface_query` / `get_surface_query_result` / `release_surface_query` |
| `WaterCutoutTrapezoid`, `WaterCutoutHullLOD`, group `water_cutout_provider`, `hull_cutout_*` | `HullProfile`, `HullWaterFootprint`, group `ocean_hull`, `near_hull_*` |
| Manual foam system, `BoatWaterInteractor`, `BoatWakeTrail` | Simulation foam |
| `OceanSystem._update_external_wind_state`, `EXTERNAL_WIND_*` | Per-cascade spectrum snapshots and blends |
| `material_override` on the ocean scene | `water_material` export + RenderingServer override |
| `spectrum_blend_states.z` = alpha | `.zw` = equal-power weights |

New files: `docs/water-interaction-plan.md` (this plan),
`addons/ocean_system/{hull_profile.gd, hull_water_footprint.gd, hull_slicer.gd, water_surface_query_result.gd}`,
`addons/ocean_system/water_interaction_sim.gd`,
`addons/ocean_system/shaders/compute/ocean_sampling.glslinc`,
`addons/ocean_system/shaders/compute/iwave_*.glsl` and `iwave_common.glslinc`.

## Open questions / risks

- **`#include` in `RDShaderFile`** — verify at the start of 1.2 (see there).
- **`texture_get_rd_texture` on a `Texture2DArray`** — the pressure pass needs
  the hull-profile array on the RenderingDevice. If that fails, `OceanSystem`
  builds the array directly as an RD texture and wraps it in a
  `Texture2DArrayRD` for the material.
- **Two to three frames of query latency** — extrapolation covers height for
  buoyancy. A future fast-moving consumer (e.g. projectiles on the real surface)
  may need extrapolating XZ as well.
- **Ship self-interaction** — the bow wave feeding back into the ship's own
  buoyancy is physical, but it may need a per-footprint `self_wave_scale`
  if ships pitch unnaturally. Decide after 3.8.
- **Simulation window size vs. wake length** — 256 m covers the player's wake in
  third person; distant AI ships outside the window have no waves (their
  pressure is skipped). Revisit with cascaded simulation windows only if that
  becomes visible.

## Deferred verification

Not part of this stage; run these once the phases are in place.

- **1.1 readback:** frame time with and without buoyant bodies, before and after
  the async change.
- **2 cutout:** first-person on deck and third-person close-ups in rough seas —
  no water inside the hull, no holes outside it, correct under heavy roll
  (~40°). Fragment cost with 0, 2 and 8 near ships.
- **3 iWave:**
  - *Dispersion calibration:* move one pressure disc in a straight line at
    U = 3, 5, 8 m/s, sample `h` along the centreline behind it, and tune
    `interaction_gravity_scale` until crest spacing matches `λ = 2πU²/g`
    within 10% at every speed.
  - *Wedge:* wake half-angle about 19.5° at every speed.
  - *Stability:* no growth over 10 minutes with 4 ships turning.
  - *Scrolling:* fast free-camera flight shows no seams or stuck waves at the
    window edge.
  - *Cost:* simulation GPU time at 512² with 1 and 8 ships (goal ≤ 0.5 ms).
