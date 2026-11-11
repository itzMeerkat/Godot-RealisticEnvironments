# Ocean System

**English** · [简体中文](README.zh-CN.md)

An open ocean for Godot 4.8 Forward+. It has wind-driven FFT waves out to a
curved horizon, physically based water shading, foam and reflections, and the
wakes boats make. Gameplay code can query the water height on the GPU.

Requires `gre_core` and a `RenderingDevice` (Forward+). Without one
(Compatibility renderer, headless) the ocean reports an error and stays off.

## How it works

- **One sea state, several tiles.** A `GREWaveSpectrum` describes the sea: a
  wind-driven JONSWAP spectrum, corrected for water depth (TMA). The
  `GREWaveCascade`s are FFT tiles of this spectrum at different sizes (default
  250, 37 and 9 m). Each tile draws only its own band of wavelengths, so
  together they draw the spectrum exactly once, from long swell to short chop.
- **GPU wave synthesis.** Compute shaders advance each cascade's spectrum to
  the current time and run an inverse FFT. The output is a displacement map
  and a normal map (slopes and foam) with full mip chains. Small tiles update
  more often than large ones, and frames in between blend two FFT results.
- **Following the wind.** The wind comes from `wind_source_path`, or else from
  the spectrum's own settings. When it changes past a threshold, a new
  spectrum is generated in a spare slot and crossfaded in. The sea never jumps,
  and long swell turns toward a new wind more slowly than chop.
- **Mesh to the horizon.** The mesh is a quadtree of grid patches around the
  camera (CDLOD, drawn as one multimesh), finest near the camera. It bends with
  the earth's curve, so the sea ends at the real horizon. The vertex shader
  displaces it by every cascade. Far waves are filtered through mip levels, not
  faded out.
- **Shading.** Absorption and scattering in the water set its colour. Light
  through thin crests makes them glow, and the shader adds refraction,
  caustics and foam where waves compress. One rough-surface Fresnel weights
  every reflection: the sky with its clouds, stars, planets and atmosphere,
  the sun's highlight, and the scene (screen-space or planar).
- **Water queries.** The ocean registers a `GREWaterSurface` (see `gre_core`). All
  queries in a frame go to the GPU in one dispatch. They sample the same
  surface that is drawn and are read back asynchronously.
- **Interactive waves.** Hulls report themselves to the `GREWaterSurface`
  (`GREBuoyantBody` does), and a wave simulation around the camera draws the
  waves their motion makes: the Kelvin wake (a V of about 19.5° at any speed),
  the bow wave and the rings of a bobbing hull. A hull makes waves only by
  moving relative to the water, so floating with the swell makes none. Every
  wave travels at its real speed: the simulation moves each Fourier mode
  exactly, by the finite-depth dispersion relation, once per physics tick.
  Water queries leave them out unless their owner opts in
  (`GREWaterSurface.set_query_wave_response()`, `GREBuoyantBody.wave_response`);
  the water inside the owner's own hull then comes from a rim around it, so a
  hull never feels the water it displaces and nothing builds up.
- **Wake foam.** Hulls churn up foam on the same window: around the waterline
  and in a trail behind them, denser the faster they move through the water
  (not the deeper they sit), plus foam where wake crests grow steep. It drifts
  with the surface drift and fades over about 8 s, and it is drawn as the
  whitecaps are (lace, roughness, light), so `foam_intensity` scales it too.
- **Open hulls.** The water skips pixels a `GREWaterMask` lid marks in the
  stencil buffer (see `gre_core`), so it does not show inside open boats. Every
  water shader tier has the `stencil_mode` line; add it to a custom one.

The sea lies at `water_level`. The node's own transform is ignored.

## How to use

1. Enable **Core** and **Ocean System** in **Project Settings > Plugins**, then
   instance `ocean_system.tscn`. Leave the node at the origin, unrotated and
   unscaled, and set the height with `water_level`.
2. Use a `Camera3D` whose `far` reaches past the horizon. From 10 m up the
   horizon is 11 km away, from 100 m up 36 km; the demo uses 60 km.
3. Optional: set `wind_source_path` to a `GREWindSystem` and `sky_source_path` to
   a `GRESkySystem`. Without them, the waves use the spectrum's own wind and the
   water reflects the **Manual Sky** colours.

`gre_ocean_environment` does all of this for you.

### Settings

