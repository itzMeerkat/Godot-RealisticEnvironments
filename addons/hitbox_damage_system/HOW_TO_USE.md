# Hitbox Damage System HOW TO USE

## 安装

1. 将 `addons/hitbox_damage_system/` 复制到目标项目的 `res://addons/hitbox_damage_system/`。
2. 在 Godot 中打开 `Project > Project Settings > Plugins`，启用 `Hitbox Damage System`。
3. 给可受击目标添加一个 `HitboxHealthManager`，并在目标模型或刚体下添加一个或多个 `ProjectileHitbox`。

## 基础结构

```text
TargetRigidBody3D
  HitboxHealthManager
  Hitboxes
    HullHitbox            script: ProjectileHitbox
      CollisionShape3D
  HitboxHealthDebugUI     optional
```

`ProjectileHitbox` 默认检测 physics layer 2 的 projectile，并位于 physics layer 3 的 hitbox。项目中的 layer 名称是 `Projectile` 和 `Hitbox`。

## 伤害与血量

`HitboxHealthManager` 按 `hitbox_group` 管理血量，例如 `hull`、`mast`、`engine`。

主要参数：

- `group_max_health`：每个 hitbox group 的最大血量。
- `group_damage_multipliers`：每个 group 的伤害倍率。
- `damage_per_momentum`：默认伤害来自 projectile 动量大小乘以该系数。
- `minimum_hit_damage`：没有显式伤害时的最低伤害。
- `destroy_projectile_on_hit`：命中后是否销毁 projectile。
- `hit_effect_scene`：命中特效场景。建议实现 `play()`。

## Projectile 判定

`ProjectileHitbox` 不强依赖任何具体 projectile 类型。满足任一条件即可被识别为 projectile：

- 节点在 `projectile` group 中。
- 节点实现 `launch()` 方法。

`ProjectileLauncher` 发射的 projectile 会自动加入 `projectile` group，并写入 source metadata，用于 `ignore_own_projectiles`。

## 外部行为

系统不会直接执行沉没、爆炸、计分或删除目标。需要外部系统监听：

```gdscript
hitbox_health_manager.group_destroyed.connect(_on_group_destroyed)
```

例如 `BuoyantSinkingMonitor` 可以连接到 `group_destroyed`，在 `hull` 被摧毁时开始沉没。

## Debug UI

`HitboxHealthDebugUI` 是可选组件。它只导出 `debug_enabled` 和 `hitbox_manager_path`；标题、位置、尺寸、刷新频率和显示分组策略都固定在代码中，避免调试显示细节占用 Inspector。
