# Projectile Launcher System Codebase

## 入口

`projectile_launcher.tscn` 是一个挂载 `projectile_launcher.gd` 的 `Node3D`。可以直接实例化，也可以手动创建 `Node3D` 并挂载脚本。

`plugin.cfg` 和 `projectile_launcher_system_plugin.gd` 只负责插件识别，不参与运行时逻辑。

## 主要脚本

`projectile_launcher.gd` 是发射入口。它负责：

- 解析枪口 transform。
- 计算散布后的发射方向。
- 实例化弹丸。
- 配置弹丸 collision layer 和 mask。
- 实例化枪口焰。
- 调用 recoil receiver。
- 发出 `fired(projectile, fire_direction, shot_data)` 信号。

`projectile.gd` 是默认弹丸脚本。它继承 `RigidBody3D`，通过 `launch()` 设置质量、线速度、阻力和生命周期。阻力在 `_physics_process()` 中作为速度平方阻力施加。

`muzzle_flash.gd` 是默认枪口焰脚本。它继承 `Node3D`，运行时创建 `GPUParticles3D` 和 `OmniLight3D`，播放后自动销毁。

`cannon_slide_recoil.gd` 是视觉后坐力 driver。它用一个标量后坐偏移和速度模拟目标节点沿局部轴的弹簧阻尼运动。

`physics_recoil.gd` 是物理后坐力 driver。它对目标 `RigidBody3D` 施加与发射方向相反的 impulse。

## 预制场景

`default_projectile.tscn` 是默认球体弹丸：

- 根节点：`RigidBody3D`
- 碰撞层：Layer 2，项目中命名为 `Projectile`
- 碰撞掩码：Layer 3，项目中命名为 `Hitbox`
- 碰撞：`SphereShape3D`
- 显示：`SphereMesh`
- 脚本：`projectile.gd`

`default_muzzle_flash.tscn` 是默认枪口焰：

- 根节点：`Node3D`
- 脚本：`muzzle_flash.gd`
- 粒子和灯光由脚本在运行时创建

## 发射方向

如果调用 `fire(direction)` 且 `direction` 非零，Launcher 使用传入的世界方向。

如果 `direction` 为零，Launcher 使用 `muzzle_path` 指向节点的 `-Z` 方向。

如果没有 `muzzle_path`，Launcher 使用自身 `-Z` 方向。

## 散布

散布在 `ProjectileLauncher._apply_spread()` 中计算。

实现方式是围绕基础方向构建一个圆锥，并在圆锥内均匀随机生成方向。`spread_degrees` 是圆锥半角。

## 碰撞层

`ProjectileLauncher` 默认会递归查找弹丸实例中的所有 `CollisionObject3D`，并设置：

```gdscript
collision_layer = projectile_collision_layer
collision_mask = projectile_collision_mask
```

默认值是 `projectile_collision_layer = 2` 和 `projectile_collision_mask = 4`，也就是弹丸位于 Layer 2，只检测 Layer 3。项目的 `project.godot` 将这两层命名为 `Projectile` 和 `Hitbox`。

如果自定义弹丸需要自己管理碰撞层，可以关闭 `configure_projectile_collision`。

## Recoil Receiver 边界

Launcher 不依赖任何具体 recoil 类型。它只遍历 `recoil_receiver_paths`，并在节点存在 `apply_recoil()` 方法时调用：

```gdscript
receiver.apply_recoil(fire_direction, shot_data)
```

这允许后续添加 `CameraRecoil`、`AimRecoil`、`GunPatternRecoil`，而不需要修改 Launcher。

## Cannon Slide Recoil 逻辑

`CannonSlideRecoil` 在 `_ready()` 记录目标节点初始 local `position` 作为 `rest_position`。

每次 `apply_recoil()`：

```gdscript
_recoil_velocity += recoil_strength * kick_velocity_per_strength
```

每帧：

```gdscript
acceleration = -offset * spring_strength - velocity * damping
velocity += acceleration * delta
offset += velocity * delta
```

随后 clamp 到 `[0, max_recoil_distance]`。`recoil_axis` 先按目标节点自身局部空间解释，再转换到目标父节点空间，最后设置：

```gdscript
target.position = rest_position + axis_in_target_parent_space * offset
```

因此它能自然支持连发叠加，不会出现重复播放动画曲线导致的断裂。

## Physics Recoil 逻辑

`PhysicsRecoil` 会优先使用配置的 `rigid_body_path`，否则向父节点链查找第一个 `RigidBody3D`。

基础冲量：

```gdscript
projectile_mass * initial_speed
```

如果 `use_projectile_momentum == false`，改用 `fallback_impulse`。

最终冲量：

```gdscript
-fire_direction.normalized() * base_impulse * impulse_multiplier * recoil_strength
```

如果配置了 `impulse_point_path`，使用 `RigidBody3D.apply_impulse()` 并传入相对刚体中心的作用点偏移；否则使用 `apply_central_impulse()`。
