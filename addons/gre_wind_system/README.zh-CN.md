# Wind System（风系统）

[English](README.md) · **简体中文**

一个 `GREWindSystem` 节点：整个场景共用一股风，可以带阵风。海浪和云都可以跟随它。
它不依赖任何插件。

## 工作原理

风有固定的方向和一个基础风速。阵风在风速上叠加三个正弦波之和（风速不会低于 0）。
`GREWindSystem` 满足风源约定（见 `gre_core` 的 `GREWindSource`），所以其他系统不需要知道它的
类型就能读取它。

海面不会随每一阵风跳变。只有当风的变化超过阈值时，海洋才生成新的海浪谱，并在几秒内
交叉淡入到新的海浪谱。

## 使用方法

1. 添加一个 `GREWindSystem` 节点（**添加子节点 > GREWindSystem**）。
2. 把 `GREOceanSystem.wind_source_path` 和/或 `GRESkySystem.cloud_wind_source_path`
   指向它。
3. 设置：
   - `wind_speed`：风速（m/s）
   - `wind_direction`：风吹向的方向，单位为度（0 = +Z，90 = +X）
   - `gust_strength`：最大阵风，单位 m/s（0 = 稳定的风）
   - `gust_frequency`：每秒的阵风次数

在代码中：`get_wind_speed()`（包含阵风）、`get_wind_direction_degrees()`、
`get_wind_vector_2d()` 和 `get_wind_vector_3d()`。修改设置时会发出
`wind_changed` 信号（每次阵风不会发出）。

如果想用自己的节点驱动风（天气、玩法），给它加上 `get_wind_speed()` 和
`get_wind_direction_degrees()`，再把路径指向它即可。
