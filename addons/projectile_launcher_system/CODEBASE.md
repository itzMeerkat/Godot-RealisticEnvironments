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
- 可选绘制开炮方向调试箭头。
- 发出 `fired(projectile, fire_direction, shot_data)` 信号。

`projectile.gd` 是默认弹丸脚本。它继承 `RigidBody3D`，通过 `launch()` 设置质量、线速度、阻力和生命周期。阻力在 `_physics_process()` 中作为速度平方阻力施加。默认弹丸在 `global_position.y <= waterline_y` 时销毁，避免穿过海面继续下降，并在该路径上生成 projectile 类型配置的入水效果。

`muzzle_flash.gd` 是默认枪口焰脚本。它继承 `Node3D`，运行时创建 `GPUParticles3D` 和 `OmniLight3D`，播放后自动销毁。

`water_impact_effect.gd` 是默认入水效果脚本。它继承 `Node3D`，运行时创建一次性 `GPUParticles3D`，由 `Projectile` 在入水点调用 `play()`。

`cannon_slide_recoil.gd` 是视觉后坐力 driver。它用一个标量后坐偏移和速度模拟目标节点沿局部轴的弹簧阻尼运动。

`physics_recoil.gd` 是物理后坐力 driver。它对目标 `RigidBody3D` 施加与发射方向相反的 impulse。

`projectile_aim_controller.gd` 是瞄准控制器。它根据当前相机视野中心和 `y = aim_plane_y` 平面的交点生成世界空间 aim point，绘制 marker，并让多个 Launcher 或炮模型 yaw 目标水平转向该点。

## 预制场景

`default_projectile.tscn` 是默认球体弹丸：

- 根节点：`RigidBody3D`
- 碰撞层：Layer 2，项目中命名为 `Projectile`
- 碰撞掩码：Layer 3，项目中命名为 `Hitbox`
- 碰撞：`SphereShape3D`
- 显示：`SphereMesh`
- 脚本：`projectile.gd`
- 入水效果：`default_water_impact.tscn`

`default_muzzle_flash.tscn` 是默认枪口焰：

- 根节点：`Node3D`
- 脚本：`muzzle_flash.gd`
- 粒子和灯光由脚本在运行时创建

`default_water_impact.tscn` 是默认炮弹入水效果：

- 根节点：`Node3D`
- 脚本：`water_impact_effect.gd`
- 粒子由脚本在运行时创建

## 入水销毁与效果

`Projectile._physics_process()` 先检查 waterline，再检查生命周期。只有 `destroy_below_water == true` 且 `global_position.y <= waterline_y` 时会进入 `_destroy_with_water_impact()`，生成 `water_impact_effect_scene` 后销毁自身。

效果生成位置使用弹丸当前 XZ 坐标，Y 固定为 `waterline_y`。Projectile 会把效果添加到当前场景根节点，设置世界位置，然后调用效果的 `play()` 方法。如果效果没有 `play()` 但根节点是 `GPUParticles3D`，则直接开启 `emitting`。

这个配置位于 projectile scene 上，因此不同弹丸类型可以拥有不同入水效果，不需要修改 Launcher。

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

## Debug Arrow

`ProjectileLauncher` 是 `@tool` 脚本。启用 `debug_draw_fire_direction` 后，它会创建一个内部 `MeshInstance3D`，名称为 `DebugFireDirectionArrow`，并使用 `ImmediateMesh` 绘制世界空间线段箭头。

该节点通过 `add_child(..., INTERNAL_MODE_BACK)` 创建，不作为场景内容保存。箭头每帧根据当前 `muzzle_path` 或 Launcher 自身 transform 更新。

箭头方向只表示默认开炮方向，即 `-muzzle_transform.basis.z`，不包含散布随机偏移。

## Aim Controller

`ProjectileAimController` 每帧通过 `Camera3D.project_ray_origin()` 和 `Camera3D.project_ray_normal()` 从屏幕中心生成射线。射线与水平面求交：

```gdscript
distance = (aim_plane_y - ray_origin.y) / ray_direction.y
aim_point = ray_origin + ray_direction * distance
```

如果射线平行平面、交点在相机后方或超过 `max_aim_distance`，本帧没有有效 aim point，并隐藏 marker。

Marker 是内部 `MeshInstance3D`，名称为 `AimMarker`，用 `ImmediateMesh` 绘制圆环、十字和中心竖线。中心竖线由 `marker_height` 控制，目的是在海浪或其他表面遮挡圆环时仍可见。

Launcher 对准逻辑只做 yaw 旋转。旋转轴来自 `yaw_reference_path` 的全局 Y 轴；如果没有配置，则使用 Aim Controller 父节点的全局 Y 轴；仍然没有参考节点时才回退到世界 `Vector3.UP`。每个 `launcher_paths[i]` 可选匹配一个 `yaw_target_paths[i]`：

- 如果有 `yaw_target_paths[i]`，旋转该目标，适合让炮模型和 Launcher 一起转。
- 如果没有，旋转 Launcher 自身。

旋转以 Launcher 的世界位置作为 pivot，先把 Launcher 当前 `-Z` 和 aim point 方向投影到垂直于参考 Y 轴的平面，再计算 signed yaw delta，然后将该轴上的 yaw 旋转应用到目标节点的全局 transform。这样船体横摇/纵摇时，火炮仍然沿船体自身 Y 轴转向，不会被世界 Y 轴持续拉出船体局部姿态。

### 弹道解算

启用 `solve_ballistics` 后，Aim Controller 会为每个 Launcher 维护三份状态：

- `_current_reachable`：当前 marker 是否可达。
- `_current_launch_directions`：当前可达时的解算方向。
- `_last_valid_launch_directions`：最后一次可达时的解算方向。

红色 marker 时 `_current_launch_directions` 不会更新，但 `_last_valid_launch_directions` 会保留。`get_launch_direction_for_launcher()` 的优先级是：

1. 当前可达方向。
2. 最后一次可达方向。
3. Launcher 当前 `-Z` 方向。

弹道解算使用数值模拟，不使用无阻力解析式，因此会考虑 `drag_coefficient`。模拟中的初速度为：

```gdscript
launch_direction * launcher.initial_speed + launcher.get_inherited_velocity_at(muzzle_position)
```

阻力加速度与默认 `Projectile` 一致：

```gdscript
-velocity.normalized() * velocity.length_squared() * drag_coefficient / projectile_mass
```

搜索过程会在 `min_pitch_degrees` 到 `max_pitch_degrees` 之间采样，寻找弹道到达目标水平距离时高度误差过零的区间，再用二分细化。

Marker 颜色由当前解算状态决定：当前可达使用 `reachable_marker_color`，不可达使用 `unreachable_marker_color`。

## 继承速度

`ProjectileLauncher.fire()` 会在发射时计算炮口继承速度。优先查找父级 `RigidBody3D`，并使用刚体在炮口点的速度：

```gdscript
rigid_body.linear_velocity + rigid_body.angular_velocity.cross(muzzle_position - rigid_body.global_position)
```

找不到父级刚体时，Launcher 会使用自身上一帧位置估算速度。最终弹丸速度为：

```gdscript
fire_direction * initial_speed + inherited_velocity
```

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

默认 `use_shot_muzzle_as_impulse_point == true`。如果 `shot_data` 中有 `muzzle_transform`，优先使用本次开火的枪口位置作为作用点，因此多个 Launcher 可以共用同一个 `PhysicsRecoil`。

如果没有本次枪口数据，或关闭 `use_shot_muzzle_as_impulse_point`，则使用 `impulse_point_path`。如果也没有配置 `impulse_point_path`，使用 `apply_central_impulse()`。
