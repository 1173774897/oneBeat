# 录制视频中的品牌图位置（2026-10-21）

生成方式：内置 imagegen，以真实成片画面和项目原始品牌图作参考。最终三个方案均为 990×1589，保留麦克风声波和停止录制控件。仅作为位置设计方案，待选定后接入场景 UI。

## 方案
- A `A-top-right.png`：右上角轻量角标。品牌位于天空留白区，声波完整保留，人物活动区留白最大。
- B `B-waveform-integrated.png`：品牌与声波一体。左侧品牌约占声波条宽 22%，右侧显示 MIC 标签和实时声波，推荐此方案。
- C `C-bottom-left-sticker.png`：左下角漫画贴标。品牌有奶油白贴纸描边，视觉存在感最强；使用时需按底部停止控件和前景植物做避让。

原始品牌素材：`entry/src/main/resources/rawfile/comic/brand/onebeat_wordmark.png`。真实场景参考来自 `/private/tmp/onebeat-recording-debug/attached-frame.png`。

## 提示词
### A-top-right
```text
Use case: ui-mockup / compositing.
Create a polished design preview of brand placement INSIDE recorded video footage of the 同拍 / ONEBEAT app.
Input image 1 is the exact unbranded recorded-video frame and EDIT TARGET: preserve the same full portrait scene, sunset sky, sun/clouds, teal sea, orange coastal path, original small walking character, existing measured waveform, label and small stop control. No top/bottom app panels, phone frame, status bar, modal or new controls. Match its original composition and artwork closely, don't redesign the scene or character.
Input image 2 is the EXACT brand graphic to insert, not merely a style reference. Preserve its 同拍 / ONEBEAT letterforms, coral Chinese word, teal English word and black dimensional ink shadow. Keep its proportions and colors. It should be recognizable but not dominate the recorded content.
Deliver one finished full-size portrait video-frame mockup, opaque background, about 1024px wide. No design annotation, plan title, arrows, measurements or explanatory captions in the frame. The original waveform remains near 27% from the top and the stop pill stays centered near the bottom. Avoid covering the walking character, waveform signal or stop control.
Option A: Add a small freely floating brand graphic in the UPPER RIGHT part of the open sky, width about 20% of the whole frame, right inset about 5%, top inset about 6%. No backing plaque, no huge glow. The original asset's black ink thickness provides contrast, with a very subtle ivory edge only if necessary. Leave the existing waveform bar and all its labels exactly unchanged. Keep generous clear space between logo and waveform. This is a restrained persistent corner brand.
```

### B-waveform-integrated
```text
Use case: ui-mockup / compositing.
Create a polished design preview of brand placement INSIDE recorded video footage of the 同拍 / ONEBEAT app.
Input image 1 is the exact unbranded recorded-video frame and EDIT TARGET: preserve the same full portrait scene, sunset sky, sun/clouds, teal sea, orange coastal path, original small walking character, existing measured waveform, label and small stop control. No top/bottom app panels, phone frame, status bar, modal or new controls. Match its original composition and artwork closely, don't redesign the scene or character.
Input image 2 is the EXACT brand graphic to insert, not merely a style reference. Preserve its 同拍 / ONEBEAT letterforms, coral Chinese word, teal English word and black dimensional ink shadow. Keep its proportions and colors. It should be recognizable but not dominate the recorded content.
Deliver one finished full-size portrait video-frame mockup, opaque background, about 1024px wide. No design annotation, plan title, arrows, measurements or explanatory captions in the frame. The original waveform remains near 27% from the top and the stop pill stays centered near the bottom. Avoid covering the walking character, waveform signal or stop control.
Option B: Integrate the brand graphic into the LEFT END of the existing translucent dark waveform bar, occupying about 22% of the bar's width. The logo is contained fully inside that same horizontal panel, not a separate floating object. Add a subtle slim ivory divider after the logo. To its right retain a clearly readable “MIC · 周围的声音” caption with live vertical white/teal waveform bars beneath it. Redistribute the waveform to use the remaining 74% of the bar width; the bar's original position, overall size and corner radius remain unchanged. Remove the small “ONEBEAT / REC” type label from this bar so the inserted original brand asset is the sole brand treatment. No logo elsewhere.
```

### C-bottom-left-sticker
```text
Use case: ui-mockup / compositing.
Create a polished design preview of brand placement INSIDE recorded video footage of the 同拍 / ONEBEAT app.
Input image 1 is the exact unbranded recorded-video frame and EDIT TARGET: preserve the same full portrait scene, sunset sky, sun/clouds, teal sea, orange coastal path, original small walking character, existing measured waveform, label and small stop control. No top/bottom app panels, phone frame, status bar, modal or new controls. Match its original composition and artwork closely, don't redesign the scene or character.
Input image 2 is the EXACT brand graphic to insert, not merely a style reference. Preserve its 同拍 / ONEBEAT letterforms, coral Chinese word, teal English word and black dimensional ink shadow. Keep its proportions and colors. It should be recognizable but not dominate the recorded content.
Deliver one finished full-size portrait video-frame mockup, opaque background, about 1024px wide. No design annotation, plan title, arrows, measurements or explanatory captions in the frame. The original waveform remains near 27% from the top and the stop pill stays centered near the bottom. Avoid covering the walking character, waveform signal or stop control.
Option C: Add the exact brand graphic as a small COMIC STICKER in the LOWER LEFT road area, width about 22% of the whole frame, left inset about 5%, top near 83% of frame height. A close-fitting ivory sticker outline follows the logo's silhouette, with a small offset black ink shadow. Slight 4-degree counterclockwise tilt, like a collectible sticker on the video. Keep it to the left of the existing centered stop control with at least a small visible gap; don't cover any character, foreground vegetation or controls. Preserve the entire original waveform bar unchanged. No logo elsewhere.
```

## 局部修正提示词
### A-top-right
```text
Use case: precise-object-edit. Reference image 1 is the EDIT TARGET. Make one tiny text repair only: the waveform caption must read EXACTLY “MIC · 周围的声音” in white. Current image has a malformed Chinese character there. Keep the brand at upper right, every scene element, waveform and existing centered bottom stop pill completely unchanged. Same opaque portrait canvas. No other edits.
```

### B-waveform-integrated
```text
Use case: precise-object-edit. Reference image 1 is the EDIT TARGET. Add back the small centered bottom stop-recording pill that is visible in reference image 2. It is part of the video footage and MUST remain visible. Place it centered horizontally, about 93.3% down the frame, width about 34% of frame and height 6.3%, with its bottom about 3.5% above bottom edge. Match reference 2: translucent near-black rounded pill, coral small square, bold white “停止录制”, mint “00:01”. Keep the integrated brand inside the waveform bar exactly as in reference image 1, and keep every other pixel of the scene unchanged. No extra controls, no changed waveform or character. Opaque portrait canvas.
```

### C-bottom-left-sticker
```text
Use case: precise-object-edit. Reference image 1 is the EDIT TARGET. Add back the small centered bottom stop-recording pill from reference image 2. It is part of the video footage and MUST remain visible. Place it centered horizontally, about 93.3% down the frame, width about 34% of frame and height 6.3%, bottom about 3.5% above edge. Match reference 2: translucent near-black rounded pill, coral square, bold white “停止录制”, mint “00:01”. Keep the lower-left brand sticker completely unchanged. The pill belongs below and right of that sticker without overlap. Preserve every other scene pixel, original waveform, character, logo and background. No extra controls or layout changes. Opaque portrait canvas.
```

