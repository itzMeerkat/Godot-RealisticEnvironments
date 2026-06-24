# Hitbox Damage System Codebase

## 入口

`plugin.cfg` 和 `hitbox_damage_system_plugin.gd` 只负责插件识别，不参与运行时逻辑。

## 主要脚本

`projectile_hitbox.gd` 是 `Area3D` 命中盒。它负责：

- 设置 hitbox collision layer/mask。
- 监听 `body_entered`。
- 过滤 projectile。
- 生成 hit data，包括位置、速度、质量、动量和 `hitbox_group`。
- 调用 manager 的 `handle_projectile_hit()`。

`hitbox_health_manager.gd` 是 grouped health 和 damage 路由器。它负责：

- 自动收集子树中的 `ProjectileHitbox`。
- 按 `hitbox_group` 初始化和维护血量。
- 根据动量、group multiplier、hitbox multiplier 计算伤害。
- 生成命中特效。
- 发出 `hitbox_hit`、`group_health_changed`、`group_destroyed` 信号。

`hitbox_health_debug_ui.gd` 是运行时调试 UI。它通过 manager 的 duck-typed API 读取 `get_group_health()` 和 `get_group_max_health()`。

`projectile_hit_smoke_effect.gd` 和 `default_projectile_hit_smoke.tscn` 是默认一次性烟雾命中特效。

## 依赖边界

该 addon 不直接依赖 `projectile_launcher_system`。如果 projectile 是由 `ProjectileLauncher` 发射的，source metadata 会被 manager 用于 `ignore_own_projectiles`；没有这些 metadata 时只是不启用 own-projectile 过滤。
