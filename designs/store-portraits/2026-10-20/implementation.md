# 收藏小铺专用角色照片与播放线修复（2026-10-20）

## 素材
使用内置 imagegen，根据现有角色原设单独生成，保留设计、服装和配色，仅更换静态姿势。三个文件均为 1024×1536 RGBA，保留生成透明通道。没有覆盖多人练习插画、角色动画或走路帧。

- Wave：`entry/src/main/resources/rawfile/comic/store/wave.png`，双手扶背带。
- 条纹步客：`entry/src/main/resources/rawfile/comic/store/mismatch.png`，抱臂站姿。
- 台灯漫游者：`entry/src/main/resources/rawfile/comic/store/lamp.png`，站定扶灯罩。

`StorePage.ets` 的 `StoreCharacter.photoAsset` 只供商店角色卡片使用。“角色”和“我的”共用同一卡片，角色的购买、使用和动画键仍为原 `asset`。

### 原始提示词（内置模式，transparent_background=true）
#### wave
参考图：`entry/src/main/resources/rawfile/comic/poses/wave.png`

```text
Use case: illustration-story. Asset type: a new transparent full-body character catalog portrait for the oneBeat comic collectible shop.
Input image 1 is the exact character identity and illustration-style reference. Keep Wave's original character design unchanged: short blunt purple bob with pink color block, large dark eyes, peach skin, cyan sleeveless undershirt, bright yellow short overalls with two silver fasteners and chest pocket, multicolored high-top canvas sneakers.
Create a NEW posed portrait, distinct from the reference's raised waving hand: Wave stands still in a relaxed confident stance, both feet planted, holding both overall straps near her chest, small friendly smile, face in three-quarter view. Keep the same proportions, recognizable face, clothing shapes and colors.
Style: matching crisp thick black comic ink outlines, restrained pen hatching, flat cel colors. Full body including shoes, centered, portrait canvas, occupy about 90% of image height with clean margin. Real transparent background, clean cutout edges. No scene, text, border, glow, ground shadow, props, walking pose, waving gesture or redesign. This is character art for a shop card, not a UI mockup.
```

#### mismatch
参考图：`entry/src/main/resources/rawfile/comic/poses/mismatch.png`

```text
Use case: illustration-story. Asset type: a new transparent full-body character catalog portrait for the oneBeat comic collectible shop.
Input image 1 is the exact character identity and illustration-style reference. Keep the original character design unchanged: cyan-blue skin, teal rib-knit beanie, dark green hair fringe, cool narrow flat eyes, black and cream horizontal striped long sleeve shirt, asymmetrical orange and purple elbow pads, cuffed blue denim shorts, vivid red high-top canvas sneakers.
Create a NEW posed portrait distinct from the reference's raised waving hand: the character stands still facing three-quarter toward camera, arms loosely crossed at chest with the colored elbow pads still visible, weight on one leg, both red shoes on the ground; calm mildly mischievous expression. Keep the original proportions, face and costume details.
Style: matching crisp thick black comic ink outlines, restrained pen hatching, flat cel colors. Full body including shoes, centered, portrait canvas, occupy about 90% image height with clean margin. Real transparent background, clean cutout edges. No scene, text, border, glow, ground shadow, new props, walking pose, waving gesture or redesign. This is character art for a shop card, not a UI mockup.
```

#### lamp
参考图：`entry/src/main/resources/rawfile/comic/poses/lamp.png`

```text
Use case: illustration-story. Asset type: a new transparent full-body character catalog portrait for the oneBeat comic collectible shop.
Input image 1 is the exact character identity and illustration-style reference. Keep 台灯漫游者's original design unchanged: huge warm yellow-orange conical lampshade head, simple cream round face partly hidden under its rim with sleepy oval eyes, narrow brown segmented lamp neck, sky-blue pajama shirt with cream piping and lilac buttons, matching blue and cream striped cropped pajama pants, lilac slippers with cream pompoms, brown electrical cord tail ending in the same two-prong plug.
Create a NEW stationary posed portrait; do NOT reuse the walking-frame pose: character stands relaxed front three-quarter, both feet together flat on ground, one hand gently holds the lower lampshade rim and other hand tucked at the pajama pocket; sleepy friendly expression. Cord curves gently beside body, plug visible. Preserve face, costume, shape language and proportions.
Style: matching crisp black comic ink outlines, restrained pen hatching, flat cel colors. Full body including lampshade and slippers centered, portrait canvas, occupy about 90% height with clean margins. Real transparent background and clean cutout edges. No scene, text, border, glow, ground shadow, extra props, stride, walking or redesign. This is character art for a shop card, not a UI mockup.
```

## 可调位置
- 小铺卡片：`StorePage.ets / characterCard()`，图片 width/height 均为 `96%`，`ImageFit.Contain`，父 Stack 高 `150vp` 并底部居中。增加百分比放大，减小缩小；高度受父容器裁切约束。三个新图均用此布局。
- 口令兑换：同文件 `redemptionArtworkX()` 按实测插画区宽度，扣掉左侧文字区域（`max(168+8, 宽度×0.46)`）后居中；`REDEMPTION_CHARACTER_X_OFFSET=0`，增加向右，减少向左。插画 `comic/poses/mismatch-ticket.png`，保持 `160×240vp`，`REDEMPTION_CHARACTER_TOP=14`（增大下移）。仍保留镜像。
- 播放线：`DrumMachinePage.ets`，宽 `DRUM_EDITOR_PLAYHEAD_WIDTH=2vp`，X 仍由播放的拍位置投影到每格 `DRUM_EDITOR_CELL_WIDTH=22vp`；Y 为表头高度 `DRUM_EDITOR_HEADER_HEIGHT=56vp`。增大线宽加粗，增大表头高度下移。Z=10，不拦截格子点击。

## 播放线根因
当前 ArkUI 编译产物丢弃组件内手写的 getter/setter，`editorPlayheadStep` 读取为 undefined；显示条件为 false、横坐标无法正常计算。改成普通投影方法与赋值方法后，编译产物保留。仍由原 `editorPlayheadBeats` @State 和 `getVisualSnapshot().mainPlayheadMs` 驱动，不变更音频、节奏排程或组队同步。

## 验证
- Hvigor assembleHap：通过。检查实际 ArkUI 编译产物，投影方法和赋值方法均保留，显示条件调用投影方法。
- drum-editor-preview、drum-preview-live-update、metronome-drum-preview-seek、drum-preview-session-ownership、store-user-feedback、redemption-hero-layout：通过。
- Pura X 与 Pura 80 Pro 均安装此版本，核对兑换页插画尺寸和居中；Pura 80 Pro 核对三张新小铺卡片。
- Pura X 实际试听：播放线两帧原生 bounds 的 X 从 409 移至 1225，宽度均为 6px（2vp），均 visible=true 且 HitTestMode.None；停止后仍可见。
- Pura X 点击第一个第3格数字：播放线 X=354px；切到6连音后保持同一拍位置，X=420px。关闭编辑页未应用测试改动，试听已停止。
- 真机截图保存在同目录 device-checks/。仅为此 UI 修复检查了节奏时间线回归，没有更改音频和组队同步代码。

