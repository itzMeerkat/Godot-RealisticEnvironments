# AGENTS.md

## Scope
- This addon owns reusable projectile launchers, projectile scenes, aim solving, fire input bridging, muzzle effects, and recoil receivers.
- Runtime behavior is in scripts such as `projectile_launcher.gd`, `projectile.gd`, `projectile_aim_controller.gd`, `projectile_fire_input_controller.gd`, `cannon_slide_recoil.gd`, and `physics_recoil.gd`.
- `plugin.cfg` and `projectile_launcher_system_plugin.gd` only register the addon in the editor.

## Boundaries
- Do not add target health, hitbox health, sinking, or scoring logic here. Put those in `hitbox_damage_system` or downstream gameplay code.
- `ProjectileLauncher` should remain muzzle-driven: `muzzle_path` may point into a model or animation tree, while the launcher itself may live in a stable functional node tree.
- Recoil receivers are duck-typed via `apply_recoil(fire_direction, shot_data)`.
- Custom projectiles should either implement `launch()` or be `RigidBody3D` nodes that can accept velocity/mass configuration.

## Scene Editing
- Keep projectile and muzzle flash scenes reusable and independent of demo boat paths.
- Keep resource UIDs and `res://` paths intact when editing `.tscn` files.

## Verification
- For project verification, run/open `demo/main.tscn` and check firing, muzzle flash, projectile velocity inheritance, aim marker, and recoil behavior.
