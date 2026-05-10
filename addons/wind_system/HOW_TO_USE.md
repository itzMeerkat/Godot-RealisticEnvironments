# Wind System HOW TO USE

## 安装

1. 将 `addons/wind_system/` 复制到目标 Godot 项目的 `res://addons/wind_system/`。
2. 在 Godot 中打开 `Project > Project Settings > Plugins`，启用 `Wind System`。
3. 将 `res://addons/wind_system/wind_system.tscn` 实例化到场景中。也可以创建一个 `Node`，挂载 `res://addons/wind_system/wind_system.gd`，或在脚本中创建 `WindSystem.new()`。

## 参数

- `wind_speed`：基础风速，单位为米/秒。
- `wind_direction`：风向角度。`0` 指向 `+Z`，`90` 指向 `+X`。
- `gust_strength`：阵风最大附加速度。设为 `0` 时输出稳定风速。
- `gust_frequency`：阵风变化频率，单位为次/秒。

这些参数都可以在 Inspector 调整，也可以运行时设置：

```gdscript
@onready var wind: WindSystem = $WindSystem

func _ready() -> void:
	wind.wind_speed = 12.0
	wind.wind_direction = 35.0
	wind.gust_strength = 2.5
```

## 读取风数据

```gdscript
var speed := wind.get_wind_speed()
var direction_degrees := wind.get_wind_direction_degrees()
var wind_2d := wind.get_wind_vector_2d()
var wind_3d := wind.get_wind_vector_3d()
```

`get_wind_speed()` 会包含阵风影响；`get_base_wind_speed()` 只返回基础风速。

## 与其他系统连接

Ocean System 可以直接把 `WindSystem` 作为 `wind_source_path`。其他系统也可以通过同一套 getter 消费风数据，不需要引用 Ocean System。
