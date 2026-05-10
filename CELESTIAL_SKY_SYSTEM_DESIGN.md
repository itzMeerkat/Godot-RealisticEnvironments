# Sun, Moon, and Starfield System Design

Add a reusable `SkySystem` that owns the day-night cycle, celestial lighting, visible sun/moon disks, and starfield. Keep it separate from `OceanSystem`; the ocean should receive normal Godot light from the sun and moon, with optional water color tuning later.

## Project Fit

Current structure already separates reusable systems:

* `addons/ocean_system/` has `OceanSystem`, water material, and the water shader.
* `addons/wind_system/` has `WindSystem`, a small provider-style runtime node.
* `systems/debug/` has the native debug panel.
* `demo/main.tscn` currently composes the scene and owns the static skybox plus root `Sun`.

The new system should follow the same pattern: put reusable sky logic in `addons/sky_system/`, then instance it from `demo/main.tscn`.

## Goals

* Drive sun and moon direction, light color, light intensity, and visibility from normalized time of day.
* Render stars that fade in at night.
* Replace the demo's static skybox with a dynamic sky material.
* Expose simple getters for gameplay and debugging.
* Keep the MVP lightweight: no weather, no clouds, and no compute work.

## Files

```text
addons/sky_system/
  sky_system.tscn
  sky_system.gd
  sky_profile.gd
  materials/
    sky.tres
    celestial_disk.tres
    starfield.tres
  shaders/
    sky.gdshader
    celestial_disk.gdshader
    starfield.gdshader
```

Optional later:

```text
addons/sky_system/textures/moon_albedo.png
addons/sky_system/textures/star_noise.png
```

## Scene

```text
SkySystem (Node3D, script: sky_system.gd)
  WorldEnvironment
  SunLight (DirectionalLight3D)
  MoonLight (DirectionalLight3D)
  SunVisual (MeshInstance3D)
  MoonVisual (MeshInstance3D)
  Starfield (MeshInstance3D)
```

`WorldEnvironment` owns the dynamic sky background. `SunLight` and `MoonLight` own lighting. `SunVisual`, `MoonVisual`, and `Starfield` are presentation only and should use unshaded materials.

## Runtime API

```gdscript
@tool
class_name SkySystem
extends Node3D

signal time_of_day_changed(time_of_day: float)
signal lighting_changed

@export_range(0.0, 1.0, 0.001) var time_of_day := 0.35
@export var cycle_enabled := true
@export var cycle_duration_seconds := 600.0
@export var axis_tilt_degrees := 25.0
@export var sun_energy_multiplier := 1.0
@export var moon_energy_multiplier := 1.0
@export var star_brightness := 1.0
@export var profile: SkyProfile

func get_time_of_day() -> float
func get_sun_direction() -> Vector3
func get_moon_direction() -> Vector3
func get_sun_visibility() -> float
func get_moon_visibility() -> float
func get_night_factor() -> float
```

Time mapping:

* `0.00` midnight
* `0.25` sunrise
* `0.50` noon
* `0.75` sunset

## Profile Resource

Keep tuning data out of `sky_system.gd`.

```gdscript
@tool
class_name SkyProfile
extends Resource

@export var sun_color_gradient: Gradient
@export var moon_color_gradient: Gradient
@export var sky_top_gradient: Gradient
@export var sky_horizon_gradient: Gradient
@export var water_color_gradient: Gradient
@export var foam_color_gradient: Gradient
@export var sun_energy_curve: Curve
@export var moon_energy_curve: Curve
@export var star_visibility_curve: Curve
@export var ambient_energy_curve: Curve
```

Water and foam gradients are optional integration hooks. The default sky system should still work without an `OceanSystem` reference.

## Celestial Motion

Use an artistic orbit for the first version:

1. Convert `time_of_day` to an angle around an east-west arc.
2. Tilt the arc by `axis_tilt_degrees`.
3. Put the moon opposite the sun.
4. Fade each body based on altitude above the horizon.

```text
sun_visibility = smoothstep(-0.05, 0.08, sun_direction.y)
moon_visibility = smoothstep(-0.05, 0.08, moon_direction.y)
night_factor = 1.0 - smoothstep(-0.08, 0.18, sun_direction.y)
```

## Lighting

Sun:

* Direction follows `sun_direction`.
* Color comes from `profile.sun_color_gradient`.
* Energy comes from `profile.sun_energy_curve * sun_energy_multiplier`.
* Shadows stay enabled.

Moon:

