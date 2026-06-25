# AGENTS.md

## Scope
- This addon owns probe-based buoyancy, buoyancy probe generation, contact state, floating debug bodies, and generic sinking behavior for buoyant bodies.
- Runtime behavior is in `buoyant_body.gd`, probe node/volume scripts, `floating_debug_body.gd`, and `buoyant_sinking_monitor.gd`.
- `plugin.cfg` and `buoyancy_system_plugin.gd` only register the addon in the editor.

## Buoyancy Rules
- `BuoyantBody` queries `OceanSystem.sample_water_surface_batch(points, owner)` and expects a stable owner.
- Probe generation is editor-only. Runtime uses saved probe nodes and should not generate missing probes.
- Object weight and center of mass come from the parent `RigidBody3D`, not from probe volumes.

## Integration
- `BuoyantSinkingMonitor` may listen to external damage systems through a signal connection, but this addon should not depend directly on hitbox or projectile classes.
- Keep FX/contact probes separate from physical buoyancy probes.

## Scene Editing
- Keep generated probe nodes editable and serialized under `GeneratedProbes`.
- Keep `res://` paths and resource UIDs intact when editing `.tscn` files.

## Verification
- For project verification, run/open `demo/main.tscn` and check buoyancy forces, contact probe state, and sinking behavior.
