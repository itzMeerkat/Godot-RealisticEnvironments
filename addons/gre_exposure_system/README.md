# Exposure System

**English** · [简体中文](README.zh-CN.md)

Automatic camera exposure that behaves like an eye. It meters the light falling
on the scene, adapts to it over time, keeps night darker than day, and fades
colours in dim light. It depends on nothing.

## How it works

- **Incident-light meter.** Each frame, `GREExposureController` reads the lux at
  the camera from a light source (e.g. `GRESkySystem`). It picks the exposure that
  renders an 18 % grey card in that light at 0.18 (a white surface at 1).
  `exposure_compensation_ev` shifts the result.
- **Adaptation.** The exposure moves toward that target over time. Adapting to
  more light (`brighten_seconds`) is faster than adapting to less
  (`darken_seconds`).
- **Perceptual darkness.** In dim light the eye adapts only part of the way
  (Krawczyk et al. 2005), so dusk and night stay darker than day. Turn
  `perceptual_adaptation` off to expose every light level like a camera.
- **Adapting to the view** (`adapt_to_view`). A `GREViewLuminanceEffect` measures
  the rendered image's average brightness. When the view is brighter than the
  metered light (a low sun or moon glowing in haze), exposure drops further, as
  the eye does under glare. A darker view (the sea, a hull) does not raise it.
  In dim light, small bright areas count too, so a sunset's last glow fades
  instead of turning white as the sky around it goes dark.
- **Night vision** (`night_vision`). A `GRENightVisionEffect` fades dark pixels
  toward a slightly blue grey, the way rods take over from cones.

The result goes into the target's `CameraAttributes.exposure_multiplier`, at
runtime only. Godot applies it to lights, emission and the sky. The two effects
are added to the target's compositor at runtime and need a `RenderingDevice`.
The view meter measures every view drawn with that compositor (a
`WorldEnvironment`'s serves each camera in its world without a compositor of
its own): with several (split screen, a `SubViewport` minimap) it follows
whichever rendered last. Give an extra camera a `Compositor` of its own to
leave it out.

## How to use

1. Add an `GREExposureController` node.
2. Set `light_source_path` to a `GRESkySystem`, or to any node with
   `get_scene_illuminance()` (lux at the camera, negative while unknown) and
   `get_illuminance_unit_lux()` (the lux of a scene irradiance of 1).
3. Set `target_path` to the `WorldEnvironment` or the `Camera3D`. A camera's
   own attributes override the world's, so target the camera if it has any.
   A target without attributes gets a `CameraAttributesPractical`.
4. Keep physical light units off, and don't use a second auto-exposure.

Settings: `exposure_compensation_ev`, `perceptual_adaptation`,
`brighten_seconds`, `darken_seconds`, `night_vision`, `night_vision_strength`,
`adapt_to_view`. `get_adapted_illuminance()` returns the lux the eye is
currently adapted to.

Things that glow by themselves (a lamp, a signal light, a screen) should look
as bright whatever the eye is adapted to. Set their energy every frame from
`GREExposureController.display_energy(node, glow)`, glow being how bright they look
relative to the screen's white:

```gdscript
material.emission_energy_multiplier = GREExposureController.display_energy(self, 1.5)
```
