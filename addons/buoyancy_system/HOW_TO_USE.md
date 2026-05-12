# Buoyancy System HOW TO USE

## Setup

1. Add an `OceanSystem` to the scene.
2. Add a `CurrentSystem` if objects should drift with ocean current.
3. Add a `RigidBody3D` for the floating object.
4. Add `BuoyantBody` as a child of the rigid body.
5. Instance `buoyancy_probe.tscn` several times under the rigid body and move
   the probes to the hull/bottom contact points.

`BuoyantBody` automatically collects child `BuoyancyProbe` nodes. Use more
probes for larger or longer shapes so buoyancy can create realistic torque.

The buoyancy implementation uses OceanSystem's GPU batched surface query API.
It does not require `enable_height_queries`; probe points are uploaded to a
small GPU buffer and only compact sample data is read back.
