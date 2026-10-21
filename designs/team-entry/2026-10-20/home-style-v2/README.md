# 方案二：首页风格适配与加入页

本目录保存使用内置 image_gen 生成的设计图。2026-10-20 已按最终方案实施多人练习页与加入页，详情见 [实施与调节说明](implementation.md)，真机截图保存在 `device-checks/`。首页本轮未改动。

后续已按参考图重绘网点，最新素材、定位和疏密调节方式见 [网点重绘说明](halftone-redraw.md)，对应真机截图在 `halftone-device-checks/`。

## 最终设计图

- [多人练习入口](multiplayer-entry.png)：延续方案二的左右双票券，以首页的一红一白卡面、浅紫标签/按钮、黑色硬阴影和简洁粗体字建立连续性。保留原蓝色条纹角色与 Wave，补入同系列小植物。
- [加入队伍](join-team.png)：纵向整张票券承接扫码、加入码两个区域；扫码为主操作，六位加入码为空时按钮处于不可点击状态。直接沿用此前输入的昵称，不再次填写。

按用户最新要求保留并增加网点装饰，放在角色背后、票券边角和插画区。网点不覆盖输入内容或主按钮文字。概念图中的人物基于项目原 PNG 生成；落地应直接复用原设素材，不以生成版本替换角色原图。

加入链路保留现有扫码和 6 位数字加入码。扫码需要相机与 Wi-Fi；加入码通过蓝牙发现，最终仍使用 Wi-Fi 直连。页面没有增加附近队伍、额外登录、VIP 或社交功能。

参考：当前真机首页、上一轮方案 B、现有 mismatch / wave / cloud-phone 角色、plant_06 植物素材。图为布局与视觉方案，后续实施应使用原生控件还原，不把整张截图当作交互界面。

## 提示词一：双票券首页风格适配

```text
Use case: ui-mockup / style-transfer.
Create a refined high-fidelity mobile UI concept for 同拍, revising the existing two-ticket multiplayer entry screen to genuinely match the CURRENT APP HOME SCREEN.
Reference roles, in order:
Image 1 is the EDIT TARGET: the previous two-ticket concept. Preserve its two parallel captain/member ticket concept and required functions, but redesign its visual treatment and spacing.
Image 2 is the AUTHORITATIVE STYLE REFERENCE: an actual screenshot of the current app homepage. Match its calmer typography, wide cream negative space, coral/off-white/lilac flat card colors, 2px-equivalent ink outlines, small 8px-equivalent corner radii, precise solid black shadows offset about 4px right / 5px down. Its control text is ordinary heavy black sans-serif, NOT huge slanted extruded comic lettering. Retain its hand-drawn character and tiny plant illustration language.
Images 3 and 4 are exact original character cutouts: blue-skinned striped-shirt beanie character and purple/pink-haired girl with yellow overalls. Preserve identity, original costume, colors, hair, face, anatomy and original waving pose. Treat as original PNG inserts, without a black matte.
Image 5 is the original small purple flower illustration, used sparingly as a grounded detail. Small scenery accents may also follow the homepage reference.
Output ONE complete clean flat app-screen mockup, front-on, portrait ratio matching Image 2 (roughly 10:16, about 1320x2120), no phone frame, no presentation labels or extra artboard. Normal small generic 9:41 status bar, no personal notification icons.

DESIGN:
Use cream #FFF9EE background and controlled airy spacing, with a restrained standard header: back chevron and bold black title “多人练习” at normal page-title scale, small ONEBEAT / 同拍 wordmark at right if it fits. Below, a modest black one-line subheading “一个节拍，一起出发。” around 20–22dp-equivalent, not an enormous hero headline. Give it just one tiny coral stroke.
One compact full-width nickname card: small label “你的昵称”, white rounded-rectangle input placeholder “输入昵称”, and modest LILAC filled button “叫啥都行”. Align everything like real native UI.
Under it, TWO side-by-side equal-height portrait tickets, a comfortable gap, with restrained side notches and a fine dotted tear line near the bottom. Preserve the idea of individual illustrated role passes but make them feel like the homepage's card family:
LEFT ticket: mostly flat CORAL #FF7056, thick ink border and a solid offset ink backing; small cream role tag “我是队长”; black bold title “创建队伍”; small helper “选角色 · 定节拍”; the unchanged original blue character in the middle at a moderate size with breathing room, not touching the surrounding controls. Very small flowers near the base of the character only. Below the dotted tear line, a clean cream pill-like action with dark text “开始创建  ›”.
RIGHT ticket: mostly warm OFF-WHITE #FFFDF8, matching outline and offset shadow, lilac small role tag “我是队员”; black bold title “加入队伍”; small helper “扫码或输入加入码”; unchanged original girl at matching size; a tiny plant/base detail echoing homepage scenery. Below the dotted line, a light LILAC action “选择加入  ›”. Keep each original character's full silhouette legible, but prioritize the controls and title over the illustration.
Do not use the old concept's huge italic text, embossed 3D typography, gradient card fills, dense halftone fields, starbursts behind every character, thick dotted oversized perforations, thick sticker outlines around every text fragment, or repeated slogan blocks. Use the actual homepage's warm paper and playful but disciplined native-control styling.
Footer: small Wi-Fi icon, “Wi-Fi 直连” and muted helper “无需连接同一个路由器”. Bottom safe space and home indicator.
Functional scope unchanged: nickname/random nickname, create-team path, join-team path. No nearby rooms, team counts, VIP, login, social feed, extra navigation or bottom tabs. All quoted Chinese text must be correct and readable. This should look like the page immediately after the reference homepage in the SAME APP, not an unrelated loud poster.
```

