# oneBeat 介绍截图 · 奶油底与自然倚靠

五张连续系列，工作尺寸 1080 × 1920。用统一的奶油底、一块大色面和细边框手机，保留 oneBeat 的角色线稿和配色。手机是展示主体，屏幕和介绍文字留空。

本轮动作调整的重点是明确支撑：手机底部落地，侧边角色单手扶边、另一只手自然放在身侧或口袋；云行者改为肘部倚在手机顶边、手掌托腮。人物与手机的接触关系直接画在完整原稿中，避免后期分别移动时出现悬空。

| 编号 | 主题 | 角色 |
| --- | --- | --- |
| 01 | 珊瑚色 | Lilroll |
| 02 | 薄荷色 | Wave |
| 03 | 丁香紫 | 云行者 |
| 04 | 杏黄色 | 条纹步客 |
| 05 | 墨蓝色 | 台灯漫游者 |

## 直接使用

- `templates/01-template.png` 至 `05-template.png`：1080 × 1920 的空屏底板。
- `editor.html`：所有资源已内嵌的离线换屏工具。双击后用浏览器打开，选择底板和本地截图，即可导出 PNG。
- `layers/01-overlay.png` 至 `05-overlay.png`：只有真实可见屏幕区域透明的覆盖层，机框、人物和前景手部均保留。
- `layers/0x-screen-mask.png`：可替换屏幕的独立蒙版，白色/不透明表示截图可显示的区域。
- `source/`：内嵌原画的 SVG 组装源文件。
- `artwork/01.png` 至 `05.png`：生成后的完整原画。
- `previews/contact-sheet.png`：五张总览；`previews/editor-qa.json`：离线换屏验证结果。

在换屏工具中，“完整显示”保持截图比例、必要时留暖白边；“填满屏幕”保持截图比例并裁切。换屏只作用于可见屏幕蒙版，原画中的手、肘部和机框不会被截图覆盖。

图像编辑软件使用方法：按 `config.json` 中对应的 `screen.bounds` 缩放、摆放真实截图，叠上同编号透明覆盖层；需要精确圆角时使用屏幕蒙版裁切。

## 再调位置和比例

优先改 `config.json` 的 `artworkTransform`，当前为 `x=0、y=0、width=1080、height=1920`。增大 `x` 向右，增大 `y` 向下。同步放大 `width/height` 会放大整张人物与手机的组合；比例应保持 1080:1920，避免拉伸。每张 `items[].artworkTransform` 可以覆盖全局值，单独调整一张。

`build.cjs` 的 `resolveGeometry()` 与编辑器使用同一个变换，手机、人物、前景手部、屏幕蒙版及截图会一起移动。画布为 1080 × 1920，超出画布的部分会裁切，因此放大时需要同时调节 x/y。

原画路径是本目录的 `artwork/01.png`…`05.png`，由 `config.json` 中 `items[].artwork` 指定；运行时位置和缩放由上述 `artworkTransform` 控制。人物动作与握姿已画进原画，修改关节、手指或人物与手机的相对位置需要重新绘制对应原画，并重新核对屏幕蒙版。不能只移动原画中的手而保留旧蒙版。

`items[].screen.bounds.{x,y,width,height}` 是截图映射到屏幕的区域；x/y 增大分别将截图映射区向右/下移动，width/height 增大扩大映射区。这是次要校准点，受 `items[].mask` 的实际屏幕轮廓约束，不能用它移动整部手机。

当前五张的屏幕映射坐标（像素）如下。人物和机框本身已画在原画中；本表只用于后续换屏。

| 编号 | x | y | width | height |
| --- | --- | --- | --- | --- |
| 01 | 367 | 305 | 612 | 1390 |
| 02 | 133 | 315 | 655 | 1430 |
| 03 | 199 | 593 | 683 | 1273 |
| 04 | 82 | 314 | 664 | 1443 |
| 05 | 318 | 309 | 662 | 1434 |

## 生成和复核

原画由内置 `image_gen` 重绘。最终修正提示词保存在 `prompts/02-wave-correction.json`、`prompts/corrections.json` 和 `prompts/01-visible-elbow.json`。先前版本和未采用的草稿没有覆盖本轮交付。

`prepare-screen-masks.cjs` 只分析与屏幕中心连通的浅色区域，生成换屏蒙版和红色选区检查图；它不重画人物。`build.cjs` 负责渲染底板、透明覆盖层和离线编辑器。蒙版需在每次重画后目视复核，尤其是浅色手部附近。

```sh
node designs/app-market/2026-10-31-natural-pose-v4/prepare-screen-masks.cjs
node designs/app-market/2026-10-31-natural-pose-v4/build.cjs
node designs/app-market/2026-10-31-natural-pose-v4/verify-editor.cjs
```

本机使用已安装的 sharp / Playwright 与 Chrome。构建检查透明屏幕孔和未选中区域的透明度；浏览器检查五张底板的本地上传、填充、重置、导出尺寸，以及蒙版以外像素保持不变。
