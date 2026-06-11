# Godot FFT 海面：逆光浪尖散射透光效果技术路径文档

## 1. 目标

为现有 FFT 海面增加“太阳低角度逆光时，浪尖内部被照穿并产生柔和散射”的视觉效果。

目标不是一开始做完整物理体积散射，而是用可控的实时近似实现以下观感：

- 太阳接近地平线时，浪尖、浪唇、薄水层边缘出现青绿/蓝绿/金色透光。
- 正午或顺光时，效果明显减弱，不能让整片海面一直发光。
- 透光主要集中在高浪尖、陡峭面、破碎浪区域，而不是平静水面。
- 泡沫仍然偏白，不能被过度染成绿色。
- 与现有 FFT displacement、normal、foam、reflection/refraction 管线兼容。

---

## 2. 推荐实现路线

分三层实现：

1. **MVP：基于法线、视线、太阳方向的逆光透射近似**
   - 不依赖真实厚度。
   - 只需要水面法线、相机方向、太阳方向、浪尖 mask。
   - 成本低，最适合快速验证视觉方向。

2. **增强版：接入 FFT 数据生成浪尖/薄水 mask**
   - 使用 FFT 输出的高度、法线、坡度、Jacobian/foam/curvature 数据。
   - 让透光严格绑定到浪峰和破碎区域。

3. **高质量版：加入屏幕空间深度厚度、折射、吸收、bloom**
   - 用 depth texture 估算水体厚度。
   - 用 screen texture 做折射背景色。
   - 用 Environment / bloom 放大逆光亮部。

---

## 3. 输入数据设计

### 3.1 必需输入

| 数据 | 来源 | 用途 |
|---|---|---|
| 水面法线 `N` | FFT normal map 或 shader 法线 | 判断浪面朝向、背光面 |
| 视线方向 `V` | Godot `VIEW` 或相机向量 | 判断是否处于逆光观察角度 |
| 太阳方向 `L` | DirectionalLight3D 或手动 uniform | 判断光是否从浪后方穿过 |
| 浪尖 mask `crest_mask` | 高度/坡度/foam/curvature | 控制透光只出现在浪尖 |
| 太阳颜色 `sun_color` | DirectionalLight3D 或环境参数 | 日落时偏暖，白天偏白 |

### 3.2 可选输入

| 数据 | 来源 | 用途 |
|---|---|---|
| FFT 高度图 | displacement texture | 找高浪峰 |
| FFT slope/derivative | 频谱导数或 normal | 找陡峭浪面 |
| Jacobian / folding | FFT 破碎指标 | 找浪峰压缩和白沫区域 |
| foam map | 现有泡沫系统 | 遮挡/混合透光 |
| depth texture | 屏幕深度 | 估算水体厚度、浅水/岸边吸收 |
| screen texture | 屏幕颜色 | 做折射和背景透过 |

---

## 4. 效果拆解

最终透光强度建议由 5 个 mask 相乘：

```text
transmission = back_view
             * back_normal
             * sun_low
             * crest_mask
             * thin_mask
             * foam_occlusion
```

每个 mask 负责一个视觉条件：

| mask | 作用 |
|---|---|
| `back_view` | 相机和太阳接近对向时增强，也就是“逆光” |
| `back_normal` | 浪面背对太阳时增强，让光像从水体后方穿过 |
| `sun_low` | 太阳低角度时增强，正午减弱 |
| `crest_mask` | 只在浪尖/浪唇/陡峭区域出现 |
| `thin_mask` | 越薄越亮，越厚越暗 |
| `foam_occlusion` | 泡沫区域降低青绿透光，转为白色散射 |

---

## 5. 第一阶段：MVP shader 近似

### 5.1 核心判断

假设：

- `L`：从水面片元指向太阳的方向。
- `V`：从水面片元指向相机的方向。
- `N`：水面法线。

逆光判断：

```glsl
float back_view = pow(clamp(-dot(L, V), 0.0, 1.0), back_view_power);
```

含义：太阳和相机越在片元两侧，`back_view` 越强。

背面透光判断：

```glsl
float back_normal = pow(clamp(dot(-N, L), 0.0, 1.0), back_normal_power);
```

含义：水面法线背对太阳时，认为光在“穿过”水体。

太阳低角度判断：

```glsl
float sun_low = 1.0 - smoothstep(sun_low_start, sun_low_end, L.y);
```

含义：太阳方向的世界 Y 分量越低，效果越强。

