# Ocean System HOW TO USE

## 安装

1. 将 `addons/ocean_system/` 复制到目标 Godot 项目的 `res://addons/ocean_system/`。
2. 在 Godot 中打开 `Project > Project Settings > Plugins`，启用 `Ocean System`。
3. 将 `res://addons/ocean_system/ocean_system.tscn` 实例化到 3D 场景中。

## 基本设置

- `parameters`：波浪 cascade 列表。每个 `WaveCascadeParameters` 控制一个波浪尺度。
- `tile_length` 使用米，`wind_speed` 使用 m/s，`fetch_length` 使用 km，`water_depth_meters`
  使用米。保持这些值对应现实尺寸时，船体、浮力和波浪查询会处在同一尺度下。
- `simulation_map_size`：每层 displacement/normal 贴图分辨率。越高越细，GPU 成本越高。
- `ocean_radius`、`mesh_inner_extent`、`mesh_base_cell_size`、`mesh_ring_count`：控制近处海面网格密度和范围。
- `enable_far_lod`、`far_lod_radius`、`far_lod_blend_distance`、`far_foam_coverage`、`far_foam_threshold_boost`：控制远海网格、远处细节淡出和远处泡沫的连续过渡。
- `water_color`、`foam_color`、`clear_roughness`、`normal_strength`、`foam_intensity`：控制材质外观。
- `sky_source_path`：可指向 `SkySystem` 或任何提供 `get_sun_direction()`、`get_sun_color()`、
  `get_sky_top_color()`、`get_sky_horizon_color()`、`get_sun_visibility()` 的节点，用于远海程序化天空反射和浪尖逆光 glow。
- `sky_reflection_*`、`sun_glitter_*`、`crest_glow_*`：控制远海天空反射、太阳闪光带和低太阳逆光浪尖散射。
- `enable_planar_reflections`、`reflection_*`：控制动态几何的平面反射。默认开启
  `reflection_clip_below_water`，会用反射视口的 depth buffer 裁掉水面以下像素，避免沉没物体继续出现在水面反射中；如水线边缘闪烁，可略微调大 `reflection_clip_bias`。
- 清水区域默认使用很低的 diffuse/specular，程序化天空、平面反射、太阳 glitter、背向太阳的
  `sun_scatter_*` 和浪尖 glow 会作为 radiance 叠加，避免把反射混入 `ALBEDO` 后产生塑料感。

所有主要参数都导出到 Inspector，也可以直接在代码中设置：

```gdscript
@onready var ocean: OceanSystem = $OceanSystem

func _ready() -> void:
	ocean.water_color = Color(0.05, 0.12, 0.16)
	ocean.foam_intensity = 1.6
	ocean.updates_per_second = 20.0
```

## 连接外部风系统

Ocean System 不依赖 Wind System。任何节点只要提供 `get_wind_speed()` 和 `get_wind_direction_degrees()`，或拥有 `wind_speed` / `wind_direction` 属性，都可以作为风源。

```gdscript
ocean.use_external_wind = true
ocean.wind_source_path = ocean.get_path_to($WindSystem)
```

每个 cascade 仍可用 `wind_speed_multiplier` 和 `wind_direction_offset` 对外部风做局部调整。

风向不会瞬间改写波浪方向。每个 `WaveCascadeParameters` 会把风向当作目标方向，并按自己的
`wave_turn_rate_degrees_per_second` 或自动 tile-length 转向速度逐渐转向。系统会保留 active/pending
两套频谱并用 `spectrum_direction_blend_duration` 混合，避免大角度变风时波面硬切。

## 水面查询

水面查询统一使用 GPU point-query 后端；不再维护 CPU 高度贴图缓存。

```gdscript
var sample := ocean.sample_water_surface(global_position, self)
var samples := ocean.sample_water_surface_batch(points, self)
```

`OceanSystem` 会收集本帧所有 owner 的请求，合并到一个大 query buffer 中一次 dispatch，并在下一帧按 owner 分发结果。调用方必须传入稳定的 owner（通常是 `self`），否则异步结果无法可靠归属。如果 GPU 结果尚未就绪，会返回空数组而不是静水替代样本。

## 船体遮水

`WaterCutoutHullLOD` 用于视觉上隐藏船体内部的水面。将它作为船体子节点，设置 `source_model_path` 指向船体模型，然后 toggle `editor_generate_cutouts` 生成可编辑的 `WaterCutoutTrapezoid` 子节点。每个梯形都可以在编辑器中单独选中、移动、旋转，并调整 `half_length`、`start_half_width`、`end_half_width`、垂直范围和边缘参数。

`vertical_min_offset` 和 `vertical_max_offset` 控制 cutout 的垂直生效范围；`height_feather` 控制上下边界的垂直渐变距离，用来避免船体部分离水时仍把下方水面挖空。`feather` 控制顶视角轮廓边缘的水平软边。`WaterCutoutTrapezoid` 只保留 `debug_enabled` 作为整体调试显示开关，线框样式和运行时显示策略固定在代码中。

遮水系统与 `BuoyancyProbeVolume` 解耦；浮力 probe 只负责物理和质量。

## 独立性说明

该插件只依赖自身目录下的脚本、材质和 shader。复制到其他项目时请保持 `addons/ocean_system/` 目录结构不变。
