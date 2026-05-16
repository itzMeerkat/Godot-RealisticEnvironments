# Ocean System HOW TO USE

## 安装

1. 将 `addons/ocean_system/` 复制到目标 Godot 项目的 `res://addons/ocean_system/`。
2. 在 Godot 中打开 `Project > Project Settings > Plugins`，启用 `Ocean System`。
3. 将 `res://addons/ocean_system/ocean_system.tscn` 实例化到 3D 场景中。

## 基本设置

- `parameters`：波浪 cascade 列表。每个 `WaveCascadeParameters` 控制一个波浪尺度。
- `tile_length` 使用米，`wind_speed` 使用 m/s，`fetch_length` 使用 km，`water_depth_meters`
  使用米。保持这些值对应现实尺寸时，船体、浮力和波浪查询会处在同一尺度下。
- `map_size`：每层 displacement/normal 贴图分辨率。越高越细，GPU 成本越高。
- `ocean_radius`、`generated_inner_extent`、`generated_base_cell_size`、`generated_ring_count`：控制近处海面网格密度和范围。
- `enable_far_lod`、`far_lod_radius`、`far_lod_blend_distance`：控制远海网格和远处细节淡出。
- `water_color`、`foam_color`、`clear_roughness`、`normal_strength`、`foam_intensity`：控制材质外观。

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

## 连接独立海流

海流与风、波浪方向独立。Ocean 可以读取任意提供 `get_current_vector_3d(world_position)` 的节点：

```gdscript
ocean.current_source_path = ocean.get_path_to($CurrentSystem)
```

如果不设置 current source，则使用 `fallback_current_speed` 和 `fallback_current_direction`。海流主要供
浮力、船只和 gameplay 查询使用，不参与波浪频谱生成。

## 水面查询

开启 `enable_height_queries` 后，可以查询 CPU 缓存的水面高度和法线。读回 GPU 贴图有成本，建议把 `height_query_updates_per_second` 保持在较低值。

```gdscript
var height := ocean.get_water_height(global_position)
var normal := ocean.get_water_normal(global_position)
var sample := ocean.sample_water_surface(global_position)
```

浮力和 gameplay 应优先使用 `sample_water_surface_batch(points)`。该接口使用 GPU point-query 后端，只上传查询点并读回小型 sample buffer，不需要开启 `enable_height_queries`，也不会整张 displacement 贴图读回。主渲染设备上的查询结果会延迟一个 physics frame 返回，避免手动 `submit/sync`。

## 独立性说明

该插件只依赖自身目录下的脚本、材质和 shader。复制到其他项目时请保持 `addons/ocean_system/` 目录结构不变。
