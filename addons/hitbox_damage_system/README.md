# Hitbox Damage System

`Area3D` hitboxes that detect projectiles, a manager that turns hits into
grouped health (e.g. `hull`, `mast`) and emits signals, a smoke hit effect, and
an optional debug health panel. No dependency on the launcher or buoyancy addons.

## Visual effects

- **Hit smoke:** a smoke puff at each impact point, facing back along the
  shot.

## Setup

```
Ship (RigidBody3D)
└─ Hitboxes (HitboxHealthManager, Node3D)
   ├─ HullHitbox  (ProjectileHitbox, hitbox_group = "hull") + CollisionShape3D(s)
   └─ MastHitbox  (ProjectileHitbox, hitbox_group = "mast") + CollisionShape3D(s)
```

- `HitboxHealthManager` is the hitbox container: in `_ready` (and on
  `refresh_hitboxes()`) it registers itself with every `ProjectileHitbox`
  below it. A hitbox without a registered manager uses `manager_path` or
  searches up its ancestors for a node with `handle_projectile_hit()`.
- `ProjectileHitbox` configures itself on physics layer 3 (bit 4, "Hitbox")
  with mask 2 (bit 2, "Projectile") unless `configure_collision_layers` is off.
- Connect `group_destroyed` to whatever should react — e.g.
  `BuoyantBody._on_hitbox_group_destroyed`.

## Hit flow

1. A body enters a `ProjectileHitbox`. It counts as a projectile if it's in
   group `projectile` or has a `launch()` method.
2. The manager's `should_ignore_projectile()` drops the hit if the projectile's
   `source_rigid_body_instance_id` metadata matches the manager's owner body
   (own-shot filtering, `ignore_own_projectiles`).
3. The same projectile can't hit the same hitbox again within
   `same_projectile_hit_interval`.
4. Hit data (`position`, `velocity`, `speed`, `mass`, `momentum`,
   `momentum_magnitude`, `hitbox_group`, `damage_multiplier`, …) goes to
   `projectile_hit` and `handle_projectile_hit()`.
5. Damage = explicit `hit_data.damage` if present, otherwise
   `momentum × damage_per_momentum × group multiplier × hitbox multiplier`,
   at least `minimum_hit_damage`.
6. Health for the group drops; `hitbox_hit`, `group_health_changed` and (once,
   at 0) `group_destroyed` fire. `hit_effect_scene` spawns at the impact point
   facing back along the velocity, and the projectile is freed if
   `destroy_projectile_on_hit`.

Per-group max health and damage multipliers are dictionaries keyed by group
name (`group_max_health`, `group_damage_multipliers`); unlisted groups use
`default_group_max_health` and multiplier 1.

Manager API: `handle_projectile_hit(hitbox, projectile, hit_data)`,
`get_group_health()`, `get_group_max_health()`, `set_group_health()`,
`is_group_destroyed()`, `reset_health()`, `refresh_hitboxes()`.

## Effects and debug

- `ProjectileHitSmokeEffect` (`default_projectile_hit_smoke.tscn`) builds a
  one-shot `GPUParticles3D` smoke puff in code and frees itself. Any effect
  scene with `play()`, or a `GPUParticles3D`, works as `hit_effect_scene`.
- `debug_ui_enabled` on the manager shows a panel with a health bar per group
  in `group_max_health`, updated on every health change. It is an internal
  `CanvasLayer` built in `_ready`.
