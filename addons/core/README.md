# Core

The shared foundation of the ocean addons. Every `*_system` addon may depend on
`core`; `core` depends on nothing, and the systems never depend on each other.
Anything two systems need goes here.

## Water surface contract

`WaterSurface` (abstract, `RefCounted`) is how anything that floats on water or
disturbs it talks to a water simulation, without knowing which one. A
simulation registers one surface per `World3D`; consumers look it up:

```gdscript
var water := WaterSurface.find(self)  # null when the world has no water
water.submit_query(self, points)      # every physics tick
var result := water.get_query_result(self)  # null until the first readback
if result != null:
	var height := result.samples[0].extrapolated_height(water.get_query_age(result))
# in _exit_tree:
water.release_query(self)
```

| Member | Purpose |
| --- | --- |
| `static register(world, surface)`, `static unregister(world, surface)` | Called by the simulation when it enters / leaves the tree. One surface per world; a second registration is an error. |
| `static find(node) -> WaterSurface` | The surface of `node`'s world, or `null`. |
| `submit_query(owner, points, body = null)` | Queue points; the latest submission per owner wins. `body` (default: the owner's nearest `PhysicsBody3D`) lets the simulation leave out waves that body makes itself. |
| `get_query_result(owner) -> WaterSurfaceQueryResult` | Latest completed result, or `null`. Its points belong to its dispatch, not to the latest submission. |
| `get_query_age(result) -> float` | Seconds from the result's dispatch to now (the start of the current physics tick inside one), for `WaterSurfaceSample.extrapolated_height()`. |
| `release_query(owner)` | Forget an owner. |
| `get_clock() -> float` | The clock `dispatch_time` is measured on. |
| `can_add_impulses()`, `add_impulse(position, radius, amplitude)` | Splashes in the simulation's dynamic waves, when it runs them. |

`WaterSurfaceQueryResult` holds `points`, `samples` (`samples[i]` answers
`points[i]`) and `dispatch_time`. `WaterSurfaceSample` holds the surface
`height`, `normal`, `displacement` and `surface_velocity` over a point, and
`extrapolated_height(age)` to hide the readback latency.

Implemented by `ocean_system` (`OceanSurfaceQueries`, registered by
`OceanSystem`). Used by `buoyancy_system` and `floating_boat_template`.

## Rendering helpers

`RenderingContext` owns the `RenderingDevice` resources of one compute feature
and frees them together, newest first, when it is freed:

- `own(rid)` for anything created directly on the device; creation helpers for
  textures of any type (`create_texture_rid`, `create_texture` for 2D and 2D
  arrays), storage buffers, samplers, uniform sets, compute pipelines and
  single-mip slice views;
- `load_shader(path, version)` / `load_shader_file(file, version)`, cached per
  file and `#[versions]` entry;
- static `image_uniform`, `sampled_uniform`, `buffer_uniform` and
  `linear_sampler_state`;
- static `create_push_constant(values)` (ints and bools as `int32`, the rest as
  `float32`) and `create_float_push_constant(values)` (all `float32`), at the
  exact byte size the shader declares (no 16-byte padding).

A failed creation (a shader that does not compile, an invalid RID) is reported
with `push_error` and sets `failed`; owners check it after building their
resources and disable their feature.

## Editor helpers

`HullSlicer` gathers triangles from mesh instances and slices them with
horizontal planes, for hull profile baking (`ocean_system`) and probe
generation (`buoyancy_system`).

## Files

| File | Role |
| --- | --- |
| `water_surface.gd` | `WaterSurface` contract and per-world registry |
| `water_surface_query_result.gd`, `water_surface_sample.gd` | Query result types |
| `rendering_context.gd` | `RenderingContext` RenderingDevice helper |
| `hull_slicer.gd` | `HullSlicer` mesh slicing |
