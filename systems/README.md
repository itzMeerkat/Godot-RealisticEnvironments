# systems/

Demo-level support code. These are not packaged as addons and may reference
addon classes directly.

## `camera/` — `PlayerCameraRig`

`player_camera_rig.tscn`: `YawPivot → PitchPivot → SpringArm3D → Camera3D`
(far plane 8 km, collision-aware spring arm).

Modes, cycled with `cycle_mode_action` (third → first → free look):

- **Third person** — orbits `third_person_focus_path` (or the follow target) at
  `third_person_distance`; yaw follows the target's heading and re-centres
  `recenter_delay` seconds after the last mouse look.
- **First person** — sits on `first_person_anchor_path`, optionally locked to the
  anchor's rotation with smoothing (`first_person_lock_to_anchor_transform`).
- **Free look** — flies with the `camera_move_*` actions, `camera_boost`, and the
  mouse wheel to change speed.

Hold right mouse to capture the mouse and look around. In third person the FOV
widens slightly with the follow target's speed. `set_target_paths(follow, first_person, third_person)` rebinds the
rig at runtime; `enable_camera_movement` gates mouse and movement input
(`demo/main.gd` turns it off while the cursor is over the debug panel).

## `debug/` — `OceanDebugPanel`

A `CanvasLayer` built entirely in code. Call
`setup(ocean, wind, sky, buoyant_body, player_body)`; any argument after the
ocean may be null and its section is skipped. Sections: FPS, ocean
(simulation size, update rate, colours, shading, foam), sky reflection / glitter
/ scatter / crest glow, far LOD, wind, sky (time, astronomy), buoyancy, and one
tab per wave cascade. `toggle_panel_visible()` and `is_interacting()` are used
by the demo scripts.

## `hud/` — `CompassHud`

A `Control` that draws a compass dial with the heading of a `Node3D` and the
wind direction (arrow) from a wind source. Bind with `setup(target, wind)` or
the `heading_target_path` / `wind_source_path` exports.
