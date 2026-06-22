# Projectile Launcher System HOW TO USE

## 安装

1. 将 `addons/projectile_launcher_system/` 复制到目标 Godot 项目的 `res://addons/projectile_launcher_system/`。
2. 在 Godot 中打开 `Project > Project Settings > Plugins`，启用 `Projectile Launcher System`。
3. 将 `res://addons/projectile_launcher_system/projectile_launcher.tscn` 实例化到武器或炮口节点下。也可以创建一个 `Node3D`，挂载 `res://addons/projectile_launcher_system/projectile_launcher.gd`。

## 基础发射

```gdscript
@onready var launcher: ProjectileLauncher = $ProjectileLauncher

func _input(event: InputEvent) -> void:
	if event.is_action_pressed(&"fire_projectile"):
		launcher.fire()
```

`fire()` 不传方向时，会使用枪口节点的 `-Z` 方向。如果没有配置 `muzzle_path`，会使用 `ProjectileLauncher` 自身的 `-Z` 方向。

也可以传入世界方向：

```gdscript
launcher.fire(global_transform.basis.x)
```

## Launcher 参数

- `muzzle_path`：可选枪口 `Node3D`。未设置时使用 Launcher 自身位置和方向。
- `projectile_parent_path`：弹丸生成到哪个节点下。未设置时默认生成到当前场景根节点。
- `projectile_scene`：自定义弹丸场景。未设置时使用默认球体弹丸。
- `projectile_mass`：弹丸质量。
- `initial_speed`：弹丸初速度。
- `drag_coefficient`：弹丸阻力系数。
- `projectile_lifetime`：弹丸自动销毁时间，`0` 表示不按时间销毁。
- `inherit_launcher_velocity`：发射时是否叠加炮口的世界速度。默认开启，适合船只、载具等移动平台。
- `configure_projectile_collision`：发射时是否覆盖弹丸碰撞层配置。
- `projectile_collision_layer`：弹丸自身所在的 3D physics layer。默认是 Layer 2，项目中命名为 `Projectile`。
- `projectile_collision_mask`：弹丸会检测哪些 3D physics layer。默认是 Layer 3，项目中命名为 `Hitbox`。
- `spread_enabled`：是否启用散布。
- `spread_degrees`：散布圆锥最大半角。
- `muzzle_flash_scene`：自定义枪口焰场景。未设置时使用默认基础效果。
- `muzzle_flash_lifetime`：Launcher 对枪口焰实例的兜底销毁时间。
- `recoil_strength`：传给 recoil driver 的后坐力强度。
- `recoil_receiver_paths`：接收后坐力事件的节点路径列表。
- `debug_draw_fire_direction`：显示一根指向当前开炮方向的调试箭头。
- `debug_arrow_length`：调试箭头长度。
- `debug_arrow_color`：调试箭头颜色。
- `debug_arrow_on_top`：调试箭头是否无视深度显示在最前。

## 自定义弹丸

推荐让自定义弹丸继承 `Projectile`，或至少实现：

```gdscript
func launch(direction: Vector3, speed: float, projectile_mass: float, projectile_drag := -1.0, projectile_lifetime := -1.0) -> void:
	pass
```

如果自定义场景根节点是普通 `RigidBody3D`，Launcher 会直接设置 `mass` 和 `linear_velocity`。如果该节点有 `drag_coefficient` 或 `lifetime` 属性，也会一并设置。

默认 `Projectile` 会在 `global_position.y <= waterline_y` 时销毁，`waterline_y` 默认 `0`。如果某种弹丸需要穿过海面，把 `destroy_below_water` 关闭即可。

入水效果是弹丸类型自己的配置：

- `water_impact_effect_scene`：弹丸碰到 waterline 销毁时生成的效果场景。
- `water_impact_effect_lifetime`：没有自销毁逻辑的效果的兜底销毁时间。

默认球体弹丸绑定了 `default_water_impact.tscn`。如果你做不同类型的炮弹，例如实心弹、爆炸弹、燃烧弹，可以在各自 projectile scene 的 `Projectile` 导出参数里设置不同的 `water_impact_effect_scene`。

## 碰撞层

默认设置是：

