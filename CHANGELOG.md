# Changelog

All notable changes to the open-source addons of Godot-RealisticEnvironments.
The addons share one version (`plugin.cfg`) and follow semantic versioning;
before 1.0 a minor version may change the API.

## Unreleased

## 0.1.0 (in preparation)

First open-source release.

- Ocean: FFT wave cascades (JONSWAP/TMA) following an external wind, CDLOD
  mesh to a curved horizon, foam, iWave wakes, bow waves and splashes, hull
  cutouts, physical water optics (absorption, scattering, crest glow,
  refraction, caustics), rough-surface Fresnel reflections of the sky, stars
  and planets, screen-space or planar reflections, sun glitter, wind-dependent
  micro-roughness, asynchronous GPU water queries, Low / Medium / High shader
  tiers.
- Sky: astronomical sun and moon, physical atmosphere with sea haze and fog
  and aerial perspective, volumetric clouds with blended weather presets, the
  Bright Star Catalogue, the Milky Way, airglow and planets.
- Exposure: incident-light metering, eye adaptation, rod night vision.
- Buoyancy: probe buoyancy with editor-generated probes, sinking.
- Hitbox damage: grouped health and hit effects.
- `ocean_environment`: drop-in scene with wind, sky, ocean and exposure.
- `boat_template`: ready-wired boat (driving, stability, buoyancy, health,
  wake, bow spray).
- Plugins set up the project they need (global shader uniforms, debanding,
  input actions); misconfigured nodes show editor warnings.
- `examples/`: ocean only, floating objects, a drivable boat.
