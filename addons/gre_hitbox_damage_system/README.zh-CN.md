# Hitbox Damage System（受击伤害系统）

[English](README.md) · **简体中文**

检测投射物的受击区（hitbox），以及按分组记录的生命值（例如 `hull` 船体、`mast` 桅杆）。
另外还有一个烟雾命中效果和可选的生命值面板。它不依赖任何插件。

## 工作原理

- `GREProjectileHitbox` 是一个 `Area3D`。投射物刚体进入它时，它生成一条命中记录（位置、
  速度、质量、动量）并报告给它的管理器。投射物指任何属于 `projectile` 组或带有
  `launch()` 方法的物体。
- `GREHitboxHealthManager` 把每次命中转换为对该受击区所属分组的伤害：
  - 如果命中记录自带 `damage`，就直接使用它；
  - 否则伤害 = 投射物动量 × `damage_per_momentum` × 分组倍率
    （`group_damage_multipliers`）× 受击区的 `damage_multiplier`，且不低于
    `minimum_hit_damage`。

  随后它发出信号、生成命中效果并释放投射物。管理器所属物体自己发射的投射物会被忽略。
- 某个分组的生命值降到 0 时，管理器发出一次 `group_destroyed`。任何节点都可以响应它，
  例如让船沉没或移除它。

## 使用方法

```
Ship (RigidBody3D)
└─ Hitboxes (GREHitboxHealthManager)
   ├─ HullHitbox  (GREProjectileHitbox, hitbox_group = "hull") + CollisionShape3D
   └─ MastHitbox  (GREProjectileHitbox, hitbox_group = "mast") + CollisionShape3D
```

1. 添加 `GREHitboxHealthManager`，在 `group_max_health` 中设置每个分组的生命值，例如
   `{"hull": 300.0, "mast": 60.0}`。其他分组使用 `default_group_max_health`。
2. 在它下面添加带碰撞形状和 `hitbox_group` 的 `GREProjectileHitbox` 区域。把每个区域的
   `collision_mask` 设为包含投射物所在的物理层（演示场景中受击区在第 3 层
   "Hitbox"，投射物在第 2 层 "Projectile"）。
3. 把 `group_destroyed` 连接到需要响应的节点。

受击区会向它上方最近的管理器报告，或向 `manager_path` 指定的管理器报告。找不到管理器
时，它会在编辑器中给出警告。

- 信号：`projectile_hit`（受击区）；`hitbox_hit`、`group_health_changed`、
  `group_destroyed`（管理器）。
- 方法：`handle_projectile_hit(hitbox, projectile, hit_data)`、
  `get_group_health()`、`get_group_max_health()`、`set_group_health()`、
  `is_group_destroyed()`、`reset_health()`。
- 在自己的代码中造成伤害（碰撞、脚本）时，调用
  `handle_projectile_hit(null, null, {"hitbox_group": &"hull", "damage": 25.0, "position": point})`
  （`position` 决定命中效果出现的位置）。
- `hit_effect_scene`（默认是一团烟雾）在每次命中处生成；`debug_ui_enabled` 为每个
  分组显示一条生命值条。