- 弹丸在 `Projectile` 层，Layer 2。
- 弹丸只检测 `Hitbox` 层，Layer 3。

因此弹丸不会撞普通模型、船体或环境。后续添加命中盒时，把 hitbox 的 3D physics layer 设为 `Hitbox`。如果 hitbox 是 `Area3D` 并需要检测弹丸，通常也要让它的 collision mask 包含 `Projectile`。

如果你希望某个自定义弹丸自己管理碰撞层，把 `configure_projectile_collision` 关闭即可。

## 开炮方向调试

启用 `debug_draw_fire_direction` 后，Launcher 会在编辑器和运行时显示一个调试箭头。箭头起点是 `muzzle_path` 指向节点的位置；如果没有配置 `muzzle_path`，起点就是 Launcher 自身位置。

箭头方向始终使用当前配置的默认开炮方向，也就是枪口或 Launcher 的 `-Z` 方向。它不显示每次开火的随机散布结果。

可以用这些参数调整显示：

- `debug_arrow_length`：箭头长度。
- `debug_arrow_head_length`：箭头头部长度。
- `debug_arrow_head_angle_degrees`：箭头头部张角。
- `debug_arrow_color`：颜色。
- `debug_arrow_on_top`：是否穿透显示。

## 瞄准控制器

`ProjectileAimController` 会从当前相机视野中心发射一条射线，并计算它与水平平面 `y = aim_plane_y` 的交点。默认 `aim_plane_y = 0`，适合用海平面作为瞄准平面。

基础结构：

```text
BoatRigidBody
  Cannon006
    ProjectileLauncher
  Cannon007
    ProjectileLauncher
  ProjectileAimController
```

配置：

- `launcher_paths`：所有要瞄准的 `ProjectileLauncher`。
- `yaw_target_paths`：和 `launcher_paths` 一一对应的可选模型旋转目标。填炮模型根节点时，炮模型会和 Launcher 一起转；留空时只旋转 Launcher。
- `yaw_reference_path`：yaw 旋转轴参考节点。留空时使用 AimController 的父节点。船、载具上建议指向船体/载具刚体，这样火炮沿船体自身 Y 轴旋转，而不是世界 Y 轴。
- `camera_path`：可选。留空时使用当前 viewport 的活动 `Camera3D`。
- `aim_plane_y`：瞄准平面高度，默认 `0`。
- `yaw_smoothing`：水平旋转平滑。设为 `0` 时立即对准。

Marker 显示参数：

- `marker_radius`：海面圆环半径。
- `marker_height`：中心竖线高度。海浪遮挡圆环时，竖线能帮助定位。
- `marker_color`：颜色。
- `marker_on_top`：是否无视深度显示在最前。

`ProjectileAimController` 只做 yaw 调整，不改变炮管 pitch。当前 `ProjectileLauncher.fire()` 默认沿自身 `-Z` 发射，所以控制器会让 Launcher 的 `-Z` 在 `yaw_reference_path` 的局部水平面上指向 marker。

### 弹道解算

启用 `solve_ballistics` 后，`ProjectileAimController` 会根据 marker 位置为每个 Launcher 数值解算发射方向。解算会考虑：

- Launcher 的 `initial_speed`
- Launcher 的 `projectile_mass`
- Launcher 的 `drag_coefficient`
- Godot 默认重力
- Launcher 继承到的炮口世界速度

Marker 颜色：

- 绿色：当前 marker 至少能被一门炮命中。
- 红色：当前 marker 无法被命中。

红色时仍允许开火。控制器会为每门炮缓存最后一次绿色时的发射方向；如果当前不可达，就使用最后一次有效方向。如果从未有过有效解，则回退到 Launcher 当前方向。

主要参数：

- `min_pitch_degrees` / `max_pitch_degrees`：允许解算的仰角范围。
- `prefer_high_arc`：是否优先使用高抛物线。
- `pitch_search_steps` / `pitch_refine_steps`：搜索精度。
- `simulation_step` / `max_simulation_time`：弹道模拟步长和最长时间。
- `impact_height_tolerance`：没有找到精确过零解时，可接受的高度误差。
- `reachable_marker_color` / `unreachable_marker_color`：可达/不可达 marker 颜色。

## 枪口焰

