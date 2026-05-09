# Ocean 组件实现说明

这个目录实现了一套基于 GPU FFT 的开放水面系统。核心目标是用少量 wave cascade 生成近处细节，同时用同一张 ocean mesh 和同一套水面 shader 覆盖远处海面，避免近海和远海因为材质、光照或颜色路径不同而产生明显接缝。

## 主要文件

- `ocean_system.gd`：主入口。负责生成海面网格、驱动波浪计算、同步 shader 参数、跟随相机、处理外部风源和 CPU 高度查询。
- `wave_cascade_parameters.gd`：单个波浪 cascade 的参数资源。每个 cascade 通常代表一个尺度范围的波浪。
- `wave_generator.gd`：GPU 计算管线封装。它调用 compute shader 生成频谱、做 FFT，并输出 displacement/normal 纹理数组。
- `rendering/render_context.gd`：RenderingDevice 管线、buffer、texture 和 compute dispatch 的底层封装。
- `shaders/compute/*.glsl`：波浪频谱、调制、FFT、转置和解包等计算 shader。
- `shaders/spatial/water.gdshader`：最终水面渲染 shader。近海和远海都走这一份 shader。
- `mat_water.tres`：默认水面材质，保存 shader 参数的默认值。
- `ocean_system.tscn`：可直接实例化的 OceanSystem 场景。

## 整体数据流

1. `OceanSystem` 读取 `parameters` 中的多个 `WaveCascadeParameters`。
2. `WaveGenerator` 根据 cascade 参数和风力状态生成波谱。
3. Compute shader 将频域波谱通过 FFT 转成空间域的 displacement map 和 normal/foam map。
4. `OceanSystem` 将这些纹理数组写入当前水面材质的 shader 参数：
   - `displacements`
   - `normals`
   - `previous_displacements`
   - `previous_normals`
   - `num_cascades`
   - `wave_blend_alpha`
5. `water.gdshader` 在 vertex 阶段采样 displacement，在 fragment 阶段采样 normal/foam，并计算水体光照。

`previous_*` 纹理和 `wave_blend_alpha` 用来在频谱更新之间做视觉插值，减少 FFT 更新频率低于帧率时的跳变。

## OceanSystem

`OceanSystem` 继承自 `MeshInstance3D`。它既是渲染节点，也是海面系统的协调者。

### 参数同步

`OceanSystem` 中大多数导出参数都有 setter。setter 会立即把值同步到 shader 或标记频谱需要重算：

- 颜色、波浪纹理、cascade 数量和 `wave_blend_alpha` 都通过 `_set_water_shader_parameter()` 写入材质实例。
- `roughness`、`specular_strength`、foam 参数和 Far LOD 参数也走同一条材质同步路径。
- cascade 参数、风速、风向变化会调用 `_mark_spectra_dirty()`，让下一次 wave update 重新生成频谱。

运行时会复制当前 `material_override`，确保每个 `OceanSystem` 拥有独立材质状态，避免多个海面实例互相覆盖贴图、颜色或插值进度。

### 外部风源

如果 `use_external_wind` 为 true，系统会从 `wind_source_path` 指向的节点读取风力：

- 优先调用 `get_wind_speed()` / `get_wind_direction_degrees()`。
- 如果没有方法，则读取 `wind_speed` / `wind_direction` 属性。

风速或风向变化时，所有 cascade 会被标记为需要重新生成 spectrum。

### 更新频率

`updates_per_second` 控制波浪计算更新频率。它减少的是 GPU compute 的更新频率，不是渲染帧率。渲染 shader 每帧仍然会采样当前纹理，并通过 `wave_blend_alpha` 在上一帧输出和当前输出之间插值。

## 海面网格

当前网格由 `OceanSystem` 在运行时生成，不依赖手工建模的平面。

`_create_generated_clipmap_mesh()` 会生成一张以原点为中心的圆形 ring mesh：

- 中心是一个顶点。
- 外侧由多圈同心圆组成。
- 每圈使用相同的角向 segment 数量。
- 半径数组由 `_build_circular_clipmap_radii()` 生成。

近处半径覆盖到 `ocean_radius`，用于细致渲染。启用 Far LOD 后，网格会继续向外追加 `far_lod_ring_count` 圈，直到 `far_lod_radius`。

### 相机跟随

`follow_active_camera` 启用时，OceanSystem 每帧把自身的 XZ 位置移动到当前相机附近。shader 使用世界坐标采样波浪，所以海面网格移动不会让纹理看起来跟着网格滑动。

`follow_snap_size` 可以让海面按固定间隔吸附移动，用于降低连续移动导致的浮点抖动或视觉 shimmer。

## Cascade 设计

每个 `WaveCascadeParameters` 表示一个波浪尺度：

- `tile_length` 控制该 cascade 的世界空间重复周期。
- `displacement_scale` 控制顶点位移强度。
- `normal_scale` 控制法线强度。
- 风速、风向、fetch、swell、spread、detail、whitecap 等参数影响频谱形状。

常见配置是：

- 大 tile length：低频大浪、主涌浪。
- 中 tile length：中尺度波浪。
- 小 tile length：近处碎波和细节。

Far LOD 不再是独立模块，而是复用这些 cascade。远处会逐渐衰减高频 cascade，只保留低频 cascade，避免远处网格因为高频位移和法线采样出现闪烁、泛白或过密泡沫。

