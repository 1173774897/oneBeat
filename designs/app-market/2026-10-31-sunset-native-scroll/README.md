# oneBeat · sunset 六联原生背景

本版为纯场景：不放人物、应用界面和介绍文案。使用项目现有 sunset、entity 和 vegetation PNG，保留原画、透明留白、宽高比及代码显示比例，没有重新绘制或改色。应用运行时代码未改。

## 文件

- `sunset-native-panorama.png`：6480×1920 母图。
- `panorama-preview.png`：2160×640 连续预览。
- `background-slices/background-01.png` 至 `background-06.png`：六张 1080×1920 等宽背景，按编号排列。
- `onebeat-sunset-backgrounds.zip`：母图、预览、六份背景和本说明。
- `phone-preview/strip.png`：套入既有纸白机框的六张预览；`continuous-preview.png` 为无间隔拼接。
- `phone-preview/01.png` 至 `06.png`：空屏机框预览；`layers/` 提供挖空屏幕的 overlay 与屏幕 mask。屏幕内容尚未放入。
- `scene-layout.json` / `compose.cjs`：背景布局和可重复生成脚本。
- `phone-frames.json` / `phone-preview.cjs`：机框布局和生成脚本。
- `sunset-native-panorama.svg`：嵌入原始 PNG 的场景排版文件。
- `render-report.json`：原图来源、SHA256、透明边界及全部几何参数。

## 场景几何与代码依据

选用单页逻辑视口 360×640vp，按 `pixelsPerVp=3` 导出；世界横向延伸为六页（2160vp）。这对应原生 WalkScene 的响应式布局，并非把完整六联图当成一个超宽视口重新计算物件大小。

尺寸依据 `entry/src/main/ets/assets/AssetCatalog.ets` 的 `entityDisplaySize()`、`entry/src/main/ets/scene/SideEntitySprite.ets` 的高度与 Contain；植被依据 `WalkScene.ets` 和 `VegetationSprite.ets`。原 PNG 的透明边缘保留，不能 trim 后再缩放。

| 物件 | 原始 PNG | 代码容器 vp | 实际图片框 vp | 导出图片框 px |
|---|---|---:|---:|---:|
| bench | `entry/src/main/resources/rawfile/scenes/sunset/entities/bench.png`（400×400） | 120×110 | 110×110 | 330×330 |
| billboardreck | `entry/src/main/resources/rawfile/scenes/sunset/entities/billboardreck.png`（400×400） | 240×220 | 220×220 | 660×660 |
| cable | `entry/src/main/resources/rawfile/scenes/sunset/entities/cable.png`（1000×600） | 275×165 | 275×165 | 825×495 |
| cactus | `entry/src/main/resources/rawfile/scenes/sunset/entities/cactus.png`（300×400） | 120×110 | 82.5×110 | 247.5×330 |
| 植被 | `entry/src/main/resources/rawfile/vegetation/plant_{01,02,04,07,12}.png`（350×350） | 78×58 | 58×58 | 174×174 |

天空先按原生单页 Cover 取景，再横向展开，保留纵向色阶；太阳只放一轮。云、海面、泥地同向平铺，道路交替镜像，每个 tile 为 720vp / 2160px。环境高度与纵向位置保留原生比例。

## 再调整位置

优先改本目录的 `scene-layout.json`，避免为宣传图改动应用运行时位置。`entities[].xVp` 与 `vegetation[].xVp` 均为完成运行时 lane 偏移后的容器左边缘：增大向右，减小向左，1vp=3px。`foreground` 从 false 改 true 会切到近侧；实体下移 160vp（480px），植被下移 158vp（474px）。代码不额外对近侧做放大。

| 实体 | 当前 xVp | 当前 foreground |
|---|---:|---|
| bench-01 | 64 | false |
| cactus-01 | 244 | true |
| billboardreck-01 | 414 | false |
| cable-01 | 762 | false |
| bench-02 | 1115 | true |
| cactus-02 | 1292 | false |
| billboardreck-02 | 1487 | false |
| cable-02 | 1834 | false |

植被按配置顺序当前 xVp 为 `8, 194, 312, 650, 704, 1018, 1068, 1220, 1368, 1748, 1790, 1940, 2080, 2124`；增减方向相同。最后一株延伸至右画布外，保留连续街景的裁边感。

太阳素材为 `entry/src/main/resources/rawfile/scenes/sunset/sunset_sun.png`，由 `scene-layout.json` 的 `sun.xVp=680`、`sun.yRatio=0.24`、`sun.widthRatio=0.30` 控制；分别增大时向右、向下、放大，减小时相反。尺寸以单页视口宽 360vp 为基准。

缩放应优先保留应用比例：`AssetCatalog.ets` 当前 `SIDE_ENTITY_DISPLAY_HEIGHT=110`，`BILLBOARDRECK_DISPLAY_SCALE=2`；增大前者放大全部实体，增大后者只放大破损广告架。`WalkScene.ets` 当前 `VEGETATION_DISPLAY_HEIGHT=58`，增大放大植被。宣传图脚本每次读取这些源常量，修改它们也会影响应用；仅做海报时建议在脚本派生独立覆盖值。`pixelsPerVp=3` 是整张导出倍率，增大会同时放大尺寸及输出分辨率，不用于单独改变某个物件。

纵向约束来自 `WalkScene.ets`：`ROAD_BAND_HEIGHT_RATIO=0.46`，`ROAD_PATH_CENTER_RATIO=0.66`，`ENTITY_BG_LIFT_PX=115`，`ENTITY_FG_DROP_PX=45`，`VEGETATION_BG_PATH_OFFSET_PX=-114`，`VEGETATION_FG_PATH_OFFSET_PX=44`。实体远侧底为 1274.712px、近侧底为 1754.712px；增大 BG_LIFT 使远侧实体上移，增大 FG_DROP 使近侧下移；增大植被 PATH_OFFSET 使对应植被下移。画布边界会裁去超出部分。

## 机框调整及后续放屏幕

机框优先改 `phone-frames.json`。首两张共享同一母画布：A 当前 `(x=320,y=780,w=830,h=1750,rotation=-10)`，B 当前 `(1080,-420,830,1750,-10)`。第三至六张的局部位置均为 `(134,580,812,1760)`，角度依次 `-2,2,0,-1`。增大 x 向右、y 向下、width/height 放大；正角度顺时针，负角度逆时针。首两张要作为整体渲染再裁切，避免跨页边缘出现偏差。

`frame.inset=24`：增大缩小屏幕、加厚机框；`radius=100`：增大使外角更圆。阴影 `x=18,y=20`：增大分别向右、向下。白屏由同一圆角和旋转几何产生，可用 `phone-preview/layers/screen-mask/01.png` 至 `06.png` 裁剪真实截图，再把 `phone-preview/layers/overlay/` 下对应编号 PNG 盖上。第三至六张机框底部有意超出画布，屏幕最终可用区域受 1080×1920 裁切限制。

## 生成及验证

在本目录运行：

```sh
node compose.cjs
node phone-preview.cjs
```

脚本使用当前机器已安装的 Sharp；背景脚本还读取本仓库原始资源与 ArkTS 常量。没有生成式模型步骤。

已验证所有 15 份使用素材与项目原 PNG 字节相等；8 个实体、14 株植被符合代码几何；六份背景重新拼接与母图逐像素一致。机框预览独立检查整幅及首两张的裁片重组和屏幕挖空。未运行应用测试，因为只新增设计文件，未修改应用行为。
