# Contributing

Thanks for helping. This file covers how to report problems and how to send
changes; `AGENTS.md` holds the detailed working rules for the code (for people
and coding agents alike), and each addon's `README.md` explains how to use it.

## Scope

The open-source addons are `gre_core`, `gre_ocean_system`, `gre_sky_system`,
`gre_wind_system`, `gre_exposure_system`, `gre_hitbox_damage_system`,
`gre_ocean_environment` and `gre_boat_template`, plus `examples/`. The projectile
weapons (`gre_projectile_launcher_system`), the armed `gre_floating_boat_template` and
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
   other except through `gre_core`; errors are reported with `push_error` and the
   feature turns itself off instead of crashing; no compatibility shims.
3. Keep every script free of GDScript warnings. `tools/gd_lint.py` lists them
   through a headless editor:

   ```bash
   GODOT=/path/to/Godot_v4.8_console.exe python tools/gd_lint.py
   ```

4. Run what you touched: `demo/main.tscn`, the relevant example, or
   `demo/ocean_optics_debug.tscn` for water shading. Headless runs have no
   `RenderingDevice`, so they catch script errors but not rendering ones.
5. Document new public members with `##` comments (they become the inspector
   tooltips and the editor's class reference), update the addon's short
   `README.md` and its Chinese `README.zh-CN.md` if setup or usage changes
   (and `AGENTS.md` if a rule changes) in the same change, and add a line to
   `CHANGELOG.md` under *Unreleased*.

Generated files (`addons/gre_sky_system/stars/*`, `examples/assets/simple_hull.*`)
are regenerated with their tools, never edited by hand.

By contributing you agree that your contribution is licensed under the
project's MIT license (`LICENSE`).
