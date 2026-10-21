# 多人练习入口三版设计 · 2026-10-20

本轮仅提供设计预览，没有修改 TeamPage.ets 或应用运行时素材。使用内置 image_gen 生成，每版独立一张图。

| 方案 | 图片 | 设计与取舍 |
| --- | --- | --- |
| A 漫画双格 | [option-a-comic-panels.png](option-a-comic-panels.png) | 双人击掌头图 + 昵称卡 + 上下两块漫画入口；点击目标宽，操作最直接，最接近现有页面。 |
| B 组队通行证 | [option-b-team-passes.png](option-b-team-passes.png) | 昵称横条 + 左右角色票券；创建与加入同等突出，角色插画与实际入口合为一体，推荐优先考虑。 |
| C 同拍出发台 | [option-c-shared-stage.png](option-c-shared-stage.png) | 紫色双人舞台 + 下方集中操作区；氛围最强，昵称和按钮更紧凑，实施时需适配较矮屏幕。 |

三版保留昵称输入、随机昵称、创建队伍、加入队伍。加入入口仍进入现有扫码/加入码选择流程，图中的方式标签不代表新增连接链路。Wi-Fi 提示遵循当前直连能力。

沿用原角色设定和品牌配色，生成图中人物是基于原素材的概念呈现；实际实施应直接复用现有角色 PNG，不以生成图替换角色原设。

参考素材：
- entry/src/main/resources/rawfile/comic/poses/mismatch.png
- entry/src/main/resources/rawfile/comic/poses/wave.png
- entry/src/main/resources/rawfile/comic/brand/onebeat_wordmark.png

下方保留完整生成提示词。图中排版为方案预览，后续落地需要用原生控件重建按钮、输入框和文字，不把整张图当作可交互页面。

## A · 漫画双格

```text
Use case: ui-mockup.
Asset: A finished, polished Chinese HarmonyOS mobile app screen for 同拍 / oneBeat, the existing comic-style synchronized rhythm practice application. Produce ONE complete portrait screen, roughly 1024 by 2048, straight-on flat screenshot, no phone frame, no surrounding presentation board, no wireframe. Design quality must feel ready for a real app with generous deliberate spacing and clear touch targets.
References: Image 1 is the ORIGINAL blue-skinned striped-shirt character, Image 2 is the ORIGINAL purple/pink-haired yellow-overalls girl, Image 3 is the existing brand wordmark. These are supporting cutout assets for compositing, not screenshots to copy. Preserve the two characters' exact identities, faces, hair, clothes, colors, body proportions, and original waving poses. Do not redesign or invent characters. Remove the transparent/black preview backing when placing the cutouts. Scale/crop original assets tastefully; never cover important controls with characters. Use the wordmark sparingly, if useful.
Established design language: cream paper #FFF9EE, coral #FF7056, lilac #C5B7EB, ink #171B1F, tiny teal accents #29B5AE. Confident near-flat graphic comic art, thick varied ink contours, crisp rectangular cards with moderately rounded corners, strong offset SOLID black shadows, printed sticker layering, bold slightly italic Chinese display headlines, clean highly legible Chinese UI text. Very subtle paper grain and restrained halftone only on illustrations; clean text backgrounds. No watercolor, no pastel travel painting, no realistic 3D, no glassmorphism, no washed-out grey minimalist wireframe.
Functional scope: This is the entry page reached by tapping 多人练习 on the home page, BEFORE creating/joining a team. Retain back navigation, a nickname text field with random-name button, a clearly actionable 创建队伍 path for captain, and 加入队伍 path for member. Joining proceeds to existing scan/code methods; show these as descriptive chips only. Do not invent nearby team listings, already joined members, team counts, QR codes, premium offers, login, chat, social feeds, bottom tab bars, or other features.
Typography: render the quoted Chinese text correctly and clearly, black on light backgrounds. A small normal status bar at top and home indicator at bottom. Everything important fits on one screen with breathing room.
Concept A — COMIC DOUBLE PANEL. Cream background with a restrained, charming comic editorial hierarchy.
Top header: back chevron, big bold italic “多人练习”, small “TEAM UP. KEEP THE BEAT.” beneath.
Upper hero is a compact wide comic strip: original blue character on left and original girl on right, raised hands toward one another, sticker cutout edges, pale lilac beat halo and four coral beat ticks behind them. One small cream outlined caption sticker “一个节拍，一起出发！”; hero takes only about one quarter of usable screen.
Below hero, a full-width clean white small nickname card. Label “你的昵称”; one actual input field placeholder “输入昵称” and a teal compact button “叫啥都行”.
Then TWO FULL-WIDTH STACKED ACTION PANELS, visually balanced, clearly larger than the nickname area: upper CORAL panel with a little outlined “我是队长” tag, large title “创建队伍”, helper “选角色、定节奏，带大家出发”, and one bold black arrow in a cream circular hit area at right. Lower LILAC panel with “我是队员”, large title “加入队伍”, helper “跟着队长的邀请，一起同拍”, small descriptive chips “扫码” and “加入码”, and matching right arrow. Use strong ink offset shadows and 14–18px radius equivalent at mobile scale. Do not repeat character art inside the two panels; the upper hero already carries them.
Footer tiny wifi icon with “Wi-Fi 直连 · 面对面一起练”. Organize the composition like two compelling comic panels with crisp readable hierarchy, not dense forms or a giant illustration. Output only this single app screen.
```