## Far LOD

Far LOD 的职责是渲染从细致近海边界到地平线之间的水面。现在它被集成在 `OceanSystem` 和 `water.gdshader` 中，不再有单独的 `FarOcean` 节点、材质或 shader。

### 网格层

`enable_far_lod` 打开后，`_build_circular_clipmap_radii()` 会在 `ocean_radius` 外继续追加远处 ring。

远处 ring 使用非线性半径分布：

```gdscript
var t := float(i) / float(far_ring_count)
var eased_t := t * t
var radius := lerpf(outer_radius, far_radius, eased_t)
```

这样靠近近海边界的 ring 更密，远处 ring 更稀。视觉上可以保留过渡区的起伏，同时降低远距离顶点数量。

### Shader 层

`water.gdshader` 用 `distance_lod` 表示当前片元/顶点进入远海 LOD 的程度：

```glsl
float linear_lod = smoothstep(
	near_ocean_radius * 0.75,
	near_ocean_radius + far_lod_blend_distance,
	dist
);
return pow(linear_lod, far_lod_curve);
```

`distance_lod = 0` 表示近海，`distance_lod = 1` 表示远海。

远处主要做两件事：

- `get_cascade_lod_weight()` 按 cascade 的 tile length 过滤高频波浪。
- 根据 `distance_lod` 降低远处法线和泡沫细节，避免高频波浪和白沫在地平线附近聚成一片。

Far LOD 不再叠加独立 procedural swell。远处浪型必须来自同一组 FFT cascade，只是被低通滤波成远距离可稳定渲染的版本。如果远处缺少大尺度起伏，应优先调整最大尺度 cascade 的 `tile_length`、`displacement_scale`、风速、fetch 或 swell，而不是给远海加一套独立波形。

泡沫也会随距离降低覆盖率：

- `far_foam_threshold_boost` 抬高远处泡沫阈值。
- `far_foam_coverage` 限制远处 foam 占比。

水面反射不按近远分支。近海、远海、关闭 Far LOD 后扩大的主 ocean 都使用同一套 `roughness`、`specular_strength`、Fresnel 和 GGX specular 路径。调试反光问题时应先把这条统一路径调正确，再考虑是否需要额外的距离实验参数。

## Water Shader 光照

水面 shader 使用自定义 `light()`，大致分为：

- Fresnel：视角越掠射，反射越强。
- GGX specular：受 `roughness` 和 `specular_strength` 影响。
- 简化 diffuse/subsurface scattering：用 `water_color` 和光照方向模拟水体散射。
- Foam 混合：根据 normal map 中的 foam signal 混合 `foam_color`。

近海和远海共享同一份 shader，因此颜色、roughness、specular、foam 和日落光色都会走同一条路径。这是减少接缝和色差的关键。

## CPU 高度查询

`enable_height_queries` 开启后，`OceanSystem` 会周期性把 GPU displacement texture 读回 CPU，缓存到 `_height_images`。之后可以通过：

- `get_water_height(world_position)`
- `get_water_normal(world_position)`

查询水面高度和近似法线。

注意：读回 GPU texture 可能造成同步开销，所以 `height_query_updates_per_second` 应低于渲染帧率。当前 CPU 查询采样同一套 FFT displacement；Far LOD 不额外添加独立波形。

## 调试入口

`systems/debug/ocean_debug_panel.gd` 会暴露主要海面参数：

- wave resolution 和 update rate
- ocean radius
- water / foam color
- roughness / specular
- foam intensity / threshold / softness
- Far LOD radius、ring count、blend distance、curve
- Far normal 和 foam 衰减参数
- 各 cascade 的 wind、fetch、swell、spread、detail、whitecap、foam amount

调试远海过渡时，通常优先看：

- `far_lod_blend_distance`：过渡范围。
- `far_lod_curve`：是否更久保留近处细节。
- `far_low_frequency_tile_length`：哪些 cascade 被认为是远处低频。
- `far_normal_strength`：远处反光和波纹强度。
- `roughness` / `specular_strength`：整体反光是否过白。

## 常见修改方向

- 如果远处太平：先增强最大尺度 cascade 的 `displacement_scale`、增大 `tile_length`，或让 `far_low_frequency_tile_length` 保留更多中低频 cascade。
- 如果远处太碎或闪烁：提高 `far_low_frequency_tile_length`，降低 `far_normal_strength`，或降低小尺度 cascade 的 `normal_scale`。
- 如果远处泡沫铺满：提高 `far_foam_threshold_boost`，降低 `far_foam_coverage`。
- 如果近远接缝明显：增大 `far_lod_blend_distance`，调整 `far_lod_curve`，并确认近海与远海没有走不同材质。
- 如果整个海面越远越白：优先检查统一反射路径里的 `specular_strength`、`roughness`、Fresnel/GGX 实现、环境反射强度和天空/太阳光颜色。

## 维护原则

- 不要重新引入独立 FarOcean 材质或 shader，除非有非常明确的渲染管线需求。
- 近海和远海应尽量共享颜色、光照、foam 和反射参数。
- 远海优化优先通过 mesh LOD 和 cascade 过滤实现。不要为远海单独创造一套不受 cascade/风场驱动的波形。
- shader 参数命名应保持与 `OceanSystem` export 参数一致，方便 DebugPanel 和材质资源同步。
