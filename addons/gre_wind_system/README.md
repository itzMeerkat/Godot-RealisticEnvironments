# Wind System

**English** · [简体中文](README.zh-CN.md)

A `GREWindSystem` node: one wind for the whole scene, with optional gusts. The
ocean's waves and the sky's clouds can follow it. It depends on nothing.

## How it works

The wind has a fixed direction and a base speed. Gusts add a sum of three sine
waves to that speed (never below 0). `GREWindSystem` meets the wind source
contract (see `gre_core`'s `GREWindSource`), so other systems read it without knowing
its type.

The ocean does not jump with every gust. It generates a new spectrum only when
the wind has changed by more than its thresholds, and it crossfades to that
spectrum over a few seconds.

## How to use

1. Add a `GREWindSystem` node (**Add Child Node > GREWindSystem**).
2. Point `GREOceanSystem.wind_source_path` and/or
   `GRESkySystem.cloud_wind_source_path` at it.
3. Set:
   - `wind_speed` (m/s)
   - `wind_direction`: degrees the wind blows toward (0 = +Z, 90 = +X)
   - `gust_strength`: the largest gust in m/s (0 = steady wind)
   - `gust_frequency`: gusts per second

From code: `get_wind_speed()` (gusts included), `get_wind_direction_degrees()`,
`get_wind_vector_2d()` and `get_wind_vector_3d()`. The `wind_changed` signal
fires when a setting changes (not on each gust).

To drive the wind from your own node instead (weather, gameplay), give it
`get_wind_speed()` and `get_wind_direction_degrees()` and point the paths at it.
