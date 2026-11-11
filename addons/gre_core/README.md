# Core

**English** · [简体中文](README.zh-CN.md)

The shared foundation of the ocean addons. It depends on nothing; `gre_ocean_system`,
`gre_sky_system`, `gre_buoyancy_system` and `gre_boat_template` depend on it. Enable it
before them.

## How it works

The systems never use each other's types. When two of them have to work
together, the contract between them lives here:

| Class | Role |
| --- | --- |
| `GREWaterSurface` | The water contract. A water simulation (`GREOceanSystem`) registers one per `World3D`; anything that samples the water finds it with `GREWaterSurface.find(node)`. It also gives the surface drift (`get_surface_drift()`), the water's mean flow downwind that carries foam and floating things. |
| `GREWaterSurfaceQueryResult`, `GREWaterSurfaceSample` | The answer to a water query: per point, the surface height, normal, displacement and water velocity. |
| `GREWaterDisturbance` | A hull in the water, as `GREWaterSurface.submit_disturbance()` takes it: footprint, depth and the water's velocity under it. The water draws the waves its motion makes. |
| `GREWaterMask` | Keeps the water out of an open hull: an invisible lid that marks the stencil buffer, and the water does not draw there. |
| `GREWindSource` | Reads any wind provider (a `GREWindSystem` or a node of your own) by its methods or properties. |
| `GREProjectSetup` | Lets the addons' plugins add missing project settings (global shader uniforms, input actions) without changing existing ones. |
| `GRERenderingContext` | Owns a compute feature's `RenderingDevice` resources, frees them together and records failures. |

Water queries are asynchronous: the points of every consumer are sampled on
the GPU in one batch and read back a few frames later. A result is therefore
slightly old, and each sample can extrapolate its height to the present.

## How to use

### Read the water height

```gdscript
var _water : GREWaterSurface

func _ready() -> void:
	_water = GREWaterSurface.find(self)  # null if no water is registered in this world

func _physics_process(_delta : float) -> void:
	if _water == null:
		return
	_water.submit_query(self, PackedVector3Array([global_position]))  # every tick
	var result := _water.get_query_result(self)  # null until the first readback
	if result != null and result.samples.size() == 1:
		var sample := result.samples[0]
		var height := sample.extrapolated_height(_water.get_query_age(result))
		# sample.normal, sample.surface_velocity, ...

func _exit_tree() -> void:
	if _water != null:
		_water.release_query(self)
```

- Submit every physics tick; the latest submission per owner wins.
- A result answers the points of its own dispatch (`result.points`). If you
  change the number of points, check the sample count.
- Always extrapolate with `get_query_age(result)`.
- Only need whether one point is under water? `_water.point_depth(self, point)`
  does the submit, read and extrapolation: metres under the surface (negative
  above), NAN until the first readback. Still call it every tick and release the
  owner in `_exit_tree()`.

### Provide or read wind

A wind source is any node with `get_wind_speed()` (m/s) and
`get_wind_direction_degrees()`, or with `wind_speed` and `wind_direction`
properties. Directions are the way the wind blows toward, in degrees: 0 = +Z,
90 = +X. Read one with `GREWindSource.is_valid(node)`, `get_speed(node)`,
`get_direction(node)` and `get_velocity(node)`.

### Write your own water

Extend `GREWaterSurface` and implement its abstract methods. Call
`GREWaterSurface.register(get_world_3d(), surface)` in `_enter_tree()` and
`unregister()` in `_exit_tree()`. Each world can have only one water surface.
Water without interactive waves can ignore `submit_disturbance()`,
`release_disturbance()` and `set_query_wave_response()`.

### Make waves

Report a hull every physics tick with `submit_disturbance(self, disturbance)`
(one `GREWaterDisturbance`, reused) and call `release_disturbance(self)` in
`_exit_tree()`. `GREBuoyantBody` does this for floating bodies. Query results
leave those waves out unless the owner calls
`set_query_wave_response(self, response)` (0 none, 1 all;
`GREBuoyantBody.wave_response`); the water inside its own reported hull then
comes from around the hull, so it never feels the water it displaces.

### Keep water out of an open hull

An open boat's floor sits below the waterline, so without help the sea shows
inside it. Add a `GREWaterMask` (a `MeshInstance3D`) to the boat, level, just
below the gunwale and above the seats. Set `hull_path` to the hull's model and
press **Fit to Hull** in the inspector. It slices the model at that height and
makes the lid the inside of the hull's outline (the inner skin of a hull with
two), pushed `edge_margin` into the walls. Or give it a flat lid mesh of your
own. The editor shows the lid tinted; in the game it is invisible.

- The lid marks the pixels where it is in view with stencil value 128
  (`GREWaterMask.STENCIL_REFERENCE`), and the water skips them. A custom water
  shader needs the same `stencil_mode read, compare_not_equal, 128;`.
- It works only while the camera is above the lid: from below (a camera low
  in the boat) the water inside shows, rather than a hole in the sea.
- Waves rising above the lid inside the hull still show, and so does a crest
  in front of the boat that rises above the gunwale, where it overlaps the
  opening (it is cut there).
