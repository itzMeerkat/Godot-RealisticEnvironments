# Water Hull Cutout

This document describes the visual-only hull cutout used to hide ocean surface
intersections with boats.

## Goal

The boat physics and buoyancy can be acceptable while the rendered ocean surface
still visually passes through the hull. This system does not add water collision.
Instead, it masks the water mesh inside a boat-shaped footprint and adds foam at
the edge, which is the common real-time rendering approach for making hull-water
intersections look acceptable.

## Files

- `addons/ocean_system/water_hull_cutout.gd`
  - `WaterHullCutout`, a `Node3D` marker that defines a rectangular hull mask.
  - It adds itself to the `water_hull_cutout` group.
- `addons/ocean_system/ocean_system.gd`
  - Collects up to `MAX_HULL_CUTOUTS` active cutout nodes each frame.
  - Sends each cutout's world position, orientation, size, feather, and foam
    strength to the water shader.
- `addons/ocean_system/shaders/spatial/water.gdshader`
  - Discards water fragments inside each hull cutout rectangle.
  - Adds foam near the cutout edge to hide the hard boundary.
- `demo/floating_box.tscn`
  - Uses `BuoyancyCellVolume` from the buoyancy system for the demo boat. The legacy
    `WaterHullCutout` path remains available for simple rectangular masks.

## How It Works

Each `WaterHullCutout` describes an oriented rectangle in world XZ space:

- `global_position` is the cutout center.
- local `X` is the cutout width direction.
- local `Z` is the cutout length direction.
- `half_extents.x` is half width.
- `half_extents.y` is half length.

`OceanSystem` packs this data into shader arrays:

- `hull_cutout_centers`: center xyz and feather.
- `hull_cutout_axes`: right and forward directions in XZ.
- `hull_cutout_shapes`: half width, half length, foam amount.

The water shader computes a signed distance to each oriented rectangle. If the
fragment is inside a rectangle, the shader discards that water pixel. If the
fragment is near the outside edge, it increases the foam factor.

## Adding It To A Boat

1. Add a `Node3D` under the boat root.
2. Attach `res://addons/ocean_system/water_hull_cutout.gd`.
3. Name it `WaterHullCutout` for clarity.
4. Move it to the boat's waterline footprint center.
5. Set `half_extents` to roughly cover the area where the hull intersects the
   water.

The node follows the boat automatically because it is a child of the boat.

## Tuning

Use these properties on `WaterHullCutout`:

- `enabled`
  - Turns this cutout on or off.
- `half_extents`
  - `x`: half width of the hidden water area.
  - `y`: half length of the hidden water area.
  - Increase these if water still appears inside the hull.
  - Decrease these if water disappears too far outside the hull.
- `feather`
  - Width in meters of the foam band around the cutout edge.
  - Increase this if the cut edge is too obvious.
  - Decrease this if foam spreads too far from the hull.
- `foam_amount`
  - Strength of foam injected at the cutout edge.
  - Increase this to hide artifacts.
  - Decrease this if the boat has too much white foam around it.

For a simple boat, a `WaterHullCutout` can start with:

```text
half_extents = Vector2(3.6, 12.5)
feather = 0.9
foam_amount = 0.85
```

## Multiple Boats

The shader supports up to `MAX_HULL_CUTOUTS` cutouts. The current value is `16`
in both `ocean_system.gd` and `water.gdshader`.

To support more boats:

1. Increase `MAX_HULL_CUTOUTS` in `ocean_system.gd`.
2. Increase `MAX_HULL_CUTOUTS` in `water.gdshader`.
3. Keep the value modest; each extra cutout adds fragment shader work.

## Limitations

- The cutout is a rectangular footprint, not the exact hull silhouette.
- It is visual only. It does not affect buoyancy, collision, or water queries.
- Water can still look wrong if the cutout is much larger or smaller than the
  visible hull.
- If the boat rolls heavily, a flat XZ footprint is still only an approximation.
- The edge is hidden with foam, not true displaced water.

## Recommended Next Steps

For better visuals later:

- Add a separate wake/foam emitter following the hull sides and stern.
- Replace the rectangular footprint with several smaller cutouts for complex
  hulls.
- Use `BuoyancyCellVolume` from the buoyancy system as the shared buoyancy and water
  exclusion source for editable hull-shaped volumes.
- Add a bow/stern-specific foam mask so the waterline reads less rectangular.
- Use a low transparent waterline mesh on the boat to further hide the edge.

The important design principle is to keep physical buoyancy and visual masking
separate. Buoyancy should stay stable and predictable; the cutout should only
make the rendered intersection look better.
