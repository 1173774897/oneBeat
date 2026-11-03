# oneBeat · 第四张左上完整手机模板

本版按“缩小到原来的0.3倍”制作第四张：整台手机、屏幕、边框、圆角和阴影同比缩小到30%，移至左上角；屏幕保持真正透明。其余五张与上一版透明PNG逐像素一致。

## 交付文件

- `transparent-screens/04.png`：修改后的第四张，1080×1920，RGBA PNG。
- `transparent-screens/01.png`—`06.png`：完整六张透明模板。
- `transparent-screens/master-transparent.png`：6480×1920共享透明母图。
- `transparent-screens/04-preview.jpg`：第四张棋盘格预览。
- `transparent-screens/checkerboard-preview.jpg`：六张棋盘格预览。棋盘格仅用于展示透明度，不在交付PNG内。
- `transparent-screens/export-manifest.json`：屏幕与机框完整露出、其余五张不变的验证记录。
- `phone-preview/layers/screen-mask/04.png`：第四张对应的屏幕蒙版。
- `phone-frames.json`：布局配置；`phone-preview.cjs`：矢量机框生成；`export-transparent.cjs`：透明导出与检查。
- `onebeat-transparent-template-v3.zip`：六张模板、透明母图、蒙版、预览及本说明。

## 再调整第四张

首选修改 `phone-frames.json` 中 `singlePhones` 的 `id="D"`、`page=4` 项：

| 参数 | 当前值 | 调节效果 |
|---|---:|---|
| `x` | 80 | 增大向右，减小向左；单位为第四张局部像素 |
| `y` | 96 | 增大向下，减小向上 |
| `scale` | 0.3 | 增大整台手机变大，减小变小；包括边框、圆角、描边与阴影 |
| `width` / `height` | 812 / 1760 | 未缩放基准尺寸，优先用scale保持比例，不单独改宽高 |
| `rotation` | 2° | 增大顺时针旋转，减小逆时针旋转；旋转中心为缩放后手机中心 |

实际手机框为243.6×528px；透明屏幕为229.2×513.6px，屏幕内距7.2px；圆角30px、屏幕圆角22.8px、描边1.2px、青绿阴影偏移(5.4,6)px。缩放后的旋转外框、描边和阴影约处于x70.26—338.53、y91.31—634.87，全部在1080×1920范围内。

尺寸与角度改变后会扩大或缩小旋转包围范围，左上定位并不等于旋转后的最外缘。保持完整露出时，需要连同阴影一起检查画布边界；不要只看屏幕中心。

背景素材是本目录 `sunset-native-panorama.png`，由 `phone-frames.json` 的 `background` 选择。它与上一版母图字节一致，生成脚本按6480×1920原尺寸读取，不移动或缩放背景。

## 重生成

```sh
node phone-preview.cjs
node export-transparent.cjs
```

已验证屏幕内部alpha=0、机框与阴影完整位于画布内、六张裁切可重组、原生背景未改动，以及其余五张和上一版逐像素一致。上一版保留在相邻的 `2026-10-31-sunset-native-scroll-v2/`。
