# PRO 定制鼓机漫画介绍图 v2

生成方式：内置 imagegen 编辑模式，背景不透明。

修改：02 选择内置节奏型和加花；03 支持点格子，写鼓点。两格的页面画面与辅助信息一起调整，其他分格沿用初版。

输入：`pro-drum-comic.png`。

输出：`pro-drum-comic-v2.png`，1024×1536。

## 完整提示词

```text
Use case: precise-object-edit.
Edit target: the supplied finished comic-page image for the 同拍 app's PRO 定制鼓机 membership introduction.
Make a targeted revision ONLY to feature panels 02 and 03. Preserve the overall 1024×1536 portrait composition, panel frame boundaries, masthead, brand wordmark, exact original characters, colors, heavy comic lettering, Ben-Day dots, ivory paper, black outlines and hard shadows. Keep panel 01, panel 04, title and bottom membership strip unchanged.

Required revised reading order:
Panel 02 (upper-right, keep its purple number 02 and purple-accented panel location) must now introduce choosing built-in rhythm patterns and fills.
Exact large heading: “选择内置节奏型和加花” (line break into two lines if needed; do not paraphrase or omit characters).
Replace this panel's existing step-grid image with a clean enlarged illustration of the app's arrangement controls. The main recognizable cream card labeled “段落 A” should show two prominent separate dropdown rows: “节奏型” with selected value “八分摇滚” and a chevron; “加花” with selected value “军鼓短句” and a chevron. A hand can point to the dropdowns to show choosing a built-in preset. Include smaller controls “重复 4 小节” and “每 4 小节”, and a small second “段落 B” card or sequence arrow if helpful. Move the original “最多 8 个段落” badge from former panel 03 into panel 02 as a secondary badge. Maintain the exact functional terms and readable native-app-like labels. This panel is about CHOOSING existing presets, not editing individual grid cells.

Panel 03 (lower-left, keep its turquoise number 03 and turquoise-accented panel location) must now introduce custom grid editing.
Exact large heading: “支持点格子，写鼓点” (line break only if needed; do not omit “支持”).
Replace the former arrangement-card artwork with the step-grid editor visual from former panel 02: cream grid workspace, a few labeled instrument rows “底鼓” “军鼓” “闭镲”, coral and lilac cells, an orange vertical playhead with triangular cap, a finger visibly tapping a grid cell. Retain Wave's recognizable character cameo in this panel if space permits. Move the two informational captions from old panel 02 into panel 03: exact text “10 种鼓声” and “4 等分 / 3 连音 / 6 连音”. The real subdivision controls may be drawn once in the grid header. Fit a simplified enlarged but clearly recognizable editor crop into this smaller comic panel; prioritize readable headings and clear grid interaction rather than tiny crowded UI text.

Keep these other text elements and their placement/design unchanged:
“PRO 定制鼓机”
“把节奏，编成你的步调”
Panel 01 “挑一种喜欢的律动”, “12 种风格”
Panel 04 “先试听，再一起出发”, “保存你的编排”, “应用到队伍”, “试听整曲”
Footer “畅游月卡 · 包含 PRO 定制鼓机”.

All Chinese text must be correctly written, sharp and legible, consistent with the original comic. No additional feature claims, price, watermark or new characters. Match the original artifact faithfully; this is a content swap/update of two panels, not a visual redesign. Opaque background.
```
