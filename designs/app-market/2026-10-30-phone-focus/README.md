# oneBeat 应用市场截图底板 · 手机主视觉

五张 1080 × 1920 的竖版底板，先完成背景、手机框和少量 oneBeat 原有角色。屏幕保持空白；介绍文字暂未制作。

## 视觉方案

| 编号 | 主题 | 后续适合展示的内容 |
| --- | --- | --- |
| 01 | 米白纸底、珊瑚色节奏弧线 | 产品开场、主要练习页 |
| 02 | 薄荷绿、并行曲线 | 组队与同步 |
| 03 | 浅紫、唱片弧线 | 鼓机与编排 |
| 04 | 暖杏色、夕阳海边步道 | 角色行进与场景 |
| 05 | 墨黑、青绿与浅紫印刷色带 | 录制与作品 |

这是连续的一套方案，不是五种互不相关的风格。所有主手机保持正面、无透视，便于把真实截图直接放入。背景采用纸感印刷纹理，与应用现有漫画笔触呼应；角色直接引用项目原图，置于手机后方，不遮挡屏幕。

研究的实际上架案例与官方截图指南见 [research.md](research.md)。手机框为无品牌展示框。画布尺寸是本轮设计工作尺寸，上架时可按目标渠道要求另行导出。

## 使用文件

- `previews/full-contact.png`：五张大机身版本的总览。
- `previews/fit-contact.png`：五张完整机身版本的总览。
- `templates/full/01-template.png` 至 `05-template.png`：大机身底板，底部自然延伸到画面外。
- `templates/fit/01-template.png` 至 `05-template.png`：完整机身底板。
- `templates/` 中同名 SVG：内嵌图片的可编辑源文件。
- `layers/full/`、`layers/fit/`：独立手机框、屏幕蒙版、角色、背景和屏幕透明的完整覆盖层，均同时提供 SVG 与 PNG。
- `backgrounds/01.png` 至 `05.png`：生成后的原始背景。
- `assets/`：模板使用的原有角色 PNG 副本。
- `editor.html`：离线换屏工具，双击后用浏览器打开。每张模板可分别选择截图，切换完整显示/填满屏幕，导出 PNG。资源已内嵌，不需要本地服务。

`onebeat-phone-focus-kit.zip` 包含主要 PNG 底板、透明覆盖层、手机框/蒙版、原始背景、角色和可重建的源文件。工作目录另外保留了全部独立 SVG 与分层 PNG；解压包后也可以运行 `build.cjs` 重新生成它们。

若使用图像编辑软件，将真实截图放在最下面，上面叠放对应的 `layers/.../0x-overlay.png`，屏幕孔会透出截图；也可以分别导入背景、截图、手机框和角色。屏幕蒙版用于裁切真实截图的圆角区域。

换屏工具默认“完整显示”，保留原图宽高比。由于不同设备截屏比例不同，可能在空余处出现暖白留边；选择“填满屏幕”会等比裁切。大机身版的屏幕下部会超出画布，需要展示完整页面时选择“完整机身”。

## 再次调整位置与尺寸

优先修改唯一布局源 `config.json`，然后执行 `build.cjs` 重新生成模板、图层与离线编辑器。不要单独修改导出 PNG 的位置。

| 配置 | 当前值 | 增加/减小的效果 |
| --- | --- | --- |
| `modes.full.phone.x` | 140 px | 增加向右，减小向左 |
| `modes.full.phone.y` | 410 px | 增加向下、顶部留白变大、底部裁切更多；减小向上 |
| `modes.full.phone.width` | 800 px | 增加手机和屏幕同时变大、底部裁切更多；减小缩小 |
| `modes.full.phone.inset` | 24 px | 增加边框变厚、可用屏幕变窄；减小边框变薄 |
| `modes.full.phone.screenRadius` | 68 px | 增加屏幕圆角更大；减小更方正 |
| `modes.fit.phone` | x=195、y=320、width=690、inset=22、screenRadius=60 | 同上；这是完整机身版本的独立布局 |
| `screenRatio` | 1276 : 2848 | 屏幕高度由宽度和此比例派生；增大 height 会使手机变高，增大 width 会使手机变矮 |
| `items[].characters[].full/fit` | 每个角色分别有 x、y、width | x 增加向右，y 增加向下，width 增加放大；角色始终在手机后方 |
| `frame.sideKeys` | outset=4.5、width=6.5、volumeTop=230、volumeHeight=92、volumeGap=26、powerTop=300、powerHeight=142 | outset 增加向机身外突出；Top 增加向下，Height 增加拉长；按 phone.width/800 缩放 |
| `frame.earpiece` | width=74、height=2.8、top=13 | width 增加向两边延长；top 增加向下，受屏幕上缘限制 |

改变手机宽度后，如需继续居中，将 x 改为 `(1080 - width) / 2`。屏幕高度、机身高度和蒙版由 `build.cjs` 的 `layout()` 自动派生；可用范围还受到 1080 × 1920 画布裁切的限制。

背景素材路径为 `backgrounds/01.png`…`05.png`，由 `config.json` 的 `items[].background` 指定；运行时在 `build.cjs` 的 `background()` 中以 x=0、y=0、width=1080、height=1920 等比填充画布。编辑器同步采用相同的 cover 规则。若要改变背景图形自身位置，优先重新生成对应背景；更改画布填充范围可能露出底色。

角色原始素材位于 `entry/src/main/resources/rawfile/comic/poses/`，模板使用的副本位于本目录的 `assets/`。运行时位置和缩放由 `config.json` 的 `items[].characters[].full/fit.{x,y,width}` 控制。

| 模板与素材 | 大机身 x/y/width | 完整机身 x/y/width |
| --- | --- | --- |
| 01 / `assets/mismatch.png` | -110 / 1210 / 340 | -50 / 1220 / 325 |
| 01 / `assets/wave.png` | 855 / 1245 / 340 | 805 / 1260 / 325 |
| 02 / `assets/cloud.png` | -125 / 1250 / 345 | -70 / 1320 / 330 |
| 02 / `assets/teapot.png` | 870 / 1360 / 320 | 810 / 1350 / 315 |
| 03 / `assets/lilroll.png` | 855 / 1290 / 345 | 800 / 1310 / 330 |
| 04 / `assets/scooter.png` | -125 / 1350 / 360 | -65 / 1360 / 345 |
| 05 / `assets/lamp.png` | 850 / 1210 / 355 | 805 / 1230 / 335 |

## 生成与验证

背景由内置 `image_gen` 生成，完整提示词和参考图路径保存在 [prompts/backgrounds.json](prompts/backgrounds.json)。手机框、蒙版和布局使用确定性的 SVG，便于后续精准换屏。

```sh
node designs/app-market/2026-10-30-phone-focus/build.cjs
```

构建使用本机已有的 `sharp`；优先查找当前 Node 依赖，随后使用本机 Codex 捆绑版本。`build-report.json` 记录最终屏幕和机身坐标，以及屏幕孔透明性检查结果。交付前另外检查离线打开、上传截图、切换版式和 PNG 导出。
