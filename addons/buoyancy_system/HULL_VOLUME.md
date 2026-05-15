# Hull Volume

`HullVolume` is an editable displacement volume for boats. It is intended to
become the shared source of truth for buoyancy, water exclusion, flooding, and
damage.

## Editing

Add a `HullVolume` node under the boat rigid body. The volume is made from
cross-sections along the node's local Z axis.

Each `HullVolumeSection` has:

- `z_position`: local position along the boat length.
- `points`: local `Vector2(x, y)` outline points for that cross-section.

The node draws a wireframe debug volume in the editor and at runtime. If the
section list is empty, the node initializes a simple boat-like default shape.

## Buoyancy

When `generate_buoyancy_samples` is enabled, `BuoyantBody` automatically finds
child `HullVolume` nodes and asks them for generated sample points. These points
use the same water query and force application path as manual `BuoyancyProbe`
nodes.

Manual probes still work and can be mixed with hull volumes during migration.

## Water Exclusion

When `water_exclusion_enabled` is enabled, `OceanSystem` converts adjacent hull
sections into tapered water exclusion segments. The water shader uses these
segments to hide water inside the hull footprint and add edge foam.

Unlike the legacy `WaterHullCutout`, hull volume segments include a maximum
exclusion height relative to the `HullVolume` origin. Keep
`exclusion_height_above_origin` near the authored waterline; high values can
remove waves above a submerged bow and create visible holes.

## Current Limits

- The first implementation uses section half-widths as tapered segment masks. It
  does not yet rasterize the exact section polygon.
- Editing is Inspector-based through section resources and debug wireframe
  preview. Viewport point handles can be added later without changing the data
  model.
- Flooding and damage are represented by `flooding_fraction` and efficiency
  values on the whole volume for now. Per-compartment state is the next natural
  extension.
