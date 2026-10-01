# Sky System

Day/night sky with astronomically positioned sun and moon, directional lights,
a procedural sky shader, a rotating starfield, volumetric clouds with weather
presets, and getters that other systems (the ocean) read for lighting.

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

## Clouds

Volumetric, raymarched clouds that drift with the wind, form and dissipate on
their own, light correctly from sunrise to night (including clouds still lit
after sunset) and show up in the sky, behind the stars, in the ambient light
and in the ocean's sky reflection. They need a RenderingDevice (Forward+ or
Mobile renderer).

- `clouds_enabled`, `cloud_preset` (a `CloudPreset`). Presets ship in
  `cloud_presets/`: `clear`, `fair`, `cloudy`, `overcast`, `rain`, `storm`.
- In the editor a new `cloud_preset` applies at once. At runtime it blends in
  over `cloud_transition_seconds`; `transition_clouds_to(preset, seconds)`
  does the same with an explicit duration. Every `CloudPreset` field
  interpolates (`CloudPreset.BLENDED_PROPERTIES`).
- Wind: `cloud_wind_source_path` (duck-typed wind source, speed scaled by
  `cloud_wind_speed_multiplier`), or `cloud_wind_speed` /
  `cloud_wind_direction` without one.
- Lighting: `cloud_light_intensity`, `cloud_ambient_intensity`. A preset also
  scales the scene: `sun_light_scale` multiplies the sun/moon lights and
  `get_sun_visibility()`; `ambient_light_scale` multiplies the environment
  ambient energy.
- Quality: `cloud_cubemap_size`, `cloud_update_stride`, `cloud_view_steps`,
  `cloud_light_steps`, `cloud_max_distance`, `cloud_fade_distance`. Defaults
  (1024, stride 4, 64/6 steps) cost about 0.5 ms (fair) to 1.3 ms (storm) of
  GPU time on an RTX 4070 Ti.
- `get_cloud_cubemap()` returns the cloud texture (or `null` while clouds are
  off) for other shaders; `get_cloud_state()` the blended weather on screen.

### Limits

- Clouds are drawn as seen from below the cloud base: the camera altitude is
  clamped under it, so flying into or above the clouds is not supported.
- Clouds do not cast shadows on the scene; heavy cover only dims the lights
  through `sun_light_scale` / `ambient_light_scale`.
- A refreshed texel blends with its previous value, so fast changes (a preset
  jump, a fast day cycle) settle over roughly half a second.

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

### How the clouds work

`CloudRenderer` runs three compute shaders on the main RenderingDevice
(`shaders/compute/`):

1. `cloud_noise_bake.glsl`, once: tiling 3D noise. Shape (128³, Perlin-Worley
   eroded by Worley fbm) forms cloud bodies, detail (64³, Worley fbm) carves
   the edges. Both are stretched to a roughly uniform 0–1 range, so a coverage
   of *c* covers about *c* of the sky.
2. `cloud_weather.glsl`, every frame: a 512² **weather map** centred on the
   camera (r coverage, g cloud type, b density). It is the only thing that
   says where clouds are; the raymarcher only reads it. Today it is noise in
   world space, moved by the wind offset and reshaped over time by the
   evolution time (the noise's third axis), so cloud fields drift, grow and
   fade. A future cloud simulation (advection, growth, rain-out) replaces this
   pass and keeps the map's format.
3. `cloud_raymarch.glsl`, every frame: marches rays through a spherical cloud
   shell (planet radius 6360 km, so the layer curves down to the horizon)
   into the **upper half of a cubemap** around the camera. Per sample:
   coverage-thresholded shape noise times a height profile chosen by cloud
   type (stratus thin and low, cumulonimbus filling the layer), eroded by
   detail noise; a short march toward the sun or moon for self-shadowing;
   multiple scattering as three octaves of weaker extinction and flatter
   dual-lobe Henyey-Greenstein phase; ambient light from above attenuated by
   two-stream diffusion through the cloud column, plus light from below that
   fades as the cover closes; the planet's shadow for twilight. Distant
   clouds fade into the sky (aerial perspective). Steps are spaced
   quadratically and jittered per texel and frame.

Each frame refreshes one texel in every `cloud_update_stride`² block (an
ordered-dither sequence), blended 60/40 with the texel's previous value. The
cubemap is indexed by view direction, so turning the camera costs nothing;
the clouds are kilometres away, so moving the camera a few hundred metres
between refreshes does not show either.

The cubemap stores premultiplied radiance in rgb and opacity in a. The sky
shader composites `sky * (1 - a) + rgb` (sun and moon disks included), the
starfield fades stars by `1 - a`, and the ocean does the same in its
procedural sky reflection. The radiance map (ambient light, reflections)
follows because the sky material's cloud parameters are re-sent once per full
refresh. Those parameters go through `RenderingServer.material_set_param`, so
the runtime texture is never stored in `materials/*.tres`.

## Files

`sky_system.gd` / `.tscn`, `sky_profile.gd` (`SkyProfile`),
`cloud_preset.gd` (`CloudPreset`), `cloud_presets/*.tres`,
`cloud_renderer.gd` (`CloudRenderer`), `shaders/compute/cloud_*.glsl` and
`cloud_noise.glslinc`, `shaders/sky.gdshader`, `shaders/starfield.gdshader`,
`shaders/celestial_disk.gdshader`, `materials/*.tres`.
