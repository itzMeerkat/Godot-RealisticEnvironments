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
  hitbox_damage_system/  Projectile hitboxes, grouped health, hit effects
  projectile_launcher_system/  Launchers, projectiles, aim solver, recoil, FX
  floating_boat_template/      Boat scene that wires all of the above together
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
`floating_boat_template`, which composes everything.

## Road to a commercial release

What the addons still need before they can be sold as an industry-grade ocean
for Godot. The hitbox and projectile addons are demo gameplay and out of scope
here. Items are grouped by priority; each group assumes the ones above it.

**Where we stand.** The open-ocean core is strong: a physically normalized
JONSWAP FFT with per-cascade update rates and crossfaded spectrum changes, a
CDLOD mesh out to a curved horizon, physical water optics (absorption,
scattering, refraction, caustics, rough-surface Fresnel, sun glitter), async
GPU surface queries, probe buoyancy, hull cutouts and an iWave wake and
bow-wave simulation, plus a physical sky, atmosphere, volumetric clouds and
exposure. What is missing is mostly everything *around* the open ocean, and
the work that turns a sandbox into a product.

### Tier 1: release blockers

- [ ] **Shallow water and coastlines.** Today depth is one number per cascade
  (`water_depth_meters`). Needed: a baked or runtime top-down depth/terrain
  cache, wave attenuation and shoaling by depth, shoreline foam and swash,
  and no water drawn through terrain above sea level.
- [ ] **Underwater.** The camera cannot go below the surface: needed are
  underwater fog and absorption (sharing the water's optical properties), the
  surface seen from below (Snell's window, total internal reflection), a
  waterline/meniscus where the surface crosses the lens, and caustics from
  below.
- [ ] **Works without our sky.** The ocean must look right with a stock Godot
  `WorldEnvironment` (procedural/physical sky, Godot fog, physical light units
  on or off). The sky, atmosphere and exposure addons become an optional
  upgrade, not a requirement.
- [ ] **Platform and renderer coverage.** Verified support for Forward+ and
  Mobile on Windows, Linux, macOS (Metal) and Steam Deck; a defined fallback
  for the Compatibility renderer (no compute: a GPU-light or CPU wave mode).
  Quality presets (Low → Ultra) as a resource, where lower tiers compile
  features out instead of branching on uniforms.
- [ ] **Headless servers and multiplayer.** Dedicated servers have no
  `RenderingDevice`, so today they have no waves and no buoyancy. Needed: a
  CPU wave evaluation that matches the GPU surface (for servers and for
  synchronous one-off queries), an exported wave seed, and an API to set and
  sync the ocean clock so every peer sees the same sea.
- [ ] **Any camera, any viewport.** Everything follows
  `get_viewport().get_camera_3d()`. Needed: an explicit camera/viewport
  binding, split-screen and SubViewport support, and stereo/XR (verified in
  OpenXR).
- [ ] **Large worlds.** Floating-origin support (shift the LOD grid, the
  interaction window, queries and hull state together) and checks on
  double-precision builds. Long-session time precision: the ocean clock
  reaches the GPU as 32-bit floats, so the wave phase needs a loop period or
  a rebased clock.
- [ ] **Measured performance budget.** GPU timings per pass (RenderingDevice
  timestamps) exposed as Godot custom monitors, a benchmark scene, and
  published numbers per preset and GPU class. Includes running the open
  *Deferred verification* list in `docs/water-interaction-plan.md`.
- [x] **Release-safe error handling.** `assert()` is stripped from release
  exports; checks that guard runtime state now report (`push_error`) and
  degrade or disable the feature in release builds too.
- [ ] **Licensing and packaging.** Each addon installable on its own (Asset
  Library / Godot Asset Store / itch), `plugin.cfg` versions, a changelog and
  semantic versioning, a declared Godot version range. The demo's Sketchfab
  models need verified redistribution licenses or replacements, and the
  commercial license terms (and the upstream MIT notice) must be settled.

### Tier 2: feature parity with leading ocean packages

- [ ] **Local water bodies.** Lakes, ponds and pools at their own heights,
  and rivers along splines with flow, all sharing the shading and buoyancy.
- [ ] **Currents and flow.** A global current and painted/spline flow maps
  that advect foam and normals and carry floating bodies.
- [ ] **Wave shaping inputs.** Regions that calm or amplify waves (harbours,
  storms), directional swell added to the spectrum, and sea-state presets on
  the Beaufort scale that drive wind, spectrum, foam and clouds together.
- [ ] **More interaction sources.** Spheres, capsules and characters
  (swimmers, oars, debris) pushing water, rain ripples, and simulation
  windows for distant ships (today only hulls inside one camera window make
  waves).
- [ ] **Water effects.** A generic splash and spray system driven by impulses
  and buoyancy contact events, whitecap spray and mist (generalizing the
  boat template's bow spray), and rain on the surface.
- [ ] **Reflections and shadows.** Cheaper reflection modes than planar
  (screen-space, probe), cloud shadows on the sea and the scene, and
  documented interplay with Godot's volumetric fog and SDFGI/VoxelGI.
- [ ] **Physics.** Volume-based buoyancy for arbitrary meshes as an
  alternative to probes, compartment flooding, verified Jolt Physics
  behaviour, and ready controllers (outboard motor, sail, oars).
- [ ] **Gameplay queries.** Ray-versus-surface and `is_underwater(point)`
  helpers, a synchronous height lookup (from the CPU evaluation) for
  spawning and AI, and wave-surface-aware projectiles and aiming.
- [ ] **Audio hooks.** Sea-state, hull-speed, slam and splash events and
  parameters for ambience and impact sounds.

### Tier 3: editor experience and documentation

- [ ] **One-click setup.** An editor action that adds a wired ocean
  environment (ocean, wind, optional sky and exposure) to a scene, and
  `@export_tool_button` actions instead of bool toggles for baking.
- [ ] **Editor tooling.** Gizmos for hull footprints, probe volumes and the
  interaction window; bake progress and validation; inspector previews of
  presets.
- [ ] **Documentation.** Built-in class reference from doc comments, a
  getting-started guide, tuning guides (sea states, optics, performance),
  migration notes per release, troubleshooting/FAQ, and one small example
  scene per feature (ocean only, floating object, boat, weather cycle,
  coast, underwater).
- [ ] **Quality assurance.** Unit tests for the CPU math (spectrum
  normalization, cascade intervals, LOD selection, buoyancy), screenshot
  regression scenes, and CI that at least parses every script and shader.

### Tier 4: differentiators

- [ ] Breaking waves and plunging crests, storm and rogue-wave events.
- [ ] Deterministic replay of a sea state (seed + clock) for cinematics and
  networking.
- [ ] Marketing material that leans on what is already unusual: physical
  units end to end, a real atmosphere over the sea, and iWave bow waves.

## Credits

- Wave simulation origin: Ethan Truong (2Retr0), MIT — `LICENSE_original`.
- Ship and buoy models under `demo/assets/` are third-party Sketchfab assets.
- This project: MIT — `LICENSE`.
