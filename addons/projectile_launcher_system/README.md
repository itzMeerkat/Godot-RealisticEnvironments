# Projectile Launcher System

Launch physical projectiles from a muzzle, inherit the platform's velocity,
aim with a ballistic solver, apply recoil, and show muzzle-flash / water-splash
effects. No dependency on other addons.

## Pieces

| Class | Role |
| --- | --- |
| `ProjectileLauncher` (`projectile_launcher.tscn`) | Spawns projectiles and muzzle flashes, notifies recoil receivers, emits `fired`. |
| `Projectile` (`default_projectile.tscn`) | `RigidBody3D` with quadratic drag, lifetime, and water-plane cleanup. |
| `ProjectileAimController` | Center-screen aim point, per-launcher ballistic pitch solve, yaw turning, aim marker. |
| `ProjectileFireInputController` | Input bridge: fires a set of launchers on an action with cooldown. |
| `PhysicsRecoil` | Applies an opposite impulse to a `RigidBody3D`. |
| `CannonSlideRecoil` | Visual spring-damper slide of a barrel/carriage. |
| `ProjectileMuzzleFlash`, `ProjectileWaterImpactEffect` | One-shot particle effects built in code. |

## `ProjectileLauncher`

`fire(direction := Vector3.ZERO) -> Node`:

1. Uses `direction`, or the muzzle's −Z if zero. `muzzle_path` is optional
   (default: the launcher itself).
2. Applies optional random cone `spread_degrees`.
3. Instantiates `projectile_scene` (default `default_projectile.tscn`) under
   `projectile_parent_path` or the current scene, tags it and all children with
   group `projectile` and source metadata (`source_launcher_instance_id`,
   `source_rigid_body_instance_id`, `source_rigid_body_path`), and sets its
   collision layer 2 / mask 4 unless `configure_projectile_collision` is off.
4. Calls `launch(direction, speed, mass, drag, lifetime)` if the projectile has
   it, otherwise sets mass/velocity directly; then adds the inherited velocity
   (the parent rigid body's velocity at the muzzle, or the launcher's own
   estimated velocity if there is no rigid body).
5. Spawns the muzzle flash, calls `apply_recoil(fire_direction, shot_data)` on
   each `recoil_receiver_paths` node, and emits `fired(projectile, direction,
   shot_data)`.

`shot_data` carries the launcher, projectile, `recoil_strength`, mass, speed,
drag, collision settings, inherited velocity and muzzle transform.

`debug_enabled` draws the current fire direction as an arrow.

## `Projectile`

Applies `-v̂ · |v|² · drag_coefficient` each physics tick, frees itself after
`lifetime`, and when `destroy_below_water` is on, frees itself once its Y drops
below `waterline_y`, spawning `water_impact_effect_scene` there. The water
check is a flat plane, not the wave surface.

## `ProjectileAimController`

Every frame, when enabled:

1. Casts a ray from the center of the camera (`camera_path` or the active
   viewport camera) to the horizontal plane `aim_plane_y`.
2. For each launcher in `launcher_paths`, if `solve_ballistics` is on, searches
   pitch between `min_pitch_degrees` and `max_pitch_degrees`
   (`pitch_search_steps` coarse samples, `pitch_refine_steps` bisection),
   simulating the shot with the launcher's speed, drag, mass, inherited velocity
   and project gravity. It picks the lowest (or, with `prefer_high_arc`, the
   highest) pitch interval where the height error at the aim distance changes
   sign and bisects it; with no sign change it accepts the closest sample only
   if it is within `impact_height_tolerance`. Unreachable launchers keep their
   last valid direction.
3. Yaws each `yaw_target_paths` entry (or the launcher) toward the aim point
   around the yaw reference's up axis, with `yaw_smoothing`.
4. Draws a ring marker coloured by reachability.

`get_launch_direction_for_launcher(launcher)` is what the fire input controller
asks for.

## `ProjectileFireInputController`

On `fire_action` (default `fire_projectile`) in `_unhandled_input`, fires every
launcher in `launcher_paths` using directions from `aim_controller_path` if set,
then waits `cooldown`. With `require_controlled_owner`, it only fires when the
nearest ancestor exposing `controlled_property` (default `player_controlled`)
has it set to true.

## Recoil

- `PhysicsRecoil.apply_recoil()` applies an impulse opposite the fire direction
  to `rigid_body_path` (or the nearest ancestor body), sized by
  `projectile_mass × initial_speed × recoil_strength × impulse_multiplier`
  (or `fallback_impulse`), at the shot's muzzle position when available.
- `CannonSlideRecoil.apply_recoil()` kicks a spring along a local
  `recoil_axis`, clamped to `max_recoil_distance`, moving `target_path` (or its
  parent) back to rest.

Any node with `apply_recoil(fire_direction, shot_data)` can be a receiver.
