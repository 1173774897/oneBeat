# PRO 定制鼓机漫画介绍图 v4

生成方式：内置 imagegen 编辑模式，背景不透明。

输入：用户确认的 `pro-drum-comic-v3.png`。

输出：`pro-drum-comic-v4.png`（1024×1536）。仅修改段落 B 的节奏型为“反拍开镲”、加花为“重音滾奏”，保留主卡片及现有手势。

## 完整提示词

```text
Use case: text-localization / precise-object-edit.
Edit target: the supplied completed Chinese PRO 定制鼓机 comic-page image.
The user has approved the row order and all existing graphics. Make ONLY TWO tiny text substitutions inside the SMALL “段落 B” arrangement card in panel 02 (upper-right purple feature panel):
1. In the small card's first row labeled “节奏型”, replace its selected dropdown value “八分摇滚” with the EXACT text “反拍开镲”.
2. In the small card's third row labeled “加花”, replace its selected dropdown value “军鼓短句” with the EXACT text “重音滾奏”.
Exact character check: 反 拍 开 镲 ; 重 音 滾 奏. Use 滾 exactly as requested, not 滚.
Match the original black lettering's size, stroke weight, baseline and perspective inside the same cream dropdown boxes. Keep dropdown chevrons in place.

Keep all other pixels as faithful as possible: the LARGE “段落 A” card must remain “八分摇滚” and “军鼓短句”; both cards keep their current four-row order; the small card's repeat/frequency values remain “4 小节” and “每 4 小节”. KEEP THE CYAN POINTING HAND AND STRIPED SLEEVE EXACTLY WHERE THEY ARE. Do not uncover, rearrange or redesign any card or labels. Do not remove the hand. The user explicitly approved this source image.
Preserve the exact masthead, logos, comic layout, all panel titles and badges, characters, all other text, grid, decorative dots, colors, outlines and footer. No new elements, no restyling, no cropping, no watermark. Same 1024×1536 opaque portrait canvas. Only the two small-card dropdown text values change.
```