### 5.2 MVP 版 Godot shader 片段

下面片段适合先塞进现有 water spatial shader 的 `fragment()` 中做验证。

```glsl
shader_type spatial;

uniform vec3 sun_dir_world = vec3(0.0, 0.15, -0.98); // 从水面指向太阳
uniform vec3 sun_color = vec3(1.0, 0.72, 0.45);
uniform vec3 water_transmission_color = vec3(0.02, 0.55, 0.45);

uniform float transmission_strength = 1.2;
uniform float back_view_power = 2.0;
uniform float back_normal_power = 1.5;
uniform float sun_low_start = 0.02;
uniform float sun_low_end = 0.35;
uniform float emission_boost = 0.25;

float saturate(float x) {
    return clamp(x, 0.0, 1.0);
}

void fragment() {
    vec3 N = normalize(NORMAL);
    vec3 V = normalize(VIEW);

    // 把世界空间太阳方向转到 view space，便于和 Godot 的 VIEW/NORMAL 对齐。
    vec3 L = normalize((VIEW_MATRIX * vec4(normalize(sun_dir_world), 0.0)).xyz);

    float back_view = pow(saturate(-dot(L, V)), back_view_power);
    float back_normal = pow(saturate(dot(-N, L)), back_normal_power);
    float sun_low = 1.0 - smoothstep(sun_low_start, sun_low_end, normalize(sun_dir_world).y);

    // MVP 阶段可以先用法线陡峭度代替真实浪尖 mask。
    float slope_mask = smoothstep(0.25, 0.85, 1.0 - N.y);
    float crest_mask = slope_mask;

    float transmission_mask = back_view * back_normal * sun_low * crest_mask;

    vec3 transmission = water_transmission_color
                      * sun_color
                      * transmission_strength
                      * transmission_mask;

    // 方式 A：加入 BACKLIGHT，较符合“透光/背光”语义。
    BACKLIGHT = transmission;

    // 方式 B：少量加入 EMISSION，用于 HDR + bloom。不要太大，否则水面会自发光。
    EMISSION = transmission * emission_boost;
}
```

### 5.3 MVP 验收标准

完成后先不要调颜色，先调 mask：

- 太阳在相机正前方/浪后方时，浪尖应变亮。
- 太阳在相机同侧顺光时，透光应明显消失。
- 太阳高度升高到接近正午时，透光应明显减弱。
- 平缓水面不应整片发亮。
- 浪的背光边缘比正面更亮。

建议加一个 debug 模式：

```glsl
uniform int debug_view = 0;

// 0 正常渲染
// 1 back_view
// 2 back_normal
// 3 sun_low
// 4 crest_mask
// 5 final transmission_mask
```

---

## 6. 第二阶段：接入 FFT 浪尖数据

MVP 的 `crest_mask` 只靠法线会比较粗糙。真正好看的效果应该来自 FFT 的浪峰信息。

### 6.1 推荐浪尖 mask 组成

```text
crest_mask = max(
    height_crest * slope_crest,
    curvature_crest,
    jacobian_crest
)
```

### 6.2 高度 mask

如果你的 FFT displacement 里有垂直位移 `height`：

```glsl
float height_crest = smoothstep(crest_height_start, crest_height_end, height);
```

建议参数：

```text
crest_height_start = 0.4 * wave_amplitude
crest_height_end   = 0.9 * wave_amplitude
```

如果海面会随 Beaufort/wind strength 变化，这两个值应该跟浪高参数联动，而不是写死。

### 6.3 坡度 mask

使用法线 Y 分量或者 FFT 导数：

```glsl
float slope = 1.0 - clamp(N.y, 0.0, 1.0);
float slope_crest = smoothstep(slope_start, slope_end, slope);
```

建议初值：

```text
slope_start = 0.25
slope_end   = 0.75
```

### 6.4 曲率 mask

如果可以从高度图采样邻域，近似 Laplacian：

```glsl
float h_c = texture(height_tex, uv).r;
float h_l = texture(height_tex, uv + vec2(-texel.x, 0.0)).r;
float h_r = texture(height_tex, uv + vec2( texel.x, 0.0)).r;
float h_d = texture(height_tex, uv + vec2(0.0, -texel.y)).r;
float h_u = texture(height_tex, uv + vec2(0.0,  texel.y)).r;

float curvature = h_l + h_r + h_d + h_u - 4.0 * h_c;
float curvature_crest = smoothstep(curv_start, curv_end, curvature);
```