## B · 组队通行证

```text
Use case: ui-mockup.
Asset: A finished, polished Chinese HarmonyOS mobile app screen for 同拍 / oneBeat, the existing comic-style synchronized rhythm practice application. Produce ONE complete portrait screen, roughly 1024 by 2048, straight-on flat screenshot, no phone frame, no surrounding presentation board, no wireframe. Design quality must feel ready for a real app with generous deliberate spacing and clear touch targets.
References: Image 1 is the ORIGINAL blue-skinned striped-shirt character, Image 2 is the ORIGINAL purple/pink-haired yellow-overalls girl, Image 3 is the existing brand wordmark. These are supporting cutout assets for compositing, not screenshots to copy. Preserve the two characters' exact identities, faces, hair, clothes, colors, body proportions, and original waving poses. Do not redesign or invent characters. Remove the transparent/black preview backing when placing the cutouts. Scale/crop original assets tastefully; never cover important controls with characters. Use the wordmark sparingly, if useful.
Established design language: cream paper #FFF9EE, coral #FF7056, lilac #C5B7EB, ink #171B1F, tiny teal accents #29B5AE. Confident near-flat graphic comic art, thick varied ink contours, crisp rectangular cards with moderately rounded corners, strong offset SOLID black shadows, printed sticker layering, bold slightly italic Chinese display headlines, clean highly legible Chinese UI text. Very subtle paper grain and restrained halftone only on illustrations; clean text backgrounds. No watercolor, no pastel travel painting, no realistic 3D, no glassmorphism, no washed-out grey minimalist wireframe.
Functional scope: This is the entry page reached by tapping 多人练习 on the home page, BEFORE creating/joining a team. Retain back navigation, a nickname text field with random-name button, a clearly actionable 创建队伍 path for captain, and 加入队伍 path for member. Joining proceeds to existing scan/code methods; show these as descriptive chips only. Do not invent nearby team listings, already joined members, team counts, QR codes, premium offers, login, chat, social feeds, bottom tab bars, or other features.
Typography: render the quoted Chinese text correctly and clearly, black on light backgrounds. A small normal status bar at top and home indicator at bottom. Everything important fits on one screen with breathing room.
Concept B — SIDE-BY-SIDE TEAM PASSES, a distinct premium comic ticket design.
Cream paper background. Header has a back chevron and “多人练习”. Editorial headline below on two lines: “一个节拍，” then “一起出发。” with a little coral underline on the second line; tiny brand-like beat marks, lots of confident negative space.
Place a full-width nickname strip below the headline: label “你的昵称”, white input placeholder “输入昵称”, compact teal button “叫啥都行”. The form must be unmistakable.
Main visual: TWO TALL TICKETS SIDE BY SIDE, same width and height, a clean 16px gap at 390px-equivalent viewport. Each ticket is a fully tappable entry with visible lower button. Strong thick black outlines, solid black offset shadows, subtle side semicircular notches and a short dotted perforation near the lower third.
LEFT ticket has coral header/body accents and a cream face, a little “我是队长” badge, the exact original blue striped character cutout centered in its illustration area, title “创建队伍”, smaller two-line helper “选角色 · 定节奏” / “带大家一起出发”, and a coral bottom button with black text “开始创建 ↗”.
RIGHT ticket has lilac header/body accents and a cream face, “我是队员” badge, the exact original girl cutout centered in its illustration area, title “加入队伍”, helper “扫码或输入加入码” / “跟着队长一起出发”, and a lilac bottom button with black text “选择加入 ↗”.
Do not make the ticket text too tiny; both 4-character action titles must be prominent and readable. Avoid the separate top character hero from Concept A; all character illustration belongs inside these two passes. Let them feel like collectible comic passes with real usable app controls, not physical printed prop photography.
Footer a slim outlined pill “Wi-Fi 直连” and unobtrusive text “无需连接同一个路由器”. No other controls. Output only this single app screen.
```

