# AGENTS.md

## Scope
- This addon is a reusable hitbox, grouped health, damage, hit-effect, and debug UI system.
- Runtime behavior is in `projectile_hitbox.gd`, `hitbox_health_manager.gd`, and `hitbox_health_debug_ui.gd`.
- `plugin.cfg` and `hitbox_damage_system_plugin.gd` only register the addon in the editor.

## Boundaries
- Keep this addon independent from boat-specific behavior. Do not add sinking, buoyancy, camera, or player-control logic here.
- `ProjectileHitbox` detects projectiles by duck typing: nodes in the `projectile` group or nodes with `launch()`.
- `HitboxHealthManager` emits `group_destroyed`; downstream systems should connect to that signal for sinking, explosions, scoring, or despawn behavior.
- Own-projectile filtering uses projectile metadata written by `ProjectileLauncher`, but the addon must still work without `projectile_launcher_system`.

## Scene Editing
- Keep `res://` paths and resource UIDs intact when editing `.tscn` files.
- If a demo target needs boat groups such as `hull`, set `hitbox_group` and `group_max_health` explicitly in the scene rather than changing generic defaults.

## Verification
- For project verification, run/open `demo/main.tscn` and check projectile hits, health UI updates, hit smoke, and sinking signal integration.
