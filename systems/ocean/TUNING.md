# Ocean 参数实验指南

这份文档用于调试海面颜色、反射、远海 LOD 和泡沫。建议每次只改一类问题，并记录参数组合，否则很容易把浪型、反射和泡沫互相抵消。

## 推荐测试场景

优先固定以下条件再调参：

- 风速：先用 10，再用 20 复查。
- 时间：中午、黄昏各测试一次。
- 相机：保持一个低视角，看得到近海、中距离和地平线。
- Fog：调试海面时保持关闭。
- Foam：如果判断反光问题，可以先把 `Foam Intensity` 降低到 0，确认白色是否仍存在。

观察时把画面分成三段：

- 近处：玩家附近的细节水面。
- 中距离：从近海细节区外侧到远海过渡段。
- 最远处：接近地平线的区域。

## 先判断问题来源

### 白色区域会随法线噪声移动

通常是反射/Fresnel 被远处动态 normal 放大。

优先调：

- `Roughness`
- `Specular`
- `Far Normal`

### 白色区域像固定颜色层

通常是环境光、天空反射、water color 或 light color 的问题。

优先调：

- `Roughness`
- `Specular`
- 天空/太阳光颜色和能量
- `Water Color`

### 白色区域跟浪尖一致

通常是 foam。

优先调：

- `Foam Intensity`
- `Foam Threshold`
- `Foam Softness`
- `Far Foam Coverage`
- `Far Foam Threshold`

## 统一反射参数

当前水面反射不按距离分支。近处、远处、Far LOD 和关闭 Far LOD 后扩大的主 ocean 都使用同一套反射 shader。调试时先以近海看起来正确的效果为基准，然后观察同一套模型在远处为什么被放大。

### Roughness

全局反射粗糙度。

- 提高：反射更软，白色高光更分散。
- 降低：反射更清晰，但更容易显出高光噪声和环境反射过亮。

建议先在 `0.6 - 0.8` 之间实验。

### Specular

全局镜面反射强度。

- 降低：压制远处白反光。
- 提高：保留更强的太阳/天空反射。

建议先在 `0.25 - 0.6` 之间实验。

### Far Normal

远处法线强度。

- 降低：减少远处动态反射噪声。
- 提高：远处波纹和反光更明显。

推荐范围：

- 常规：`0.1 - 0.2`
- 仍有移动噪声：`0.05 - 0.12`
- 远处太平：`0.2 - 0.35`

当前默认：`0.14`。

## Far LOD 波形参数

这些参数控制远处如何使用同一组 FFT cascade。

### Far LOD Blend Distance

控制从近海到 Far LOD 的距离范围。

- 增大：过渡更慢，更不容易出现环状边界。
- 减小：更快进入远海低频版本，性能和稳定性更好，但可能更早变平。

### Far LOD Curve

控制波形 LOD 的曲线。

- 提高：更久保留近处/中距离波形细节。
- 降低：更早过滤高频 cascade。

注意：它影响的是波形/normal cascade 过滤，不是反射材质。中距离反光泛白优先先调统一的 `Roughness` 和 `Specular`，并观察 custom light/Fresnel 的变化。

### Low Freq Tile

决定哪些 cascade 在远处被视为低频。

- 提高：远处只保留更大尺度波浪，更稳定但可能更平。
- 降低：远处保留更多中频波浪，更有起伏但可能带来闪烁和白噪声。

## 推荐调参流程

1. 先关掉 foam 或把 `Foam Intensity` 降到 0，确认白色问题是否来自反射。
2. 设置 `Far LOD Enabled = false`，把 `Ocean Radius` 加大，用主 ocean 单独验证反射。
3. 从近处效果能接受的值开始，分别测试 `Roughness = 0.6 / 0.7 / 0.8`。
4. 在最佳 roughness 下测试 `Specular = 0.25 / 0.4 / 0.55`。
5. 如果远处仍有移动噪声，把 `Far Normal` 从 `0.14` 降到 `0.08 - 0.12`；如果 Far LOD 已关闭，则降低各 cascade 的 `Normal Scale`。
6. 重新开启 Far LOD，确认近远海没有接缝或反光突变。
7. Foam 恢复后，如果远处白沫铺开，再调 `Far Foam Coverage` 和 `Far Foam Threshold`。
8. 最后用风速 20 和黄昏各复查一次。

## 参数记录模板

```text
Time of day:
Wind speed:
Camera height/angle:

Roughness:
Specular:
Far Normal:
Far LOD Curve:
Low Freq Tile:
Far Foam Coverage:
Far Foam Threshold:

Observation:
Next change:
```