注意：曲率采样会多 4 次纹理读取，成本较高。可以优先在 FFT/compute 阶段生成 curvature texture。

### 6.5 Jacobian / folding mask

如果你的 FFT 海面已经计算了 folding、Jacobian 或 foam seed，直接复用它。

典型逻辑：

```glsl
float jacobian_crest = smoothstep(jacobian_start, jacobian_end, jacobian_compression);
```

如果 Jacobian 越小代表越压缩，可以反过来：

```glsl
float jacobian_crest = smoothstep(jacobian_threshold_high, jacobian_threshold_low, jacobian);
```

### 6.6 泡沫与透光的关系

泡沫不是透明水体，它应该更偏白、更散、更不通透。

推荐：

```glsl
float foam = texture(foam_tex, uv).r;
float foam_occlusion = mix(1.0, 0.35, foam);

vec3 foam_scatter = vec3(1.0, 0.92, 0.78) * foam * back_view * sun_low * 0.25;
transmission = transmission * foam_occlusion + foam_scatter;
```

含义：

- 没泡沫：青绿/蓝绿透光强。
- 有泡沫：削弱绿色透光，增加白色/暖色边缘散射。

---

## 7. 第三阶段：屏幕空间厚度与吸收

### 7.1 为什么需要厚度

真实水体越厚，吸收越强，透出来的光越少；薄水层、浪尖、浪唇更容易被照穿。

没有真实体积网格时，可以用两种近似：

1. **浪尖薄度近似**：高、尖、陡的浪默认更薄。
2. **屏幕空间深度厚度**：用 depth texture 估算水面到水下物体/地形的距离。

### 7.2 屏幕深度采样

```glsl
uniform sampler2D depth_texture : hint_depth_texture, repeat_disable, filter_nearest;

vec3 get_view_pos_from_depth(vec2 uv) {
    float depth = textureLod(depth_texture, uv, 0.0).r;
    vec4 upos = INV_PROJECTION_MATRIX * vec4(uv * 2.0 - 1.0, depth, 1.0);
    return upos.xyz / upos.w;
}
```

### 7.3 厚度估算

```glsl
vec3 scene_pos = get_view_pos_from_depth(SCREEN_UV);
vec3 water_pos = VERTEX; // Godot fragment 中的 view-space 片元位置

float thickness = abs(scene_pos.z - water_pos.z);
float depth_thin = exp(-thickness * absorption_strength);
```

建议：

```text
absorption_strength = 0.08 ~ 0.35
```

如果 open ocean 下方采不到有效地形，`depth_thin` 可能不稳定。这时应使用 fallback：

```glsl
float crest_thin = mix(0.25, 1.0, crest_mask);
float thin_mask = max(depth_thin, crest_thin);
```

### 7.4 Beer-Lambert 风格吸收近似

水体颜色可按厚度吸收：

```glsl
vec3 absorption_color = vec3(0.15, 0.55, 0.75); // 蓝绿色保留更多
vec3 transmittance = exp(-thickness * absorption_color * absorption_strength);
```

实际项目里可以艺术化，不必严格物理。

---

## 8. 屏幕折射与背景透过

如果你已有折射，可以只在浪尖透光处增强折射颜色；如果没有，可以用 `hint_screen_texture` 做一个轻量版本。

```glsl
uniform sampler2D screen_texture : hint_screen_texture, repeat_disable, filter_linear_mipmap;

vec2 refract_offset = N.xz * refraction_strength * thin_mask;
vec3 refracted_bg = textureLod(screen_texture, SCREEN_UV + refract_offset, refraction_lod).rgb;

ALBEDO = mix(ALBEDO, refracted_bg * water_transmission_color, transmission_mask * 0.25);
```

注意：

- 折射不要太强，否则浪尖会像玻璃扭曲。
- 远处海面可降低折射强度，避免屏幕空间 artifact。
- 透明材质的排序和 screen texture 捕获限制需要单独测试。

---

## 9. 和 Godot 渲染管线的集成建议

### 9.1 优先使用的 Godot shader 输出

| 输出 | 用途 | 建议 |
|---|---|---|
| `BACKLIGHT` | 背光/次表面近似 | 主力使用 |
| `SSS_STRENGTH` | 次表面散射 | 可试，但水面不一定比手写 mask 好控 |
| `SSS_TRANSMITTANCE_COLOR` | 透射颜色 | 适合做薄水层透光 |
| `EMISSION` | HDR 亮部和 bloom | 少量使用，避免假发光 |
| `ALBEDO` | 水体基础色 | 不要把透光全部塞进 ALBEDO |
| `ALPHA` | 透明度 | 谨慎，透明排序可能影响海面 |

