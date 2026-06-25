# Boat Water Foam Effects

This demo boat system adds lightweight, visual-only foam by manually increasing the ocean shader's local foam amount. It does not simulate fluid motion and does not modify the FFT wave data.

## Components

- `BoatWaterInteractor` creates two short bow foam streaks, one on each side of the bow.
- `BoatWakeTrail` records stern positions in world space and exposes them as fading foam sources.
- `SimpleBoatController` is only a demo movement controller for the parent `RigidBody3D`.
- `OceanSystem` collects all nodes in the `manual_water_foam_source` group and sends their foam sources to `water.gdshader`.

## Scene Setup

For a boat `RigidBody3D`, add these child nodes:

```text
BoatRigidBody3D
  BoatWaterInteractor      script: addons/floating_boat_template/boat_water_interactor.gd
  BoatWakeTrail            script: addons/floating_boat_template/boat_wake_trail.gd
  SimpleBoatController     script: addons/floating_boat_template/simple_boat_controller.gd, optional
```

The boat scene used by the demo is `demo/floating_box.tscn`.

`BoatWaterInteractor` and `BoatWakeTrail` automatically add themselves to `manual_water_foam_source`. The active `OceanSystem` scans that group every frame, so no explicit NodePath is needed for the foam effects.

## How It Works

Each source returns dictionaries from `get_manual_foam_sources()`:

```gdscript
{
	"position": Vector3(...),
	"radius": 0.3,
	"amount": 0.5,
	"direction": Vector3(...), # optional, for elongated sources
	"length": 1.2,             # optional, full capsule length
}
```

`OceanSystem` packs these into shader uniforms:

- `manual_foam_sources`: `center.x`, `center.z`, `radius`, `amount`
- `manual_foam_shapes`: `direction.x`, `direction.z`, `half_length`, unused

The water shader samples those sources in world XZ coordinates and blends the result into the existing `foam_factor`. This means manual foam uses the same `foam_color`, roughness, specular response, reflections, and distance fade path as regular ocean foam.

## Bow Foam

`BoatWaterInteractor` creates two capsule-shaped foam streaks angled outward and backward from the bow. This imitates the boat splitting water without using a local heightfield.

Important parameters:

- `bow_offset`: local bow position. Move this if foam starts too far forward or backward.
- `side_offset`: distance from centerline to each side streak.
- `bow_radius`: streak thickness.
- `bow_streak_length`: streak length.
- `outward_splay`: how much each streak angles away from the centerline.
- `bow_foam_amount`: maximum foam contribution before speed scaling.
- `min_speed` / `max_speed`: speed range used to fade the effect in.

## Stern Wake

`BoatWakeTrail` records stern positions in world space. Each point fades with age and expands over time. Newest points are submitted first so a long `lifetime` will not cause old wake points to fill the shader source limit and disconnect the wake from the boat.

Important parameters:

- `stern_offset`: local stern position.
- `point_spacing`: distance the boat must move before a new point is recorded.
- `lifetime`: how long points remain visible.
- `min_radius` / `max_radius`: foam source radius at low and high speed.
- `max_foam_amount`: maximum foam contribution before age and speed fading.
- `max_points`: hard cap on recorded points. Keep this below `MAX_MANUAL_FOAM_SOURCES` with room for bow foam and future effects.

## Tuning Notes

- If the wake disconnects from the boat, reduce `point_spacing`, reduce `lifetime`, or increase `max_points` while staying below the shader source limit.
- If bow foam looks too round, reduce `bow_radius` or increase `bow_streak_length`.
- If bow foam points sideways too much, reduce `outward_splay`.
- If effects look pasted on, lower `bow_foam_amount` and `max_foam_amount`; they blend through the normal water foam shader, but high values can still look artificial.
- If the effect disappears at long lifetimes, remember that `OceanSystem.MAX_MANUAL_FOAM_SOURCES` is currently `96`.

## Limitations

- Manual foam is visual only. It does not affect buoyancy, collision, or wave displacement.
- Sources are passed as a fixed-size uniform array, so this is intended for a small number of nearby boats.
- The effect follows world coordinates and is packed directly into water shader uniforms.
- The wake is made from overlapping foam sources, not a continuous texture simulation.

## Related Files

- `addons/floating_boat_template/boat_water_interactor.gd`
- `addons/floating_boat_template/boat_wake_trail.gd`
- `addons/floating_boat_template/simple_boat_controller.gd`
- `addons/ocean_system/ocean_system.gd`
- `addons/ocean_system/shaders/spatial/water.gdshader`
