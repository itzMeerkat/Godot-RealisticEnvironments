# Wind System

A tiny, dependency-free wind provider node. The ocean reads it, and anything
else (particles, sails, gameplay) can too.

## Usage

Add a `WindSystem` node (or instance `wind_system.tscn`) and point
`OceanSystem.wind_source_path` at it with `use_external_wind` enabled.

Exports: `wind_speed` (m/s), `wind_direction` (degrees, 0 = +Z, 90 = +X),
`gust_strength` (extra m/s, 0 = steady), `gust_frequency` (cycles/s).

Methods:

| Method | Returns |
| --- | --- |
| `get_wind_speed()` | Base speed + current gust, clamped ≥ 0 |
| `get_base_wind_speed()` | Base speed without gusts |
| `get_gust_offset()` | Current gust contribution |
| `get_wind_direction_degrees()` / `get_wind_direction_radians()` | Heading |
| `get_wind_vector_2d()` | `(sin θ, cos θ) × speed` in XZ |
| `get_wind_vector_3d()` | Same, as `Vector3(x, 0, z)` |

Signal `wind_changed` fires when an export changes (not on every gust).

## Notes

- Gusts are three layered sines of an internal clock that only advances at
  runtime, so the editor always shows the base speed.
- Any node can replace `WindSystem` as the ocean's wind source if it exposes
  `get_wind_speed()` and `get_wind_direction_degrees()`, or `wind_speed` and
  `wind_direction` properties.
- The ocean only regenerates spectra when speed moves by ≥ 0.25 m/s (at most
  every 0.5 s), so strong fast gusts cost spectrum regenerations. Direction
  changes are handled by gradual per-cascade turning instead.
