# Ocean System Codebase

## 入口

`ocean_system.tscn` 是完整运行入口，根节点挂载 `ocean_system.gd`。根节点是 `MeshInstance3D`，运行时由脚本生成海面网格，并把 GPU 生成的 displacement/normal texture array 写入 `mat_water.tres` 的 shader 参数。

`plugin.cfg` 和 `ocean_system_plugin.gd` 只用于让 Godot 识别插件。运行时代码不依赖 EditorPlugin。

## 主要脚本

- `ocean_system.gd`：系统协调者，负责导出参数、材质参数同步、网格生成、风源读取、波浪更新节流、双缓冲纹理绑定和 CPU 高度查询。
- `wave_cascade_parameters.gd`：每个 wave cascade 的参数资源。setter 会标记频谱需要重算，缩放相关参数会发出 `scale_changed`。
- `wave_generator.gd`：RenderingDevice compute 管线封装，负责生成频谱、调制频谱、FFT、unpack displacement/normal/foam。
- `rendering/render_context.gd`：RenderingDevice 辅助类，统一创建 shader、buffer、texture、descriptor set、pipeline，并在释放时回收 RID。

## 更新流程

`OceanSystem._process()` 每帧做三件事：

1. 根据当前相机更新海面网格节点的 XZ 位置。
2. 如果启用外部风源，检测风速/风向变化并在阈值和刷新间隔满足时标记频谱重算。
3. 根据 `updates_per_second` 决定是否调用 `_update_water()`。

`_update_water()` 会调用 `WaveGenerator.update()`。`WaveGenerator` 不会一次性计算所有 cascade，而是在自己的 `_process()` 中每帧处理一个 cascade，用 `pass_num_cascades_remaining` 做分帧负载平衡。一次 pass 完成后发出 `output_maps_swapped`，`OceanSystem` 再更新当前/上一帧纹理 RID，并通过 `wave_blend_alpha` 做视觉插值。

## Cascade 数据

`parameters` 是 `Array[WaveCascadeParameters]`，最多 8 个。设置数组时，`OceanSystem` 会：

- 清理旧资源上的 `scale_changed` 连接。
- 自动补齐空槽位为新的 `WaveCascadeParameters`。
- 给每个 cascade 初始化随机频谱 seed 和初始时间。
- 重建 `WaveGenerator` 并刷新 `map_scales` shader uniform。

每个 cascade 自己决定有效风速和风向。如果 `OceanSystem.use_external_wind` 为 false，使用本地 `wind_speed` / `wind_direction`；否则使用外部风源，再叠加 `wind_speed_multiplier` 和 `wind_direction_offset`。

风向是波浪的目标方向，不是即时方向。`WaveCascadeParameters` 为每个 cascade 维护
`current_wave_direction`、`active_spectrum_direction`、`pending_spectrum_direction`、active/pending
频谱槽和 `spectrum_blend_alpha`。长 tile 默认转向慢，短 tile 默认转向快。方向变化超过阈值时，
pending 槽生成新方向频谱，water shader 按 `spectrum_blend_states` 在 active/pending 层之间混合。

## GPU 管线

`WaveGenerator.init_gpu()` 创建以下资源：

- `spectrum`：每个 cascade 一层的频谱 texture array。
- 双频谱模式下实际为每个 cascade 分配 active/pending 两层。
- `butterfly_factors`：FFT butterfly 数据 buffer。
- `fft_buffer`：Stockham FFT 临时 buffer。
- 两套 displacement/normal 输出 texture array，用于 ping-pong 双缓冲；每套同样包含 active/pending 层。

compute pass 顺序是：

1. `spectrum_compute.glsl`：当 cascade 标记为 dirty 时生成初始频谱。
2. `spectrum_modulate.glsl`：按时间推进频谱并写入 FFT buffer。
3. `fft_compute.glsl`、`transpose.glsl`、`fft_compute.glsl`：完成二维逆 FFT。
4. `fft_unpack.glsl`：写 displacement map、normal map 和 foam 信息。

`wave_generator.gd` 只在 map size 或 cascade 数量变化时重建管线。风速或波参数变化会标记频谱槽 dirty；
单纯风向变化由每个 cascade 的转向状态和 pending 频谱混合处理。

## 材质与网格

`ocean_system.gd` 在运行时复制材质，避免多个 `OceanSystem` 实例共享同一份 shader 参数。大多数导出参数的 setter 会立即调用 `_set_water_shader_parameter()`。

网格不使用外部 mesh 资产。`_create_generated_clipmap_mesh()` 生成圆形 clipmap 风格网格，近处密、远处疏。Far LOD 使用同一个 mesh 的外圈，并由 `water.gdshader` 根据距离淡出高频 normal 和 foam。

## 水面查询

开启 `enable_height_queries` 后，系统会按 `height_query_updates_per_second` 将 GPU displacement texture 读回 `_height_images`。缓存图像包含每个 cascade 的 active/pending 两层。`get_water_height()` 和 `get_water_displacement()` 在 CPU 侧双线性采样缓存图像，同时应用 spectrum blend 和 wave output blend。`get_water_surface_velocity()` 用当前/上一 displacement 缓存估算表面速度。`get_water_normal()` 用周围高度差估算法线。

`sample_water_surface()` 和 `sample_water_surface_batch()` 通过 GPU point-query 返回高度、法线、位移与表面速度。批量接口使用 `surface_query.glsl`：调用方提交世界坐标与 owner，`OceanSystem` 在 `_process()` 中把本帧所有 owner 的请求合并到一个大 point buffer，一次 compute dispatch 后只读回一个 sample buffer，再按 offset/count 分发缓存结果。浮力系统走该路径，不依赖 `enable_height_queries`；当主 RenderingDevice 的异步结果尚未就绪时返回空结果，不生成静水替代样本。

## 依赖边界

Ocean System 不直接依赖 Wind System 或 Sky System。外部风源只要求提供 `get_wind_speed()`、`get_wind_direction_degrees()`，或同名属性。Sky 对 ocean 颜色的写入也是通过普通属性名完成。
