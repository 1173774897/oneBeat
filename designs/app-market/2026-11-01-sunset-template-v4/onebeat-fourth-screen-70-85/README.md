# oneBeat · 第四张70%与85%双版本

按用户更正，将“缩小0.3”理解为缩小30%、保留原来的70%。同时额外制作原尺寸85%的版本；两版都是相对最初812×1760px手机框计算，不在70%的基础上再次缩放。

## 文件

| 版本 | 第四张透明PNG | 第四张预览 | 配置 |
|---|---|---|---|
| 70% | `transparent-screens/04.png` | `transparent-screens/04-preview.jpg` | `phone-frames.json` |
| 85% | `transparent-screens-85/04.png` | `transparent-screens-85/04-preview.jpg` | `phone-frames-85.json` |

`comparison-70-85.jpg` 为左右对比。棋盘格仅用于预览，交付PNG屏幕为真正透明。两个transparent-screens目录均保留完整六张模板、共享透明母图和校验记录；只有第四张与最初模板不同，其余五张逐像素一致。

`onebeat-fourth-screen-70-85.zip` 包含两张第四页PNG、两张屏幕蒙版、预览、布局配置及本说明。此前误解为30%的版本保留在相邻v3目录，不作为本次结果。

## 继续调节

首选修改各自配置文件 `singlePhones` 中的 `id="D"`、`page=4` 项：

| 参数 | 70%版 | 85%版 | 增大／减小的效果 |
|---|---:|---:|---|
| `scale` | 0.7 | 0.85 | 增大整台手机放大，减小缩小；边框、圆角、描边、阴影一起同比变化 |
| `x` | 80 | 80 | 增大向右，减小向左，以第四张局部坐标为准 |
| `y` | 96 | 96 | 增大向下，减小向上 |
| `rotation` | 2° | 2° | 增大顺时针，减小逆时针 |
| 基准width / height | 812 / 1760 | 812 / 1760 | 建议用scale整体改大小，保留宽高比 |
| 实际手机框 | 568.4×1232px | 690.2×1496px | 均完整位于1080×1920画布内 |
| 实际透明屏幕 | 534.8×1198.4px | 649.4×1455.2px | 透明开口与原屏幕同比例 |

位置优先用x/y修改，尺寸优先用scale修改。旋转后的最外缘不等于未旋转的x/y；放大或移动后需连同阴影检查边界。当前70%全框及阴影保守范围约x57.28—683.23、y85.06—1353.37；85%范围约x52.41—812.49、y82.71—1622.81，均完整露出。

背景素材为本目录 `sunset-native-panorama.png`，由两份配置的 `background` 属性读取；与原生v2母图字节一致。它按6480×1920原尺寸作为背景，只有机框几何改变。

## 重生成

70%版：

```sh
node phone-preview.cjs
node export-transparent.cjs
```

85%版：

```sh
node phone-preview.cjs phone-frames-85.json phone-preview-85
node export-transparent.cjs phone-frames-85.json phone-preview-85 transparent-screens-85
```

已验证两版屏幕alpha=0、完整屏幕／机框／阴影位于画布内、原背景不变、六张裁片可还原各自母图，以及其余五页与v2透明版逐像素相同。两份export-manifest.json记录实际屏幕坐标与结果。