* Direction follows `moon_direction`.
* Color comes from `profile.moon_color_gradient`.
* Energy comes from `profile.moon_energy_curve * moon_energy_multiplier`.
* Shadows should be disabled by default for the MVP.

Sky:

* Zenith and horizon colors come from profile gradients.
* Ambient energy comes from `profile.ambient_energy_curve`.
* Tonemap settings can reuse the current demo defaults unless night readability needs tuning.

## Stars And Visual Bodies

Starfield MVP:

* Use an inward-facing sphere or large cube with `starfield.gdshader`.
* Fade by `profile.star_visibility_curve.sample(night_factor) * star_brightness`.
* Generate sparse stars procedurally from view direction, or use a small noise texture if needed.
* Keep twinkle subtle to avoid noisy ocean reflections.

Sun and moon visuals:

* Use unshaded disks placed far along their direction vectors.
* Reposition relative to the active camera each frame.
* Make the disks face the active camera.
* Add moon phase later if needed.

```text
visual_position = camera_position + body_direction * celestial_visual_distance
```

## Ocean Integration

The existing water shader already reacts to Godot lights through its `light()` function, so the MVP does not need water shader changes.

Optional later integration:

* `SkySystem` can export `ocean_path: NodePath`.
* If assigned, it can set `OceanSystem.water_color` and `OceanSystem.foam_color` from `SkyProfile`.
* If reflected sky tint is needed later, add shader globals such as `sky_horizon_color`, `sky_zenith_color`, and `night_factor`.

## Demo Integration

In `demo/main.tscn`:

* Instance `res://addons/sky_system/sky_system.tscn`.
* Remove or disable the root `Sun` once `SkySystem/SunLight` is active.
* Move the current sky background setup into `SkySystem`.
* Keep `WindSystem`, `Water`, camera, audio, and debug panel structure unchanged.

In `demo/main.gd`, pass the sky system to debug setup only if sky controls are added:

```gdscript
@onready var sky_system := $SkySystem

func _ready() -> void:
	if Engine.is_editor_hint(): return
	debug_panel.setup(water, wind_system, sky_system)
```

`OceanDebugPanel.setup()` should keep the third argument optional for compatibility.

## Debug Controls

Add a `Sky` section to the existing debug panel:

* `Cycle Enabled`
* `Time of Day`
* `Cycle Duration`
* `Sun Energy`
* `Moon Energy`
* `Star Brightness`

Use the existing row helpers in `systems/debug/ocean_debug_panel.gd`.

## Implementation Phases

1. `SkySystem` scene and script: time-of-day, sun/moon directions, light colors, light energy, dynamic sky colors.
2. Starfield and sun/moon visual disks.
3. `SkyProfile` resource for gradients and curves.
4. Optional debug panel controls.
5. Optional ocean color/foam tint integration.

## Decisions And Notes

* The first version should use an artistic day-night cycle. Real latitude/date behavior can be considered later if gameplay needs it.
* Night brightness should stay configurable, so the same system can support realistic darkness or readable stylized moonlight.
* `demo/media/skybox.png` should remain available as a fallback mode.

Camera mode matters because celestial visuals are effectively infinitely far away, while the project may support several very different views:

* Boat-level and first-person cameras spend more screen time near the horizon, so sun/moon disk size, horizon placement, and starfield scale need careful tuning to avoid obvious sliding or intersection with the ocean.
* Free-fly cameras can look straight up, down, and around quickly, so the starfield should be stable in all directions and not depend on a narrow horizon-only composition.
* Third-person cameras may show more scene geometry and player silhouettes, so light intensity and shadow behavior become more noticeable than the disk visuals.

Recommendation for clouds: implement them later as a separate `systems/weather/` feature, with `SkySystem` exposing the sun/moon/time data that clouds need.

Pros of separate weather:

* Keeps `SkySystem` focused on celestial time, light, sky color, and stars.
* Allows clouds, rain, wind response, storms, and precipitation to evolve without bloating the sky controller.
* Fits the existing project style, where `WindSystem` and `OceanSystem` are separate but can share data.

Cons of separate weather:

* Requires a small coordination API between weather and sky, such as `get_sun_direction()`, `get_night_factor()`, and possibly cloud shadow intensity.
* Slightly more scene setup than placing every sky-related visual under one node.

If the first cloud pass is only a simple decorative sky-layer, it can start as a child of `SkySystem`. Once it needs wind, coverage, storms, precipitation, or gameplay effects, move it to `systems/weather/`.
