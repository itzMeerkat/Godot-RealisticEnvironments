# Projectile Launcher System

Physical projectiles fired from a muzzle, with inherited platform velocity,
ballistic aiming, recoil, muzzle flashes and water splashes. No dependencies.
Development/demo gameplay, not part of the open-source addons.

## Pieces

| Class | Role |
| --- | --- |
| `GREProjectileLauncher` (`projectile_launcher.tscn`) | `fire(direction)`: spawns a projectile and muzzle flash, notifies recoil receivers, emits `fired(projectile, direction, shot_data)`. |
| `GREProjectile` (`default_projectile.tscn`) | `RigidBody3D` with quadratic drag and a lifetime; splashes and frees itself below `waterline_y` (a flat plane). |
| `GREProjectileWeaponController` | Aims every launcher under its body at the screen centre (ballistic pitch solve, yaw turning, aim marker) and fires on `fire_action` with a cooldown; applies body recoil. |
| `GRECannonSlideRecoil` | Spring-damper slide of a barrel or carriage. |
| `GREProjectileMuzzleFlash`, `GREProjectileWaterImpactEffect` | One-shot effects. |

## Usage

1. Instance `projectile_launcher.tscn` at each gun. Set `yaw_target_path` to
   the node that should turn (e.g. the gun) and optional `GRECannonSlideRecoil`
   nodes as `recoil_receiver_paths`.
2. Add a `GREProjectileWeaponController` on the carrying body. It collects the
   launchers below the body; call `refresh_launchers()` after adding some at
   runtime.
3. Enable the plugin to add the `fire_projectile` action (Space).

With `require_controlled_owner`, the controller only aims and fires while the
nearest ancestor's `player_controlled` is true. Low guns need a negative
`min_pitch_degrees` to hit nearby water (the rowboat uses −10°).

Projectiles go on physics layer 2 with mask 4 (hitboxes), carry group
`projectile` and `source_rigid_body_instance_id` metadata for own-shot
filtering. Any node with `apply_recoil(fire_direction, shot_data)` can be a
recoil receiver. Aiming uses the flat `aim_plane_y`, not the wave height.