### 9.2 推荐组合

```text
BACKLIGHT = 主体青绿/蓝绿透光
EMISSION  = 很小的 HDR bloom 引导
ALBEDO    = 保持原本水色，只做少量混合
FOAM      = 白色散射覆盖，不跟着全绿
```

### 9.3 渲染设置建议

- 使用 Forward+ 优先测试。
- 开启 HDR。
- 在 WorldEnvironment 或 CameraAttributes 中调整曝光。
- Bloom 只让最亮的浪尖参与，强度不要盖过太阳高光。
- 日落场景中太阳颜色偏暖，水体透光色偏青绿，两者混合会更自然。

---

## 10. 参数表

| 参数 | 说明 | 初始值 |
|---|---|---|
| `transmission_strength` | 总强度 | `1.0 ~ 2.0` |
| `water_transmission_color` | 水体透光色 | `(0.02, 0.55, 0.45)` |
| `back_view_power` | 逆光角度锐度 | `2.0` |
| `back_normal_power` | 背面法线锐度 | `1.5` |
| `sun_low_start` | 开始明显增强的太阳高度 | `0.02` |
| `sun_low_end` | 超过后开始减弱的太阳高度 | `0.35` |
| `crest_height_start` | 浪峰高度起点 | 视浪高而定 |
| `crest_height_end` | 浪峰高度终点 | 视浪高而定 |
| `slope_start` | 坡度起点 | `0.25` |
| `slope_end` | 坡度终点 | `0.75` |
| `foam_occlusion` | 泡沫遮挡透光强度 | `0.5 ~ 0.8` |
| `absorption_strength` | 厚度吸收强度 | `0.08 ~ 0.35` |
| `emission_boost` | bloom 引导 | `0.1 ~ 0.35` |
| `refraction_strength` | 折射偏移 | `0.005 ~ 0.03` |

---

## 11. GDScript 参数同步

建议每帧或太阳变化时，把太阳方向和颜色同步到材质。

```gdscript
@export var sun: DirectionalLight3D
@export var water_mesh: MeshInstance3D

func _process(_delta: float) -> void:
    if sun == null or water_mesh == null:
        return

    var mat := water_mesh.get_active_material(0) as ShaderMaterial
    if mat == null:
        return

    # shader 里要求 sun_dir_world 表示“从水面片元指向太阳”。
    # 如果你项目中的方向定义相反，直接取负，并用 debug_view 验证。
    var light_ray_dir_world := -sun.global_transform.basis.z.normalized()
    var dir_to_sun_world := -light_ray_dir_world

    mat.set_shader_parameter("sun_dir_world", dir_to_sun_world)
    mat.set_shader_parameter("sun_color", sun.light_color * sun.light_energy)
```

验证方法：

- 当相机看向太阳方向，浪尖应亮。
- 当相机背对太阳看水面，效果应弱。
- 如果反了，把 `dir_to_sun_world` 乘以 `-1.0`。

---

## 12. 调试视图

强烈建议加调试开关，逐个检查 mask。

```glsl
if (debug_view == 1) {
    ALBEDO = vec3(back_view);
} else if (debug_view == 2) {
    ALBEDO = vec3(back_normal);
} else if (debug_view == 3) {
    ALBEDO = vec3(sun_low);
} else if (debug_view == 4) {
    ALBEDO = vec3(crest_mask);
} else if (debug_view == 5) {
    ALBEDO = vec3(thin_mask);
} else if (debug_view == 6) {
    ALBEDO = vec3(transmission_mask);
}
```

调试顺序：

1. 先只看 `back_view`，确认逆光方向正确。
2. 再看 `back_normal`，确认浪的背面被选中。
3. 再看 `sun_low`，确认太阳升高后效果消失。
4. 再看 `crest_mask`，确认只选中浪尖。
5. 最后看 `transmission_mask`，确认所有条件相乘后仍有可见范围。

---

## 13. 美术调参与常见问题

### 13.1 整片海都在发光

原因：

- `crest_mask` 太宽。
- `back_view_power` 太低。
- `EMISSION` 太强。
- `sun_low` 没有限制太阳高度。

解决：

