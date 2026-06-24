# Floating Boat Template HOW TO USE

## 安装

1. 将 `addons/floating_boat_template/` 与依赖 Addon 一起复制到目标项目。
2. 依赖 Addon：`ocean_system`、`buoyancy_system`、`projectile_launcher_system`、`hitbox_damage_system`。
3. 在 Godot 中启用 `Floating Boat Template`，然后实例化 `res://addons/floating_boat_template/floating_boat.tscn`。

## 推荐结构

`floating_boat.tscn` 提供稳定功能节点：

```text
FloatingBoat
  CollisionShape3D
  BuoyantBody
  BuoyantSinkingMonitor
  HitboxHealthManager
  HitboxHealthDebugUI
  ProjectileHitboxes
  BoatWaterInteractor
  SimpleBoatController
  BoatWakeTrail
  CameraTargets
    ThirdPersonFocus
    FirstPersonSeat
  BuoyancyProbeVolume
    GeneratedProbes
  PhysicsRecoil
  ProjectileFireInputController
  ProjectileAimController
```

用户实例化后通常只改实例：

- 添加或替换可见模型，例如 `ModelRoot/UserBoatModel`。
- 调整 `RigidBody3D.mass`、`center_of_mass`、阻尼和扶正力矩。
- 替换或调整 `CollisionShape3D`。
- 设置 `BuoyancyProbeVolume.source_paths` 指向船体低模/代理网格，然后在编辑器中生成并保存 probes。
- 添加 `ProjectileHitbox` 到 `ProjectileHitboxes` 下，并设置 `hitbox_group`。
- 配置 `HitboxHealthManager.group_max_health` 和命中特效。
- 添加或指向模型里的 `ProjectileLauncher`/muzzle 节点，并配置 `ProjectileFireInputController` 与 `ProjectileAimController` 的 launcher paths。
- 移动 `CameraTargets/ThirdPersonFocus` 和 `CameraTargets/FirstPersonSeat`。

## 模型替换

不要把模板脚本写死到某个 GLB 内部路径。推荐让 demo 或用户场景保存具体路径：

```text
FloatingBoat instance
  ModelRoot
    UserBoatModel.glb
  ProjectileHitboxes
    HullHitbox
  BuoyancyProbeVolume
    GeneratedProbes
```

如果炮口需要跟随模型动画，`ProjectileLauncher` 可以留在稳定功能树中，只把 `muzzle_path` 指向模型或 `BoneAttachment3D` 下的 `Marker3D`。如果 launcher 已经在模型树中，也可以直接配置 `ProjectileFireInputController.launcher_paths` 指向它们。

## Demo

`demo/floating_box.tscn` 现在是 `floating_boat.tscn` 的实例。它保留 pirate ship 模型、具体炮位路径、生成 probe、碰撞形状和调参数据，用于展示如何把模板应用到具体船型。