## 提示词二：恢复网点装饰（最终多人页）

```text
Use case: precise-object-edit / ui-mockup.
Image 1 is the EDIT TARGET: the refined two-ticket multiplayer entry page for 同拍. Image 2 is the actual homepage STYLE REFERENCE for printed comic halftone marks. Image 3 is the previous more decorated ticket draft, a reference for visible dot decoration only, NOT for layout or oversized typography.
User correction: restore a noticeable amount of comic HALFTONE / BEN-DAY DOT decoration. They like the comic dots and do not want the refinement to become visually plain.

Change ONLY the decorative background details in Image 1:
- In the illustration region of the CORAL left ticket, put two deliberate black-ink halftone fans / patches behind the unchanged blue character, one toward the upper outside edge and one near the plant baseline. Discrete large-to-small round dots, visible at normal screen size, like a graphic print rather than grain/noise.
- In the illustration region of the OFF-WHITE right ticket, add lilac and black halftone patches behind the unchanged girl, with a recognizable dotted fan toward the right side and a small dotted corner near the base. Both passes should feel equally finished.
- Add a small restrained dot patch near the slogan/brand corner if useful. Total dot treatment can cover roughly one quarter of the available illustration background, close to the playful density of the homepage; keep generous solid/cream areas between patches.
- Keep all dots behind the character artwork and foliage, off faces, off text, off the input, and off buttons.

Preserve ALL other elements: exact screen composition and portrait ratio, cream page background, back header “多人练习”, small wordmark, modest slogan “一个节拍，一起出发。”, nickname input and “叫啥都行” button, two side-by-side tall ticket silhouettes, left coral/right off-white cards, lilac role tag and CTA, both original characters and original poses/costumes, purple flowers, thin dotted tear lines, typography, text wording, footer, hard black offset shadows, and native-looking form controls. Do not restore the old huge italic/3D headline. Do not change any functional element or add more UI. No device frame, no annotations, no dark matte, no photorealism. Produce the revised single complete app-screen mockup.
```

## 提示词三：配套加入页