## C · 同拍出发台

```text
Use case: ui-mockup.
Asset: A finished, polished Chinese HarmonyOS mobile app screen for 同拍 / oneBeat, the existing comic-style synchronized rhythm practice application. Produce ONE complete portrait screen, roughly 1024 by 2048, straight-on flat screenshot, no phone frame, no surrounding presentation board, no wireframe. Design quality must feel ready for a real app with generous deliberate spacing and clear touch targets.
References: Image 1 is the ORIGINAL blue-skinned striped-shirt character, Image 2 is the ORIGINAL purple/pink-haired yellow-overalls girl, Image 3 is the existing brand wordmark. These are supporting cutout assets for compositing, not screenshots to copy. Preserve the two characters' exact identities, faces, hair, clothes, colors, body proportions, and original waving poses. Do not redesign or invent characters. Remove the transparent/black preview backing when placing the cutouts. Scale/crop original assets tastefully; never cover important controls with characters. Use the wordmark sparingly, if useful.
Established design language: cream paper #FFF9EE, coral #FF7056, lilac #C5B7EB, ink #171B1F, tiny teal accents #29B5AE. Confident near-flat graphic comic art, thick varied ink contours, crisp rectangular cards with moderately rounded corners, strong offset SOLID black shadows, printed sticker layering, bold slightly italic Chinese display headlines, clean highly legible Chinese UI text. Very subtle paper grain and restrained halftone only on illustrations; clean text backgrounds. No watercolor, no pastel travel painting, no realistic 3D, no glassmorphism, no washed-out grey minimalist wireframe.
Functional scope: This is the entry page reached by tapping 多人练习 on the home page, BEFORE creating/joining a team. Retain back navigation, a nickname text field with random-name button, a clearly actionable 创建队伍 path for captain, and 加入队伍 path for member. Joining proceeds to existing scan/code methods; show these as descriptive chips only. Do not invent nearby team listings, already joined members, team counts, QR codes, premium offers, login, chat, social feeds, bottom tab bars, or other features.
Typography: render the quoted Chinese text correctly and clearly, black on light backgrounds. A small normal status bar at top and home indicator at bottom. Everything important fits on one screen with breathing room.
Concept C — ONE SHARED STAGE + COMPACT CONTROL DECK. Visually distinct from ticket cards and stacked panels.
Top 55% of screen is a confidently composed lilac comic stage. At top a back chevron and large black italic “多人练习”. Below, smaller cream outlined caption sticker “一个节拍，一起出发！”. Use the two exact original waving character assets together as the focal scene, blue character left and yellow-overalls girl right, hands visually meeting near center, thick cream sticker borders and solid black backing for physical sticker depth. Put a large simple cream broken circular beat halo behind them with four coral beat marks, tiny restrained halftone patches at outside edges. Keep the actual character design unchanged. Add only a few simple graphic beat strokes, no landscape, no new props, no duplicate characters.
A CREAM CONTROL DECK with rounded top corners and black outline overlaps the stage's bottom edge, filling the lower 45%. The overlap is clean and intentional, with solid ink depth like paper layers.
At the top of this deck a black bold label “先给自己起个名字”, then one white outlined nickname field with placeholder “输入昵称”, and the compact teal “叫啥都行” button alongside. The input row spans the deck width.
Below, TWO EQUAL SIDE-BY-SIDE chunky action buttons in one row, coral on left and lilac on right, each with thick ink borders and offset black shadows, no extra character art. Left small label “我是队长” and large “创建队伍” with a tiny right arrow. Right small label “我是队员” and large “加入队伍” with tiny right arrow. Under left in subdued small text “选角色，定节拍”; under right “扫码或输入加入码”. Keep buttons comfortable to tap, roughly 110px high at 390px viewport equivalent.
Footer below the deck tiny Wi-Fi symbol and “打开 Wi-Fi，和身边的人一起练”. This is a restrained single-stage branded landing screen, clear and spacious; avoid adding a second hero or extra nested card rows. Output only this single app screen.
```

