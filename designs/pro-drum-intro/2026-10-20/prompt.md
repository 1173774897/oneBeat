# PRO 定制鼓机漫画介绍图

用途：畅游月卡查看方案时，介绍 PRO 定制鼓机功能。

生成方式：内置 imagegen；opaque background；按当前正式功能核对文案。

最终图片：`pro-drum-comic.png`（1024×1536）。

图片分为选风格、格子编辑、段落与加花、试听与队伍应用四个分格；页头为功能名称，页尾为月卡权益归属。

参考文件：
- `designs/store-portraits/2026-10-20/device-checks/x-drum-six-seek.jpeg`
- `entry/src/main/resources/rawfile/comic/store/mismatch.png`
- `entry/src/main/resources/rawfile/comic/store/wave.png`
- `entry/src/main/resources/rawfile/comic/brand/onebeat_wordmark.png`

## 完整提示词

```text
Use case: ads-marketing.
Asset type: ONE finished portrait American comic-book page introducing the PRO custom drum machine in the Chinese app 同拍 / ONEBEAT, to be shown inside the 畅游月卡 membership plan details. This is a polished raster promotional illustration, not a wireframe, not a screenshot collage, not a generic feature-card infographic.

Format: portrait 2:3, ideally 2048 × 3072 px, crisp high-resolution Chinese lettering, opaque warm ivory paper #FFF9EE. Leave a safe 4% perimeter. Strong editorial design, 4 narrative feature panels plus a big title masthead, with energetic irregular comic gutters, thick near-black ink frames, occasional diagonal division, hard offset ink shadows, abundant Ben-Day halftone dots, restrained speed lines and punchy sound-effect accents. Match the app palette: coral #FF7056, lilac #C5B7EB, turquoise #29B5AE, ivory, black. Use clean solid color fields; NO weathered yellow grunge. Dynamic contemporary American indie comic with the existing cute character proportions preserved, rather than superhero redesigns.

Input references and their roles:
Image 1 is the REAL current drum-grid editor UI, a factual page-layout and UI-color reference. Preserve recognizable cream workspace, black title bar, coral active cells, lilac weaker hits, thin orange moving playhead, track-name column and 4等分 / 3连音 / 6连音 controls. Re-illustrate legible selected details cleanly; do not copy its phone status bar, notifications, time, dimmed background, or entire screenshot.
Image 2 is the exact original character design of 条纹步客: cyan skin, teal rib-knit beanie, dark green hair, narrow eyes, black/cream striped shirt, asymmetrical orange/purple elbow pads, denim shorts, red high-tops. Preserve identity, outfit, colors, proportions and line style, but allow expressive teaching/pointing poses.
Image 3 is the exact original Wave character design: purple/pink bob haircut, peach skin, cyan sleeveless top, yellow short overalls, colorful high-top sneakers. Preserve identity, outfit, colors and proportions, allow lively reaction / practicing poses.
Image 4 is the official 同拍 / ONEBEAT wordmark; use it small and intact as brand identification. The main title must still be PRO 定制鼓机.

Design and reading order:
MASTHEAD (roughly top 15%): Huge slanted, dimensional comic headline “PRO 定制鼓机”; an ivory caption “把节奏，编成你的步调”. Small official wordmark in a corner. Coral burst and lilac halftones; characters may subtly break a frame edge. This is an app feature introduction, not a membership price poster.

FOUR feature-story panels underneath, two upper panels and two lower panels, somewhat asymmetric sizes, generous cream gutters, a clear 01→02→03→04 reading order, no panels nested into a phone-only layout. The UI illustrations occupy substantial space, about half of the whole page, and clearly depict both the arrangement page and grid editor.

PANEL 01 (upper left, coral accents):
Exact large heading: “01 挑一种喜欢的律动”
Exact short badge: “12 种风格”
Show 条纹步客 choosing a style on an illustrated close-up of the actual arrangement screen. Cream interface with top “定制鼓机”, a tiny black PRO badge, horizontal style chips “摇滚” “爵士” “放克”, a “4/4” meter selector and “120 BPM” field. Coral selected chip, ink outline. Keep screen as a readable clean page crop or modest tilted phone, not a fancy audio mixing console.

PANEL 02 (upper right, a somewhat larger editorial focus, lilac accents):
Exact large heading: “02 点格子，写鼓点”
Exact two short captions: “10 种鼓声” and “4 等分 / 3 连音 / 6 连音”
Show an enlarged dynamic close-up of the real grid editor (reference 1), a hand tapping one coral cell and an orange vertical playhead with a small triangular cap. A few instrument labels “底鼓” “军鼓” “闭镲” are sufficient; grid clearly aligns in rows/columns and has beat numbers. Show the three subdivision selectors once. Retain crisp black ink, not blurry screen texture.

PANEL 03 (lower left, turquoise accents):
Exact large heading: “03 段落与加花，自由编排”
Exact badge: “最多 8 个段落”
Show recognizable native arrangement cards labeled “段落 A” and “段落 B” connected by a bold comic flow arrow. Card A visibly has “节奏型”, “重复 4 小节”, “加花”, “每 4 小节”; card B is a second compact arrangement card. Add a small drum-roll illustration. This illustrates multiple sections, repeat counts and fill frequency, NOT an audio waveform DAW or piano roll.

PANEL 04 (lower right, coral / cream):
Exact large heading: “04 先试听，再一起出发”
Exact two short captions: “保存你的编排” and “应用到队伍”
Show Wave and 条纹步客 practicing together cheerfully, each holding a phone with the same coral/lilac step pattern, aligned rhythm marks and musical notes. Integrate recognizable illustrated “试听整曲” and “应用到队伍” controls as feature examples, not large clickable purchase CTAs. Capture the pleasure of leading the group with your own beat, without promising zero-latency audio or adding unsupported features.

BOTTOM STRIP: exact readable text “畅游月卡 · 包含 PRO 定制鼓机”.

Typography: Chinese glyphs must be correct, large, high contrast, typeset-like heavy comic sans for headings and clean bold Chinese for captions. Prioritize mobile readability over decorative microtext. Place captions in classic comic narration boxes and simple speech bubbles, no long paragraphs. No extra invented copy beyond the specified interface labels and captions. Slightly tilted big headings are okay; body text stays horizontal.
Constraints: only advertise the real supported functions above. No price, discount, AI composition, microphone recording, MIDI, per-note volume slider, randomize button, music scores, or claim of saving only eight presets. The “8” refers only to arrangement sections. Do not depict a drummer in a generic recording studio in place of the actual application. No watermark. Keep all content finished and presentation-ready.
```