```text
Use case: ui-mockup.
Create ONE finished high-fidelity “加入队伍” member-join screen for the 同拍 / oneBeat app, matching the updated two-ticket multiplayer entry screen as the NEXT PAGE in the SAME app.

Reference roles:
Image 1 is the PRIMARY DESIGN SYSTEM reference: the updated multiplayer entry page with coral and off-white tickets, visible comic halftone dot patches, small lilac actions, thick ink outlines and black offset hard shadows. Match its typeface scale, quiet cream background, comfortable spacing and ticket silhouettes.
Image 2 is the ACTUAL APP HOMEPAGE, a supporting style reference for native-control simplicity, black bold text, hand-drawn art and printed Ben-Day dots.
Image 3 is the ORIGINAL cloud character holding a phone: blue body, one large eye, white cloud hair, pink cheeks, small wings, rainbow pin and coral phone. Use this asset unchanged as a cutout illustration; preserve character identity, proportions, colors, costume and pose. No dark matte.
Image 4 is the ORIGINAL small purple flower illustration, a small grounded decorative detail if useful.

Output one complete flat app-screen screenshot with the same approximately 10:16 portrait ratio as Image 1 (about 1320x2120), no device frame, no concept labels or presentation border. Normal generic 9:41 status bar and bottom home indicator, no personal notifications.
Palette: cream #FFF9EE, warm white #FFFDF8, coral #FF7056, lilac #C5B7EB, ink #171B1F. Near-flat fills, 2px-equivalent ink borders, modest 8px-equivalent rounded corners, solid shadows offset about 4px right / 5px down. Clean ordinary heavy black Chinese UI typography; no giant italic extruded 3D headline, no gradients, no glassmorphism. Clear touch targets.

LAYOUT:
1. Compact native page header: back chevron on left, black bold title “加入队伍”, and a small lilac outlined role tag “队员” on the right.
2. A compact friendly invitation hero, approximately the next 150dp of height. LEFT: black bold two-line text “拿到队长的” / “邀请了吗？” and smaller helper “扫码，或输入 6 位加入码” / “和大家一起出发。” RIGHT: the original cloud-with-phone cutout at moderate size. Visible, tasteful black and lilac HALFTONE DOT fans behind the cloud and a small coral beat stroke, consistent with the recently restored dotted decoration in Image 1. Do not remove the dots or turn this into a plain grey form. Keep text backgrounds clean; no dots over the eye or text. A tiny original flower accent can ground the illustration.
3. Below the hero, one large WHITE VERTICAL TICKET with thin ink border, solid black offset backing, subtle semicircular side notches at the internal tear line, moderately rounded corners, and spacious inset. This contains TWO METHODS stacked:
   TOP METHOD is the primary scan path. Header line “扫描队长二维码” in 18–20dp bold black, small coral pill “推荐”. Helper “对准队长展示的二维码”. A small simple scan-bracket/camera icon at the right as an accent, NOT a real QR code. Full-width coral button, black bold text “打开相机扫码  ›”. Small grey note “扫码需要相机和 Wi-Fi”.
   Fine dotted perforation divider between methods, with small centered “或者” on a cream label. Preserve the ticket metaphor without oversized black dots or clutter.
   BOTTOM METHOD is joining by six-digit numeric code. Title “输入 6 位加入码” in matching black bold type. An obvious single numeric input styled as six evenly spaced slots showing EMPTY placeholder dashes “— — — — — —”; warm pale cream inset, clear thin ink outline, generous touch height. Show the INITIAL EMPTY STATE, not a real code. Below, a full-width light-lilac “用加入码进入  ›” button in a visibly subdued disabled treatment until six digits are entered. Small grey note “加入码需要蓝牙发现”. This remains one numeric entry field concept, not six unrelated form questions.
4. Footer outside the ticket: tiny Wi-Fi icon and muted text “Wi-Fi 直连 · 无需连接同一个路由器”. Comfortable safe area.

Keep visible comic halftone decoration in the hero and a few OUTER card corner regions, never behind form values or buttons. This should be a strong visual continuation of Image 1, with the same cream paper, plant-and-character linework, coral/lilac balance, and printed comic feeling.
Functional fidelity: nickname was already entered on the previous screen, so do NOT ask for it again. Only the existing scan and six-digit join-code paths are present. No nearby-room lists, fake connected members, fake camera previews, real QR codes, new login, new nickname settings, VIP, bottom navigation, calendar or sharing. No unnecessary technical descriptions. Every quoted Chinese phrase must be spelled correctly and legible. Fit essential controls on one screen.
```

