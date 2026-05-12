# Current System HOW TO USE

## Usage

Instance `res://addons/current_system/current_system.tscn` in your scene, then
set `current_speed` and `current_direction`.

`current_direction` is compass-like: `0` points along world `+Z`, `90` points
along world `+X`.

Code that needs ocean current should depend on this interface:

```gdscript
var current := current_system.get_current_vector_3d(global_position)
```

The current system is intentionally independent from wind. If a project wants
wind-driven current, add that behavior inside a custom current provider instead
of coupling it to OceanSystem.
