# Boat Template

`boat.tscn` is a ready-wired boat: driving, stability, buoyancy and sinking,
hitbox health, hull cutout and wake, bow spray, and camera anchors. Make a boat
by creating an **inherited scene** from it and adding your model, collision,
probes and hitboxes. The demo's boats (`demo/rowboat.tscn`, and
`demo/floating_box.tscn`, a caravel with an animated sail) are built this way,
through the development template `floating_boat_template`, which adds weapons.

Depends on `core`, `buoyancy_system`, `hitbox_damage_system` and
`ocean_system`. The spray hazes itself with `sky_system`'s atmosphere (it
includes its `atmosphere.gdshaderinc`), so the Sky System plugin must be
enabled too.

Enable **Boat Template** in Project Settings > Plugins: it adds the default
drive actions `boat_forward`, `boat_back`, `boat_turn_left` and
`boat_turn_right` (W, S, A, D) unless the project has them.

## Visual effects

- **Bow spray:** sheets of velocity-aligned droplet streaks at the stem while it
  cuts the water.
- **Bow slams:** jets of spray, and a splash ring in the water, when the bow
  re-enters the sea fast. Their height follows the impact speed.
- **Hull wake and cutout:** wakes, bow waves and no water inside the hull,
  through the ocean (`HullWaterFootprint`).
- **Hazed spray:** the spray is hazed by the sky system's atmosphere.

## Template tree

```
Boat (RigidBody3D, FloatingBoat)   drive input, stability, model animation, debug trail
├─ CollisionShape3D           placeholder 2×1×5 box — replace
├─ BuoyantBody                buoyancy + sinking  ← Hitboxes.group_destroyed
├─ BuoyancyProbeVolume
│  └─ GeneratedProbes         empty — generate probes per boat
├─ Hitboxes                   HitboxHealthManager: put ProjectileHitbox areas here
├─ HullWaterFootprint         hull cutout, wake and bow wave — bake a profile per boat
├─ CameraTargets
│  ├─ ThirdPersonFocus
│  └─ FirstPersonSeat
└─ BowSpray                   stem spray and bow-slam splashes — move to the stem
```

The root has mass 1000 kg with a custom centre of mass; `BuoyantBody` has
`sinking_enabled` on, and `Hitboxes` starts with a single `hull` group (100 HP).
Debug geometry (position trail, probe debug draw, health panel) is
created at runtime as internal nodes and never saved into the scene.

## Making a new boat

1. New Inherited Scene from `boat.tscn`; add the model as a child.
   The bow must point along −Z.
2. Replace `CollisionShape3D`'s shape; set `mass` and `center_of_mass`.
3. On `BuoyancyProbeVolume` set `source_paths` to the hull mesh,
   `design_waterline_y`, the probe counts, volume and column height, toggle
   **Editor Generate All Probes**, and save. Size the probes so that the
   columns reach up towards the gunwale and hold well over the boat's weight
   when fully submerged (the rowboat holds 2.4×, settling at 41 % of its
   columns). A column that tops out at the waterline has no reserve buoyancy,
   and a light boat then plunges through waves.
4. Add `ProjectileHitbox` `Area3D`s under `Hitboxes` with `hitbox_group` names;
   list those groups in `Hitboxes.group_max_health` and, if losing them should
   sink the boat, in `BuoyantBody.sink_on_destroyed_groups` (default `hull`).
5. Move `CameraTargets/*` markers to the deck, and `BowSpray` to the stem at
   the waterline (just below it, so it is wet when the boat sits still). Set
   its `emission_half_width` to about half the bow's width a little aft of
   the stem, and `particle_size` up for large ships (the caravel uses 1.2 m
   and 0.3 m).
6. On `HullWaterFootprint`, set `bake_source_paths` to the hull mesh (hull
   only) and press **Bake Profile**, then save. This hides water inside
   the hull near the camera and makes the hull push water in the interaction
   simulation (Kelvin wake, bow wave, rings when heaving). Tune the wake with
   `wake_strength` and `wake_edge_softness`, or turn it off with
   `wake_enabled`; see the ocean README. Raise `cutout_height_offset` if waves
   cresting over a low gunwale show water inside the boat.
7. Optional: set `animation_player_path` and `autoplay_animation` on the root to
   loop an animation from the imported model (the caravel's sail).
8. Set `player_controlled` on the instance that the player drives.

## Player vs. AI boats

`player_controlled` gates the root's drive input (other nodes can read it too:
the development template's weapons aim and fire only on the player's boat).
Non-player boats therefore float, take damage and sink, but don't read input.
Every boat with a baked `HullWaterFootprint` makes wakes and
bow foam, player or not. `demo/main.gd` enforces a single player boat among its
direct children.

## `BowSpray`

Spray at the stem. Every physics tick it queries the water at its own position
(the world's `WaterSurface` query) and tracks its velocity from its transform:

- **Spray** — while the stem is in the water, a sheet of droplets is thrown to
  both sides, at up to `spray_rate` particles per second as the stem's speed
  into the water goes from `spray_speed_min` to `spray_speed_full`.
- **Slam** — when the stem re-enters the water after at least
  `slam_rearm_time` in the air, at an impact speed along the surface normal of
  at least `slam_speed_threshold` (2 m/s), it throws a burst: jets at
  `slam_jet_ratio` (2.5) × the impact speed (capped at `slam_max_jet_speed`),
  up and out to both sides of the bow, `slam_particles_per_speed` particles
  per m/s, and a splash ring in the interaction simulation
  (`WaterSurface.add_impulse`): the water at the stem is raised by the
  stagnation head `slam_ring_strength × v² / 2g` (capped at
  `slam_ring_max_rise`; 0.4 m for a 4 m/s slam at the default 0.5) over
  `slam_ring_radius`, and spreads as a ring. Jets rise up to `jet² / 2g`: a 4 m/s nose-dive
  throws spray ~5 m up, a 6 m/s one ~10 m, well above the caravel's 3 m deck.
  Emits `slammed(impact_speed, position)`.

Droplets are velocity-aligned streaks, emitted in world space with the hull's
horizontal velocity, fading and growing over `particle_lifetime`. They are
transparent, so they haze themselves through the sky system's atmosphere
(`bow_spray.gdshader` includes its `atmosphere.gdshaderinc`; this template is
the one place allowed to use both).

## `FloatingBoat`

- **Drive** — throttle force along the flattened forward axis until
  `max_forward_speed` / `max_reverse_speed`, yaw torque scaled down at low
  speed (`low_speed_turn_factor`), and extra side-slip damping. All forces scale
  with mass. Reads the `boat_forward`, `boat_back`, `boat_turn_left` and
  `boat_turn_right` actions by default (`*_action` exports), which enabling
  the plugin adds. A missing action is reported once and the boat ignores
  drive input.
- **Stability** — per-axis local angular damping (`local_angular_damping`, X =
  pitch, Y = yaw, Z = roll) and a roll-righting spring with dead zone and
  torque cap. Zero values disable them.
- **Model Animation** — loops `autoplay_animation` of `animation_player_path`
  from `_ready`; a wrong path or name fails an assert.
- **Debug** — `debug_enabled` draws a world-space position trail while the boat
  is player-controlled.
