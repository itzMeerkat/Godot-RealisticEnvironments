# PlayerCameraRig

`PlayerCameraRig` is a reusable first-person, third-person, and free-look camera
component for boats, characters, and other controllable actors.

## Scene Setup

Instance `res://systems/camera/player_camera_rig.tscn` into a gameplay scene and
assign:

- `follow_target_path`: the actor root used for yaw and velocity.
- `third_person_focus_path`: a `Marker3D` near the point the camera should orbit.
- `first_person_anchor_path`: a `Marker3D` at the player eye or seat position.

When `first_person_lock_to_anchor_transform` is enabled, first-person mode uses
the anchor's full transform every frame. This makes the camera inherit a boat's
pitch, roll, yaw, and position directly, while mouse look is applied locally as
the player's head movement. `first_person_anchor_rotation_smoothing` damps the
anchor rotation so wave-driven pitch, roll, and yaw feel less rigid.

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
`InputMap` actions so projects can rebind them under Project Settings -> Input
Map. The included ocean demo keeps all bindings in `project.godot`; gameplay
scripts only read action names and do not register key events at runtime.
