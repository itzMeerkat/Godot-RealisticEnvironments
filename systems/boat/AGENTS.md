# AGENTS.md

## Scope
- `systems/boat` contains demo boat support code and examples, not reusable addon runtime APIs.
- New reusable systems should live under `addons/` instead of this directory.

## Current Role
- `simple_boat_controller.gd`, `boat_water_interactor.gd`, `boat_wake_trail.gd`, and `boat_animation_autoplay.gd` support `demo/floating_box.tscn`.
- Projectile launching now belongs to `addons/projectile_launcher_system`.
- Hitbox health now belongs to `addons/hitbox_damage_system`.
- Sinking monitoring now belongs to `addons/buoyancy_system`.

## Editing Notes
- Keep demo-only node paths out of reusable addons.
- If a feature becomes model-independent, move it into an addon and update the demo scene to use the addon path.
