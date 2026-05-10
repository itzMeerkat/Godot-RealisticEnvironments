# Sky System Codebase

## 入口

`sky_system.tscn` 是完整运行入口，根节点挂载 `sky_system.gd`。场景内部包含：

- `WorldEnvironment`
- `SunLight`
- `MoonLight`
- `SunVisual`
- `MoonVisual`
- `Starfield`

`plugin.cfg` 和 `sky_system_plugin.gd` 只负责插件识别，不参与运行时逻辑。

## 主要脚本

- `sky_system.gd`：系统协调者，负责时间推进、天体方向计算、灯光更新、天空 shader 参数更新、星空和可选天体 mesh 的位置/颜色更新。
- `sky_profile.gd`：颜色和能量曲线资源。提供 `sample_*()` 方法，所有采样前都会确保默认 Gradient/Curve 存在。

## 初始化

`SkySystem._ready()` 在运行时先调用 `_ensure_unique_runtime_resources()`，复制 `Environment`、`Sky`、sky material 以及 sun/moon/starfield 的 `material_override`。这样多个 `SkySystem` 实例不会共享同一份动态材质状态。

如果 `profile` 为空，会创建一个新的 `SkyProfile`，再调用 `_update_sky()` 完成第一次同步。

## 时间推进

`time_of_day` 是 0 到 1 的归一化一天时间。setter 会 wrap 到 `[0, 1)`，调用 `_update_sky()`，并发出 `time_of_day_changed`。

运行时 `_process()` 在 `cycle_enabled` 为 true 时，根据 `cycle_duration_seconds` 推进 `time_of_day`。如果 `advance_calendar_with_cycle` 为 true，也同步推进 `day_of_year` 和 `lunar_age_days`。随后更新星空/视觉物体的位置和 starfield shader 的 `time` 参数。

## 天体方向

太阳方向由 `_get_solar_equatorial_coordinates()`、`_get_solar_hour_angle()` 和 `_equatorial_to_horizontal_direction()` 计算。`latitude_degrees`、`day_of_year`、`axis_tilt_degrees` 和 `north_offset_degrees` 都参与结果。

月亮状态由 `_get_moon_state()` 返回 Dictionary，包含：

- `direction`
- `phase`

月亮方向使用月龄、太阳黄经、月球轨道倾角和本地恒星时近似计算。星空旋转使用 `_get_celestial_north_axis()` 和 `_get_local_sidereal_time()`。

## 天空和灯光更新

`_update_sky()` 是核心同步函数。它会：

1. 计算太阳方向、月亮方向、可见度、夜晚因子、月相和星星可见度。
2. 根据太阳高度选择 `_profile_sample_time`，用于在 `SkyProfile` 中采样颜色和能量。
3. 调用 `_update_light()` 更新 `SunLight` 和 `MoonLight` 的方向、颜色、能量和可见性。
4. 调用 `_update_environment()` 写入 ambient light 和 sky shader 参数。
5. 调用 `_update_starfield_visibility()`、`_update_visual_colors()` 和 `_update_visual_positions()`。
6. 如果开启 ocean 联动，调用 `_update_ocean_colors()`。
7. 发出 `lighting_changed`。

`render_bodies_in_sky` 为 true 时，太阳/月亮通过 sky shader 绘制，`SunVisual` 和 `MoonVisual` 保持隐藏。为 false 时，脚本会使用两个 mesh visual 显示天体。

## Profile 采样

`SkyProfile` 存储 sun、moon、sky、water、foam 的 Gradient，以及 sun、moon、star、ambient 的 Curve。`sample_*()` 方法统一 wrap 时间或 clamp 夜晚因子，然后返回采样结果。

默认 profile 在 `_ensure_defaults()` 中创建。Gradient 使用五个关键颜色点，Curve 使用若干 `Vector2` 点并调用 `bake()`。

## Ocean 联动

Sky System 不直接依赖 Ocean System 类型。`ocean_path` 解析到任意 Node 后，`_update_ocean_colors()` 只检查目标是否有 `water_color` 和 `foam_color` 属性，再用 `set()` 写入 profile 采样值。
