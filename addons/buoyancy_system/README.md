# Buoyancy System

Probe-based buoyancy for `RigidBody3D`s floating on an `OceanSystem`. Probes are
generated from a hull mesh in the editor, saved into the scene, and sampled
every physics tick through the ocean's batched GPU query. Also includes water
contact events and sinking (roll, flooding or a destroyed hitbox group).

Requires `ocean_system`.

## Setup

```
RigidBody3D                (e.g. FloatingBoat)
├─ CollisionShape3D
├─ <hull model>
├─ BuoyantBody             finds the parent body and the ocean; optional sinking
└─ BuoyancyProbeVolume     source_paths → hull model
   └─ GeneratedProbes      BuoyancyProbeNode / BuoyancyFxProbeNode children
```

1. Add `BuoyantBody` under the rigid body. It uses `rigid_body_path` or the
   nearest `RigidBody3D` ancestor, and `ocean_path` or the first node in group
   `ocean_system`. Both are resolved once in `_ready`; a missing body or ocean
   fails an assert, and finding no probe volumes is an error.
2. Add a `BuoyancyProbeVolume`, set `source_paths` to the hull mesh root(s) and
   `design_waterline_y` (local) to where the hull should float.
3. In the editor toggle `editor_generate_physical_probes`,
   `editor_generate_fx_probes` or `editor_generate_all_probes`, then save the
   scene. Generation only runs in the editor; at runtime a volume with no probes
   just warns once.
4. Tune probe volumes, `buoyancy_strength` and drag. Probes are ordinary nodes:
   move, delete or duplicate them by hand as needed.

## Probes

- **`BuoyancyProbeNode`** (physical) — its position is the *top* of a water
  column `buoyancy_height` tall. Submersion = how much of that column is below
  the sampled water height (0–1). Fully submerged it displaces
  `max_submerged_volume_cubic_meters`. Per-probe drag multipliers scale
  `BuoyantBody`'s longitudinal/lateral drag.
- **`BuoyancyFxProbeNode`** (contact) — applies no force. It is queried in the
  same batch and produces wet/dry state and enter/exit events, with a `tag`
  (`bow`, `side`, `stern` when generated) and optional per-probe thresholds.

Both are editor-only spheres (hidden and mesh-less at runtime).

## `BuoyantBody`

It caches the probe set: one `BuoyancyProbeState` per enabled probe (created
and kept by the volume), each probe's position in body space, and the physical
probes' volumes, column heights and drag multipliers in packed arrays. The
cache is rebuilt when volumes are collected and whenever a volume emits
`probes_changed` (a probe or volume was added, removed, enabled, disabled or
edited). Probes must therefore stay rigid relative to the body.

Each `_physics_process` it transforms the cached positions by the body
transform, submits them with `ocean.submit_surface_query(self, points)`, reads
the latest completed result, and for every physical probe applies at the probe
position:

- buoyancy `ρ · g · buoyancy_strength · displaced_volume` upward;
- longitudinal and lateral drag against the probe's horizontal velocity, scaled
  by body mass, the probe's share of total volume, and submersion;
- a per-probe force cap of `mass × volume_share × max_probe_acceleration`.

It also applies central `heave_damping` against vertical velocity, weighted by
overall submersion.

Query results arrive a few frames after dispatch (see the ocean README):

- Every water height used above is
  `sample.extrapolated_height(ocean.time - result.dispatch_time)`.
- Until the first result arrives, the body is held with `freeze = true` (only
  if it wasn't frozen already and `apply_forces` is on). Otherwise it would
  free-fall through the water during startup hitches; the first result
  unfreezes it.
- A result dispatched before the probe set last changed is ignored (it answers
  the old points). Rebuilding the cache re-submits immediately, so every later
  dispatch matches the new set.
- The body releases its query in `_exit_tree`.

API: `get_probe_states(tag_filter)`, `get_wet_probe_states(tag_filter)`,
`get_probe_state(probe)` (null if the node is not an enabled probe of this
body), `refresh_volumes()`; signals `probe_entered_water(state)` and
`probe_exited_water(state)`. Set `apply_forces = false` to stop both forces and
sampling.

`BuoyancyProbeState` is updated in place every tick: `probe`, `tag`,
`is_fx_probe`, `has_sample` (false until the first water sample),
`world_position`, `water_position`, `depth` (water height − probe Y),
`submersion`, `is_wet`, `was_wet`, `entered`, `exited`, `force` (applied this
tick), `normal`, `surface_velocity`, `time`. Wet/dry switching uses hysteresis
and `min_event_interval`: physical probes take `enter_depth_threshold` /
`exit_depth_threshold` from their volume, contact probes their own (the enter
threshold must be above the exit threshold). Keep a state only as long as the
probe set is unchanged; editing a probe replaces its state object.

## `BuoyancyProbeVolume` generation

The generator intersects every triangle of the source meshes with the plane
`design_waterline_y` (using `HullSlicer` from `ocean_system`), builds the 2D convex hull of the waterline (falling back
to the mesh bounds footprint), then:

- places `physical_probe_count` probes at evenly spaced stations along Z
  (skipping `longitudinal_margin_fraction` at each end) — as mirrored pairs at
  the hull's half-width around `symmetry_plane_x` when `mirror_across_yz_plane`
  is on (an odd count adds one centreline probe), otherwise one probe per
  station at the hull's centre;
- places `fx_probe_count` contact probes as left/right pairs on the waterline
  edge at stations along Z, tagged `bow` / `side` / `stern` by position
  (`bow_is_negative_z` picks the bow end).

With `debug_enabled` it draws probes, the waterline intersection and hull,
per-probe forces, gravity, net force and centre of mass. With it off, nothing
is redrawn. The debug mesh is an internal child created at runtime (or when the
volume is opened in the editor) and is never saved into the scene.

## Sinking

`BuoyantBody`'s **Sinking** group is off by default (`sinking_enabled`). When
on, after each tick's forces it starts sinking when roll exceeds
`max_roll_degrees`, or when every probe in `sinking_probe_paths` (resolved once
in `_ready`; each must be an enabled probe of the body) is deeper than
`sink_probe_depth_threshold`. `_on_hitbox_group_destroyed(group, hit_data)`
starts it for a group listed in `sink_on_destroyed_groups`.

Sinking multiplies `buoyancy_strength` by `sink_buoyancy_multiplier`, emits
`sinking_started(reason, data)` (`reason` is `roll`, `draft`,
`hitbox_group_destroyed` or whatever `start_sinking()` was given), and frees
`delete_root_path` (default: the rigid body) after `delete_delay`.
`start_sinking()` works whether or not sinking is enabled; `is_sinking()` reports
it.

This addon does not know about hitboxes. Connect a damage system's signal to
`_on_hitbox_group_destroyed` in the scene (the boat template does this with
`HitboxHealthManager.group_destroyed`).
