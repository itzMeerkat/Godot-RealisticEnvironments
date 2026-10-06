# Exposure System

Camera exposure from the light falling on the scene. An `ExposureController`
reads a light meter (lux on a level surface at the camera), exposes the camera
for it the way an incident-light meter would, and adapts to changes over time
the way an eye does. It meters the light, not the rendered image, so looking at
the sun, the sea or a dark hull does not change it. It has no dependencies on
other addons.

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

## Files

`exposure_controller.gd` (`ExposureController`), `exposure_system_plugin.gd`,
`plugin.cfg`.
