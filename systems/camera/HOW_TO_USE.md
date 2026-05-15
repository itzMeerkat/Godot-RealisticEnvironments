# PlayerCameraRig

`PlayerCameraRig` is a reusable first-person, third-person, and free-look camera
component for boats, characters, and other controllable actors.

## Scene Setup

Instance `res://systems/camera/player_camera_rig.tscn` into a gameplay scene and
assign:

- `follow_target_path`: the actor root used for yaw and velocity.
- `third_person_focus_path`: a `Marker3D` near the point the camera should orbit.
- `first_person_anchor_path`: a `Marker3D` at the player eye or seat position.

The component contains this hierarchy:

```text
PlayerCameraRig
  YawPivot
    PitchPivot
      SpringArm3D
        Camera3D
```

`SpringArm3D` handles third-person camera distance and gives a place to enable
collision handling later. First-person and free-look modes collapse the spring
arm to zero length.

## Controls

The demo binds `C` to `cycle_camera_mode`, cycling:

```text
Third person -> First person -> Free look -> Third person
```

Hold right mouse to look. In free-look mode, movement is driven by Godot
`InputMap` actions so projects can rebind them:

- `camera_move_forward` / `camera_move_back`: `W/S`
- `camera_move_left` / `camera_move_right`: `A/D`
- `camera_move_down` / `camera_move_up`: `Q/E`
- `camera_boost`: `Shift`

`DemoInputActions.ensure_defaults()` registers these actions at runtime if the
project settings were not refreshed yet. The demo scene also calls
`ensure_project_settings_defaults()` in editor mode so the actions are written
under Project Settings -> Input Map.
