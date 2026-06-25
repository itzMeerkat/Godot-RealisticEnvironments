# AGENTS.md

## Scope
- `systems/boat` is retained only as a pointer for historical demo boat code location.
- New reusable floating boat work belongs to `addons/floating_boat_template`.

## Current Role
- Boat controls, water interaction, wake trail, and model animation autoplay now belong to `addons/floating_boat_template`.
- Projectile launching belongs to `addons/projectile_launcher_system`.
- Hitbox health belongs to `addons/hitbox_damage_system`.
- Sinking monitoring belongs to `addons/buoyancy_system`.

## Editing Notes
- Keep demo-only node paths out of reusable addons.
- If a feature becomes model-independent, move it into an addon and update the demo scene to use the addon path.
