# GodotOceanWaves

A Godot 4.7 (Forward+) sandbox for FFT-simulated open ocean and the gameplay
systems that sit on top of it: GPU water-height queries, probe-based buoyancy,
a physically-driven sailing ship, cannons with ballistic aiming, hitbox damage,
and sinking.

The wave simulation started as a fork of
[2Retr0/GodotOceanWaves](https://github.com/2Retr0/GodotOceanWaves) — see
`README_original.md` for the upstream write-up of the spectrum/FFT math and
`LICENSE_original` for its license.

## Running the demo

1. Open the folder in Godot **4.7** with the **Forward+** renderer. The ocean
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

## Repository layout

```
project.godot            Godot manifest (main scene, input map, physics layer names)
addons/                  Reusable systems, each self-contained with its own README
  ocean_system/          FFT ocean: compute pipeline, water shader, mesh, reflections, queries
  sky_system/            Day/night sky, atmosphere, sun + moon lights, starfield, astronomy, volumetric clouds
  wind_system/           Wind provider node with procedural gusts
  exposure_system/       Camera exposure from the scene's light meter, eye-like adaptation
  buoyancy_system/       Probe-based buoyancy, probe generation, sinking monitor
  hitbox_damage_system/  Projectile hitboxes, grouped health, hit effects
  projectile_launcher_system/  Launchers, projectiles, aim solver, recoil, FX
  floating_boat_template/      Boat scene that wires all of the above together
systems/                 Demo-level support code: camera rig, debug panel, compass HUD
demo/                    Demo scenes, ship/buoy instances and third-party assets
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
        submit_surface_query / get_surface_query_result   (GPU point query, async readback)
                                   ▼
                     BuoyantBody (buoyancy + sinking) ── forces ──▶ RigidBody3D (FloatingBoat)
                                   ▲            │ probe wet/dry states → your gameplay
                                   │ group_destroyed
 ProjectileWeaponController        │
   └─ ProjectileLauncher ──projectile──▶ ProjectileHitbox ──▶ HitboxHealthManager
```

Systems talk through duck-typed methods, node groups and signals rather than
hard references, so each addon can be dropped into another project on its own
(except `buoyancy_system`, which needs `ocean_system`, and
`floating_boat_template`, which composes everything).

## Credits

- Wave simulation origin: Ethan Truong (2Retr0), MIT — `LICENSE_original`.
- `demo/player/camera.gd`: free-look camera by Marc Nahr, MIT (header in file).
- Ship and buoy models under `demo/assets/` are third-party Sketchfab assets.
- This project: MIT — `LICENSE`.
