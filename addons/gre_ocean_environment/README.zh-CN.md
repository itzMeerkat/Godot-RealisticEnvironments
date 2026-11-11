# Ocean Environment（海洋环境）

[English](README.md) · **简体中文**

拿来即用的开阔海洋。`ocean_environment.tscn` 包含风、天空、海洋和曝光，彼此已经
连接好。

需要 `gre_core`、`gre_wind_system`、`gre_sky_system`、`gre_ocean_system` 和 `gre_exposure_system`。

## 工作原理

```
GREOceanEnvironment        sea_level for the whole environment
├─ GREWindSystem
├─ GRESkySystem            clouds drift with GREWindSystem
├─ Ocean                waves follow GREWindSystem, reflects GRESkySystem
└─ GREExposureController   exposes for GRESkySystem's light
```

- 天空的云随 `GREWindSystem` 漂移。
- 海洋的浪跟随 `GREWindSystem`，并反射 `GRESkySystem` 的天空。
- `GREExposureController` 根据 `GRESkySystem` 的光照设置曝光。

这个场景只负责设置各系统之间的路径。`GREOceanEnvironment` 只增加一个设置 `sea_level`，
它同时设置海洋的 `water_level` 和天空的 `sea_level`（两者必须一致）。

## 使用方法

1. 把上面列出的插件和本插件复制到 `addons/`，并在 **项目设置 > 插件** 中启用。
2. 使用 Forward+ 渲染器，并保持物理灯光单位关闭。
3. 实例化 `ocean_environment.tscn`，删除其他的 `WorldEnvironment` 和
   `DirectionalLight3D`。
4. 添加一个 `far`（远裁剪面）超过地平线的 `Camera3D`（演示场景用 60 000 米），
   然后运行。

- 用 `sea_level` 设置海面高度。不要移动、旋转或缩放这个环境节点。
- 要修改其他内容（时间、天气、风、海浪、质量、曝光），右键点击实例，打开
  **子节点可编辑**，再编辑各个系统。各系统的 README 说明了它们的设置。
- 脚本可以通过 `wind`、`sky`、`ocean` 和 `exposure` 访问各系统，例如
  `$OceanEnvironment.sky.time_of_day = 0.75`。

要一艘现成的船，见 `gre_boat_template`。
