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
- `configure_projectile_collision`：发射时是否覆盖弹丸碰撞层配置。
- `projectile_collision_layer`：弹丸自身所在的 3D physics layer。默认是 Layer 2，项目中命名为 `Projectile`。
- `projectile_collision_mask`：弹丸会检测哪些 3D physics layer。默认是 Layer 3，项目中命名为 `Hitbox`。
- `spread_enabled`：是否启用散布。
- `spread_degrees`：散布圆锥最大半角。
- `muzzle_flash_scene`：自定义枪口焰场景。未设置时使用默认基础效果。
- `muzzle_flash_lifetime`：Launcher 对枪口焰实例的兜底销毁时间。
- `recoil_strength`：传给 recoil driver 的后坐力强度。
- `recoil_receiver_paths`：接收后坐力事件的节点路径列表。

## 自定义弹丸

推荐让自定义弹丸继承 `Projectile`，或至少实现：

```gdscript
func launch(direction: Vector3, speed: float, projectile_mass: float, projectile_drag := -1.0, projectile_lifetime := -1.0) -> void:
	pass
```

如果自定义场景根节点是普通 `RigidBody3D`，Launcher 会直接设置 `mass` 和 `linear_velocity`。如果该节点有 `drag_coefficient` 或 `lifetime` 属性，也会一并设置。

## 碰撞层

默认设置是：

- 弹丸在 `Projectile` 层，Layer 2。
- 弹丸只检测 `Hitbox` 层，Layer 3。

因此弹丸不会撞普通模型、船体或环境。后续添加命中盒时，把 hitbox 的 3D physics layer 设为 `Hitbox`。如果 hitbox 是 `Area3D` 并需要检测弹丸，通常也要让它的 collision mask 包含 `Projectile`。

如果你希望某个自定义弹丸自己管理碰撞层，把 `configure_projectile_collision` 关闭即可。

## 枪口焰

默认枪口焰是 `default_muzzle_flash.tscn`，脚本为 `muzzle_flash.gd`。它会在运行时创建一个短寿命 `GPUParticles3D` 和一个短暂 `OmniLight3D`。

可以直接编辑默认场景上的导出参数，也可以用自己的 `muzzle_flash_scene` 替换。

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
- `PhysicsRecoil.impulse_point_path` 可选。设置后会在该点施加冲量，从而产生转矩。
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
