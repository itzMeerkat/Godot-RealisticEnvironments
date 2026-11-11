# 示例

[English](README.md) · **简体中文**

只使用开源插件的小场景。打开其中一个，点击 **运行当前场景**（F6）。每个示例都以
`ocean_environment.tscn` 为基础。相机直接读取鼠标和键盘，不需要配置输入动作。

| 场景 | 内容 | 操作 |
| --- | --- | --- |
| `ocean_only.tscn` | 拿来即用的环境：天空、云、风和海浪。 | 按住鼠标右键环顾；W A S D 飞行，Q / E 下降 / 上升，Shift 加速，滚轮调整速度。 |
| `floating_objects.tscn` | 箱子和木桶随波起伏、顺风漂移。 | 同上。 |
| `boat.tscn` | 船只模板的船和两个箱子。 | W A S D 驾驶；按住鼠标右键环绕，滚轮缩放。 |

要修改时间、天气或海浪，选中 `GREOceanEnvironment`，右键打开 **子节点可编辑**，然后编辑
`GRESkySystem`、`GREWindSystem` 或 `Ocean`。

## 制作方法

**漂浮物。** `crate.tscn` 和 `barrel.tscn` 都是一个 `RigidBody3D`（质量、网格、
碰撞形状），带一个 `GREBuoyantBody` 子节点。它的 `draft` 就是它们的吃水深度：250 千克的
箱子为 0.25 米，侧躺的 40 千克木桶为 0.13 米。作为漂浮杂物，它们沿纵向和横向的阻力
相同。

**船。** `simple_boat.tscn` 是 `addons/gre_boat_template/boat.tscn` 的继承场景：

1. `Model` 是 `assets/simple_hull.obj`，由 `tools/make_example_hull.py` 生成
   （船头朝 −Z）。
2. 根节点设置 `mass`、`center_of_mass` 以及驾驶参数，`propulsion_position` 位于
   船尾板水线以下。`CollisionShape3D` 使用由网格生成的凸形状，`GREBuoyantBody` 让船体
   吃水 0.255 米。
3. 把 `CameraTargets` 移到船上。
4. `GREWaterMask` 位于 0.3 米高处，在船舷上沿稍下方；对 `Model` 点击 **Fit to Hull** 生成了
   它的盖子（`assets/simple_hull_water_mask.tres`），所以船内不会显示水面。

`boat.tscn` 为它驾驶的船打开了 `player_controlled`。W A S D 动作由 Boat Template
插件添加。
