# Examples

**English** · [简体中文](README.zh-CN.md)

Small scenes that use only the open-source addons. Open one and press
**Run Current Scene** (F6). Each one starts from `ocean_environment.tscn`. The
cameras read the mouse and keyboard directly, so they need no input actions.

| Scene | Shows | Controls |
| --- | --- | --- |
| `ocean_only.tscn` | The drop-in environment: sky, clouds, wind and waves. | Hold right mouse to look; W A S D fly, Q / E down / up, Shift faster, wheel changes the speed. |
| `floating_objects.tscn` | Crates and barrels riding the waves and drifting downwind. | As above. |
| `boat.tscn` | The boat template's boat and two crates. | W A S D drive; hold right mouse to orbit, wheel zooms. |

To change the time of day, the weather or the waves, select `GREOceanEnvironment`,
turn on **Editable Children** (right-click), and edit `GRESkySystem`,
`GREWindSystem` or `Ocean`.

## How they were made

**Floating objects.** `crate.tscn` and `barrel.tscn` are each a `RigidBody3D`
(mass, mesh, collision shape) with a `GREBuoyantBody` child. Its `draft` is how
deep they sit: 0.25 m for the 250 kg crate, 0.13 m for the 40 kg barrel lying
on its side. Their drag is the same along and across, as for debris.

**The boat.** `simple_boat.tscn` is an inherited scene of
`addons/gre_boat_template/boat.tscn`:

1. `Model` is `assets/simple_hull.obj`, made by `tools/make_example_hull.py`
   (bow along −Z).
2. The root sets `mass`, `center_of_mass` and the drive settings, with
   `propulsion_position` at the transom below the waterline.
   `CollisionShape3D` holds a convex shape made from the mesh, and
   `GREBuoyantBody` floats the hull 0.255 m deep.
3. `CameraTargets` was moved onto the boat.
4. `GREWaterMask` sits 0.3 m up, just below the gunwale; **Fit to Hull** on
   `Model` made its lid (`assets/simple_hull_water_mask.tres`), so no water
   shows inside.

`boat.tscn` turns on `player_controlled` for the boat it drives. The Boat
Template plugin adds the W A S D actions.
