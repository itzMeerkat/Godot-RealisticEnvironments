# Floating Boat Template Codebase

## 入口

`floating_boat.tscn` 是可复用模板场景。它只包含稳定功能节点和默认参数，不包含 demo 资产。

`plugin.cfg` 和 `floating_boat_template_plugin.gd` 只负责插件识别，不参与运行时逻辑。

## 主要脚本

`floating_boat.gd` 继承 `FloatingDebugBody`，作为模板 root 类型。它目前只提供明确的 `class_name FloatingBoat`，具体物理稳定行为来自 `FloatingDebugBody`。

`simple_boat_controller.gd` 对父级 `RigidBody3D` 施加前进/倒退力、转向力矩和横向阻尼。

`boat_water_interactor.gd` 实现船首泡沫源。它加入 `manual_water_foam_source` group，并通过 `get_manual_foam_sources()` 给 `OceanSystem` 提供世界空间泡沫数据。

`boat_wake_trail.gd` 实现船尾 wake 泡沫。它记录世界空间轨迹点，并按年龄衰减泡沫强度和扩大半径。

`floating_boat_animation_autoplay.gd` 是可选模型动画辅助脚本，用于把指定 `AnimationPlayer` 的某个动画设为循环并播放。

## 依赖系统

- `BuoyantBody` 和 `BuoyancyProbeVolume` 来自 `buoyancy_system`。
- `ProjectileFireInputController`、`ProjectileAimController` 和 recoil drivers 来自 `projectile_launcher_system`。
- `HitboxHealthManager`、`ProjectileHitbox` 和 health UI 来自 `hitbox_damage_system`。
- `BoatWaterInteractor` 和 `BoatWakeTrail` 通过 `manual_water_foam_source` 与 `OceanSystem` 的 manual foam path 集成。

## Demo 实例

`demo/floating_box.tscn` 实例化 `floating_boat.tscn`，并覆盖：

- root 质量、重心和扶正参数。
- 碰撞形状。
- camera targets。
- hitbox health 配置和船体 hitbox shape。
- pirate ship GLB 实例和炮位路径。
- buoyancy probe source paths 和已生成 probes。
- projectile launcher、aim controller、fire controller、physics recoil 参数。
