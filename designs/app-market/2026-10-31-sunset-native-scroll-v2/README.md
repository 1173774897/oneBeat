# oneBeat · sunset 六联背景 v2

本版按手机机框的真实遮挡范围重排路边物件。8个实体各用一次：保留 bench、billboardreck、cable、cactus；重复项换成 sign、mailbox、gaslight、telescope。长椅和仙人掌放到第二张下方空地，其余物件从机框右侧、跨页空隙露出。机框、场景纵向比例和原始素材显示尺寸保持一致，无人物、应用界面或介绍文字。

植物改为12种、18株、6簇，每簇三株连续生长。原生PNG透明边缘保留，枝叶自然交叠；不再按均匀间距逐株排列。

## 使用文件

- `transparent-screens/01.png` 至 `06.png`：白色屏幕已经挖成真正透明通道的六张最终模板；`master-transparent.png` 为共享透明母图。屏幕外像素和机框几何保持一致。
- `onebeat-sunset-transparent-screens.zip`：六张透明屏幕PNG、透明母图及使用说明。`transparent-screens/checkerboard-preview.jpg` 中棋盘格仅用于展示透明度，不存在于PNG素材中。
- `sunset-native-panorama.png`：6480×1920完整背景。
- `panorama-preview.png`：2160×640背景预览。
- `background-slices/background-01.png` 至 `06.png`：六张1080×1920背景，按编号拼接。
- `phone-preview/strip.png`：套入纸白机框的六张总览。
- `phone-preview/continuous-preview.png`：无间隔套框总览；`pair.png` 为首两张共用母图。
- `phone-preview/01.png` 至 `06.png`：六张空白屏幕模板。
- `phone-preview/layers/overlay/01.png` 至 `06.png`：屏幕已挖空的模板，放在真实屏幕内容上方。
- `phone-preview/layers/screen-mask/01.png` 至 `06.png`：对应屏幕裁剪蒙版。
- `onebeat-sunset-v2.zip`：以上PNG及布局、验证记录和本说明，不含重复嵌图的大体积SVG。

## 继续调整实体

优先修改本目录 `scene-layout.json` 的 `entities[].xVp`。当前为容器左边缘的世界坐标，已经包含运行时lane偏移；增大向右、减小向左，每1vp对应3px。有效画布为0—2160vp，越界内容会裁掉；大机框仍会遮住其后方物件，应同步检查套框预览。

| 实体 | 当前 xVp | foreground | 复制素材路径 |
|---|---:|---|---|
| sign | 323 | false | `assets/scenes/sunset/entities/sign.png` |
| cactus | 365 | true | `assets/scenes/sunset/entities/cactus.png` |
| bench | 480 | true | `assets/scenes/sunset/entities/bench.png` |
| billboardreck | 547 | false | `assets/scenes/sunset/entities/billboardreck.png` |
| cable | 1031 | false | `assets/scenes/sunset/entities/cable.png` |
| mailbox | 1375 | false | `assets/scenes/sunset/entities/mailbox.png` |
| gaslight | 1738 | false | `assets/scenes/sunset/entities/gaslight.png` |
| telescope | 2079 | false | `assets/scenes/sunset/entities/telescope.png` |

`foreground` 从false改为true会切到近侧，实体下移160vp（480px），不改变尺寸；billboardreck、cable及新增四种依照应用物件池放远侧。bench从上一版远侧改为近侧，使用同一代码公式在第二张下方完整露出。

原始素材在仓库 `entry/src/main/resources/rawfile/scenes/sunset/entities/` 下同名PNG。显示尺寸由 `entry/src/main/ets/assets/AssetCatalog.ets` 的 `entityDisplaySize()` 控制，并由 `SideEntitySprite.ets` 保持原图宽高比、在容器中居中：

| 实际图像框 | 逻辑尺寸 vp | 此次3×导出 px |
|---|---:|---:|
| bench | 110×110 | 330×330 |
| billboardreck | 220×220 | 660×660 |
| cable | 275×165 | 825×495 |
| cactus、sign、mailbox、gaslight、telescope | 82.5×110 | 247.5×330 |

`SIDE_ENTITY_DISPLAY_HEIGHT=110` 增大时实体整体变大；`BILLBOARDRECK_DISPLAY_SCALE=2` 增大时只放大广告架。海报脚本直接读取这些源常量，修改它们也会影响应用，位置调整优先使用本设计配置。图像透明留白属于原生比例，不应先trim再缩放。

## 成簇调整植物

优先修改 `scene-layout.json` 的 `vegetationClusters[].xVp`，可整簇移动，增大向右、减小向左。各株的 `plants[].offsetVp` 是相对簇起点的横向偏移，增大使该株右移，拉大相邻偏移差会使植物更疏，缩小差值会更密。

| 簇 | 当前 xVp | foreground | 植物编号及当前 offsetVp |
|---|---:|---|---|
| coastal-leaves | -8 | true | 04:0，08:28，07:56 |
| sunny-flowers | 630 | true | 11:0，10:28，05:57 |
| wire-side-shrubs | 1020 | true | 01:0，03:29，12:57 |
| mailbox-grasses | 1368 | false | 02:0，04:26，06:52 |
| lamp-side-foliage | 1740 | true | 09:0，07:26，10:52 |
| lookout-shrubs | 2084 | false | 12:0，01:26，08:52 |

素材复制在 `assets/vegetation/plant_01.png` 至 `plant_12.png`，原图来自 `entry/src/main/resources/rawfile/vegetation/`。全部原图350×350，图像显示58×58vp（174×174px），在78×58vp容器内居中。`WalkScene.ets` 的 `VEGETATION_DISPLAY_HEIGHT=58` 增大会放大植物；`VEGETATION_BG_PATH_OFFSET_PX=-114`、`VEGETATION_FG_PATH_OFFSET_PX=44` 增大会使对应侧下移。簇的foreground切为true会下移158vp（474px）。最左和最右簇有意部分裁边。

## 其他布局与约束

`pixelsPerVp=3` 是整张导出倍率，增大会同时放大输出分辨率和所有元素，不用于独立放大某个物件。逻辑单屏360×640vp，横向六屏。道路、海天、太阳与上一版一致；太阳 `xVp=680`、`yRatio=0.24`、`widthRatio=0.30`，分别增大时向右、向下、放大。

机框源在 `phone-frames.json`：首两台 `(x,y,w,h,rotation)` 分别为 `(320,780,830,1750,-10)`、`(1080,-420,830,1750,-10)`；第三至六张局部位置为 `(134,580,812,1760)`、角度依次 `-2,2,0,-1`。增大x/y向右/下，增大宽高放大，角度增大顺时针。边框inset=24、radius=100、阴影x=18/y=20。首两张共享渲染后再裁切，跨页边缘保持连续。

## 重生成与验证

在本目录运行：

```sh
node compose.cjs
node phone-preview.cjs
node verify-visibility.cjs
```

前两步已验证8种实体无重复、12种植物共18株、原始素材字节一致；背景及套框模板的六张裁片分别与各自母图逐像素一致，屏幕overlay挖空正确。`visibility-report.json` 进一步记录机框及植物遮挡后的实体可见比例。广告架和电缆架以跨页局部露出的方式呈现，比例和高度没有为避让屏幕而改变。

仅新增设计目录，未改应用运行时文件。上一版保留在相邻的 `2026-10-31-sunset-native-scroll/`。
