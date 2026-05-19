# Godot 开船游戏：船与海面互动效果需求文档

## 1. 文档目标

本文档描述开船游戏中船只与海面互动的三个核心视觉系统需求：

1. 船行驶产生的尾迹浪 Wake
2. 船头破浪 Bow Wave
3. 水花 / 喷溅 Splash

当前阶段不实现完整流体模拟、不实现真实水面高度传播、不实现复杂物理浪叠加。目标是在 Godot 中用较低成本实现可信、可控、可调参的船水互动视觉效果。

---

## 2. 总体设计原则

### 2.1 视觉优先

本阶段效果以视觉表现为主，不追求物理精确。

船体与海面的互动应让玩家直观感受到：

- 船正在水面上真实移动
- 船速越快，水面扰动越明显
- 船转向、加速、撞浪时会产生更强烈的水花和泡沫
- 船头、船尾、船侧产生的效果有明确区别

### 2.2 与船只状态绑定

所有水面互动效果都应尽量由船只当前状态驱动，而不是固定播放。

主要输入参数包括：

- 船只世界坐标
- 船只前进方向
- 船只速度
- 船只加速度
- 油门输入
- 转向输入
- 船体倾斜角度
- 船头是否撞击浪面
- 船体是否发生较强垂直冲击

### 2.3 可调参

每类效果都需要暴露参数，方便在编辑器中调试。

推荐参数包括：

- 效果强度
- 触发速度阈值
- 最大强度速度
- 持续时间
- 扩散宽度
- 透明度衰减
- 粒子数量
- 粒子速度
- 噪声强度
- 泡沫颜色
- 生命周期

### 2.4 分层实现

建议将效果拆成三个独立系统：

- WakeSystem：负责船尾尾迹浪和尾部泡沫
- BowWaveSystem：负责船头破浪和船头泡沫
- SplashSystem：负责瞬时水花、撞击喷溅、急转甩水

三个系统可以共享船只状态数据，但渲染和触发逻辑应保持独立。

---

## 3. 系统一：尾迹浪 Wake

## 3.1 功能描述

尾迹浪是船在水面上移动后，在船尾形成的持续性水面扰动。

它是玩家最常看到的水面互动效果，主要用于表现船只速度、航向和运动轨迹。

尾迹浪应包括以下视觉元素：

- 船尾正后方的泡沫带
- 船两侧向外扩散的 V 字形尾迹
- 随距离逐渐变淡的水纹
- 高速时更长、更宽、更亮的白浪
- 低速时较短、较淡的小扰动

---

## 3.2 视觉表现需求

### 3.2.1 低速状态

当船只速度较低时：

- 船尾产生轻微泡沫
- 尾迹长度较短
- V 字形不明显
- 水纹较细，透明度较低
- 效果应平滑出现，不应突然弹出

适用情况：

- 缓慢前进
- 靠岸
- 小范围调整方向

### 3.2.2 中速状态

当船只以正常巡航速度航行时：

- 船尾形成稳定泡沫轨迹
- 两侧产生清晰的 V 字形扩散浪
- 尾迹宽度随船体宽度和速度变化
- 尾迹会在一段距离后逐渐淡出
- 水纹方向应与船只运动方向一致

适用情况：

- 正常航行
- 大多数玩家驾驶状态

### 3.2.3 高速状态

当船只高速航行时：

- 船尾泡沫更亮、更密集
- 尾迹明显拉长
- V 字扩散角度更明显
- 船尾中心区域出现较强湍流
- 尾迹边缘可以带有不规则噪声

适用情况：

- 全速前进
- 冲刺
- 竞速玩法
- 加速技能

### 3.2.4 转向状态

当船只转向时：

- 尾迹应产生弯曲，而不是笔直向后
- 急转时外侧泡沫更明显
- 船尾可产生侧向拖痕
- 转向越剧烈，尾迹越宽、越乱

适用情况：

- 左右转弯
- 漂移式转向
- 高速急转

---

## 3.3 触发条件

尾迹浪应在以下条件下产生：