| Group | Contents |
| --- | --- |
| `water_level` | Height of the still water. |
| Waves | `spectrum`: wind (used without a wind source), `fetch_length` (the sea stops growing once fully developed), `water_depth`, `swell`, `spread`, `detail`, `displacement_scale` (1 = physical height, as the demo uses), and how fast the sea follows changes. Save one as a `.tres` to reuse a sea state. `cascades` (at most 8): `tile_length`, plus foam (`whitecap`, `foam_generation`, `foam_lifetime`). Use tile lengths that don't divide each other, the largest at least 1.5 times the peak wavelength (the ocean warns otherwise). Retune `whitecap` after changing `displacement_scale`. |
| Water | `water_absorption`, `water_scattering`, `water_scattering_anisotropy`: the only source of the water's colour. |
| Surface | `clear_roughness`, `short_wave_slope_scale` (wind ripples too small to simulate), `normal_scale` (1 = physical slopes). |
| Foam | `foam_color`, `foam_intensity`, `foam_roughness`, the foam pattern texture and its tile size. |
| Sky | `sky_source_path`, reflection strength and F0, the sun's highlight; **Manual Sky** values for when there is no sky source. |
| Reflections | `reflection_mode`: `SKY_ONLY`, `SCREEN_SPACE` or `PLANAR` (default), plus the planar reflection's resolution and clipping. Render layer 20 (`reflection_water_layer`) is reserved for the water. |
| Interactive Waves | `interaction_map_size` (Off, 256, 512 or 1024 cells) and `interaction_cell_size` (default 0.25 m): together the window around the camera where hulls make waves (512 × 0.25 m = 128 m). The window is centred on the camera (turning the camera changes nothing) and fades out at its edge. |
| Quality | `shader_quality` (`LOW`, `MEDIUM`, `HIGH`), `simulation_map_size` (128–1024), `max_wave_phase_step`, `fragment_cascade_limit`, `use_bicubic_normals`, `mesh_base_cell_size`. |
| Material | `water_material`: the template the ocean copies. The ocean renders with a private duplicate. |

From code: `get_wind_speed()` and `get_wind_direction_degrees()` give the wind
the waves follow. `get_water_material()` returns the material actually used. To
show single shading terms, set its `water_debug_view` uniform (1–18) at
runtime; 16 and 17 show the interactive waves' height and slopes, 18 their
foam.

### Water queries

Use `GREWaterSurface.find(node)` from `gre_core` (its README has the example), never
`GREOceanSystem`. Results give the height, normal, displacement and velocity of
the drawn surface. `get_surface_drift()` is the drift that moves the foam
downwind, 3 % of the wind speed; `gre_buoyancy_system` carries floating bodies
with it.

### Sky source

`sky_source_path` accepts a `GRESkySystem` or any node with these methods. Only
the first one is required; the ocean falls back to the **Manual Sky** values
for missing ones.

| Method | Gives the water |
| --- | --- |
| `get_sun_direction()` | Direction toward the sun (world space). |
| `get_sun_visibility()` | Share of the sun reaching the sea (0–1). |
| `get_cloud_cubemap()` | Clouds seen from the sea: rgb premultiplied radiance at the cloud, a opacity, full mips; `null` = none. |
| `get_star_cubemap()`, `get_star_basis()`, `get_star_radiance_scale()` | Stars: radiance cubemap, world-to-cubemap rotation, scale to scene radiance. |
| `get_planet_directions()`, `get_planet_irradiance()` | Up to 8 point lights, reflected as glints. |
| `get_atmosphere_sky_volumes()`, `get_atmosphere_light()` | The sky seen from the sea, through the atmosphere. Without them the water reflects a gradient from `manual_sky_top_color` to `manual_sky_horizon_color`. |
| `get_atmosphere_view_volumes()`, `get_atmosphere_view_observer()`, `get_atmosphere_view_max_distance()` | The haze between the camera and the water. |
| `set_camera_underwater(underwater)` | Called when the camera goes under the waves or comes back up, so a sky drawn on screen after the water can leave off. |
| `get_sky_irradiance()` | The sky's irradiance on a level surface (scene units, negative while unknown), read every frame: the ambient light of what the planar reflection shows, which otherwise would reflect black wherever the sun doesn't reach it. Without it, the middle of `manual_sky_top_color` and `manual_sky_horizon_color`. |

If the source has a `lighting_changed` signal, the ocean reads it only when
that signal fires (emit it after every change). Otherwise it reads it every
frame.

## Limits

- Below the water the camera sees through the water (its colour and haze, light
  shafts from the waves) and the surface from under it (Snell's window, total
  internal reflection). The camera counts as underwater by the wave height at its
  position, so a lens half in the water shows one or the other. A rough sea clouds
  that view with bubbles and stirred-up matter, following the wind
  (`underwater_storm_churn`, `underwater_churn_wind`); seen from above the water looks
  the same.
- One ocean per world, with one depth for the whole sea (no shores).
- Hulls make waves only inside the window around the camera (about 64 m each
  way by default), at most 16 at once (the nearest). A battleship's long wake
  needs a coarser second window, which is not there yet.
- Only the drawing is curved. Queries and reflections treat the sea as flat.
- No splashes yet.
