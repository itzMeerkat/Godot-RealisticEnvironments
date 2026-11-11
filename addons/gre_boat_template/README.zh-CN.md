# Boat Template（船只模板）

[English](README.md) · **简体中文**

`boat.tscn` 是一艘已经接好系统的船：浮力、驾驶、受击生命值和相机锚点。要做一艘船，
从它创建一个**继承场景**。

需要 `gre_core`、`gre_buoyancy_system` 和 `gre_hitbox_damage_system`。启用后，插件会把驾驶动作 `boat_forward`、
`boat_back`、`boat_turn_left` 和 `boat_turn_right`（W S A D）加入项目（已存在的不会
改动）。

## 工作原理

```
Boat (RigidBody3D, GREFloatingBoat)   drive input, model animation
├─ CollisionShape3D           placeholder box: replace it
├─ Hitboxes                   GREHitboxHealthManager (one "hull" group, 100 HP)
├─ CameraTargets/ThirdPersonFocus, FirstPersonSeat
└─ GREBuoyantBody                floats the boat (draft 0.3 m)
```

- **`GREBuoyantBody`** 让船漂浮（见 `gre_buoyancy_system` 的 README）。刚体的
  `linear_damp_mode` 为 **Replace**，所以只有水让它减速。
- **`GREFloatingBoat`**（根节点）在 `player_controlled` 打开时驾驶这艘船。螺旋桨的推力和
  船舵的侧向力都作用在 `propulsion_position`，即船尾水线以下：加速时船头会稍稍抬起，
  转弯时船会倾斜并侧滑。这个点离开水面时两者都会减弱（`buoyancy_path`）。接近
  `max_forward_speed` / `max_reverse_speed` 时推力逐渐减小。`turn_acceleration` 是满舵
  时的偏航角加速度，与船的质量无关；水的横向阻力决定最终稳定的转向速度，低速时转向变弱
  （`low_speed_turn_factor`）。
- 生命值来自 `gre_hitbox_damage_system`（见它的 README）。

## 使用方法

1. 通过 **场景 > 新建继承场景** 从 `boat.tscn` 创建场景，加入你的模型，船头朝 −Z。
2. 替换碰撞形状，设置船的 `mass` 和 `center_of_mass`。在 `GREBuoyantBody` 上设置
   `draft`（船体吃水深度）和阻力；在根节点上把 `propulsion_position` 放在船尾水线
   以下。
3. 在 `Hitboxes` 下添加 `GREProjectileHitbox` 区域，并在 `group_max_health` 中列出它们的
   分组。
4. 把 `CameraTargets/*` 移到甲板上。
5. 可选：`animation_player_path` 和 `autoplay_animation` 用来循环播放模型动画
   （例如船帆）。
6. 在玩家驾驶的船上打开 `player_controlled`。
7. 开放小船：在船舷上沿稍下方添加一个 `GREWaterMask`（`gre_core`），把 `hull_path` 指向模型，
   点击 **Fit to Hull**，船内就不会显示水面。

请保持模板中节点的名称和顺序不变，继承它的场景是按路径覆盖节点的。
