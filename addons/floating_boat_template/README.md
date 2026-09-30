# Floating Boat Template

`floating_boat.tscn` is a ready-wired boat: buoyancy, sinking, hitbox health,
player controls, hull cutout and wake, cannons input/aim/recoil and camera
anchors. Make a boat by creating an **inherited scene** from it and adding your
model, collision, probes, hitboxes and launchers. `demo/floating_box.tscn` (the
caravel) is the reference example.

Depends on `buoyancy_system`, `hitbox_damage_system`,
`projectile_launcher_system` and, through buoyancy, `ocean_system`.

## Template tree

```
FloatingBoat (RigidBody3D, FloatingBoat → FloatingDebugBody)
├─ CollisionShape3D              placeholder 2×1×5 box — replace
├─ BuoyantBody
├─ BuoyantSinkingMonitor         ← HitboxHealthManager.group_destroyed
├─ HitboxHealthManager           hit smoke effect preset
├─ HitboxHealthDebugUI           off by default
├─ ProjectileHitboxes            put ProjectileHitbox areas here
├─ SimpleBoatController          W/S/A/D forces
├─ CameraTargets
│  ├─ ThirdPersonFocus
│  └─ FirstPersonSeat
├─ BuoyancyProbeVolume
│  └─ GeneratedProbes            4 placeholder probes — regenerate
├─ PhysicsRecoil
├─ ProjectileFireInputController
├─ ProjectileAimController
└─ HullWaterFootprint            hull cutout + wake — bake a profile per boat
```

The template's root has mass 1000 kg with a custom centre of mass, local
angular damping and roll-righting enabled (values set to zero — tune them per
boat).

## Making a new boat

1. New Inherited Scene from `floating_boat.tscn`; add the model as a child.
2. Replace `CollisionShape3D`'s shape; set `mass` and `center_of_mass`.
3. On `BuoyancyProbeVolume` set `source_paths` to the hull mesh and
   `design_waterline_y`, run the editor generate action, and save.
4. Add `ProjectileHitbox` `Area3D`s under `ProjectileHitboxes` with
   `hitbox_group` names; list those groups in `HitboxHealthManager.group_max_health`
   and `BuoyantSinkingMonitor.sink_on_destroyed_groups` (default `hull`).
5. Instance `projectile_launcher.tscn` at each gun; add the launcher paths to
   `ProjectileFireInputController.launcher_paths` and
   `ProjectileAimController.launcher_paths` (and yaw targets), plus optional
   `CannonSlideRecoil` nodes as `recoil_receiver_paths` on each launcher.
   Point `PhysicsRecoil` at the body.
6. Move `CameraTargets/*` markers to the deck.
7. On `HullWaterFootprint`, set `bake_source_paths` to the hull mesh (hull
   only) and toggle **Editor Bake Profile**, then save. This hides water inside
   the hull near the camera and makes the hull push water in the interaction
   simulation (Kelvin wake, bow wave, rings when heaving). Tune the wake with
   `wake_strength` and `wake_edge_softness`, or turn it off with
   `wake_enabled`; see the ocean README.
8. Optional: `FloatingBoatAnimationAutoplay` loops an animation from the imported
   model (e.g. sails).
9. Set `player_controlled` on the instance that the player drives.

## Player vs. AI boats

`player_controlled` (from `FloatingDebugBody`) sets `enabled` on
`SimpleBoatController` via its group, and `ProjectileFireInputController`
refuses to fire unless the owning body is player-controlled. Non-player boats
therefore float, take damage and sink, but don't read input. Every boat with a
baked `HullWaterFootprint` makes wakes and bow foam, player or not.
`demo/main.gd` enforces a single player boat among its direct children.

## Components in this addon

- **`SimpleBoatController`** — throttle force along the flattened forward axis
  until `max_forward_speed` / `max_reverse_speed`, yaw torque scaled down at low
  speed (`low_speed_turn_factor`), and extra side-slip damping. All forces scale
  with body mass. Uses the `camera_move_*` actions by default.
- **`FloatingBoatAnimationAutoplay`** — sets an animation to loop and plays it.
- **`FloatingBoat`** — empty subclass of `FloatingDebugBody`, used as the
  template's root type.
