# Core（核心）

[English](README.md) · **简体中文**

海洋各插件共用的基础。它不依赖任何插件；`gre_ocean_system`、`gre_sky_system`、
`gre_buoyancy_system` 和 `gre_boat_template` 依赖它，请先启用它。

## 工作原理

各系统之间从不直接使用对方的类型。两个系统需要协作时，它们之间的约定放在这里：

| 类 | 作用 |
| --- | --- |
| `GREWaterSurface` | 水面约定。水体模拟（`GREOceanSystem`）为每个 `World3D` 注册一个；需要采样水面的代码通过 `GREWaterSurface.find(node)` 找到它。它还给出表层漂流（`get_surface_drift()`），即水顺风的平均流动，带着泡沫和漂浮物移动。 |
| `GREWaterSurfaceQueryResult`、`GREWaterSurfaceSample` | 水面查询的结果：每个点的水面高度、法线、位移和水的速度。 |
| `GREWaterDisturbance` | 水中的一个船体，即 `GREWaterSurface.submit_disturbance()` 接收的数据：船体轮廓、吃水深度和其下方水的速度。水面会画出它的运动激起的波浪。 |
| `GREWaterMask` | 让开放船体内没有水：一个看不见的盖子，在模板缓冲中做标记，水面不在那里绘制。 |
| `GREWindSource` | 通过方法或属性读取任意风源（`GREWindSystem` 或你自己的节点）。 |
| `GREProjectSetup` | 供各插件补充缺少的项目设置（全局着色器 uniform、输入动作），不改动已有设置。 |
| `GRERenderingContext` | 管理一个计算功能的 `RenderingDevice` 资源，统一释放并记录创建失败。 |

水面查询是异步的：所有使用者的查询点在 GPU 上一次批量采样，几帧之后才回读到 CPU。
因此结果总是稍旧一些，每个采样都可以把高度外推到当前时刻。

## 使用方法

### 读取水面高度

```gdscript
var _water : GREWaterSurface

func _ready() -> void:
	_water = GREWaterSurface.find(self)  # 这个世界里没有注册水面时为 null

func _physics_process(_delta : float) -> void:
	if _water == null:
		return
	_water.submit_query(self, PackedVector3Array([global_position]))  # 每个物理帧提交
	var result := _water.get_query_result(self)  # 第一次回读之前为 null
	if result != null and result.samples.size() == 1:
		var sample := result.samples[0]
		var height := sample.extrapolated_height(_water.get_query_age(result))
		# 还有 sample.normal、sample.surface_velocity 等

func _exit_tree() -> void:
	if _water != null:
		_water.release_query(self)
```

- 每个物理帧都提交；同一个查询者只保留最新一次提交。
- 一个结果对应的是它那次派发的点（`result.points`）。如果你改变了点的数量，
  请检查采样数。
- 始终用 `get_query_age(result)` 外推。
- 只需知道一个点是否在水下？`_water.point_depth(self, point)` 一次完成提交、读取和
  外推：返回该点在水面下的深度（米，水面以上为负），第一次读回之前为 NAN。仍需每个
  物理帧调用，并在 `_exit_tree()` 中释放查询者。

### 提供或读取风

风源是任何具有 `get_wind_speed()`（m/s）和 `get_wind_direction_degrees()`
方法的节点，或具有 `wind_speed` 和 `wind_direction` 属性的节点。方向是风吹向的
方向，单位为度：0 = +Z，90 = +X。读取风源请用 `GREWindSource.is_valid(node)`、
`get_speed(node)`、`get_direction(node)` 和 `get_velocity(node)`。

### 实现自己的水体

继承 `GREWaterSurface` 并实现它的抽象方法。在 `_enter_tree()` 中调用
`GREWaterSurface.register(get_world_3d(), surface)`，在 `_exit_tree()` 中调用
`unregister()`。每个世界只能有一个水面。没有交互波浪的水体可以忽略
`submit_disturbance()`、`release_disturbance()` 和 `set_query_wave_response()`。

### 激起波浪

每个物理帧用 `submit_disturbance(self, disturbance)` 报告一个船体（复用同一个
`GREWaterDisturbance`），并在 `_exit_tree()` 中调用 `release_disturbance(self)`。
`GREBuoyantBody` 会为漂浮物体这样做。查询结果默认不包含这些波浪，除非查询者调用
`set_query_wave_response(self, response)`（0 为不包含，1 为全部包含；
`GREBuoyantBody.wave_response`）；此时它自己报告的船体内的水面取自船体周围，所以它
永远感受不到自己排开的水。

### 让开放船体内没有水

开放小船的船底低于水线，所以不处理的话船内会显示海面。在船上添加一个 `GREWaterMask`
（一个 `MeshInstance3D`），保持水平，放在船舷上沿稍下方、座位上方。把 `hull_path`
指向船体模型，然后在检查器中点击 **Fit to Hull**。它在这个高度切开模型，把盖子做成
船体轮廓的内侧（有内外两层船壳时取内层），并向船壁外推 `edge_margin`。也可以给它一个
你自己做的平面盖子网格。编辑器中盖子带颜色显示；游戏中它是看不见的。

- 盖子在它可见的像素上写入模板值 128（`GREWaterMask.STENCIL_REFERENCE`），水面跳过这些
  像素。自定义水面着色器也需要同样的 `stencil_mode read, compare_not_equal, 128;`。
- 只有相机在盖子上方时才起作用：从下方（相机低于船舷坐在船里）会看到船内的水，而不是
  海面上的一个洞。
- 船内高过盖子的波浪仍会显示；船前方高过船舷的浪峰在与开口重叠处会被裁掉。