- 提高 `back_view_power`。
- 提高 `slope_start/slope_end`。
- 降低 `emission_boost`。
- 让 `sun_low_end` 更低，例如从 `0.35` 降到 `0.22`。

### 13.2 浪尖太绿，像荧光液体

原因：

- `water_transmission_color` 饱和度太高。
- `EMISSION` 太大。
- 没有混入太阳暖色和泡沫白色。

解决：

- 降低绿色通道。
- 增加太阳颜色乘法。
- 泡沫区域转白色散射。

### 13.3 逆光效果不出现

原因：

- `sun_dir_world` 方向反了。
- `VIEW` 和 `sun_dir_world` 空间不一致。
- `crest_mask` 太窄。
- 材质没有进入正确 lighting 路径。

解决：

- debug `back_view`。
- 确认 `L` 被转到 view space。
- 临时令 `crest_mask = 1.0` 测试。
- 临时把 `EMISSION` 加大，看 mask 是否存在。

### 13.4 泡沫区域脏、发灰

原因：

- 透光颜色和泡沫颜色直接相乘。
- foam map 同时参与了 opacity、albedo、emission，权重冲突。

解决：

- 泡沫单独走白色散射。
- 泡沫区域降低青绿透光，而不是增强。

---

## 14. 性能建议

优先级从高到低：

1. 不要在 fragment 里做太多邻域采样。
2. curvature / foam seed 尽量在 FFT compute 阶段预计算成 texture。
3. `screen_texture` 和 `depth_texture` 只在高质量档打开。
4. 远处海面降低透光细节，使用 LOD 或 distance fade。
5. 移动端先关闭自定义 `light()`，只保留 fragment mask + 少量 emission。

距离衰减建议：

```glsl
float dist = length(VERTEX);
float distance_fade = 1.0 - smoothstep(fade_start, fade_end, dist);
transmission_mask *= distance_fade;
```

---

## 15. 推荐开发里程碑

### Milestone 1：方向和 mask 验证

目标：只用法线/太阳/视线做逆光亮边。

交付：

- `back_view` debug 正确。
- `back_normal` debug 正确。
- 低角度太阳有效，正午消失。

### Milestone 2：FFT 浪尖绑定

目标：透光只出现在浪尖、浪唇、破碎浪上。

交付：

- 接入 height/slope/foam/Jacobian 至少其中两种。
- 平缓海面不发光。
- 浪峰透光随风浪强度变化。

### Milestone 3：材质融合

目标：透光、泡沫、水体颜色和高光协调。

交付：

- 青绿透光不污染泡沫。
- sunset 场景下颜色自然。
- bloom 只在浪尖高亮，不泛白整屏。

### Milestone 4：厚度和折射增强

目标：增加薄水层、岸边、浅水区域真实感。

交付：

- depth thickness 可开关。
- refraction 可开关。
- 高低画质档位可切换。

### Milestone 5：性能和稳定性

目标：在目标平台稳定运行。

交付：

- GPU profile 通过。
- 透明排序 artifact 可接受。
- 远景无明显闪烁或噪点。

---

## 16. 最终推荐公式

```glsl
float back_view = pow(saturate(-dot(L, V)), back_view_power);
float back_normal = pow(saturate(dot(-N, L)), back_normal_power);
float sun_low = 1.0 - smoothstep(sun_low_start, sun_low_end, sun_dir_world.y);

float height_crest = smoothstep(crest_height_start, crest_height_end, height);
float slope_crest = smoothstep(slope_start, slope_end, 1.0 - N.y);
float crest_mask = max(height_crest * slope_crest, jacobian_crest);

float foam_occlusion = mix(1.0, foam_transmission_factor, foam);
float thin_mask = max(depth_thin, mix(0.25, 1.0, crest_mask));

float transmission_mask = back_view
                        * back_normal
                        * sun_low
                        * crest_mask
                        * thin_mask
                        * foam_occlusion;

vec3 transmission = water_transmission_color
                  * sun_color
                  * transmission_strength
                  * transmission_mask;

BACKLIGHT = transmission;
EMISSION = transmission * emission_boost;
```

---

## 17. 实现结论

这个效果的关键不是“让水更亮”，而是让它满足三个条件后才亮：

```text
太阳低 + 逆光 + 浪尖薄水层
```

只要这三个条件控制好，即使是便宜的 shader 近似，也能明显提升 FFT 海面在日落、日出、低角度太阳下的真实感。

