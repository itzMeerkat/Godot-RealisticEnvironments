# Buoyancy System HOW TO USE

## Setup

1. Add an `OceanSystem` to the scene.
2. Add a `RigidBody3D` for the floating object.
3. Add `BuoyantBody` as a child of the rigid body.
4. Add `BuoyancyCellVolume` under the rigid body.
5. Assign `source_model_path`, choose `voxel_size`, then toggle
   `generate_cells_now` in the Inspector to fill the source model's bounds with
   editable cells.

`BuoyantBody` automatically collects child `BuoyancyCellVolume` nodes. Each
enabled cell contributes volume, density-derived mass, buoyancy, drag, and
debug data. When `apply_mass_to_rigid_body` is enabled on the cell volume, the
parent rigid body's mass and center of mass are calculated from the enabled
cells.

`BuoyantBody` owns global water response tuning such as vertical damping,
longitudinal water drag, and lateral water drag. Each cell only stores
multipliers for those values, so the whole body can be tuned globally while
specific cells can still be made more or less resistant.

The buoyancy implementation uses OceanSystem's GPU batched surface query API.
It does not require `enable_height_queries`; sample points are uploaded to a
small GPU buffer and only compact surface data is read back.

## Water Interaction

`BuoyancyCellVolume` also aggregates submerged cells into a small number of
water interaction sources. These sources are written into `OceanSystem`'s local
interaction heightfield, so nearby ripples and wakes affect both water rendering
and buoyancy queries without spawning one visible ripple per cell.
