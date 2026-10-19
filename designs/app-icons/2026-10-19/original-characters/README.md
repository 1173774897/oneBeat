# 原角色素材图标提案

本版直接组合项目内的原 PNG，没有生成或重绘角色。脸型、表情、服装、颜色、动作保留原样；只做等比缩放、位置调整和正方形画面取景。

成品：`08-11-original-characters-board.png`，2200×2460；四个独立图标均为 900×900。

| 方案 | 项目原素材（相对 `entry/src/main/resources/rawfile/comic/`） | 图标内 x / y / width |
|---|---|---|
| 08 台灯 | `avatars/lamp.png` | 10 / 80 / 880 |
| 09 云行者打鼓 | `poses/cloud.png` | 40 / 18 / 820 |
| 10 茶壶太太敲手鼓 | `poses/teapot.png` | 23 / 12 / 854 |
| 11 同频伙伴 | `avatars/mismatch.png`；`avatars/wave.png` | -36 / 175 / 780；285 / 270 / 670 |

排版源文件为 `render-board.swift`。首选修改每个 `Placement` 的 `x`、`y`、`width`：x 增大右移，y 增大下移，width 增大等比放大；高度始终按原图比例计算。图标窗口由 `tileSize=900` 限制，超出的肩部、腿部会被自然取景裁切，不修改素材文件。背景圆由各方案 `circleRect` 控制。

纸面四格左上角分别为 `positions=[(140,320),(1160,320),(140,1360),(1160,1360)]`；增大 x / y 分别右移 / 下移。画纸尺寸由 `boardWidth=2200`、`boardHeight=2460` 控制。

在项目根目录重新出图：

```sh
swift -module-cache-path /private/tmp/onebeat-icon-swift-cache designs/app-icons/2026-10-19/original-characters/render-board.swift
```
