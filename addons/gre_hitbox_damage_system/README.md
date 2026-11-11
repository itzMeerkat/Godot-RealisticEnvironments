# Hitbox Damage System

**English** · [简体中文](README.zh-CN.md)

Hitboxes that detect projectiles, and health kept per group (e.g. `hull`,
`mast`). It also has a smoke hit effect and an optional health panel. It
depends on nothing.

## How it works

- A `GREProjectileHitbox` is an `Area3D`. When a projectile body enters it, the
  hitbox builds a hit record (position, velocity, mass, momentum) and reports
  it to its manager. A projectile is any body in group `projectile` or with a
  `launch()` method.
- A `GREHitboxHealthManager` turns each hit into damage for the hitbox's group:
  - the hit's own `damage` value if it has one, used as is;
  - otherwise projectile momentum × `damage_per_momentum` × the group's
    multiplier (`group_damage_multipliers`) × the hitbox's
    `damage_multiplier`, but at least `minimum_hit_damage`.

  It then emits signals, spawns the hit effect and frees the projectile.
  Projectiles fired by the manager's own body are ignored.
- When a group's health reaches 0, the manager emits `group_destroyed` once.
  Anything can react to it (e.g. sink or remove the ship).

## How to use

```
Ship (RigidBody3D)
└─ Hitboxes (GREHitboxHealthManager)
   ├─ HullHitbox  (GREProjectileHitbox, hitbox_group = "hull") + CollisionShape3D
   └─ MastHitbox  (GREProjectileHitbox, hitbox_group = "mast") + CollisionShape3D
```

1. Add a `GREHitboxHealthManager`, and set each group's health in
   `group_max_health`, e.g. `{"hull": 300.0, "mast": 60.0}`. Other groups use
   `default_group_max_health`.
2. Add `GREProjectileHitbox` areas below it, with collision shapes and a
   `hitbox_group`. Set each area's `collision_mask` to include the
   projectiles' physics layer (the demo uses layer 3 "Hitbox" for hitboxes and
   layer 2 "Projectile" for projectiles).
3. Connect `group_destroyed` to whatever should react.

A hitbox reports to the nearest manager above it, or to its `manager_path`. In
the editor it warns when it has none.

- Signals: `projectile_hit` (hitbox); `hitbox_hit`, `group_health_changed`,
  `group_destroyed` (manager).
- Methods: `handle_projectile_hit(hitbox, projectile, hit_data)`,
  `get_group_health()`, `get_group_max_health()`, `set_group_health()`,
  `is_group_destroyed()`, `reset_health()`.
- To deal damage from your own code (collisions, scripts), call
  `handle_projectile_hit(null, null, {"hitbox_group": &"hull", "damage": 25.0, "position": point})`
  (`position` places the hit effect).
- `hit_effect_scene` (default: a smoke puff) spawns at each hit;
  `debug_ui_enabled` shows a health bar per group.
