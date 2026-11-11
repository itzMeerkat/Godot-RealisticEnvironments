# Changelog

All notable changes to the open-source addons of Godot-RealisticEnvironments.
The addons share one version (`plugin.cfg`) and follow semantic versioning;
before 1.0 a minor version may change the API.

## 0.1.0 (in preparation)

First open-source release.

- Ocean: FFT wave cascades (JONSWAP/TMA, one spectrum split by wavelength)
  following an external wind, anisotropically filtered normals, CDLOD
  mesh to a curved horizon, foam, physical water optics (absorption,
  scattering, crest glow, refraction, caustics), rough-surface Fresnel
  reflections of the sky, stars and planets, screen-space or planar
  reflections, wind-dependent micro-roughness, asynchronous GPU water queries,
  Low / Medium / High shader tiers.
- Interactive waves: hulls make wakes, bow waves and rings as they move
  relative to the water, simulated around the camera with exact finite-depth
  dispersion (Kelvin wakes), and churn up lacy foam that drifts with the
  surface and fades (`GREWaterDisturbance`, `GREOceanSystem.interaction_map_size`,
  `interaction_cell_size`).
- Sky: astronomical sun and moon, physical atmosphere with sea haze and fog
  and aerial perspective, volumetric clouds with blended weather presets, the
  Bright Star Catalogue, the Milky Way, airglow and planets.
- Exposure: incident-light metering, eye adaptation, rod night vision.
- Buoyancy: `GREBuoyantBody` floats a `RigidBody3D` at a set `draft`, level and
  upright by design, with damping and drag relative to the water, drifting
  with the surface drift; it reports its hull for the wakes
  (`wake_strength`) and can opt in to riding the interactive waves, its own
  and other hulls' (`wave_response`).
- Hitbox damage: grouped health and hit effects.
- `gre_core`: the `GREWaterSurface` (water queries, surface drift, hull
  disturbances, wave response) and `GREWindSource` contracts the systems talk
  through, `GREWaterMask` (keeps the water out of open hulls; **Fit to Hull**
  makes its lid), and RenderingDevice helpers.
- `gre_ocean_environment`: drop-in scene with wind, sky, ocean and exposure.
- `gre_boat_template`: ready-wired boat (driving with thrust and rudder at the
  stern, buoyancy, health, wake; open hulls add a `GREWaterMask`).
- Plugins set up the project they need (global shader uniforms, debanding,
  input actions); misconfigured nodes show editor warnings.
- `examples/`: ocean only, floating objects, a drivable boat.
- Documentation in English and Simplified Chinese (`README.md` /
  `README.zh-CN.md`): how each addon works and how to use it.
