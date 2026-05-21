# AGENTS.md

## Project Shape
- This is a Godot 4 project, not a package-manager repo; `project.godot` is the root manifest and declares Godot feature `4.7` with `Forward Plus`.
- The configured main scene is `res://demo/main.tscn`; run/open that scene to exercise the full demo.
- No CI, task runner, lockfile, lint, formatter, or test config is present; focused verification is via Godot 4.7/editor runs of the affected scene, usually `demo/main.tscn`.
- Reusable systems live under `addons/`: `ocean_system`, `sky_system`, `wind_system`, and `buoyancy_system`. Read that addon's `HOW_TO_USE.md`/`CODEBASE.md` before changing behavior.
- `systems/` contains demo/support systems such as camera and debug UI; `demo/main.gd` wires `SkySystem`, `Water` (`OceanSystem`), `WindSystem`, `OceanDebugPanel`, and `PlayerCameraRig` together.
- Each addon has `plugin.cfg`, but the `*_plugin.gd` files are only for Godot plugin registration; runtime behavior is in the scene/script pairs such as `addons/ocean_system/ocean_system.tscn` plus `ocean_system.gd`.

## Ocean System Notes
- `OceanSystem` is a `MeshInstance3D` that generates the ocean mesh at runtime; do not commit serialized generated mesh data into scenes.
- `addons/ocean_system/wave_generator.gd` owns the RenderingDevice compute pipeline: spectrum generation, modulation, FFT, transpose, and unpack passes.
- Compute push constants are intentionally uploaded with exact byte counts via `RenderingContext.create_push_constant()`; do not re-pad them to 16 bytes unless a shader actually requires it.
- Storage image bindings are access-sensitive; keep read/write descriptor sets aligned with the shader declarations.
- `OceanSystem` copies its water material at runtime so multiple ocean instances do not share mutable shader parameters.
- External wind is duck-typed: an assigned wind node only needs `get_wind_speed()` and `get_wind_direction_degrees()`, or `wind_speed` / `wind_direction` properties.

## Water Queries And Buoyancy
- Use `OceanSystem.sample_water_surface_batch(points, owner)` for gameplay and buoyancy; it uses the GPU point-query path.
- `BuoyantBody` auto-finds an `OceanSystem` via explicit `ocean_path` or the `ocean_system` group and expects child `BuoyancyCellVolume` nodes for sample points.

## Scene And Asset Editing
- Keep `res://` paths and Godot resource UIDs intact when editing `.tscn`, `.tres`, or `.import` files manually.
- `.godot/`, `.import/`, exports, and `build/` are ignored generated state; avoid using them as sources of truth.
- `README.md` is the current project overview; `README_original.md` is upstream background only.
