# OneBeat 应用市场截图 · 可编辑文字 PSD

本项目使用 HarmonyOS Sans 字体。六张成品位于 [psd/](psd/)，尺寸均为 1080 × 1920；新增共 26 个原生文字图层，文字内容、字体、倾斜变换与图层效果分别保留。原始图层、通道数据和嵌入的智能对象保留，结果另存为新文件，没有覆盖 Downloads 中的原始 PSD。

先安装 [HarmonyOS_Sans_SC_Black.ttf](fonts/HarmonyOS_Sans_SC_Black.ttf)，再打开 PSD。所有新增文字统一使用官方静态 Black 字体，实际字重为 900，PostScript 名为 `HarmonyOS_Sans_SC_Black`，并施加 9° 右倾。此处的倾斜来自文字图层变换，没有修改字体文件。字体来源及许可见 [fonts/NOTICE.md](fonts/NOTICE.md) 和原文 [fonts/LICENSE.txt](fonts/LICENSE.txt)。

在编辑器中选择名称含“编号”“主标题”“副标题”“说明”或“功能提示”的文字图层，即可修改相应文字；编号和提示的底牌是独立形状图层。第一行标题使用墨黑 `#171B1F`、纸白 `#FFF9EE` 硬阴影；第二行标题使用纸白填充、墨黑描边及青绿 `#29B5AE` 硬阴影。标题阴影偏移为右 8 px、下 9 px，模糊为 0；第二行描边宽度为 5 px。阴影和描边保留为图层效果，没有合并到文字像素中。

| 文件 | 第一行标题 | 第二行标题 | 新增文字层 |
| --- | --- | --- | ---: |
| [01.psd](psd/01.psd) | 一个人练习 | 一群人同拍 | 4 |
| [02.psd](psd/02.psd) | 扫码入队 | 一起出发 | 4 |
| [03.psd](psd/03.psd) | 角色与场景 | 随心搭配 | 5 |
| [04.psd](psd/04.psd) | 节奏听得见 | 同拍看得见 | 4 |
| [05.psd](psd/05.psd) | 把这一拍 | 留成作品 | 4 |
| [06.psd](psd/06.psd) | 每一段节奏 | 都由你来编 | 5 |

第 04 张按实际 PSD 的画面留白，将文案置于底部；第 05 张放在声波条下方。整套效果可查看 [strip.jpg](strip.jpg)，单张预览位于 [previews/](previews/)。

后续调整以 [layout.json](layout.json) 中对应 `pages` 项为生成参数入口。`x` 控制整组文字及底牌的横向位置，增大向右；`yOffset` 当前六页均为 `0`，增大使整组向下。需要单独调整时，`eyebrowY` 是编号底牌的顶部，`firstBaseline`、`secondBaseline` 和 `subtitleBaseline` 分别是两行标题与说明的文字基线，增大向下。编号文字还会在底牌位置上固定偏移 `x + 14`、`eyebrowY + 30`，相关逻辑在 [build-native-psd.cjs](build-native-psd.cjs) 的 `buildPage()` 中。

| 页码 | `x` | `eyebrowY` | `headlineStyle` | `firstBaseline` | `secondBaseline` | `subtitleBaseline` |
| --- | ---: | ---: | --- | ---: | ---: | ---: |
| 01 | 96 | 88 | `headline` | 258 | 388 | 468 |
| 02 | 724 | 1394 | `compactHeadline` | 1518 | 1602 | 1662 |
| 03 | 96 | 88 | `headline` | 258 | 388 | 468 |
| 04 | 300 | 1624 | `bottomHeadline` | 1750 | 1848 | 1905 |
| 05 | 134 | 262 | `raisedHeadline` | 390 | 490 | 550 |
| 06 | 96 | 88 | `headline` | 258 | 388 | 468 |

字号由 `styles.<headlineStyle>.fontSize` 控制：`headline` 为 108，`compactHeadline` 为 68，`bottomHeadline` 为 82，`raisedHeadline` 为 88。增大字号会扩大文字，需同时注意画布边界及原界面的留白。第 04 张说明基线已接近画布底部，向下移动的余量较小；第 02 张右侧文案的横向空间也较紧。

标题效果在 `layout.json` 的 `titleEffects` 中：`shadowX: 8` 增大使阴影向右，`shadowY: 9` 增大使阴影向下，`outlineWidth: 5` 增大使描边加粗。颜色由 `palette` 控制，右倾角度由各 `styles` 的 `slantDegrees: 9` 控制。直接在 PSD 中修改即可更新成品；修改 JSON 后需重新执行生成流程才会影响 PSD，两者不会自动同步。重新生成基于原始 PSD，会覆盖本目录中的生成结果，因此应先另存手工修改的版本。

已通过程序读回验证 26 个原生 `TySh/EngineData` 文字层的文案、字体名、字号、倾斜变换及图层效果，并核对原图层记录、通道和智能对象数据的保留情况。详情见 [build-report.json](build-report.json) 和各页的 `psd/*.preservation.json`。当前尚未完成 Photoshop 或 Photopea 中实际改字并重新保存的验收；如编辑器提示更新文字图层，可在已安装上述字体的情况下更新，并另存一份。

随附的 [outline-text.py](outline-text.py)、[build-native-psd.cjs](build-native-psd.cjs) 和 [preserve_psd.py](preserve_psd.py) 用于生成、保留原 PSD 数据和验证。`text-paths.json` 仅用于生成文字预览缓存，成品 PSD 中的新增文案仍为文字图层。

需要重新生成时，在此目录安装 `package.json` 中的 Node 依赖及 Python 的 `fontTools`、`Pillow`，确认 `layout.json.sourcePsdDirectory` 指向六份原始 PSD，再执行 `npm run build`。流程先提取原合成缓存，再生成字形缓存和原生文字层，最后保全合并到副本。
