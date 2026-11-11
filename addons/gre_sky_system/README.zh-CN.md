# Sky System（天空系统）

[English](README.md) · **简体中文**

物理的昼夜天空。太阳、月亮、行星和星星按天文规律定位。大气绘制天空，并给场景加上
雾霭。它还有带天气预设的体积云，以及供曝光使用的测光。

需要 `gre_core` 插件和 `RenderingDevice`（Forward+）。

## 工作原理

- **天文。** 纬度、日期、年份和 `time_of_day` 决定太阳和月亮（含月相）、水星到土星
  的各行星（轨道根数，适用于 1800–2050 年）以及星星（随恒星时转动）的位置。太阳和
  月亮各驱动一个 `DirectionalLight3D`。
- **大气。** 每帧由计算着色器对空气、臭氧和海上雾霭积分，生成查找纹理：透射率、
  多次散射，以及分别对应相机、海面和云层的体纹理。其他部分都只采样这些纹理：
  - 天空着色器（天空以及太阳和月亮的圆盘）；
  - 灯光的颜色和亮度；
  - 不透明几何体上的雾霭（合成器效果 `GREAerialPerspectiveEffect`）；
  - 透明材质和海洋。

  天空的颜色、暮光和地影都来自这一个模型，没有手工调的渐变。
- **云。** 云是一个体积，相机可以飞进云中，也可以飞到云层上方。天气步骤根据噪声在
  相机周围生成覆盖率、云型和密度图。相机看到的云在屏幕上以一半分辨率做光线步进，
  每帧只算其中四分之一的像素，其余由前几帧补全（场景合成器中的
  `GREVolumetricCloudEffect`）。每个像素的云画在它所见表面的前方，并处在大气雾霭之中。
  其他用途由两张立方体贴图提供：一张从海面看，供海洋反射；一张从相机看，供环境光。
  它们每帧刷新 1/4、1/16 或全部纹素（`cloud_update_stride`）。一个 `GRECloudPreset`
  保存一种天气状态（云和雾霭），预设之间可以平滑过渡。云随风漂移，形状随时间变化。
- **夜空。** 亮星星表中肉眼可见的 9,096 颗星被画成会闪烁的物理点光源。银河、气辉和
  行星也会绘制。能看到哪些星，只由曝光决定。
- **测光。** `get_scene_illuminance()` 给出相机处来自太阳、月亮和天空的照度
  （勒克斯），供 `GREExposureController` 读取。

其他系统依赖的内容每次变化后，天空都会发出 `lighting_changed` 信号。
昼夜循环中，天空每帧更新一次（并发出该信号），所以无论太阳移动得多慢，暮光都不会出现
阶跃。不要把开销大的操作连接到该信号上。

## 使用方法

1. 在 **项目设置 > 插件** 中启用 **Core** 和 **Sky System**。插件会把大气的全局
   着色器 uniform 和去色带（debanding）设置加入 `project.godot`。
2. 实例化 `sky_system.tscn`，删除其他的 `WorldEnvironment` 和 `DirectionalLight3D`。
3. 添加一个指向天空的 `GREExposureController`（`gre_exposure_system`）。光照强度是物理值，
   没有它的话夜晚几乎全黑。
4. 配合海洋使用时，把 `GREOceanSystem.sky_source_path` 指向这个节点，并让 `sea_level`
   与海洋的 `water_level` 保持一致。

保持物理灯光单位关闭，也不要开启 Environment 自带的雾。`gre_ocean_environment` 已经
做好了这些设置。

### 设置

| 分组 | 内容 |
| --- | --- |
| （顶部） | `sea_level`、`time_of_day`（0 午夜，0.25 日出，0.5 正午，0.75 日落）、`cycle_enabled`、`cycle_duration_seconds`。 |
| Astronomy | `latitude_degrees`、`day_of_year`、`year`、`lunar_age_days`、`north_offset_degrees`（默认北方为 −Z）、`axis_tilt_degrees`、`advance_calendar_with_cycle`。 |
| Lights | `sun_energy_multiplier`、`moon_energy_multiplier`（1 = 物理值），以及日月圆盘在环境光和反射中的亮度。 |
| Night Sky | `star_brightness`（1 = 物理值）、`airglow_brightness`、`star_catalog`、`star_cubemap_size`。 |
| Clouds | `clouds_enabled`、`cloud_preset`、`cloud_transition_seconds`、风（`cloud_wind_source_path`，或 `cloud_wind_speed` / `cloud_wind_direction`）、云的光照和质量。 |

预设位于 `cloud_presets/`：`clear`（晴）、`fair`（少云）、`cloudy`（多云）、
`overcast`（阴）、`rain`（雨）、`storm`（暴风雨）、`no_cloud`（无云）、`sea_fog`（海雾）和 `overcast_fog`（阴天海雾）。要制作自己的
预设，复制一个修改即可。雾霭能见度和星星的闪烁程度也属于每个预设。

### 在代码中使用

- `transition_clouds_to(preset, seconds)` 切换天气。
- `set_moment(year, day_of_year, time_of_day, lunar_age_days, latitude_degrees, jump)`
  像日夜循环那样把天空移到另一个时刻和地点。时刻有变化时整个天空都会跟上（`jump` 为真时
  即使没有变化也会更新）。用它让天空跟随外部的时钟（例如游戏存档里的时间），此时关闭
  `cycle_enabled`。
- 天文数据，调用时计算（因此跟得上运行中的时钟）：`get_local_sidereal_time()`、
  `get_sun_equatorial()` 和 `get_moon_equatorial()`（赤经和赤纬），以及
  `get_planet_equatorial_directions()`。它们都在星星的坐标系中：`get_star_basis()`
  把世界方向转进这个坐标系，它的转置再转回来。`GRESkySystem.refracted(direction)`
  把真实方向抬到大气折射后看到的位置，与天空的绘制一致。有了这些就能归算六分仪观测。
- 获取函数：`get_sun_direction()`、`get_moon_direction()`、`get_sun_color()`、
  `get_sun_visibility()`、`get_moon_visibility()`、`get_moon_phase()`、
  `get_cloud_state()`、`get_scene_illuminance()`、`get_sky_irradiance()`（测光值中来自天空的部分，单位为场景单位；未知时为负）、`get_illuminance_unit_lux()`。
  它们返回缓存值，调用开销很小。
- 信号：`time_of_day_changed(time_of_day)` 和 `lighting_changed`。
- `set_camera_underwater(underwater)`：相机在水下时不在屏幕上绘制体积云，由海洋系统调用。
- 云、星星、行星和大气相关的获取函数构成海洋的天空源约定（见 `gre_ocean_system` 的
  README）。

### 透明材质的雾霭

不透明几何体会自动加上雾霭。透明材质需要自己处理：包含大气头文件，并在
`fragment()` 中写入 `FOG`。

```glsl
#include "res://addons/gre_sky_system/shaders/atmosphere.gdshaderinc"
// 在 fragment() 中：
FOG = atmosphere_fog((INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz);
```

不透明材质不能写入 `FOG`。

## 限制

- 云不会在场景上投下阴影。相机下降进入云层时，阳光变暗，整个场景同时变暗。
- 不写入深度的透明表面会画在云的后面。
- 大气在水平方向上处处相同。100 公里以外的点按 100 公里处理雾霭。
- 快速变化（预设之间直接跳转、很快的昼夜循环）需要约半秒才能稳定下来。
