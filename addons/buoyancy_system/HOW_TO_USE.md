# Buoyancy System HOW TO USE

## Setup

1. Add an `OceanSystem` to the scene.
2. Add a `RigidBody3D` for the floating object.
3. Add `BuoyantBody` as a child of the rigid body.
4. Add `BuoyancyProbeVolume` under the rigid body.
5. Assign one or more low-poly hull/proxy mesh roots to `source_paths`.
6. Keep the design waterline at local `waterline_y = 0.0`, then toggle `generate_physical_probes_now`, `generate_fx_probes_now`, or `generate_all_probes_now` in the Inspector.

The generator creates editable children under `GeneratedProbes`:

- `BuoyancyProbeNode` physical probes apply buoyancy, damping, and drag. They do not define weight or center of mass.
- `BuoyancyFxProbeNode` contact probes only track water entry/exit and are intended for foam, splash, and spray effects.

Generation is editor-only. Runtime uses saved probe nodes and will not create missing probes automatically outside the editor.

## Coordinate Convention

The first version assumes a local horizontal design waterline:

- Local `Y = waterline_y` is the static waterline plane.
- Local `X = symmetry_plane_x` is the hull symmetry plane. With the default `symmetry_plane_x = 0.0`, probes mirror across the local YZ plane.
- Local `Z` is the longitudinal axis.
- `bow_is_negative_z = true` means the bow is toward local `-Z`.

Use a low-poly closed or mostly closed hull/proxy mesh. Decorative meshes, railings, cabins, or non-manifold visual assets can produce noisy waterline intersections.

## Probe Generation

`BuoyancyProbeVolume` intersects the source mesh triangles against `Y = waterline_y`, projects the intersection segments to XZ, then builds a 2D convex hull from those waterline points for probe placement. This avoids fragile pairing on complex or fragmented intersection curves. When `debug_draw` is enabled in the editor, `show_waterline_intersection` highlights the raw intersection curve and `show_waterline_convex_hull` highlights the generated convex hull.

Physical probes are placed on the scanned left/right boundary of the waterline convex hull. When `mirror_across_yz_plane` is enabled, left/right probes are mirrored around `X = symmetry_plane_x`; the generator intentionally favors symmetry over exact containment, so a small amount of overshoot outside the original intersection is acceptable. The `physical_probe_count` is the target count; odd counts add one centerline probe.

FX probes are generated separately from physical probes and sampled on the waterline edge. They are tagged automatically as `bow`, `side`, or `stern` based on their local Z position and `bow_is_negative_z`.

Important generation parameters:

- `generated_buoyancy_height`: vertical water column height represented by each generated physical probe.
- `generated_max_submerged_volume_cubic_meters`: maximum displaced volume assigned to each generated physical probe.
- `longitudinal_margin_fraction`: avoids placing physical probes exactly at bow/stern tips.
- `generated_fx_display_radius`: editor display radius used by generated FX/contact probes.

Each physical probe can be edited manually after generation. Move the node to change the sample point. Edit `max_submerged_volume_cubic_meters`, `buoyancy_height`, and damping/drag multipliers to tune behavior. Object weight comes only from the parent `RigidBody3D.mass` and `RigidBody3D.center_of_mass` settings.

## Runtime Behavior

`BuoyantBody` automatically collects child `BuoyancyProbeVolume` nodes. It queries all physical and FX probes in one `OceanSystem.sample_water_surface_batch()` call per physics tick.

Only physical probes apply forces. FX probes update contact state and signals only.

Physical force uses:

- `max_submerged_volume_cubic_meters` is the probe's displaced volume when fully submerged.
- submersion is `clamp(immersion_depth / buoyancy_height, 0, 1)`
- displaced volume is `max_submerged_volume_cubic_meters * submersion`
- water normal as buoyancy direction
- relative vertical velocity for vertical damping
- body forward/right axes for longitudinal and lateral water drag
- `max_probe_acceleration` as a per-probe force safety cap

## Contact Events

`BuoyancyProbeVolume` and `BuoyantBody` both expose:

```gdscript
signal probe_entered_water(probe: Node, state: Dictionary)
signal probe_exited_water(probe: Node, state: Dictionary)
```

The `state` dictionary includes `tag`, `world_position`, `water_position`, `depth`, `submersion`, `is_wet`, `force`, `normal`, `surface_velocity`, and `is_fx_probe`.

Hysteresis is controlled by:

- `enter_depth_threshold`
- `exit_depth_threshold`
- `min_event_interval`

Entry/exit signals are edge-triggered only. Do not emit per-probe continuous state every frame; callers that need continuous data should read `get_probe_states(tag)` or `get_wet_probe_states(tag)`.

## Foam And Effects

The buoyancy system does not render foam or particles directly. It exposes water-contact state.

`BoatWaterInteractor` can read `bow` FX probes from `BuoyantBody.get_probe_states("bow")` and convert them to Ocean's existing `manual_water_foam_source` data. If no bow probes are available, it falls back to its fixed `bow_offset` behavior.

Particle splash/spray systems should connect to `probe_entered_water` and `probe_exited_water`, then filter by `state.tag` and `state.is_fx_probe`.

## Performance Notes

The expensive operation is probe count, not signal dispatch. Ocean queries are batched on the GPU, but each probe still creates CPU-side state and may apply a force.

Use practical budgets:

- Small buoy: 4-8 physical probes, 0-8 FX probes.
- Small boat: 8-16 physical probes, 12-32 FX probes.
- Larger vessel: 16-48 physical probes, 24-64 FX probes.

Entry/exit signals are low frequency after hysteresis. Avoid per-frame signal emission for every probe; use state polling for continuous foam intensity or debug UI.

## Water Cutout

Visual water cutout is intentionally separate from buoyancy. Add `WaterCutoutHullLOD` under the floating object when the ocean surface needs to be hidden inside the hull.
