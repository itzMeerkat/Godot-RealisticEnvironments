# Ocean Environment

A drop-in open ocean: `ocean_environment.tscn` holds the wind, the sky (sun,
moon, stars, atmosphere, clouds), the ocean and the exposure, already wired to
each other. It is the quickest way to a working sea.

Depends on `core`, `wind_system`, `sky_system`, `ocean_system` and
`exposure_system`.

## Quick start

1. Copy those addons and this one into `addons/` and enable them in
   **Project Settings > Plugins** (the Sky System plugin adds the project
   settings the sky needs).
2. Use the Forward+ renderer. Keep physical light units off.
3. Instance `ocean_environment.tscn` in your scene. Remove any other
   `WorldEnvironment` or `DirectionalLight3D`.
4. Add a `Camera3D` whose `far` reaches beyond the horizon (5 km at 2 m above
   the water, 23 km at 40 m; the demo uses 60 000 m), and run.

## What is inside

```
OceanEnvironment (Node3D, OceanEnvironment)   sea_level for the whole environment
├─ WindSystem           wind speed, direction and gusts
├─ SkySystem            sky_system.tscn; clouds drift with WindSystem
├─ Ocean                ocean_system.tscn; reflects SkySystem, waves follow WindSystem
└─ ExposureController   exposes for SkySystem's light, on SkySystem/WorldEnvironment
```

- `sea_level` (on the root) sets both `Ocean.water_level` and
  `SkySystem.sea_level`, which must match. Set it here rather than on the
  children.
- Everything else is set on the systems themselves: right-click the instance
  and choose **Editable Children**, then select a child. Common settings:
  `SkySystem.time_of_day`, `cycle_enabled`, `latitude_degrees`, `day_of_year`,
  `cloud_preset`; `WindSystem.wind_speed`, `wind_direction`, `gust_strength`;
  `Ocean.parameters` (wave cascades), `shader_quality`, `reflection_mode`;
  `ExposureController.exposure_compensation_ev`. Each system's README lists
  the rest.
- `OceanEnvironment` also gives scripts the systems: `wind`, `sky`, `ocean`,
  `exposure`.
- Don't rotate or scale the environment (the ocean must stay level); moving it
  sideways is fine.

To float things on the water, see `buoyancy_system`; for a ready boat, see
`boat_template`.

## Files

`ocean_environment.tscn`, `ocean_environment.gd` (`OceanEnvironment`),
`ocean_environment_plugin.gd`, `plugin.cfg`.