- 船只速度大于最小尾迹速度阈值
- 船只处于水面上
- 船只没有完全离开水面

推荐逻辑：

```text
if boat_speed > wake_min_speed and boat_is_on_water:
    enable_wake_effect()
else:
    fade_out_wake_effect()
```

---

## 3.4 强度计算

尾迹强度应主要由船速决定。

推荐归一化公式：

```text
wake_strength = clamp(
    (boat_speed - wake_min_speed) / (wake_max_speed - wake_min_speed),
    0.0,
    1.0
)
```

可额外加入油门输入：

```text
wake_strength = max(speed_strength, throttle_strength * throttle_wake_factor)
```

这样可以让船只刚加速时，即使速度还没完全起来，也能产生更明显的尾部泡沫。

---

## 3.5 关键参数

| 参数名 | 类型 | 说明 |
|---|---|---|
| wake_min_speed | float | 开始产生尾迹的最小速度 |
| wake_max_speed | float | 尾迹达到最大强度的速度 |
| wake_length | float | 尾迹最大长度 |
| wake_width | float | 尾迹最大宽度 |
| wake_fade_time | float | 尾迹淡出时间 |
| wake_opacity | float | 尾迹最大透明度 |
| wake_v_angle | float | V 字尾迹扩散角度 |
| wake_noise_strength | float | 尾迹边缘噪声强度 |
| wake_foam_density | float | 泡沫密度 |
| wake_lifetime | float | 单段尾迹持续时间 |

---

## 3.6 推荐实现方式

### 水面 Shader Mask

适合已有自定义海面 shader 的项目。

实现方式：

- 将船尾位置写入动态 mask 或 render texture
- 水面 shader 根据 mask 显示泡沫和扰动
- mask 随时间扩散、模糊、衰减

优点：

- 与水面融合更自然
- 多艘船可叠加
- 可统一控制泡沫、法线扰动

缺点：

- 实现复杂度更高
- 需要处理动态纹理或视野范围问题

---

## 3.7 验收标准

尾迹浪系统完成后，应满足：

- 船只静止时没有明显尾迹
- 船只低速时有轻微扰动
- 船只高速时尾迹明显增强
- 船只转向时尾迹方向和形状能反映转向轨迹
- 尾迹不会突然出现或突然消失
- 尾迹不会明显穿帮，例如漂浮在水面太高或沉入水下太深
- 多次加速、减速、转向时效果稳定

---

# 4. 系统二：船头破浪 Bow Wave

## 4.1 功能描述

船头破浪是船头切开水面时产生的局部水面扰动。

它主要发生在船头附近，用于表现船体正在推开水面，而不是简单地在水面上滑动。

船头破浪应包括以下视觉元素：

- 船头两侧向外翻开的水纹
- 船头附近的白色泡沫
- 高速时的前向喷溅
- 船头撞浪时的短时增强效果

---

## 4.2 视觉表现需求

### 4.2.1 正常前进

当船只向前航行时：

- 船头两侧出现稳定泡沫线
- 水纹沿船体两侧向后延伸
- 泡沫强度随速度增加
- 船头正前方不应出现过大阻挡视线的水花

### 4.2.2 高速破浪

当船只高速前进时：

- 船头两侧泡沫更亮
- 水花向外侧和后侧喷出
- 船头附近可以出现短暂白浪
- 效果应有一定随机性，避免过于规则

### 4.2.3 撞击浪面

当船头与较高浪面发生相对冲击时：

- 船头水花瞬间增强
- 可触发一次中型 splash
- 泡沫持续时间短暂增加
- 船头附近出现更密集的水雾或粒子

---

## 4.3 触发条件

船头破浪应在以下条件下产生：

- 船只速度大于船头破浪最小速度
- 船头接触水面或接近水面
- 船只前进方向与速度方向大致一致

推荐逻辑：

```text
if forward_speed > bow_wave_min_speed and bow_point_is_near_water:
    enable_bow_wave()
else:
    fade_out_bow_wave()
```

注意：应优先使用船只前向速度，而不是总速度。

```text
forward_speed = dot(boat_velocity, boat_forward_direction)
```

