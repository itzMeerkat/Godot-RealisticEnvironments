# Removed Sea Spray Prototype

This document preserves the broad idea behind the removed sea spray implementation. The feature was removed from the runtime project because the result was not strong enough for regular gameplay use and the implementation added a relatively large amount of shader, particle, texture, and scene complexity.

## Original Approach

The removed implementation used a `GPUParticles3D` emitter attached under the water node. It did not simulate airborne spray as independent fluid. Instead, it approximated spray as many billboarded particles that were conditionally activated over the ocean surface.

The pipeline was roughly:

1. Distribute particles evenly over the emitter's local XZ area.
2. At particle start, sample the ocean normal/foam texture arrays at the particle's world-space start position.
3. Activate only particles in high-foam areas with a sufficiently upright normal.
4. Scale active particles by foam amount and normal direction.
5. Move active particles by sampling the water displacement maps over their lifetime.
6. Add a simple parabolic vertical offset so each particle rises and falls like a splash.
7. Render each particle as a billboarded quad using a static spray texture.
8. Fade/dissolve the sprite with a noise texture and a per-particle impulse curve.

The particle process shader used the same ocean globals as the water shader:

```text
displacements
normals
previous_displacements
previous_normals
wave_blend_alpha
map_scales
```

This allowed particles to follow the double-buffered wave output and remain visually tied to the ocean surface.

## Why It Was Removed

The implementation had several practical problems:

 * Particle density was inefficient. Increasing the particle count often produced only a small increase in visible spray because most evenly distributed particles were culled by the foam threshold.
 * The effect depended heavily on the quality and stability of the foam channel, so low wave update rates could make activation feel uneven.
 * Particles followed the displacement map in a simple way, which could produce jitter or sliding rather than a convincing airborne spray motion.
 * The billboard material was unlit and mostly color-tinted by foam color, so it did not integrate well with the ocean lighting model.
 * The feature added extra shader globals, material resources, texture imports, scene nodes, and runtime UI controls for an effect that was not visually strong enough.

## Removed Runtime Assets

The following implementation pieces were removed:

 * `WaterSprayEmitter` nodes from `main.tscn` and `assets/water/ocean_system.tscn`
 * `sea_spray_enabled` runtime toggle from `OceanSystem`
 * ImGui sea spray toggle from `main.gd`
 * `assets/water/mat_spray.tres`
 * `assets/water/sea_spray.png`
 * `assets/water/sea_spray.png.import`
 * `assets/shaders/spatial/sea_spray_particle.gdshader`
 * `assets/shaders/spatial/sea_spray.gdshader`

Sea foam itself was not removed. The ocean still computes foam in the normal map alpha channel and uses it for water shading.

## Better Future Direction

A future sea spray system should likely be designed as a more deliberate VFX layer rather than a dense uniform particle grid. Possible directions:

 * Spawn particles from compact candidate regions derived from foam/whitecap data instead of distributing particles evenly across a large box.
 * Use a compute-generated spawn list or screen/world-space emitter cells so particle budget is spent only where spray is likely visible.
 * Give spray particles explicit velocity, wind influence, drag, and lifetime variation instead of mostly following water displacement.
 * Use lit or approximate-lit materials so spray responds more naturally to sun direction and fog.
 * Separate crest mist, splash bursts, and fine airborne droplets into different emitters or LOD tiers.
 * Fade the effect aggressively with distance and camera angle to keep it cheap.

The old prototype was useful as a proof of concept, but the main ocean renderer is cleaner without it.
