# Sky System

Day/night sky with astronomically positioned sun and moon, directional lights,
a physically based atmosphere (the blue sky, twilight, haze and fog over the sea)
that draws the whole sky, a rotating starfield, volumetric clouds with weather
presets, a light meter for exposure, and getters that other systems (the ocean)
read for lighting.

Requires the `core` addon (`addons/core`).

## Visual effects

- **Sun and moon:** placed astronomically for latitude, date and time, with the
  moon's phase. The lights are coloured and dimmed only by the atmosphere: pale
  yellow at noon, about 3000 K low down, red at the horizon. Sun and moon disks
  are drawn at their real radiance.
- **Physical atmosphere:**
  - air (Rayleigh), ozone and sea haze (Mie forward lobe), with multiple
    scattering and light reflected from the sea;
  - blue sky, twilight and the earth's shadow;
  - a hazed curved horizon;
  - moonlit skies handed over smoothly from twilight.
- **Weather haze and sea fog:** visibility, height and glow size, blended with
  the weather presets.
- **Aerial perspective:** distance haze on every opaque pixel. Transparent
  materials haze themselves.
- **Cloud light on the air:** clouds shade the haze (a sun behind a cloud loses
  its glow). Under an overcast deck, the cloud base lights the air and the sea.
- **Volumetric clouds:**
  - raymarched on a curved shell; they drift with the wind and grow and
    dissipate;
  - seven blended weather presets, from `clear` to `storm` and `sea_fog`;
  - single and multiple scattering, a forward-scattering glow (silver lining),
    the earth's shadow in twilight, and clouds lit after sunset.
- **Stars:** the 9,096 naked-eye stars at their true positions, turning with
  sidereal time.
  - Brightness is physical, so the exposure decides which stars show.
  - Blackbody colours; extinction and reddening toward the horizon.
  - Twinkling that depends on air mass, and bright stars that bloom wider.
- **Milky Way:** the light of stars fainter than the catalog's, from NASA's
  Deep Star Maps.
- **Airglow:** the upper atmosphere's own light, brightening toward the
  horizon.
- **Planets:** Mercury to Saturn from orbital elements, with physical
  magnitudes and colours.
- **Scene lighting:** ambient light and reflections from the sky's radiance
  map, plus a light meter that drives the exposure.

## Quick start