这样可以避免船只横向滑动时船头破浪仍然错误增强。

---

## 4.4 强度计算

基础强度由前向速度决定：

```text
bow_wave_strength = clamp(
    (forward_speed - bow_wave_min_speed) / (bow_wave_max_speed - bow_wave_min_speed),
    0.0,
    1.0
)
```

撞浪时可以添加额外冲击强度：

```text
impact_strength = clamp(
    relative_vertical_speed / bow_impact_max_speed,
    0.0,
    1.0
)

final_bow_strength = max(bow_wave_strength, impact_strength)
```

---

## 4.5 关键参数

| 参数名 | 类型 | 说明 |
|---|---|---|
| bow_wave_min_speed | float | 开始出现船头破浪的最小速度 |
| bow_wave_max_speed | float | 船头破浪达到最大强度的速度 |
| bow_foam_width | float | 船头泡沫宽度 |
| bow_foam_length | float | 船头泡沫向后延伸长度 |
| bow_splash_rate | float | 船头水花粒子生成频率 |
| bow_splash_velocity | float | 船头水花喷射速度 |
| bow_side_angle | float | 水花向两侧喷射角度 |
| bow_impact_threshold | float | 撞浪触发阈值 |
| bow_impact_multiplier | float | 撞浪增强倍率 |

---

## 4.6 推荐实现方式

### 船头左右粒子发射器

实现方式：

- 在船头左右两侧各放一个粒子发射点
- 粒子向外侧、后侧、略向上喷出
- 粒子数量随速度增加
- 粒子生命周期较短
- 粒子贴图使用泡沫、水滴、水雾混合

适合表现：

- 船头水花
- 高速破浪
- 撞浪喷溅

---

## 4.7 验收标准

船头破浪系统完成后，应满足：

- 船向前移动时，船头两侧有明显切水效果
- 船速越快，船头泡沫和水花越强
- 船静止时，船头破浪效果消失或极弱
- 船头撞击浪面时可以触发短暂增强
- 船头水花不会遮挡过多视野
- 粒子喷射方向符合船头朝向
- 效果与船尾尾迹有明显区别

---

# 5. 系统三：水花 / 喷溅 Splash

## 5.1 功能描述

水花 / 喷溅是瞬时事件型效果，用于表现船只与水面发生较强冲击或剧烈运动时的水体反应。

与尾迹浪和船头破浪不同，Splash 不一定持续存在，而是由特定事件触发。

典型触发场景包括：

- 船头撞上大浪
- 船体从浪顶落下并拍击水面
- 高速急转导致侧向甩水
- 船只从空中落回水面
- 船体与水面发生剧烈垂直冲击
- 船只受到爆炸或碰撞后砸入水中

---

## 5.2 Splash 类型划分

### 5.2.1 小型水花

用于轻微接触或低强度扰动。

表现：

- 粒子数量少
- 生命周期短
- 高度较低
- 范围较小

触发场景：

- 低速撞小浪
- 船身轻微拍水
- 小幅度转向

### 5.2.2 中型水花

用于正常驾驶中的明显冲击。

表现：

- 粒子数量中等
- 有明显向外喷射方向
- 带有少量水雾和泡沫
- 持续时间较短但可被玩家注意到

触发场景：

- 船头撞浪
- 高速转向
- 船身从小浪上落下

### 5.2.3 大型水花

用于强烈事件或夸张反馈。

表现：

- 粒子数量多
- 喷射高度较高
- 范围较大
- 可包含水柱、水雾、泡沫环
- 可伴随短暂屏幕震动或音效

触发场景：

- 船只从高处落入水中
- 高速撞击大浪
- 爆炸冲击
- 剧情或技能事件

---

## 5.3 触发条件

Splash 应基于事件触发，而不是持续播放。

推荐触发来源：

1. 垂直冲击
2. 船头撞浪
3. 急转侧向甩水
4. 高速碰撞水面

---

## 5.4 垂直冲击触发

当船体向下速度较大，并接触水面时，触发水花。

推荐逻辑：

