# Projectile Launcher System

Launch physical projectiles from a muzzle, inherit the platform's velocity,
aim with a ballistic solver, apply recoil, and show muzzle-flash / water-splash
effects. No dependency on other addons.

## Visual effects

- **Muzzle flash:** particles and a short-lived orange light.
- **Water splash:** where a projectile meets the waterline plane.
- **Cannon recoil:** a spring-damper slide of the barrel or carriage.

## Pieces

| Class | Role |
| --- | --- |
| `ProjectileLauncher` (`projectile_launcher.tscn`) | Spawns projectiles and muzzle flashes, notifies recoil receivers, emits `fired`. |
| `Projectile` (`default_projectile.tscn`) | `RigidBody3D` with quadratic drag, lifetime, and water-plane cleanup. |
| `ProjectileWeaponController` | Drives a set of launchers: center-screen aim, ballistic pitch solve, yaw turning, aim marker, fire input with cooldown, and recoil on the carrying body. |
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

`yaw_target_path` names the node a weapon controller turns toward its aim
point (e.g. the gun carriage); empty turns the launcher itself.

## `ProjectileWeaponController`

In `_ready` it resolves its carrying body (`body_path`, or the nearest
`RigidBody3D` ancestor; none is allowed) and its launchers: every
`ProjectileLauncher` under the body (or under its parent without a body) when
`auto_collect_launchers` is on, plus `launcher_paths`. Call `refresh_launchers()`
after adding or removing launchers at runtime.

With `require_controlled_owner`, it does nothing (no aim, no marker, no input)
unless the nearest ancestor exposing `controlled_property` (default
`player_controlled`) has it set to true, so AI boats keep their guns still.

Every frame, when enabled and controlled:

1. Casts a ray from the center of the camera (`camera_path` or the active
   viewport camera) to the horizontal plane `aim_plane_y`.
2. For each launcher, if `solve_ballistics` is on, searches
   pitch between `min_pitch_degrees` and `max_pitch_degrees`
   (`pitch_search_steps` coarse samples, `pitch_refine_steps` bisection),
   simulating the shot with the launcher's speed, drag, mass, inherited velocity
   and project gravity. It picks the lowest (or, with `prefer_high_arc`, the
   highest) pitch interval where the height error at the aim distance changes
   sign and bisects it; with no sign change it accepts the closest sample only
   if it is within `impact_height_tolerance`. Unreachable launchers keep their
   last valid direction. Cost: the low-arc scan stops at the first sign change,
   and when an upper bound on the trajectory (drag can only lower it: along
   the path `y'' = -g / vx²` and `vx ≤ vx0·e^(-kx)`) passes below the target
   at every sampled pitch, nothing is simulated (aiming beyond range).
3. Yaws each launcher's yaw target toward the aim point around the body's up
   axis, with `yaw_smoothing`.
4. Moves a ring marker, coloured by reachability, to the aim point (an
   internal node; its mesh is rebuilt only when the marker shape changes).

On `fire_action` (default `fire_projectile`, which enabling the plugin adds
on Space; a missing action is reported once and fire input is ignored) in
`_unhandled_input` it calls `fire()`: every launcher fires along `get_launch_direction_for_launcher()` (this
frame's solution, else the last one, else the muzzle's −Z), then it waits
`cooldown`. A boat with low guns needs a negative `min_pitch_degrees` to hit
water close by (the rowboat uses −10°).

## Recoil

- `ProjectileWeaponController` listens to each launcher's `fired` signal and,
  with `body_recoil_enabled`, applies an impulse opposite the fire direction to
  its body at the muzzle, sized by
  `projectile_mass × initial_speed × recoil_strength × impulse_multiplier`
  (or `fallback_impulse` when `use_projectile_momentum` is off).
- `CannonSlideRecoil.apply_recoil()` kicks a spring along a local
  `recoil_axis`, clamped to `max_recoil_distance`, moving `target_path` (or its
  parent) back to rest.

Any node with `apply_recoil(fire_direction, shot_data)` can be a receiver.
