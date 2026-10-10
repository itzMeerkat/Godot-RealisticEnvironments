# Examples

Small scenes that use only the open-source addons (`core`, `ocean_system`,
`sky_system`, `wind_system`, `exposure_system`, `buoyancy_system`,
`hitbox_damage_system`, `ocean_environment`, `boat_template`). Open one and
press **Run Current Scene** (F6). Each starts from `ocean_environment.tscn`;
the cameras read the mouse and keyboard directly, so they need no Input Map
actions.

| Scene | Shows | Controls |
| --- | --- | --- |
| `ocean_only.tscn` | The drop-in environment: sky, clouds, wind and waves. | Hold right mouse to look; W A S D fly, Q / E down / up, Shift faster, wheel changes speed (`free_camera.gd`) |
| `floating_objects.tscn` | Crates and barrels floating on probe buoyancy: each is a `RigidBody3D` with a `BuoyantBody` and a `BuoyancyProbeVolume` whose probes were generated in the editor. | As above |
| `boat.tscn` | A drivable boat (`simple_boat.tscn`, built on `boat_template`'s `boat.tscn`) with wake, bow spray and hull cutout, and two crates. | W A S D drive (the Boat Template plugin adds those actions); hold right mouse to orbit, wheel zooms (`orbit_camera.gd`) |

To change the time of day, the weather or the waves, select `OceanEnvironment`,
turn on **Editable Children** (right-click), and edit `SkySystem`,
`WindSystem` or `Ocean` (see `addons/ocean_environment/README.md`).

## How the floating objects were made

`crate.tscn` and `barrel.tscn` are a `RigidBody3D` (mass, mesh, collision
shape) with two children:

- `BuoyantBody`: applies the buoyancy forces to its body.
- `BuoyancyProbeVolume`: `source_paths` points at the mesh, with the probe
  count, the volume of each probe (the object's volume divided by the count),
  the column height (the object's height) and its freeboard (the part above
  `design_waterline_y`). **Generate All Probes** then places the probes, and
  the scene is saved with them.

An object floats where the displaced water weighs as much as it does: the 250 kg
crate of 1 m³ floats a quarter submerged.

## How the boat was made

`simple_boat.tscn` is an inherited scene of `addons/boat_template/boat.tscn`:

1. `Model` is the hull mesh `assets/simple_hull.obj`, made by
   `tools/make_example_hull.py` (bow along −Z).
2. Root: `mass`, `center_of_mass` and the drive and stability settings.
   `CollisionShape3D` holds a convex shape made from the mesh (**Mesh >
   Create Collision Shape** in the editor).
3. `BuoyancyProbeVolume`: `source_paths` → `Model`, `design_waterline_y`, probe
   counts and sizes, then **Generate All Probes**.
4. `HullWaterFootprint`: `bake_source_paths` → `Model`, then **Bake Profile**
   (saved as `simple_boat_hull_profile.tres`). This hides the water inside the
   hull and makes the boat push water (wake, bow wave).
5. `BowSpray` moved to the stem at the waterline, `CameraTargets` to the boat.

`boat.tscn` sets `player_controlled` on the instance it drives. See
`addons/boat_template/README.md` for every step in detail.
