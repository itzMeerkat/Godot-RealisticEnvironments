# Wind System Codebase

## 入口

`wind_system.tscn` 是一个挂载 `wind_system.gd` 的普通 `Node`。也可以直接创建 `WindSystem.new()` 或把脚本挂到任意 Node 上。

`plugin.cfg` 和 `wind_system_plugin.gd` 只负责插件识别，不参与运行时逻辑。

## 主要脚本

`wind_system.gd` 是整个系统。它继承 `Node`，通过 `class_name WindSystem` 暴露类型，并提供一组导出参数和查询函数。

导出参数分两组：

- Wind：`wind_speed`、`wind_direction`
- Gusts：`gust_strength`、`gust_frequency`

每个 setter 都会 clamp 合法范围并发出 `wind_changed` 信号。

## 运行时逻辑

运行时 `_process()` 只维护 `_elapsed_time`。编辑器模式下不推进时间，因此 Inspector 中修改参数不会让阵风相位继续变化。

`get_wind_speed()` 返回基础风速加阵风偏移，并保证不小于 0。阵风由 `get_gust_offset()` 计算：它把 `_elapsed_time * gust_frequency * TAU` 作为相位，混合三层 sine 波得到一个平滑变化的偏移，再乘以 `gust_strength`。

如果 `gust_strength <= 0` 或 `gust_frequency <= 0`，阵风偏移直接返回 0。

## 方向与向量

`wind_direction` 使用角度制。`get_wind_direction_radians()` 负责转换为弧度。

`get_wind_vector_2d()` 使用：

```gdscript
Vector2(sin(radians), cos(radians)) * get_wind_speed()
```

因此 `0` 度对应 `+Z`，`90` 度对应 `+X`。`get_wind_vector_3d()` 将这个二维向量映射到 XZ 平面，Y 固定为 0。

## 依赖边界

Wind System 没有依赖 Ocean System 或 Sky System。其他系统通过 getter 读取风速、风向或风向量。Ocean System 的外部风接口正好兼容 `get_wind_speed()` 和 `get_wind_direction_degrees()`。
