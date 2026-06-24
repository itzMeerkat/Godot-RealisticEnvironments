# AGENTS.md

## Scope
- This addon packages a reusable floating boat scene template and boat-specific helper components.
- `floating_boat.tscn` is the stable template scene. Demo boats should instance it and override model, collision, probes, hitboxes, weapons, and tuning parameters.
- Runtime helper scripts are `floating_boat.gd`, `simple_boat_controller.gd`, `boat_water_interactor.gd`, `boat_wake_trail.gd`, and `floating_boat_animation_autoplay.gd`.
- `plugin.cfg` and `floating_boat_template_plugin.gd` only register the addon in the editor.

## Boundaries
- Keep reusable boat structure here, but keep ocean simulation in `ocean_system`, buoyancy force code in `buoyancy_system`, projectile logic in `projectile_launcher_system`, and damage routing in `hitbox_damage_system`.
- Do not put demo asset paths such as `demo/assets/pirate_ship/...` into `floating_boat.tscn` or runtime scripts.
- Template scenes may connect addon systems by signal, such as `HitboxHealthManager.group_destroyed -> BuoyantSinkingMonitor._on_hitbox_group_destroyed`.

## Scene Shape
- Keep stable top-level nodes: `CollisionShape3D`, `BuoyantBody`, `BuoyantSinkingMonitor`, `HitboxHealthManager`, `HitboxHealthDebugUI`, `ProjectileHitboxes`, `BoatWaterInteractor`, `SimpleBoatController`, `BoatWakeTrail`, `CameraTargets`, `BuoyancyProbeVolume`, `PhysicsRecoil`, `ProjectileFireInputController`, and `ProjectileAimController`.
- User/demo scenes should add their model under the root, set `BuoyancyProbeVolume.source_paths`, generate probes, add hitboxes under `ProjectileHitboxes`, and configure launcher paths.
- Keep `res://` paths and resource UIDs intact when editing `.tscn` files.

## Verification
- For project verification, run/open `demo/main.tscn` and `demo/floating_box.tscn` to check buoyancy, camera targets, foam, firing, hitboxes, health UI, and sinking.
