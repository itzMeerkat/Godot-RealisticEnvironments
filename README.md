# Godot Realistic World Addons Collection

From the community, for the community. This project aims to help Godot game designers express their ideas more easily, without having to wrestle with low-level technical implementations.

## Lineage

This repository began with an ocean wave simulation from https://github.com/2Retr0/GodotOceanWaves.

The Godot version used by the original repository is now outdated. After migration, there were compilation and rendering issues, and the waves became duller and less realistic.

A fork of the original repository solved those issues: https://github.com/20k/GodotOceanWaves.

This project builds on that fork and focuses on improving overall usability.

The reason I decide to detach from the fork network is I found this repo is deviated too much from original repos.

## Maintenance Notes
This fork includes a set of fixes and runtime improvements made while converting the ocean renderer into a reusable Godot scene and making it more stable for camera-follow gameplay.

### Project layout
Project files are grouped by system boundary:

 * `addons/ocean_system/` contains the reusable ocean scene, wave parameters, wave generator, material, ocean shaders, and ocean-internal RenderingDevice helpers under `addons/ocean_system/rendering/`.
 * `addons/wind_system/` contains the optional wind provider used by the demo and available to future gameplay systems.
 * `addons/sky_system/` contains the reusable day-night sky scene, sky profile resource, celestial shaders, and lighting controller.
 * `systems/debug/` contains the optional native debug UI.
 * `demo/` contains the sample scene, camera controller, skybox, and audio assets.

### RenderingDevice and compute fixes
Several Godot 4 RenderingDevice validation errors were fixed:

 * Push constant uploads now use the exact byte count expected by each compute pipeline. This avoids pipelines rejecting a dispatch because a shader expects 4 bytes but receives a padded 16-byte block.
 * Spectrum write/read descriptor sets were separated so storage images match the shader's declared read/write access. This fixes uniform-set validation errors where a writable image was supplied to a shader binding that required a read-only image.
 * Displacement output textures are sampled by the GPU point-query path used by buoyancy and gameplay code.
 * The FFT unpack pass now reads foam history from the previously completed normal map rather than the map currently being written. This keeps foam history continuous when output maps are double-buffered.

### OceanSystem scene and gameplay API
The ocean can now be used as a packaged scene through `addons/ocean_system/ocean_system.tscn`, backed by `OceanSystem` (`addons/ocean_system/ocean_system.gd`).

The runtime ocean scene has no ImGui dependency. The demo scene uses an optional native Godot `OceanDebugPanel` (`systems/debug/ocean_debug_panel.tscn`) for live tuning of the same exported ocean and cascade parameters that are available from the Inspector or scripts.

`OceanSystem` is independent of the wind implementation. By default it uses each cascade's local wind speed and direction. If a scene assigns `wind_source_path` and enables `use_external_wind`, the ocean reads wind from that external node through `get_wind_speed()` and `get_wind_direction_degrees()` or matching `wind_speed` / `wind_direction` properties. The included `WindSystem` (`addons/wind_system/wind_system.gd`) is one such provider, and other systems such as sailing, clouds, particles, and weather can consume the same provider without coupling those systems to the ocean.

The scene exposes GPU batched water queries for buoyancy and gameplay:

```gdscript
func sample_water_surface(world_position: Vector3, request_owner: Object) -> WaterSurfaceSample
func sample_water_surface_batch(points: PackedVector3Array, request_owner: Object) -> Array[WaterSurfaceSample]
```

These functions use world-space positions, so boats and floating objects can sample the water consistently even when the render mesh follows a moving camera. Pass a stable request owner, usually `self`, so asynchronous query results are routed back to the right caller. Point queries avoid reading full displacement textures back to the CPU.

### Performance and smoothing changes
The wave update path now supports lower simulation update rates while preserving smoother visuals:

 * Wave output maps are double-buffered. The material receives current and previous displacement/normal map arrays and blends them with `wave_blend_alpha`.
 * Wave textures, colors, cascade counts, and blend state are material uniforms, so multiple `OceanSystem` instances no longer overwrite one another through project-wide shader globals.
 * If a previous cascade update pass is still running, elapsed time is accumulated and applied to the next accepted pass instead of forcing unfinished work to complete immediately.
 * The fragment shader can limit the number of normal/foam cascades sampled per pixel through `fragment_cascade_limit`.
 * Bicubic normal filtering is enabled by default and can still be toggled through `use_bicubic_normals`.
 * The project has a frame-rate cap configured through `run/max_fps`.

### Procedural clipmap mesh
The water mesh no longer relies on pre-authored mesh assets. `OceanSystem` always generates a clipmap-style grid procedurally from exported parameters:

 * `generated_inner_extent`
 * `generated_base_cell_size`
 * `generated_ring_count`

The generated mesh is a circular ring layout centered around the ocean node. Far LOD extends the same mesh with coarse outer rings, so the water shader no longer carries the old grid-morph branch or extra morph metadata.

### Visual stability fixes
Several visual artifacts were addressed:

 * The water material disables backface culling to avoid generated triangle winding differences making the ocean body disappear while foam remained visible.
 * Previously serialized generated `ArrayMesh` data was removed from `demo/main.tscn`. The procedural mesh is generated at runtime and is not saved into the scene file.
 * Foam/normal history now follows the same double-buffered timeline as displacement maps, reducing color jumps that could appear when the wave update rate was lower than the render frame rate.
 * The water fragment shader uses camera-relative distance for near/far normal and foam falloff, rather than distance from world origin.
 * The old 1-meter tile snapping that moved the whole water node from `demo/main.gd` was removed. `OceanSystem` now follows the active camera continuously in XZ space by default, keeping the render mesh near the camera while the sampled waves remain stable in world space.
 * The previous sea spray particle prototype was removed from the runtime scene and archived in `SEA_SPRAY.md`.
 * The heavy ImGui debug dependency was replaced with an optional native Godot debug panel, keeping the reusable ocean component lighter for use in other projects.

## Systems

The project is organized as a small collection of reusable Godot addons. Each system can be copied into another project independently, while still working together when used in the same scene.

* [Ocean System](addons/ocean_system/) provides the reusable FFT ocean renderer. It generates wave displacement and normal maps on the GPU, builds its own clipmap-style water mesh, supports far-ocean LOD, and exposes water height queries for gameplay.
* [Sky System](addons/sky_system/) provides a dynamic day-night sky. It controls sun and moon lighting, sky colors, moon phase, starfield visibility, and optional water/foam color driving for an ocean node.
* [Wind System](addons/wind_system/) provides a lightweight wind source. It exposes wind speed, direction, gusts, and vector getters that can be consumed by the ocean or by other gameplay systems.

Each system folder includes a `HOW_TO_USE.md` file for setup instructions and a `CODEBASE.md` file that briefly explains the implementation.

## Demo

Run the `demo/main.tscn`. You will see everything.

"Stylized Low Poly Rowboat with Paddles" (https://sketchfab.com/3d-models/stylized-low-poly-rowboat-with-paddles-f2c35c716f32474e96cce3625073e6b8) by Muyaya Concept (https://sketchfab.com/muyayaconcept) licensed under CC-BY-4.0 (http://creativecommons.org/licenses/by/4.0/)
"Red Marine Navigation Buoy (Game Ready)" (https://skfb.ly/pINBD) by Muyaya Concept is licensed under Creative Commons Attribution (http://creativecommons.org/licenses/by/4.0/).
## License

MIT license.
