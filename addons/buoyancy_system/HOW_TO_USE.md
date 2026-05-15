# Buoyancy System HOW TO USE

## Setup

1. Add an `OceanSystem` to the scene.
2. Add a `CurrentSystem` if objects should drift with ocean current.
3. Add a `RigidBody3D` for the floating object.
4. Add `BuoyantBody` as a child of the rigid body.
5. For boats, add a `HullVolume` under the rigid body and edit its section
   resources to match the hull shape.
6. For simple objects, instance `buoyancy_probe.tscn` several times under the
   rigid body and move the probes to the hull/bottom contact points.

`BuoyantBody` automatically collects child `HullVolume` and `BuoyancyProbe`
nodes. `HullVolume` can generate buoyancy sample points and also feed water
exclusion data to `OceanSystem`; probes remain useful for simple debug objects
and hand-authored force points.

The buoyancy implementation uses OceanSystem's GPU batched surface query API.
It does not require `enable_height_queries`; sample points are uploaded to a
small GPU buffer and only compact surface data is read back.
