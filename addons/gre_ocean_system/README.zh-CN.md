# Ocean System（海洋系统）

[English](README.md) · **简体中文**

适用于 Godot 4.8 Forward+ 的开阔海洋。风驱动的 FFT 海浪一直延伸到弯曲的地平线，
并带有基于物理的水体着色、泡沫、反射，以及船只激起的尾迹。游戏代码可以在 GPU 上查询
水面高度。

需要 `gre_core` 插件和 `RenderingDevice`（Forward+）。没有 `RenderingDevice` 时
（Compatibility 渲染器、无头模式），海洋会报错并保持关闭。

## 工作原理

- **一个海况，多个平铺块。** `GREWaveSpectrum` 描述整片海：一个由风驱动、按水深修正
  （TMA）的 JONSWAP 海浪谱。各个 `GREWaveCascade`（级联）是这个海浪谱在不同尺寸上的
  FFT 平铺块（默认 250、37 和 9 米）。每个平铺块只绘制属于自己的那段波长，所以合在
  一起正好把海浪谱完整地画一次，从长涌浪到短碎浪。
- **GPU 合成海浪。** 计算着色器把每个级联的海浪谱推进到当前时刻，再做逆 FFT。
  输出是一张位移贴图和一张法线贴图（斜率和泡沫），都带完整的 mip 链。小平铺块比大
  平铺块更新得更频繁，两次更新之间的帧混合两次 FFT 的结果。
- **跟随风。** 风来自 `wind_source_path`，没有时用海浪谱自己的设置。当风的变化超过
  阈值时，海洋在空闲的槽位中生成新的海浪谱并交叉淡入，因此海面不会跳变。风向改变
  时，长涌浪比碎浪转得更慢。
- **延伸到地平线的网格。** 网格是围绕相机的网格块四叉树（CDLOD，作为一个 multimesh
  绘制），离相机越近越精细。它随地球曲率弯曲，所以海面在真实的地平线处结束。顶点
  着色器用所有级联来位移它。远处的海浪通过 mip 层级过滤，而不是淡出。
- **着色。** 水的颜色由水中的吸收和散射决定。光穿过薄薄的浪尖，使浪尖发亮；着色器
  还加入折射、焦散，以及海浪受挤压处的泡沫。所有反射共用一个粗糙表面的菲涅尔项：
  天空（连同云、星星、行星和大气）、太阳高光和场景（屏幕空间或平面反射）。
- **水面查询。** 海洋注册一个 `GREWaterSurface`（见 `gre_core`）。一帧中的所有查询在一次
  GPU 派发中完成。它们采样的就是画出来的水面，结果异步回读。
- **交互波浪。** 船体向 `GREWaterSurface` 报告自己（`GREBuoyantBody` 会这样做），相机周围
  的波浪模拟画出它们的运动激起的波浪：开尔文尾迹（任何速度下都约为 19.5° 的 V 形）、
  船首波，以及上下起伏的船体激起的环形波。船体只有相对于水运动时才会激起波浪，所以
  随涌浪漂浮不会产生波浪。每个波都以真实的速度传播：模拟每个物理帧按有限水深色散关系
  精确地推进每个傅里叶分量。水面查询默认不包含它们，除非查询者选择加入
  （`GREWaterSurface.set_query_wave_response()`、`GREBuoyantBody.wave_response`）；此时
  查询者自己船体内的水面取自船体周围的一圈边缘，所以船体永远感受不到自己排开的水，
  也不会越积越大。
- **尾迹泡沫。** 船体在同一个窗口里搅起泡沫：在水线周围和身后的尾迹中，相对于水移动
  得越快泡沫越密（与吃水深度无关），尾迹波峰变陡处也会起泡沫。泡沫随表层漂流移动，约
  8 秒后消散，并且和白浪泡沫一样绘制（花边、粗糙度、光照），所以 `foam_intensity` 也会
  调整它。
- **开放船体。** 水面跳过 `GREWaterMask` 盖子在模板缓冲中标记的像素（见 `gre_core`），所以
  开放小船内不会显示水面。每个水面着色器档位都有这行 `stencil_mode`；自定义着色器也要
  加上。

海面位于 `water_level`。节点自身的变换会被忽略。

## 使用方法

1. 在 **项目设置 > 插件** 中启用 **Core** 和 **Ocean System**，然后实例化
   `ocean_system.tscn`。让节点保持在原点、不旋转、不缩放，用 `water_level`
   设置海面高度。
2. 使用一个 `far`（远裁剪面）超过地平线的 `Camera3D`。从 10 米高处看，地平线在
   11 公里外；从 100 米高处看是 36 公里。演示场景用的是 60 公里。
3. 可选：把 `wind_source_path` 指向 `GREWindSystem`，把 `sky_source_path` 指向
   `GRESkySystem`。不设置时，海浪使用海浪谱自己的风，水面反射 **Manual Sky** 的颜色。

`gre_ocean_environment` 会帮你完成以上全部设置。

### 设置

