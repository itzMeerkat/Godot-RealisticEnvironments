# Sky System HOW TO USE

## 安装

1. 将 `addons/sky_system/` 复制到目标 Godot 项目的 `res://addons/sky_system/`。
2. 在 Godot 中打开 `Project > Project Settings > Plugins`，启用 `Sky System`。
3. 将 `res://addons/sky_system/sky_system.tscn` 实例化到 3D 场景中。

## 基本设置

- `time_of_day`：归一化一天时间。`0` 为午夜，`0.25` 为日出，`0.5` 为正午，`0.75` 为日落。
- `cycle_enabled`：运行时自动推进时间。
- `cycle_duration_seconds`：现实多少秒走完一天。
- `latitude_degrees`、`day_of_year`、`lunar_age_days`、`north_offset_degrees`：控制太阳、月亮和星空位置。
- `sun_energy_multiplier`、`moon_energy_multiplier`、`star_brightness`：控制光照和星空强度。
- `profile`：`SkyProfile` 资源，用于配置天空、太阳、月亮和环境光曲线。

运行时设置示例：

```gdscript
@onready var sky: SkySystem = $SkySystem

func _ready() -> void:
	sky.time_of_day = 0.45
	sky.cycle_enabled = true
	sky.cycle_duration_seconds = 900.0
	sky.latitude_degrees = 42.0
```

## 常用 API

```gdscript
var sun_dir := sky.get_sun_direction()
var moon_dir := sky.get_moon_direction()
var night := sky.get_night_factor()
var stars := sky.get_star_visibility()
```

可以监听信号：

```gdscript
sky.time_of_day_changed.connect(_on_time_changed)
sky.lighting_changed.connect(_on_lighting_changed)
```

## Ocean 反射联动

Sky System 不写入 Ocean System 的水色。需要水面反射天空时，在 Ocean System 上设置 `sky_source_path` 指向 Sky System，Ocean 会读取太阳方向、太阳颜色和天空颜色。

## 独立性说明

该插件只依赖自身目录下的场景、脚本、材质和 shader。复制到其他项目时请保持 `addons/sky_system/` 目录结构不变。
