# Exposure System

Camera exposure from the light falling on the scene. An `ExposureController`
reads a light meter (lux on a level surface at the camera), exposes the camera
for it the way an incident-light meter would, and adapts to changes over time
the way an eye does. It meters the light, not the rendered image, so looking at
the sun, the sea or a dark hull does not change it. It has no dependencies on
other addons.

## Visual effects

- **Auto exposure:** from an incident-light meter, so bright or dark subjects
  in view never pump the image.
- **Eye adaptation:** separate time constants for brightening and darkening.
- **Perceptual darkness:** sunset, twilight and night render progressively
  darker, as the eye sees them (Krawczyk et al.), not metered to grey.
- **Night vision:**
  - rod vision below about 3 cd/m²: per-pixel desaturation and a blue shift,
    blended across the mesopic range;
  - the moon keeps its colour while the moonlit scene goes blue-grey.

## Usage

Add an `ExposureController` node (`exposure_controller.gd`) and set:

- `light_source_path` — any node with `get_scene_illuminance()` (lux on a level
  surface at the active camera; negative while unknown, e.g. before a GPU
  readback) and `get_illuminance_unit_lux()` (lux of the scene's irradiance 1,
  i.e. of a light of energy 1/π in Godot's units). `SkySystem` provides both.
- `target_path` — a `WorldEnvironment` (its `camera_attributes`) or a
  `Camera3D` (its `attributes`). A target without `CameraAttributes` gets a
  `CameraAttributesPractical`. A camera's own attributes override the
  world's, so target the camera if it has some.

Exports:

- `exposure_compensation_ev` — stops added to the meter's exposure.
- `perceptual_adaptation` — on: adapt like an eye (dim light stays dimmer, see
  below); off: like a camera (every light level exposed alike).
- `brighten_seconds` / `darken_seconds` — time constants of adapting to more
  light and to less (the eye adapts to light quickly, to darkness slowly). The
  first reading applies at once.

- `night_vision` (on), `night_vision_strength` — see like an eye in dim light
  (Night vision below).

`get_adapted_illuminance()` returns the lux the exposure is currently adapted to.

## How it works

- The meter: the exposure renders a grey card (18 %) in the metered light at
  0.18, a white diffuser at 1: `exposure = π · unit_lux / lux`.
- Perceptual adaptation (Krawczyk, Myszkowski and Seidel 2005, "Lightness
  perception in tone reproduction for high dynamic range images"): an eye
  adapted to a mean luminance `L` (cd/m²) gives it the lightness
  `1.03 − 2 / (2 + log₁₀(L + 1))`. The exposure is scaled by that lightness
  relative to a bright overcast day (grey card at 1000 cd/m², about 17 000 lux),
  never above 1. Sunset ends up about half a stop darker than day, civil
  twilight about 1.5 stops, a moonlit night about 4 stops. Adaptation stops at
  a grey card of 10⁻⁴ cd/m² (about 0.002 lux): darker nights get darker.
- Adaptation smooths the metered lux in log space with the time constant for
  its direction.
- The result is written to `CameraAttributes.exposure_multiplier` at runtime
  only (the node is not a tool script, so nothing is saved into scenes). Godot
  applies it before rendering, to lights, emission and the sky; systems that
  write their own light (the sky system's atmosphere and clouds, the ocean's
  reflections) read the same value and match it. Keep physical light units off.

## Night vision

In dim light the eye's rods take over from its cones: colour fades and what is
left is slightly blue. `NightVisionEffect` (`night_vision.glsl`) does that per
pixel, from the pixel's absolute luminance (`unit_lux / exposure` cd/m² per unit
of the colour buffer, set by the controller every frame): cones above
3 cd/m², rods below 0.01 cd/m², blended by log luminance in between (the
mesopic range). The rods see Larson et al.'s (1997) scotopic luminance,
normalized to the photopic one for white, tinted by Jensen et al.'s (2000) blue
shift. So the moon keeps its colour while the moonlit sea, the sky and the
airglow go blue-grey, and a moonless sky is no longer the yellow-green a camera
records. The controller appends the effect to its target's compositor at
runtime (a `WorldEnvironment`'s or a `Camera3D`'s, created if missing) and
removes it in `_exit_tree`; it runs after the transparent pass, on the HDR
colour before tonemapping, and needs a RenderingDevice.

Limits: star images on screen are a pixel wide, far wider than the eye's
point-spread, so their luminance per pixel is too low for the cones: bright
stars lose their colour (Antares and Betelgeuse look tinted to the eye).

## Files

`exposure_controller.gd` (`ExposureController`), `night_vision_effect.gd`
(`NightVisionEffect`), `night_vision.glsl`, `exposure_system_plugin.gd`,
`plugin.cfg`.