```text
if previous_was_airborne and boat_is_on_water:
    if downward_speed > splash_impact_min_speed:
        spawn_splash(impact_position, impact_strength)
```

冲击强度：

```text
impact_strength = clamp(
    (downward_speed - splash_impact_min_speed) / (splash_impact_max_speed - splash_impact_min_speed),
    0.0,
    1.0
)
```

---

## 5.5 船头撞浪触发

当船头相对水面产生明显向下或向前冲击时，触发船头 splash。

推荐判断条件：

- 船头采样点接触水面
- 船头相对水面的垂直速度超过阈值
- 船只前向速度超过阈值

```text
if bow_point_hits_wave:
    if forward_speed > bow_splash_min_speed and relative_vertical_speed > bow_splash_impact_threshold:
        spawn_bow_splash(bow_position, splash_strength)
```

---

## 5.6 急转侧向水花

当船只高速急转时，船体外侧应产生甩水。

推荐判断条件：

- 船速较高
- 转向输入较大
- 横向速度或角速度较大

```text
turn_splash_strength = speed_strength * abs(turn_input)

if turn_splash_strength > turn_splash_threshold:
    spawn_side_splash(outer_side_position, turn_splash_strength)
```

侧向水花应出现在转弯外侧。

示例：

- 向左急转时，右侧水花更明显
- 向右急转时，左侧水花更明显

---

## 5.7 关键参数

| 参数名 | 类型 | 说明 |
|---|---|---|
| splash_impact_min_speed | float | 触发水花的最小下落速度 |
| splash_impact_max_speed | float | 水花达到最大强度的下落速度 |
| splash_cooldown | float | 同类水花最小触发间隔 |
| splash_particle_min_count | int | 最小粒子数量 |
| splash_particle_max_count | int | 最大粒子数量 |
| splash_lifetime | float | 粒子生命周期 |
| splash_spread_angle | float | 粒子扩散角度 |
| splash_upward_velocity | float | 向上喷射速度 |
| splash_outward_velocity | float | 向外喷射速度 |
| splash_gravity_scale | float | 粒子重力倍率 |
| splash_foam_duration | float | 水花后的泡沫残留时间 |
| turn_splash_threshold | float | 急转水花触发阈值 |

---

## 5.8 推荐实现方式

### GPUParticles3D 

实现方式：

- 根据事件生成一次性粒子爆发
- 使用 one-shot 粒子
- 粒子方向根据事件类型设置
- 小型、中型、大型水花使用不同预设

推荐粒子层次：

- 水滴粒子
- 泡沫粒子
- 水雾粒子
- 可选：短暂泡沫贴片

## 5.9 验收标准

Splash 系统完成后，应满足：

- 小冲击产生小水花，大冲击产生大水花
- 水花只在事件发生时触发，不应持续无意义播放
- 高速撞浪时船头水花明显增强
- 高速急转时外侧水花明显
- 水花方向与船体运动方向一致
- 水花粒子不会明显穿过船体或从空中错误生成
- 高频事件下不会造成明显性能下降

---

# 6. 三个系统之间的关系

## 6.1 触发关系

三个系统可以同时存在，但用途不同：

| 系统 | 类型 | 持续性 | 主要驱动 |
|---|---|---|---|
| Wake | 持续效果 | 持续 | 船速、转向 |
| Bow Wave | 半持续效果 | 航行时持续 | 前向速度、船头接水 |
| Splash | 瞬时效果 | 瞬间 | 撞击、落水、急转 |

---

## 6.2 避免重复表现

需要避免以下问题：

- 船头破浪和 Splash 同时过强，导致船头一直像爆炸
- 尾迹泡沫和侧向水花混在一起，方向不清晰
- 低速时所有效果都出现，导致视觉噪音过多
- 高速时粒子过多，影响性能和画面清晰度

建议：

- Wake 用于稳定轨迹
- Bow Wave 用于船头持续切水
- Splash 只用于强事件反馈

---

## 6.3 优先级建议

当多个效果同时触发时，可以按以下优先级处理：

