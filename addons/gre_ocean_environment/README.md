# Ocean Environment

**English** · [简体中文](README.zh-CN.md)

A drop-in open ocean. `ocean_environment.tscn` contains the wind, the sky, the
ocean and exposure, already connected to each other.

Requires `gre_core`, `gre_wind_system`, `gre_sky_system`, `gre_ocean_system` and
`gre_exposure_system`.

## How it works

```
GREOceanEnvironment        sea_level for the whole environment
├─ GREWindSystem
├─ GRESkySystem            clouds drift with GREWindSystem
├─ Ocean                waves follow GREWindSystem, reflects GRESkySystem
└─ GREExposureController   exposes for GRESkySystem's light
```

The scene only sets the paths between the systems. `GREOceanEnvironment` adds a
single setting, `sea_level`, which sets both the ocean's `water_level` and the
sky's `sea_level` (the two must match).

## How to use

1. Copy the addons above and this one into `addons/`, and enable them in
   **Project Settings > Plugins**.
2. Use the Forward+ renderer, with physical light units off.
3. Instance `ocean_environment.tscn`. Remove any other `WorldEnvironment` or
   `DirectionalLight3D`.
4. Add a `Camera3D` whose `far` reaches past the horizon (the demo uses
   60 000 m), and run.

- Set the sea's height with `sea_level`. Don't move, rotate or scale the
  environment.
- To change anything else (time of day, weather, wind, waves, quality,
  exposure), right-click the instance, turn on **Editable Children**, and
  edit the systems. Their READMEs explain the settings.
- Scripts reach the systems as `wind`, `sky`, `ocean` and `exposure`, e.g.
  `$OceanEnvironment.sky.time_of_day = 0.75`.

For a ready-made boat, see `gre_boat_template`.