Enable **Sky System** (and **Core**) in Project Settings > Plugins. Enabling it
declares the atmosphere's global shader uniforms in `project.godot` (the sky's
shaders do not compile without them; see [Atmosphere](#atmosphere)) and turns
on debanding (night skies band into contours without it). It only adds what is
missing.

Instance `sky_system.tscn`. It contains a `WorldEnvironment` with the sky
material and a compositor holding the aerial perspective (`AerialPerspectiveEffect`),
`SunLight` / `MoonLight` (`DirectionalLight3D`), optional
`SunVisual` / `MoonVisual` meshes; the stars are an internal child built at
startup (see [Stars](#stars)). Remove any other
`WorldEnvironment` or directional light from the scene.

To drive the ocean, set `OceanSystem.sky_source_path` to this node.

Light levels are physical (a sunny day is about 10⁵ times as bright as a
moonlit night), so the scene needs an exposure that follows them: an
`ExposureController` (`addons/exposure_system`) pointed at this node, or your
own controller reading `get_scene_illuminance()` (see [Exposure](#exposure)).
Without one, nights and heavy overcast render near black.

## Key exports (`SkySystem`)

- `time_of_day` 0–1: 0 midnight, 0.25 sunrise, 0.5 noon, 0.75 sunset.
  `cycle_enabled` + `cycle_duration_seconds` advance it at runtime;
  `advance_calendar_with_cycle` also advances `day_of_year` and
  `lunar_age_days`.
- **Astronomy** — `latitude_degrees`, `day_of_year`, `lunar_age_days`
  (0 new, ~14.77 full), `north_offset_degrees` (rotate celestial north around
  world up; default north is −Z), `axis_tilt_degrees`,
  `sun_energy_multiplier` / `moon_energy_multiplier` (scale the lights'
  energy above the atmosphere).
- **Stars** — `star_catalog`, `star_brightness`, `star_cubemap_size` (see
  [Stars](#stars)).
  The sky's colours, the lights and the ambient light all come from the
  atmosphere.
- **Sun and moon light** — both are white
  above the atmosphere (`SkySystem.SOLAR_ENERGY` 1.3 for the sun's 128 000 lux,
  `MOON_ENERGY` for the full moon's 0.27 lux, about 1/470 000 of it, times the
  lit share of the disk). The atmosphere colours and
  dims them on the way down: the scene's lights get the transmittance from
  space to the sea along their direction (`_get_atmosphere_transmittance()`,
  the CPU copy of the transmittance LUT) times the share of the disk above the
  horizon, split into `light_color` (brightest channel 1, also
  `get_sun_color()`) and `light_energy`. A clear sun is pale yellow high up
  (energy about 1.1 at 55° in clear air), about 3000 K at 6° and deep red at the horizon; haze
  dims it further. Clouds get the light at the middle of their layer, so they
  stay lit after the sea has lost the sun. A light below 0.1 % of the other's
  is hidden (the moon by day), as it would only cost a shadowed light.
- **Visuals** — `render_bodies_in_sky` draws sun/moon disks in the sky shader
  (default) instead of the billboard meshes. The disks have their real
  radiance (the light's irradiance through the air over the disk's solid
  angle; the haze and clouds dim it in the sky shader), so the sun is the
  brightest thing in view; their glow comes from the atmosphere. The radiance
  map that lights and reflects the scene keeps faint disks and halos
  (`radiance_sun_disk_strength`, `radiance_sun_halo_strength`, times the
  radiance of a white diffuser in the body's light), as a disk that bright
  would sparkle in glossy reflections; `follow_active_camera` keeps those
  meshes centred on the camera. `sea_level`: world height of the
  sea. The sea's horizon is `√(2h/R)` below eye level for a camera `h` above it,
  and the sky reaches down to there; the haze is densest at it. The sky reads the
  camera's altitude from the atmosphere instead of `POSITION`: a sky shader that
  reads `POSITION` makes Godot re-render the radiance map on every camera move
  (in REALTIME mode). The `Sky` uses INCREMENTAL mode, and SkySystem refreshes
  the radiance map when the lighting, the clouds (once per full refresh) or the
  camera's altitude (by more than 10 % or 2 m) change.

## Stars

The real night sky: the 9,096 stars of the Yale Bright Star Catalogue (every
star the naked eye can see, to magnitude ~6.5) at their true positions, turning
with the local sidereal time for `latitude_degrees`, `day_of_year` and
`time_of_day` (Polaris stands at the latitude's altitude due north; precession
since J2000 is ignored).

- **Brightness is physical.** A star of magnitude m gives
  `128 000 · 10^(−0.4 (m + 26.74))` lux above the atmosphere (the sun's
  magnitude ties it to `SOLAR_ILLUMINANCE_LUX`), in the scene's light units and
  pre-exposed. So the exposure decides what shows, with no visibility curve:
  nothing by day, the brightest stars first at dusk, the faint ones washed out
  by a bright moon. `star_brightness` multiplies it (1 = physical).
- **The eye's sensitivity to points:** a screen shows a star by its contrast
  with the background (Weber's law), while the dark-adapted eye's threshold
  grows only with the background's square root (de Vries–Rose). The starfield
  (stars and planets, not the Milky Way) is multiplied by
  `sqrt(scene lux / 0.002)`, between 1 and 16 (`STAR_GAIN_*`; above ~0.5 lux
  the cones' Weber law holds again): under a full moon stars stay visible to
  about magnitude 4, as they do to the eye.
- **Colour** is the blackbody colour of the star's B−V index (Ballesteros 2012),
  luminance 1: blue-white Rigel, orange Betelgeuse.
- **Atmosphere:** each star is dimmed and reddened per channel by the
  atmosphere's transmittance along its direction (from the camera's view
  volume), so stars fade and turn orange toward the horizon and vanish below
  the sea's horizon; clouds hide them by their opacity.
- **Twinkling** (`CloudPreset.star_scintillation`, weather): a log-normal flicker
  whose spread grows with the air mass to the power 1.5 (Young 1967), so stars
  near the horizon flicker strongly and flash in colour while those overhead
  stay nearly steady.
- **Drawing:** one camera-facing quad per star (`shaders/starfield.gdshader`),
  placed at infinity on the far plane so every surface hides it. The star's
  light is spread over a gaussian of 0.7 px (energy kept, so its brightness
  does not depend on the resolution); a star that would burn out widens it up
  to 3×, as bright stars look bigger to the eye. Quads of stars too faint to
  show collapse in the vertex shader. Cost: about 36 000 vertices and a few
  pixels per star.

`star_catalog` is a `StarCatalog` resource (J2000 directions, V magnitudes,
colours). `stars/bright_star_catalog.tres` is baked by
`tools/bake_star_catalog.py` from the Bright Star Catalogue, 5th Revised Ed.
(Hoffleit & Warren 1991; CDS catalogue V/50); any other catalog baked to the
same format works.

**The Milky Way** is the light of the stars too faint for the catalog: NASA SVS's
Deep Star Maps 2020 "Milky Way background" (Gaia DR2, Hipparcos and Tycho-2 stars
fainter than V = 8; https://svs.gsfc.nasa.gov/4851), baked by
`tools/bake_milky_way.py` into `stars/milky_way.exr` (2048 × 1024 plate carrée in
J2000 right ascension and declination, rgb in µcd/m², imported as BC6H with
mips, 2.8 MB). Its units are not published, so the bake calibrates it: its mean
over the sky is the integrated starlight the catalog lacks (~100 S10(V) for all
stars, Benn & Ellison 1998, less the catalog's 23), which reproduces their
latitude profile (about 270 S10 in the plane, 13 at high latitudes). The sky
shader adds it to space (`milky_way_radiance()`), so the atmosphere dims it
and the clouds hide it like the sun and the moon; `star_brightness` scales it
with the stars. The map is public domain; credit: NASA/Goddard Space Flight
Center Scientific Visualization Studio. Gaia DR2: ESA/Gaia/DPAC.

**Airglow** is the upper atmosphere's own light (oxygen, sodium and OH
emission at 85–100 km), the main light of a moonless sky. The atmosphere's view
pass treats it as a thin shell at 90 km of zenith luminance 1.3·10⁻⁴ cd/m²
(22.3 V mag/arcsec², `SkySystem.AIRGLOW_ZENITH_LUMINANCE`) times
`airglow_brightness` (the solar cycle: ~0.5 at minimum, 2 at maximum): a ray
that reaches space sees it times the van Rhijn factor (its slant path through
the shell, up to ~6× near the horizon), dimmed by the air below. So the sky
brightens from the zenith toward ~15° elevation and darkens and reddens below
that, the sea reflects it, and the light meter and the radiance map include
it. Its colour is the line spectrum's (yellow-green, as cameras record it; the
eye sees a dark sky grey, which is the exposure's business).

**Planets.** Mercury, Venus, Mars, Jupiter and Saturn, placed for `year` and
`day_of_year` (the day cycle advances `year` when the day wraps; valid 1800–2050)
from JPL's approximate Keplerian elements (Standish, "Approximate Positions of
the Planets"): heliocentric orbits, geocentric directions in the J2000
equatorial frame, so they turn with the stars. Their magnitudes follow their
distances and phase angles (Meeus, *Astronomical Algorithms* ch. 41; Saturn's
rings by their tilt toward the earth); for 2000-01-01 12:00 they land within an
arcminute of the ephemeris (Venus −4.1, Jupiter −2.5). Colours come from their
B−V indices like the stars'. They are drawn by the starfield as extra quads
that do not twinkle (their disks average the turbulence out) and are left out
for cameras below `sea_level`: the water reflects them itself, as glints
(`get_planet_directions()`, `get_planet_irradiance()`), so the mirrored
planar-reflection camera must not add a second copy. Venus in the dusk lays a
glitter path on the sea.

**Reflections.** `get_star_cubemap()` holds the same stars for consumers
that draw their own sky (the ocean): a cubemap of `star_cubemap_size`² texels
per face (256: about 4 MB with mips), radiance in cd/m² above the atmosphere in
the catalog's frame, each star spread bilinearly over the four texels around
it (energy kept), plus the Milky Way (sampled at 64² per face, scaled up),
mips box-filtered. `get_star_basis()` turns world directions
into its frame and `get_star_radiance_scale()` its values into scene radiance
(`star_brightness` included). It is built once; only the basis turns with the
sky. The starfield itself is also drawn by other cameras (the ocean's mirrored
planar-reflection camera), so the water weighs the cubemap by what the planar
reflection does not cover.

The starfield is an internal child created at startup (in the editor too) and
never saved with the scene; its material is a private copy of
`materials/starfield.tres`.

## Clouds

Volumetric, raymarched clouds that drift with the wind, form and dissipate on
their own, light correctly from sunrise to night (including clouds still lit
after sunset) and show up in the sky, behind the stars, in the ambient light
and in the ocean's sky reflection. They need a RenderingDevice (Forward+ or
Mobile renderer).

- `clouds_enabled`, `cloud_preset` (a `CloudPreset`). Presets ship in
  `cloud_presets/`: `clear`, `fair`, `cloudy`, `overcast`, `rain`, `storm`,
  `sea_fog`.
- In the editor a new `cloud_preset` applies at once. At runtime it blends in
  over `cloud_transition_seconds`; `transition_clouds_to(preset, seconds)`
  does the same with an explicit duration. Every `CloudPreset` field
  interpolates (`CloudPreset.BLENDED_PROPERTIES`).
- Wind: `cloud_wind_source_path` (duck-typed wind source, speed scaled by
  `cloud_wind_speed_multiplier`), or `cloud_wind_speed` /
  `cloud_wind_direction` without one.
- Lighting: `cloud_light_intensity`, `cloud_ambient_intensity` (multiply the
  key light and the sky's light, from the atmosphere, on the clouds). A preset
  also scales the scene: `sun_light_scale` multiplies the sun/moon lights and
  `get_sun_visibility()`.
- Quality: `cloud_cubemap_size`, `cloud_update_stride`, `cloud_view_steps`,
  `cloud_light_steps`, `cloud_max_distance`. Defaults
  (1024, stride 4, 64/6 steps) cost about 0.5 ms (storm) to 0.8 ms (fair) of
  GPU time on an RTX 4070 Ti at 1080p.
- `get_cloud_cubemap()` returns the cloud texture (or `null` while clouds are
  off) for other shaders, with a full mip chain for blurred lookups; `get_cloud_state()` the blended weather on screen.

## Atmosphere

Aerosol haze or fog over the sea, part of the weather: every `CloudPreset`
has `haze_visibility` (m, at sea level: clear marine air 50–70 km, mist 1–5 km,
fog under 1 km; it also sets how bright the glow around the sun is),
`haze_scale_height` (m over which it thins to 1/e: about 1 km for haze, 150 m
for sea fog) and `haze_anisotropy` (how small the glow around the sun is). It
blends with the rest of the weather, the visibility geometrically, and works
with clouds disabled too.

The model lives in one place, the compute passes of `AtmosphereRenderer`
(`shaders/compute/atmosphere_*.glsl`, shared code in
`atmosphere_common.glslinc`). Every consumer samples their lookup textures, so
new media (multiple scattering, the air's own glow) are added there only.

- Media (after Hillaire 2020, "A Scalable and Production Ready Sky and
  Atmosphere Rendering Technique"): a sphere of sea (radius 6371 km, diffuse
  albedo 0.06) under an atmosphere that ends at 100 km. Air molecules (Rayleigh scattering, (5.8, 13.6, 33.1)·10⁻⁶ /m at sea
  level for red, green and blue, scale height 8 km), ozone (absorption
  (0.65, 1.88, 0.085)·10⁻⁶ /m in a layer 10–40 km up, peaking at 25 km) and
  the haze: extinction `3.912 / visibility` at sea level, falling off
  exponentially with altitude, scattering albedo 1, grey, ending 12 haze
  scale heights up. Light and view rays cross all three. Rays follow the
  curved sea, so the horizon itself is fully hazed while the sky overhead
  stays clear; rays below the horizon end at the sea, which adds the sunlight
  it reflects diffusely.
- Light: the key light (the sun, or the moon once the sun is 15° down and its
  twilight gone) white at its energy above the atmosphere, dimmed and coloured down to every
  point by the transmittance LUT (haze high up is lit more, and redder, than
  haze near the sea under a low sun) and shadowed by the planet. Below the
  cloud layer the clouds shade it (`cloud_shade()`): near the camera by the
  clouds toward the light over it (a blurred cloud cubemap mip, about 2.3°
  wide: a sun behind a cloud loses its glow), farther than 5 km by the mean
  cover overhead; `cloud_haze_shadow_strength` multiplies those opacities.
  There the cloud base lights the air and the sea instead: a dome of the
  clouds' mean radiance overhead (the cloud cubemap's top face, last mip),
  scattered isotropically. Under an overcast deck that is nearly all the light
  (the air and the horizon below a rain deck are as grey as its base).
  Phase: the air's Rayleigh phase; the haze's sharp forward Henyey-Greenstein
  lobe `g = haze_anisotropy` (about 0.97) holding 75 % of its scattering plus
  25 % isotropic, the shape of Mie scattering by sea salt and droplets. For
  light transport the lobe's forward peak (g² of it, delta-Eddington) counts as
  unscattered: light on its way to a point, the higher orders and in-scatter on
  its way to the camera see only the rest of the haze, while objects and the sky
  behind fade by all of it. Checked against a Monte Carlo reference of the same
  atmosphere (all orders): within 6 % in clear air and light haze; near the
  sun along long hazy paths the glow comes out too bright (30 % in sea fog, up
  to 60 % in red beside a setting sun: the peak's small deflections add up);
  without it, fog near the sun was 12× too dark. Every
  higher order of scattering (the light of the sky itself, what keeps twilight
  and shadows blue) comes from the multiple-scattering LUT, isotropic. The other
  body lights the atmosphere the same way, without the lobe (its phase averaged
  over the two mirrored directions each texel stands for), so twilight hands
  over to moonlight smoothly. The clouds take the brighter of the two at their
  altitude.
- Passes, every frame (`AtmosphereRenderer.render()`):
  1. `atmosphere_transmittance.glsl`: transmittance LUT (256 × 256, the rows
     dense enough near the sea for a 150 m fog layer), from space to any
     altitude along any direction above the horizon (Bruneton's layout).
  2. `atmosphere_multiple_scattering.glsl`: multiple-scattering LUT (32 × 32,
     the light's angle × altitude, log-spaced in haze scale heights):
     Hillaire's Ψ, second-order light over a sphere of directions summed as a
     geometric series `L₂ / (1 − f_ms)`, sea bounce included.
  3. `atmosphere_view.glsl`: **view volumes** (32 × 128 × slices, rgba16f),
     one ray per azimuth from the light × view angle (squeezed toward the
     horizon, which falls on a texel edge). Three textures: transmittance,
     in-scatter but the lobe (the air's Rayleigh phase baked in), and the
     lobe's in-scatter per unit phase (the lobe is narrower than a texel, so
     consumers apply its phase per pixel). Three volumes: the camera's, 64
     distance slices (`d = 100 km · (k/62)²`, the last one at the ray's end);
     the sea level's, 2 slices (at the cloud base and at the ray's end: the sky
     the water reflects, with its clouds in it); the cloud layer's, ray ends only.
  4. `atmosphere_ambient.glsl`: the sky's light, integrated over a volume's ray
     ends: at the cloud layer (`sky_ambient_buffer`: mean radiance above and
     below, the clouds' ambient light) and at the camera through the clouds
     (`camera_sky_light_buffer`: irradiance on a level surface, read back for
     the light meter).
- Consumers composite `background · transmittance + inscatter + lobe · phase`:
  - the sky shader and the starfield, at the ray's end. The sky shader puts the
    clouds inside the atmosphere: the air in front of the cloud base, the
    cloud, then the rest of the air and space through its gaps
    (`atmosphere_sky_with_clouds()`; the clouds are stored as seen at the
    cloud);
  - `AerialPerspectiveEffect` (in the WorldEnvironment's compositor), every
    opaque pixel by its depth. It runs **before the transparent pass** as one
    fullscreen triangle with dual-source blending, into the multisampled
    colour buffer per sample when MSAA is on (the transparent pass's resolve
    keeps it);
  - transparent materials, each for its own distance (below);
  - the ocean's sky reflection, from `get_atmosphere_sky_volumes()`;
  - the ocean's water surface (transparent), from
    `get_atmosphere_view_volumes()`: it cannot read the global uniforms
    without depending on the sky system;
  - the sun and moon lights, the sky's disks and the clouds' light, coloured
    by the transmittance from space (`_get_atmosphere_transmittance()`, the
    LUT's integral on the CPU; see **Sun and moon light** above).
- Global shader uniforms: SkySystem publishes the camera volume through
  `atmosphere_enabled`, `atmosphere_view_transmittance`,
  `atmosphere_view_inscatter`, `atmosphere_view_inscatter_lobe` (`sampler3D`),
  `atmosphere_observer` (`vec4`: world position of the camera the volume is
  built for, w its altitude as used), `atmosphere_light` (`vec4`: toward the
  light, w the lobe's g), `atmosphere_max_distance` (`float`) and
  `atmosphere_exposure` (`float`, see [Exposure](#exposure)), listed in
  `AtmosphereGlobals`. The project declares them in `project.godot`
  `[shader_globals]`: the plugin adds them, and SkySystem reports any that are
  missing. The last SkySystem set up owns them.
- Transparent materials: Godot draws them after the aerial perspective, so
  they haze themselves. Include `shaders/atmosphere.gdshaderinc` and write
  `FOG = atmosphere_fog(world_position);` (e.g. `BowSpray`'s
  `bow_spray.gdshader`). `FOG` blends the lit colour by the mean transmittance
  before alpha blending; it is exact while the transmittance is grey. A shader
  that writes `FOG` must write it on every path. Transparent
  `StandardMaterial3D`s are not hazed.
- Cost on an RTX 4070 Ti at 3840 × 2160 internal: the passes about 0.05 ms,
  the aerial perspective about 0.26 ms with 2× MSAA; the sky shader got cheaper
  (a lookup instead of a march). It all needs a RenderingDevice; the
  Compatibility renderer has no atmosphere. Godot's own Environment fog stays
  off: its height fog depends only on a pixel's height, not its distance.

## Exposure

`get_scene_illuminance()` is the scene's light meter: lux on a level surface at
the active camera, from the sun's and the moon's lights and the sky (atmosphere
and clouds, read back from the GPU a frame or two late; negative until the
first readback). `get_illuminance_unit_lux()` converts the scene's light units
(a light of energy 1/π facing a surface) to lux. `ExposureController` uses both.

Godot applies a camera's exposure (`CameraAttributes.exposure_multiplier`, the
camera's or else the world's) before rendering, to lights, emission and the
sky; the colour buffer holds pre-exposed light. The sky system matches it, so
moonlight keeps its precision in 16-bit textures:

- the atmosphere's in-scatter, the sky light buffers and the clouds are stored
  pre-exposed (the key light is multiplied by the exposure, read every frame;
  `atmosphere_exposure` publishes it). The aerial perspective and `FOG` take
  them as they are;
- the sky shader divides by it (Godot exposes the sky's output itself). In the
  radiance map pass it divides once more: Godot 4.8 renders the radiance map
  exposed and then exposes the light it gives again, so the map holds the sky
  unexposed (moonlit ambient light loses precision there);
- the ocean sums its reflections pre-exposed and divides its `EMISSION`.

The starfield is unlit `ALBEDO`, which Godot does not expose: it multiplies its
light by the exposure itself. Physical light units must stay off (they change
what Godot's exposure means).

### Limits

- Clouds are drawn as seen from below the cloud base: the camera altitude is
  clamped under it, so flying into or above the clouds is not supported.
- Clouds do not cast shadows on the scene; heavy cover only dims the lights
  through `sun_light_scale`.
- The atmosphere is horizontally uniform, and the clouds shade its light with
  two values (toward the light over the camera, and the mean cover).
- The atmosphere's second light (the moon while the sun is up or in twilight,
  the sun at night) has no haze glow around it, and its sky is mirrored about
  the key light's vertical plane (the volume's layout): exact for a full moon
  opposite the sun, approximate otherwise.
- The air below the clouds is lit by one mean cloud dome for the whole sky,
  so a lone thick cloud lights the air all around it as much as a deck would
  per unit of cover.
- Clouds are lit as locally plane-parallel columns (the two-stream field):
  light entering a cumulus through its sides, and shadows cast sideways by
  neighbouring clouds into a column, are not modelled.
- Points beyond 100 km (`AtmosphereRenderer.MAX_DISTANCE`) are hazed as at
  100 km; keep cameras' far planes below it. The planar reflection camera's
  transparent surfaces are hazed as seen from the main camera.
- A refreshed texel blends with its previous value, so fast changes (a preset
  jump, a fast day cycle) settle over roughly half a second.

## Getters and signals

`get_sun_direction()`, `get_moon_direction()` (unit vectors pointing *toward*
the body), `get_sun_color()`, `get_sun_visibility()`, `get_moon_visibility()`,
`get_moon_phase()`, `get_time_of_day()`. Stars: `get_star_cubemap()`,
`get_star_basis()`, `get_star_radiance_scale()`. Planets: `get_planet_directions()`
(world), `get_planet_irradiance()` (rgb scene irradiance above the atmosphere). Exposure:
`get_scene_illuminance()`, `get_illuminance_unit_lux()`.
Atmosphere: `get_atmosphere_sky_volumes()` (the sea-level view volumes,
`[transmittance, inscatter, inscatter_lobe]` as `Texture3D`s, or empty without
an atmosphere), `get_atmosphere_view_volumes()` (the camera's view volumes,
the same three `Texture3D`s the global uniforms publish, refilled every frame),
`get_atmosphere_view_observer()` (`Vector4`: the camera position those were
built for this frame, w its altitude as used), `get_atmosphere_view_max_distance()`
and `get_atmosphere_light()` (`Vector4`: toward the light, w the lobe's g).

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
- Every change updates the lights (colour, energy, direction) and the sky
  shader uniforms. The environment's ambient light is the sky's radiance map
  at energy 1.
  The stars turn with the local sidereal time (the sun's hour angle plus its
  right ascension).
- At runtime the environment, sky, sky material and visual materials are
  duplicated so several instances don't share state.

### How the clouds work

`CloudRenderer` runs four compute shaders on the main RenderingDevice
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
   detail noise. Lighting, with droplet optics (Henyey-Greenstein phase
   g = 0.85, `scattering_albedo` 1 by default):
   - single scattering of the sun or moon, through a march toward it that
     reaches the cloud top (at most 10 km);
   - every higher order from the delta-Eddington two-stream solution of the
     local column (optical depth straight above and below the sample, five
     cheap density samples), lit by the key light and by the sky's light on
     the column's top and bottom (the atmosphere's `sky_ambient_buffer`);
   - the phase's forward peak (g² of it) counts as unscattered for transport:
     in-scatter reaches the camera through the transport extinction, and the
     sky behind that the peak barely deflects is added; the opacity stays the
     true one;
   - the planet's shadow for twilight.

   Checked against a Monte Carlo reference of uniform layers (optical depth
   2–100, sun 15–60°, sky light): within about 0.8–1.3 (sky light alone within
   1 %), except within a few degrees of the sun behind thin cloud, where the
   glow is up to 4× too bright. Thick decks pass a physical share of daylight
   (overcast about 40 %, rain 15 %, storm 4 % at a 15° sun). The result is the
   cloud as seen at the cloud: the sky shader and the ocean put the atmosphere
   in front of it. Steps are spaced quadratically and jittered per texel and
   frame.
4. `cloud_mip_downsample.glsl`, every frame: rebuilds the cubemap's mip chain
   (2×2 box filter per face, no filtering across face edges). Premultiplied
   radiance and opacity average linearly, so every level composites like the
   top one. The ocean reads coarser levels for rough reflections.

Each frame refreshes one texel in every `cloud_update_stride`² block (an
ordered-dither sequence), blended 60/40 with the texel's previous value. The
cubemap is indexed by view direction, so turning the camera costs nothing;
the clouds are kilometres away, so moving the camera a few hundred metres
between refreshes does not show either.

The cubemap stores premultiplied radiance in rgb (pre-exposed, see
[Exposure](#exposure)) and opacity in a. The sky shader composites it inside the
atmosphere (`atmosphere_sky_with_clouds()`), the starfield fades stars by
`1 - a`, and the ocean does the same as the sky in its sky reflection. The radiance map (ambient light, reflections)
follows because the sky material's cloud parameters are re-sent once per full
refresh. Those parameters go through `RenderingServer.material_set_param`, so
the runtime texture is never stored in `materials/*.tres`.

## Files

`sky_system.gd` / `.tscn`, `atmosphere_globals.gd` (`AtmosphereGlobals`),
`sky_system_plugin.gd` (project setup), `star_catalog.gd` (`StarCatalog`),
`stars/bright_star_catalog.tres` (baked by `tools/bake_star_catalog.py`),
`cloud_preset.gd` (`CloudPreset`), `cloud_presets/*.tres`,
`cloud_renderer.gd` (`CloudRenderer`), `shaders/compute/cloud_*.glsl` and
`cloud_noise.glslinc`, `atmosphere_renderer.gd` (`AtmosphereRenderer`),
`shaders/compute/atmosphere_*.glsl` and `atmosphere_common.glslinc`,
`aerial_perspective_effect.gd` (`AerialPerspectiveEffect`),
`shaders/aerial_perspective.glsl`, `shaders/atmosphere.gdshaderinc`,
`shaders/sky.gdshader`, `shaders/starfield.gdshader`,
`shaders/celestial_disk.gdshader`, `materials/*.tres`.
