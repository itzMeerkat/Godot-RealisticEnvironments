# Volumetric clouds plan

Status: implemented · Written 2026-10-16 · Target: Godot 4.8 Forward+

The clouds used to be raymarched into one cubemap around the camera, with the
camera clamped below the cloud base. Every consumer drew that cubemap as a
sheet at the base's distance, behind all geometry. You could not fly into the
clouds or above them. This records how the clouds became a volume the camera
can be anywhere in.

## Design

One density field and one light model, in `cloud_common.glslinc`, marched three
ways:

| Pass | Observer | Used by |
| --- | --- | --- |
| `GREVolumetricCloudEffect` (screen) | the camera | the camera's view |
| `GRECloudRenderer.sea_cubemap` | the sea below the camera (clamped under the base) | water reflection, the atmosphere's cloud shadows and dome light, the mirrored camera's starfield |
| `GRECloudRenderer.camera_cubemap` (256², all faces) | the camera | the sky's radiance map, the light meter |

- **Ray setup** (`cloud_ray_segments()`): the layer is a spherical shell. A
  ray from above or inside it can dip below the base and come back out, so it
  has up to two stretches. Each ray stops at the sea or at a given limit (the
  scene's depth). The steps grow with a power of the distance along the path:
  2 outside the layer, rising to 3 inside, where a cloud around the camera
  hides everything beyond about 100 m.
- **Lighting:** unchanged physics (single scattering with delta-Eddington,
  two-stream for higher orders). The viewing cosine is now signed, so cloud
  tops seen from above show the upward field. The light behind the cloud
  comes from below for rays going down.
- **Altitudes** are above `sea_level`, as the atmosphere's are. The planet
  radius is the atmosphere's (6371 km), so the clouds sit in the atmosphere
  exactly where the haze is split.
- **Noise tiling:** seen from above, the 9 km shape-noise tiles lined up in
  rows toward the horizon. The weather map's free `a` channel now holds a
  slowly varying warp that shifts the shape noise by up to 0.35 tiles.

### The screen pass

The pass runs after the transparent pass, on a cloud buffer of half the screen
per axis. Cloud pixel p stands for screen pixel 2p.

1. **Trace:** one cloud pixel of every 2×2 block per frame, up to the scene's
   depth. It writes the cloud, the cloud's distance (opacity-weighted; for
   empty rays, where the ray enters the layer) and the scene's distance.
2. **Reconstruct:** each pixel takes the trace nearby whose ray stopped at the
   same surface. It reprojects into the previous frame at that trace's cloud
   distance, or as a direction for the sky. History is kept only where the
   same surface was there last frame, and it is clamped to the matching
   traces' range. Moving objects (the bobbing boat's sails) and fast flight
   show no ghosting.
3. **Composite:** a depth-aware upsample. With MSAA the colour is already
   resolved, so a pixel's near and far surfaces each get their own cloud,
   weighted by sample coverage. The cloud sits in the camera's view volume at
   its distance: `B (1 − a) + a I + T cloud`.

The buffers live in the viewport's render buffers (`create_texture` under
context `volumetric_clouds`), so editor viewports and resizes keep separate
histories. With the effect present, the sky and the starfield leave the
camera's view to it (`screen_clouds`). Without it, the sky falls back to the
camera cubemap, and a configuration warning says so.

### Lights

`DirectionalLight3D` energy uses `sun_light_scale` below the base and rises to
the full light at the layer's top. `_update_sky()` reruns when that share moves
by more than 0.02. The atmosphere's lights and `get_sun_visibility()` keep the
sea's share, because the water is under the clouds.

## Measurements

RTX 4070 Ti, 1280×720, `cloudy`, 64 view steps. The screen pass costs
0.13–0.8 ms of GPU time: 1.8 → 1.9 ms at sea level, 2.4 → 3.2 ms inside the
layer, 2.9 → 3.5 ms above it.

## Deferred verification

- Fast day cycles and preset transitions while above the clouds.
- XR (multiview): every view keeps its own buffers, but this is untested.
- Editor viewports in split view (up to 16 histories are kept).
- Clouds shadowing the scene (not done: a top-down transmittance map would
  feed the water and the lights).