| 分组 | 内容 |
| --- | --- |
| `water_level` | 静水面的高度。 |
| Waves | `spectrum`：风（没有风源时使用）、`fetch_length`（风区长度；海况充分成长后不再增长）、`water_depth`、`swell`、`spread`、`detail`、`displacement_scale`（1 = 物理浪高，演示场景也用 1），以及海面跟随变化的快慢。可以把它另存为 `.tres` 来复用一种海况。`cascades`（最多 8 个）：`tile_length`，以及泡沫设置（`whitecap`、`foam_generation`、`foam_lifetime`）。平铺长度之间不要互为整数倍，最大的至少为峰值波长的 1.5 倍（否则海洋会发出警告）。修改 `displacement_scale` 后要重新调整 `whitecap`。 |
| Water | `water_absorption`、`water_scattering`、`water_scattering_anisotropy`：水的颜色只由它们决定。 |
| Surface | `clear_roughness`、`short_wave_slope_scale`（小到无法模拟的风生涟漪）、`normal_scale`（1 = 物理斜率）。 |
| Foam | `foam_color`、`foam_intensity`、`foam_roughness`、泡沫纹理及其平铺尺寸。 |
| Sky | `sky_source_path`、反射强度和 F0、太阳高光；**Manual Sky** 中是没有天空源时使用的值。 |
| Reflections | `reflection_mode`：`SKY_ONLY`、`SCREEN_SPACE` 或 `PLANAR`（默认），以及平面反射的分辨率和裁剪。渲染层 20（`reflection_water_layer`）留给水面专用。 |
| Interactive Waves | `interaction_map_size`（Off、256、512 或 1024 个格子）和 `interaction_cell_size`（默认 0.25 米）：两者共同决定相机周围船体能激起波浪的窗口（512 × 0.25 米 = 128 米）。窗口以相机为中心（转动相机不会改变它），并在边缘淡出。 |
| Quality | `shader_quality`（`LOW`、`MEDIUM`、`HIGH`）、`simulation_map_size`（128–1024）、`max_wave_phase_step`、`fragment_cascade_limit`、`use_bicubic_normals`、`mesh_base_cell_size`。 |
| Material | `water_material`：海洋复制的材质模板。海洋用一份私有副本渲染。 |

在代码中：`get_wind_speed()` 和 `get_wind_direction_degrees()` 返回海浪跟随的风。
`get_water_material()` 返回实际使用的材质；在运行时设置它的 `water_debug_view`
uniform（1–18），可以单独显示某一项着色；16 和 17 显示交互波浪的高度和斜率，18 显示
它们的泡沫。

### 水面查询

使用 `gre_core` 中的 `GREWaterSurface.find(node)`（示例见它的 README），不要直接访问
`GREOceanSystem`。结果给出画出来的水面的高度、法线、位移和速度。`get_surface_drift()`
是让泡沫顺风移动的漂流，为风速的 3%；`gre_buoyancy_system` 让漂浮物随它移动。

### 天空源

`sky_source_path` 接受 `GRESkySystem`，或任何具有以下方法的节点。只有第一个方法是必需
的；缺少的部分，海洋会退回到 **Manual Sky** 中的值。

| 方法 | 提供给水面的内容 |
| --- | --- |
| `get_sun_direction()` | 指向太阳的方向（世界空间）。 |
| `get_sun_visibility()` | 到达海面的阳光比例（0–1）。 |
| `get_cloud_cubemap()` | 从海面看到的云：rgb 为云处预乘的辐亮度，a 为不透明度，带完整 mip；`null` 表示没有云。 |
| `get_star_cubemap()`、`get_star_basis()`、`get_star_radiance_scale()` | 星星：辐亮度立方体贴图、从世界到立方体贴图的旋转、换算到场景辐亮度的系数。 |
| `get_planet_directions()`、`get_planet_irradiance()` | 最多 8 个点光源，在水面上反射成闪光。 |
| `get_atmosphere_sky_volumes()`、`get_atmosphere_light()` | 从海面看出去、透过大气的天空。没有它们时，水面反射从 `manual_sky_top_color` 到 `manual_sky_horizon_color` 的渐变。 |
| `get_atmosphere_view_volumes()`、`get_atmosphere_view_observer()`、`get_atmosphere_view_max_distance()` | 相机与水面之间的雾霭。 |
| `set_camera_underwater(underwater)` | 相机没入波浪或回到水面时调用，让在水面之后绘制到屏幕上的天空停止绘制。 |
| `get_sky_irradiance()` | 天空在水平面上的辐照度（场景单位，未知时为负），每帧读取：作为平面反射中物体的环境光，否则太阳照不到的地方会反射成黑色。没有它时，取 `manual_sky_top_color` 和 `manual_sky_horizon_color` 的中间值。 |

如果天空源有 `lighting_changed` 信号，海洋只在该信号发出时读取它（每次变化后都要发
出）；否则每帧读取。

## 限制

- 相机在水下时，能看到水体本身（水色与雾化、波浪聚焦形成的光束）以及从下方看到的水面（斯涅尔窗、全反射）。是否在水下按相机位置处的波高判断，因此镜头半入水时只会显示其中一种。海况恶劣时，气泡和搅起的杂质会随风使水下视野变浑浊（`underwater_storm_churn`、`underwater_churn_wind`）；从水面上方看，水的样子不变。
- 每个世界只有一片海洋，整片海只有一个水深（没有海岸）。
- 船体只在相机周围的窗口内激起波浪（默认每个方向约 64 米），同时最多 16 个（最近的
  那些）。战列舰的长尾迹需要第二个更粗的窗口，目前还没有。
- 只有绘制是弯曲的。查询和反射都把海面当作平面。
- 暂时没有水花。