默认枪口焰是 `default_muzzle_flash.tscn`，脚本为 `muzzle_flash.gd`。它会在运行时创建一个短寿命 `GPUParticles3D` 和一个短暂 `OmniLight3D`。

可以直接编辑默认场景上的导出参数，也可以用自己的 `muzzle_flash_scene` 替换。

## 入水效果

默认入水效果是 `default_water_impact.tscn`，脚本为 `water_impact_effect.gd`。它会生成一次性向上喷溅的 `GPUParticles3D`，播放后自动销毁。

自定义入水效果场景建议实现：

```gdscript
func play() -> void:
	pass
```

Projectile 会先把效果放到入水点，再调用 `play()`。如果效果场景根节点本身是 `GPUParticles3D` 且没有 `play()`，Projectile 会直接设置 `emitting = true`。

## Cannon Slide Recoil

`CannonSlideRecoil` 用于炮管、炮架等视觉后坐力。它不会播放固定动画曲线，而是用弹簧阻尼模型支持连续开火叠加。

推荐结构：

```text
CannonRoot
  BarrelSlide
    BarrelMesh
    Muzzle
  ProjectileLauncher
  CannonSlideRecoil
```

配置：

- `CannonSlideRecoil.target_path = ../BarrelSlide`
- `ProjectileLauncher.muzzle_path = ../BarrelSlide/Muzzle`
- `ProjectileLauncher.recoil_receiver_paths` 添加 `../CannonSlideRecoil`

主要参数：

- `target_path`：真正要移动的可见炮管或炮架节点。`CannonSlideRecoil` 挂在炮节点下面时，设为 `..` 可以移动父炮节点。
- `recoil_axis`：目标节点自身局部空间里的后坐方向。默认 `Vector3.BACK`，即本地 `+Z`，适合模型朝 `-Z` 开火的 Godot 约定。
- `kick_velocity_per_strength`：每次开火给滑动后坐增加的速度。
- `max_recoil_distance`：最大后坐距离。
- `spring_strength`：回位弹簧强度。
- `damping`：阻尼。

如果后坐方向反了，把 `recoil_axis` 改成 `Vector3.FORWARD`。如果方向是横向或竖向，说明炮模型本地轴和预期不同，先在编辑器里看目标节点的本地坐标轴，再把 `recoil_axis` 改成对应方向，例如 `Vector3.LEFT`、`Vector3.RIGHT` 或 `Vector3.UP`。

## Physics Recoil

`PhysicsRecoil` 用于对船体、载具、炮架等 `RigidBody3D` 施加真实反冲。

推荐结构：

```text
BoatRigidBody
  CannonRoot
    Muzzle
    ProjectileLauncher
    PhysicsRecoil
```

配置：

- `PhysicsRecoil.rigid_body_path` 指向船体或炮架的 `RigidBody3D`。不设置时会向父节点链自动查找。
- `PhysicsRecoil.use_shot_muzzle_as_impulse_point` 默认开启。由 Launcher 触发时，会优先用本次开火的枪口位置施加冲量，适合多个 Launcher 共用一个 `PhysicsRecoil`。
- `PhysicsRecoil.impulse_point_path` 可选。没有本次枪口数据或关闭 `use_shot_muzzle_as_impulse_point` 时，会在该点施加冲量，从而产生转矩。
- `ProjectileLauncher.recoil_receiver_paths` 添加 `../PhysicsRecoil`

主要参数：

- `use_projectile_momentum`：启用时使用 `projectile_mass * initial_speed` 作为基础冲量。
- `impulse_multiplier`：冲量倍率。
- `fallback_impulse`：未使用弹丸动量时的基础冲量。

## 后坐力接口

Launcher 通过 duck typing 调用 recoil receiver：

```gdscript
func apply_recoil(fire_direction: Vector3, shot_data: Dictionary) -> void:
	pass
```

`shot_data` 包含：

```gdscript
{
	"launcher": launcher,
	"projectile": projectile,
	"recoil_strength": recoil_strength,
	"projectile_mass": projectile_mass,
	"initial_speed": initial_speed,
	"drag_coefficient": drag_coefficient,
	"muzzle_transform": muzzle_transform,
}
```
