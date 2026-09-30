# Sky System

Day/night sky with astronomically positioned sun and moon, directional lights,
a procedural sky shader, a rotating starfield, and getters that other systems
(the ocean) read for lighting.

## Quick start

Instance `sky_system.tscn`. It contains a `WorldEnvironment` with the sky
material, `SunLight` / `MoonLight` (`DirectionalLight3D`), optional
`SunVisual` / `MoonVisual` meshes and a `Starfield` sphere. Remove any other
`WorldEnvironment` or directional light from the scene.

To drive the ocean, set `OceanSystem.sky_source_path` to this node.

## Key exports (`SkySystem`)

- `time_of_day` 0–1: 0 midnight, 0.25 sunrise, 0.5 noon, 0.75 sunset.
  `cycle_enabled` + `cycle_duration_seconds` advance it at runtime;
  `advance_calendar_with_cycle` also advances `day_of_year` and
  `lunar_age_days`.
- **Astronomy** — `latitude_degrees`, `day_of_year`, `lunar_age_days`
  (0 new, ~14.77 full), `north_offset_degrees` (rotate celestial north around
  world up; default north is −Z), `axis_tilt_degrees`, energy multipliers,
  `star_brightness`.
- `profile` — a `SkyProfile` resource of gradients (sun, moon, sky top, sky
  horizon colours) and curves (sun/moon/ambient energy, star visibility).
  Missing entries are filled with built-in defaults.
- **Visuals** — `render_bodies_in_sky` draws sun/moon disks in the sky shader
  (default) instead of the billboard meshes; `follow_active_camera` keeps the
  starfield and meshes centred on the camera.

## Getters and signals

`get_sun_direction()`, `get_moon_direction()` (unit vectors pointing *toward*
the body), `get_sun_color()`, `get_sky_top_color()`, `get_sky_horizon_color()`,
`get_sky_ground_horizon_color()`, `get_sky_ground_bottom_color()`,
`get_sun_visibility()`, `get_moon_visibility()`, `get_moon_phase()`,
`get_night_factor()`, `get_star_visibility()`, `get_time_of_day()`.

Signals: `time_of_day_changed(time_of_day)`, `lighting_changed`.

The getters return values cached by the last update, so they are free to call.
`lighting_changed` fires after every update; `OceanSystem` re-reads the sky only
then. When the day cycle advances `time_of_day`, `day_of_year` and
`lunar_age_days` together, the sky updates once for all three.

## How it works

- The sun's declination comes from `day_of_year` and axial tilt; its hour angle
  from `time_of_day`. The moon's ecliptic longitude is the sun's plus the lunar
  phase angle, with a 5.145° inclined orbit. Equatorial coordinates are
  converted to local horizontal (east, up, north) for `latitude_degrees`, then
  rotated by `north_offset_degrees` into world space.
- Colours are not sampled at the raw `time_of_day`. `_get_profile_sample_time()`
  maps the *actual sun height* (and whether it's morning or evening) onto the
  profile's 0/0.25/0.5/0.75 keys, so seasons and latitudes that shift sunrise
  still get sunrise colours at the horizon.
- Every change updates the lights (colour, energy, direction; hidden below a
  small energy), environment ambient light, and the sky shader uniforms.
  Starfield visibility fades with twilight and is washed out by a bright moon;
  the starfield rotates with local sidereal time.
- At runtime the environment, sky, sky material and visual materials are
  duplicated so several instances don't share state.

## Files

`sky_system.gd` / `.tscn`, `sky_profile.gd` (`SkyProfile`),
`shaders/sky.gdshader`, `shaders/starfield.gdshader`,
`shaders/celestial_disk.gdshader`, `materials/*.tres`.
