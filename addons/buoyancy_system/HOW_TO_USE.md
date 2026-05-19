# Buoyancy System HOW TO USE

## Setup

1. Add an `OceanSystem` to the scene.
2. Add a `RigidBody3D` for the floating object.
3. Add `BuoyantBody` as a child of the rigid body.
4. Add `BuoyancyCellVolume` under the rigid body.
5. Assign `source_model_path`, choose `voxel_size`, then toggle
   `generate_cells_now` in the Inspector to create editable `BuoyancyCellNode`
   children under `GeneratedCells`. Generation scans the source mesh bounds but
   only keeps cells inside the source mesh's 3D convex hull. If the source mesh
   is degenerate, generation falls back to the source AABB.

`BuoyantBody` automatically collects child `BuoyancyCellVolume` nodes. Each
enabled cell contributes volume, density-derived mass, buoyancy, drag, and
debug data. When `apply_mass_to_rigid_body` is enabled on the cell volume, the
parent rigid body's mass and center of mass are calculated from the enabled
cell nodes. Each `BuoyancyCellNode` can be selected in the scene tree or 3D
viewport and edited directly. Move the node to change the buoyancy sample
position; edit `size`, `density`, and the per-cell multipliers in the Inspector.
The convex hull is intentionally convex, so it will not preserve concave holes
or recesses in the source model.

`BuoyantBody` owns global water response tuning such as vertical damping,
longitudinal water drag, and lateral water drag. Each cell only stores
multipliers for those values, so the whole body can be tuned globally while
specific cells can still be made more or less resistant.

The buoyancy implementation uses OceanSystem's GPU batched surface query API.
It does not require `enable_height_queries`; sample points are uploaded to a
small GPU buffer and only compact surface data is read back.

Visual water cutout is intentionally separate from buoyancy. Add
`WaterCutoutHullLOD` or `WaterHullCutout` under the floating object when the
ocean surface needs to be hidden inside the hull.

## Water Interaction

`BuoyancyCellVolume` also aggregates submerged cells into a small number of
water interaction sources. These sources are written into `OceanSystem`'s local
interaction heightfield, so nearby ripples and wakes affect both water rendering
and buoyancy queries without spawning one visible ripple per cell.
