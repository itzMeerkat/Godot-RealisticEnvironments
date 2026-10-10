# Contributing

Thanks for helping. This file covers how to report problems and how to send
changes; `AGENTS.md` holds the detailed working rules for the code (for people
and coding agents alike), and each addon's `README.md` explains how it works.

## Scope

The open-source addons are `core`, `ocean_system`, `sky_system`,
`wind_system`, `exposure_system`, `buoyancy_system`, `hitbox_damage_system`,
`ocean_environment` and `boat_template`, plus `examples/`. The projectile
weapons (`projectile_launcher_system`), the armed `floating_boat_template` and
`demo/` are the development sandbox: changes there are kept to what the
addons need.

## Reporting a problem

Please include:

- the Godot version (4.8 is required) and the renderer (Forward+);
- the OS and GPU (the ocean, sky and clouds run on compute shaders);
- what you did, what you expected and what happened, ideally with a
  screenshot and the errors from the Output panel;
- whether it happens in `examples/` or the demo, or only in your project
  (then the node warnings in the Scene dock are worth a look first).

## Sending a change

1. Open the project in Godot 4.8 (Forward+) with every plugin enabled (they
   are, in this project).
2. Keep the change focused and follow `AGENTS.md`: addons never depend on each
   other except through `core`; errors are reported with `push_error` and the
   feature turns itself off instead of crashing; no compatibility shims.
3. Keep every script free of GDScript warnings. `tools/gd_lint.py` lists them
   through a headless editor:

   ```bash
   GODOT=/path/to/Godot_v4.8_console.exe python tools/gd_lint.py
   ```

4. Run what you touched: `demo/main.tscn`, the relevant example, or
   `demo/ocean_optics_debug.tscn` for water shading. Headless runs have no
   `RenderingDevice`, so they catch script errors but not rendering ones.
5. Update the addon's `README.md` (and `AGENTS.md` if a rule changes) in the
   same change, and add a line to `CHANGELOG.md` under *Unreleased*.

Generated files (`addons/sky_system/stars/*`, `examples/assets/simple_hull.*`,
baked hull profiles and buoyancy probes) are regenerated with their tools or
editor buttons, never edited by hand.

By contributing you agree that your contribution is licensed under the
project's MIT license (`LICENSE`).
