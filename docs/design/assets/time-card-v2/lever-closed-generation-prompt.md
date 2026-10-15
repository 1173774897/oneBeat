# 独立扳手左端封盖（2026-10-14）

使用内置 imagegen 编辑工具，以运行时 `lever.png` 为编辑目标。输出保留1254×1254 RGBA画布，人工检查左端已封闭、银色转轴与主体位置保持配准。原素材留存于 `archive/lever/lever-open-left.png`。

## 最终提示词

```text
Use case: precise-object-edit
Asset type: transparent comic lever sprite used in an existing animated time-card machine.
Input image 1 is the EDIT TARGET, not just a style reference.
Primary request: repair ONLY the left end face of the yellow/gold metal cylinder at the BOTTOM of this lever. The current narrow left oval/crescent looks like a hollow open tube. Close that entire hollow left end with a solid gold/brass end cap, matching the existing cylinder, its curved silhouette, bold black ink outline, warm highlights, halftone shadows and comic texture. The end cap must visibly be solid metal, not a black empty cavity or a ring.
The silver screw on the front face of the gold cylinder is the actual rotation axle: preserve that silver screw EXACTLY in the same location and appearance. Preserve the teal grip, silver shaft, their pose, dimensions and all pixels outside this small left-end edit region as closely as possible. Preserve the gold cylinder's overall outer silhouette and its small protrusion on the right.
Composition and registration are critical: keep the complete lever in exactly the same position and scale on the same square canvas as input; no crop, no recenter, no extra margins, no camera-angle change, no redesign of handle or shaft. Request same 1254 x 1254 canvas as target if supported.
Background: genuinely transparent alpha, including all surrounding empty areas. Keep clean antialiased edges. No backdrop, no checkerboard pattern, no new objects, no text, no watermark.
Change ONLY the left hollow oval face to a solid gold closed end cap; all other structure stays unchanged.
```

