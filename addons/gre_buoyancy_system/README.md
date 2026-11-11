# Buoyancy System

**English** · [简体中文](README.zh-CN.md)

Floats `RigidBody3D`s on the water. It is made to look right, not to be exact:
a body rests level at the depth you choose, rides and rocks with the waves,
drifts downwind with the foam and slows in the water. One setting, `draft`,
places it; there are no volumes or densities to tune.

Requires `gre_core`, and water that registers a `GREWaterSurface` (e.g.
`gre_ocean_system`).

## How it works

- **Probes.** `GREBuoyantBody` lays a grid of probes over the outline of the
  body's collision shapes seen from above, on the hull's waterline plane
  (`draft` above its lowest point). Every physics tick it submits them as one
  water query (see `gre_core`'s `GREWaterSurface`) and uses the latest result,
  extrapolated to the present.
- **Lift.** Each probe lifts its share of the body's weight, `1 + depth /
  draft` times, up to the hull's full height. So in calm water the hull's
  lowest point rests exactly `draft` below the surface whatever the mass, and
  it bobs about every 2π√(draft / g) seconds: 1.1 s at 0.3 m, 6 s at a
  battleship's 9 m. The shares balance about the centre of mass, so the body
  floats level wherever its centre of mass is (inside the hull's outline).
- **Upright by design.** The lift never acts below the centre of mass, so a
  high centre of mass cannot capsize the body. A low one (ballast, like the
  demo buoy's) steadies it further.
- **Damping and drag**, relative to the water. Vertical damping works against
  the surface's own rise and fall (`damping_ratio`), so the body rides the
  waves instead of fighting them. Drag along and across the hull works against
  the surface water's velocity: the waves' motion plus the surface drift
  (`GREWaterSurface.get_surface_drift()`, 3 % of the wind on the ocean). Floating
  things drift downwind with the foam, and a hull with more `sideways_drag`
  than `forward_drag` goes where it points.
- **Wakes.** Every tick the body also reports its hull to the water: its
  footprint (from the collision shapes), how deep it sits below the surface
  around it and how the water under it moves. The ocean draws the waves its
  motion relative to the water makes: the wake, the bow wave and rings when it
  bobs, and the foam its speed churns up (`wake_strength` scales both).
- **Riding wakes (opt-in).** By default a body reads only the sea's waves,
  never the waves bodies stir up, so nothing it does can feed back into its
  motion. With `wave_response` above 0 it also feels those waves: a crate
  rocks as a ship's wake passes, a boat bobs crossing its own wake. Inside its
  own footprint the water is taken from a rim around the hull, stretched back
  along its motion, so the water it displaces itself (the bulge under it and
  the hollow it leaves behind) never lifts or sinks it. Only near the camera,
  where the ocean simulates those waves.
- **Start.** The body is held frozen until its first water sample arrives (a
  few frames), then released.

## How to use

```
RigidBody3D            mass, center_of_mass, not frozen
├─ CollisionShape3D    box, sphere, capsule, cylinder, convex or concave polygon
└─ GREBuoyantBody
```

1. Add a `GREBuoyantBody` as a child of the `RigidBody3D`, with the bow along −Z.
2. Set `draft`: how deep the hull's lowest point sits in calm water.
3. Set the drag: low `forward_drag` and high `sideways_drag` for a hull, about
   equal for debris.
4. Run. Turn on `debug_enabled` to see the probes and the water over each.

| Setting | Meaning |
| --- | --- |
| `draft` | Depth (m) of the hull's lowest point at rest; also how fast it bobs. |
| `probe_grid` | Probes across × along the hull; 0 picks a count from its proportions (about 16). More follow the waves under a long hull more closely. |
| `damping_ratio` | 0 bobs on and on, 1 settles without overshooting. |
| `forward_drag`, `sideways_drag` | How quickly (1/s) the water takes away speed along and across the hull. |
| `wake_strength` | Scales the waves and foam the body makes (1 as its motion makes them, 0 none). |
| `wave_response` | How much the body feels the waves bodies make, its own included (0 not at all, the default; 1 fully). |

- The collision shapes decide where the probes go, and their height is the
  most the body can be pushed under. Put a `CollisionShape3D` that should
  collide but not float the body (a seat, a mast) in the group
  `buoyancy_ignore` (`GREBuoyantBody.IGNORE_GROUP`). Shapes added through the
  shape-owner API rather than as `CollisionShape3D` children never count.
- Godot's own body damping (Project Settings > Physics > 3D > Default Linear
  Damp, 0.1/s) adds to the drag. Set the body's `linear_damp_mode` to
  **Replace** to keep only the water's (the boat template does).
- From code: `is_in_water()`, and `get_point_depth(global_point)` for how deep
  a point of the body is (e.g. a propeller; −INF before the first sample).
- The Scene dock warns about a frozen body, missing or unsupported collision
  shapes, a `draft` deeper than the hull and a centre of mass outside it.

## Limits

- Bodies feel the waves bodies make only with `wave_response` above 0, and
  only near the camera, where the ocean simulates them: farther away they
  float on the sea's waves alone.
- The water sees the hull's footprint as a superellipse fitted to the
  collision shapes' outline (pointed bows come out rounder).
- A body cannot capsize, flood or sink, and it floats level whatever its load.
- Splashes are not part of it yet.
