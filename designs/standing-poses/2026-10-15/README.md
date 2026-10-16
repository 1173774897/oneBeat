# 人物站立姿态

2026-10-15 使用内置 `image_gen`，逐张参照各人物对应的 `walk/.../frame_01.png` 生成。共 15 张透明 RGBA PNG（1254 × 1254），未裁切、重绘或重新缩放生成结果。保留每套配色及其墨线、排线和阴影。站姿采用松膝、偏重心、插袋或自然垂手；思古特保留滑板，单手扶着竖立的滑板。

## 资源和提示词

运行时目录：`entry/src/main/resources/rawfile/stand/`（相对于项目根目录）。

- 固定人物：`cloud`、`mismatch`、`teapot`、`wave`、`scooter`、`lilroll`、`lamp` 各自目录中的 `frame_01.png`。
- 随机人物：`braids`、`boonie`、`curly`、`buzz` 各自 `palette_1/frame_01.png` 和 `palette_2/frame_01.png`。
- [固定人物生成提示词](generate-fixed-prompts.json)
- [随机人物提示词 A](generate_random_a-prompts.json)
- [随机人物提示词 B](generate_random_b-prompts.json)
- [全部素材清单、来源哈希和透明度检查](asset-manifest.json)

Buzz 两套配色后续已重新生成，双手均自然垂放、露在兜外，保留原站姿的画幅和配色；本次提示词与检查记录：[配色 1](buzz-no-pockets-palette_1.json)、[配色 2](buzz-no-pockets-palette_2.json)。这两份记录取代上方原始提示词中 Buzz 的插兜姿势设定。

原有 `walk` 目录未改动。每张图已检查人物身份、配色、放松站姿和透明背景。

## 播放规则

`WalkScene.updateWalkFrame()` 依据 `MetronomeEngine.getVisualSnapshot()` 切换：开始前、等待共享开始时刻、预备拍、暂停和会话快照缺失时站立；正式节拍开始后继续原来的 `walk` 帧映射。站姿和行走图层保持挂载，通过可见性切换，避免在首拍边界才创建行走图片节点。

## 再调整大小和位置

优先调整 `entry/src/main/ets/scene/StandingWalkerSprite.ets` 的 `spriteSize()` 及缩放常量：

| 人物 | 当前倍率 | 实际图片框尺寸 |
| --- | --- | --- |
| 云、茶壶、台灯 | `STANDING_SMALL_SCALE = 0.7` | 98 vp |
| 波浪 | `STANDING_WAVE_SCALE = 0.85` | 119 vp |
| 随机人物 | `STANDING_RANDOM_SCALE = 0.9` | 126 vp |
| 思古特、轮滑、mismatch | `1` | 140 vp |

`STANDING_LAYOUT_SIZE = 140`，沿用行走图层的布局框。增大倍率会放大人物，并向上延伸；减小会缩小、顶部向下。默认 `Alignment.Bottom`，底部锚点保持；`mismatch` 为 `Alignment.Center`，从中心放缩。外层 `WalkerSprite` 的 `BASE_WALKER_SIZE = 140` 决定预留空间，大幅增大时需同步核对人物及昵称间距。PNG 本身的透明留白也会影响可见脚底位置。

## 验证

```sh
/Applications/DevEco-Studio.app/Contents/tools/node/bin/node scripts/tests/walker-standing-playback.cjs /Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js
```

已通过 15 套资源路径、PNG 透明通道、开始/预备拍/暂停/恢复时刻、正式节拍原帧序及图层保留挂载的回归检查，ArkTS 编译及签名 HAP 打包通过。未进行真机画面验证。

额外运行的两项旧测试存在既有失败，已将全部仓库文件读取替换成 `git show HEAD:<path>` 后复现相同结果，未改动测试或原素材：

- `walker-stand-order.cjs:11`：测试提取的 `walkerStandLeftMinXPx()` 已不在原有 `WalkScene` 中，提取结果为空。
- `random-character-catalog.cjs:78`：原有 braids 配色 1 的走路首帧与头像 SHA256 不同，未满足该测试的图片字节相同断言。