1. Splash：最高优先级，用于瞬间冲击反馈
2. Bow Wave：中等优先级，用于船头持续表现
3. Wake：基础优先级，用于长期运动轨迹

如果性能不足，应优先保留 Wake 和 Bow Wave，降低 Splash 数量。

---

# 7. 数据接口建议

## 7.1 船只状态数据结构

建议由船只控制器每帧输出一个状态对象。

```gdscript
class_name BoatWaterState

var world_position: Vector3
var velocity: Vector3
var forward_direction: Vector3
var right_direction: Vector3
var speed: float
var forward_speed: float
var lateral_speed: float
var throttle_input: float
var turn_input: float
var angular_velocity: float
var is_on_water: bool
var was_airborne: bool
var bow_position: Vector3
var stern_position: Vector3
var left_side_position: Vector3
var right_side_position: Vector3
var bow_near_water: bool
var downward_speed: float
```

---

## 7.2 系统接口

每个视觉系统可以实现统一接口：

```gdscript
func update_effect(state: BoatWaterState, delta: float) -> void:
    pass
```

Splash 系统额外提供事件接口：

```gdscript
func spawn_splash(position: Vector3, direction: Vector3, strength: float, splash_type: int) -> void:
    pass
```

---

# 8. Godot 节点结构建议

推荐节点结构：

```text
Boat
├── Mesh
├── CollisionShape3D
├── BoatController
├── WaterInteractionController
│   ├── WakeSystem
│   ├── BowWaveSystem
│   └── SplashSystem
├── Marker3D_Bow
├── Marker3D_Stern
├── Marker3D_LeftSide
└── Marker3D_RightSide
```

说明：

- Marker3D_Bow：船头破浪和船头 Splash 的位置
- Marker3D_Stern：尾迹生成位置
- Marker3D_LeftSide：左侧急转水花位置
- Marker3D_RightSide：右侧急转水花位置
- WaterInteractionController：收集船只状态并分发给三个系统

---

# 9. 性能要求

## 9.1 基础性能目标

单艘玩家船只情况下：

- Wake、Bow Wave、Splash 同时启用时不应产生明显帧率下降
- 粒子数量应随画质设置调整
- Splash 应使用对象池
- 尾迹贴片数量应有上限
- 离摄像机较远时应降低效果强度或关闭部分粒子

---

## 9.2 LOD 建议

| 距离 | Wake | Bow Wave | Splash |
|---|---|---|---|
| 近距离 | 完整显示 | 完整显示 | 完整显示 |
| 中距离 | 降低细节 | 降低粒子量 | 只显示中大型 |
| 远距离 | 简化贴图 | 关闭小粒子 | 关闭小型水花 |

---

# 10. 调试工具需求

为了方便调试，建议提供以下 Debug 选项：

- 显示船头、船尾、左右侧 Marker
- 显示当前船速
- 显示 forward_speed
- 显示 wake_strength
- 显示 bow_wave_strength
- 显示 splash_strength
- 显示 Splash 触发点
- 开关 WakeSystem
- 开关 BowWaveSystem
- 开关 SplashSystem
- 显示当前粒子数量

---

# 11. 开发优先级

建议按以下顺序开发：

## 第一阶段：基础可见效果

1. 实现船尾 Wake 基础泡沫
2. 实现船头 Bow Wave 基础粒子
3. 实现简单 Splash 事件

目标：船开起来后，水面有基本反馈。

## 第二阶段：速度和方向响应

1. Wake 强度随速度变化
2. Bow Wave 随前向速度变化
3. 急转时触发侧向 Splash
4. 尾迹方向跟随船只运动轨迹

目标：不同驾驶状态有明显差异。

## 第三阶段：表现增强

1. 添加 V 字尾迹
2. 添加船头撞浪增强
3. 添加水花大小分级
4. 添加泡沫残留
5. 添加随机噪声和自然衰减

目标：效果更自然、更有冲击力。

## 第四阶段：优化和调参

1. 添加对象池
2. 添加 LOD
3. 限制最大粒子数量
4. 调整不同船速下的视觉曲线
5. 添加 Debug 面板

目标：保证稳定性能和可维护性。
