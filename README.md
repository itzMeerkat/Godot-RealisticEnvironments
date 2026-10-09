# GodotOceanWaves

A Godot 4.8 (Forward+) sandbox for FFT-simulated open ocean and the gameplay
systems that sit on top of it: GPU water-height queries, probe-based buoyancy,
a physically-driven sailing ship, cannons with ballistic aiming, hitbox damage,
and sinking.

The wave simulation started as a fork of
[2Retr0/GodotOceanWaves](https://github.com/2Retr0/GodotOceanWaves) — see
`README_original.md` for the upstream write-up of the spectrum/FFT math and
`LICENSE_original` for its license.

## Running the demo

1. Open the folder in Godot **4.8** with the **Forward+** renderer. The ocean
   is generated with compute shaders on the `RenderingDevice`; the
   Compatibility renderer and headless runs have no `RenderingDevice`, so no
   waves are generated there.
2. Run the project. The main scene is `res://demo/main.tscn`.

`res://demo/ocean_optics_debug.tscn` is a second, lighter scene with just sky,
wind, water, a free-fly camera and the debug panel — useful for tuning water
shading without the ships.

### Controls (main demo)

| Input | Action |
| --- | --- |
| W / S | Ship throttle forward / reverse |
| A / D | Ship turn left / right |
| Space | Fire the boat's guns at the aim marker (0.5 s cooldown) |
| Right mouse (hold) | Mouse look; the aim marker follows the screen center |
| C | Cycle camera: third person → first person → free look |
| Free look: W/A/S/D, R / F, Shift, mouse wheel | Fly, up / down, boost, change fly speed |
| H or \` | Toggle the ocean debug panel |
| F | Toggle fullscreen (also "down" in free look) |
| Esc | Leave fullscreen, release the mouse |

The scene contains the player's rowboat (`Rowboat`, one bow swivel gun), a
caravel (`Caravel`) you can shoot and sink, a buoy that shows its distance to the
player, a compass HUD (ship heading + wind), and a hidden debug panel exposing
most ocean, sky, wind, buoyancy and cascade parameters live.

## Using the addons in your own project

1. Copy `addons/core` and the addons you want into your project's `addons/`
   folder (see the dependencies below and in each addon's README).
2. Enable them in **Project Settings > Plugins**. Enabling sets up the project
   for them and prints what it added: the sky's global shader uniforms and
   debanding, and the boat's and weapons' default input actions. Nothing that
   is already set is changed.
3. Use the Forward+ renderer and keep physical light units off.
4. Instance the addon's scene (`sky_system.tscn`, `ocean_system.tscn`, ...) and
   follow its README's quick start.

## Repository layout

```
project.godot            Godot manifest (main scene, input map, physics layer names)
addons/                  Reusable systems, each self-contained with its own README
  core/                  Shared foundation: WaterSurface contract, RenderingDevice helpers
  ocean_system/          FFT ocean: compute pipeline, water shader, mesh, reflections, queries
  sky_system/            Day/night sky, atmosphere, sun + moon lights, starfield, astronomy, volumetric clouds
  wind_system/           Wind provider node with procedural gusts
  exposure_system/       Camera exposure from the scene's light meter, eye-like adaptation
  buoyancy_system/       Probe-based buoyancy, probe generation, sinking monitor
  hitbox_damage_system/  Hitboxes, grouped health, hit effects
  boat_template/         Boat scene that wires the systems together (driving, buoyancy, health, wake, spray)
  projectile_launcher_system/  (development only) Launchers, projectiles, aim solver, recoil, FX
  floating_boat_template/      (development only) The boat template plus weapons, for the demo
systems/                 Demo-level support code: camera rig, debug panel, compass HUD
demo/                    Demo scenes, ship/buoy instances and third-party assets
tools/                   Development scripts (gd_lint.py: GDScript warnings via the editor's language server)
```

Each addon has a `README.md` describing what it does, how to use it and how it
works inside. `systems/README.md` covers the demo support code. `AGENTS.md`
holds the working rules for anyone (human or agent) changing the code.

## How the pieces fit

```
WindSystem ──wind speed/dir──▶ OceanSystem ◀──sun/sky colors, clouds── SkySystem ◀── wind (cloud drift)
								   │  compute: spectrum → FFT → displacement/normal maps
								   │  shader:  displacement, foam, reflections, cutouts
								   │  iWave:   wakes and foam from HullWaterFootprint
								   ▼
		WaterSurface (core): submit_query / get_query_result   (GPU point query, async readback)
								   ▼
					 BuoyantBody (buoyancy + sinking) ── forces ──▶ RigidBody3D (FloatingBoat)
								   ▲            │ probe wet/dry states → your gameplay
								   │ group_destroyed
 ProjectileWeaponController        │
   └─ ProjectileLauncher ──projectile──▶ ProjectileHitbox ──▶ HitboxHealthManager
```

Systems never reference each other directly. What several of them share lives
in the `core` addon (the `WaterSurface` contract, RenderingDevice helpers);
everything else goes through duck-typed methods, node groups and signals. Each
addon can be dropped into another project with `core` alone (buoyancy also
needs some water in the scene that registers a `WaterSurface`), except
`boat_template`, which composes them. The projectile weapons and the
`floating_boat_template` that adds them to the boat are the demo's gameplay and
not part of the open-source addons.

## Credits

- Wave simulation origin: Ethan Truong (2Retr0), MIT — `LICENSE_original`.
- Ship and buoy models under `demo/assets/` are third-party Sketchfab assets.
- Stars: the Bright Star Catalogue, 5th Revised Ed. (Hoffleit & Warren 1991;
  CDS catalogue V/50), baked by `tools/bake_star_catalog.py`.
- Milky Way: NASA/Goddard Space Flight Center Scientific Visualization Studio,
  Deep Star Maps 2020 (https://svs.gsfc.nasa.gov/4851). Gaia DR2: ESA/Gaia/DPAC.
  Baked by `tools/bake_milky_way.py`; redistribution terms to be confirmed.
- This project: MIT — `LICENSE`.
