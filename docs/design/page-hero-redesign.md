# Page-specific comic heroes

Generated and revised with the built-in imagegen tool on 2026-10-05. The initial rounded/pastel draft was superseded following feedback: final assets use American-comic inked panel geometry, Ben-Day dots and only the existing oneBeat palette. These are transparent background illustrations only; native ArkUI keeps characters, copy, controls and hit targets separate. Original pre-task artwork was not overwritten; both draft generations remain in Codex generated_images.

## Assets and runtime layout

- `entry/src/main/resources/rawfile/comic/decor/team_beat_collage.png`: lilac/light-blue skewed comic panels with ink edges and restrained coral/teal halftone accents. `TeamPage.ets` uses `TEAM_HERO_HEIGHT = 190`, full-size image bounds, and `ImageFit.Contain` to preserve the artwork's proportions. Existing -58 row overlap and ±53 character translations are unchanged. Increasing the height grows the hero and both character boxes; fixed 52% character widths and clipping still constrain the composition.
- `entry/src/main/resources/rawfile/comic/decor/join_invitation_paper.png`: blank cream invitation writing field with sparse folded-paper accents. `MemberJoinPage.ets` uses `JOIN_HERO_HEIGHT = 142`, full-size image bounds, and `ImageFit.Cover` over the existing teal card. Increasing the height grows the card and mascot; the 140vp text right-padding remains reserved for the mascot. Copy and QR/code actions remain native and unchanged; the decorative image contains no actual or fake QR codes.
- `entry_burst.png` remains exclusive to the homepage hero; old `stage_speedlines.png` remains available for other uses.

## Superseded initial exploration

### Team

Use case: stylized-concept
Asset type: production transparent PNG background illustration for the existing oneBeat mobile TEAM UP page hero, not a full UI screenshot.
Primary request: a fresh "side by side, same beat" editorial comic collage, distinctly NOT an explosion burst, radial rays or speed lines.
Canvas: wide horizontal landscape, approximately 16:9. The app renders it behind two existing standing comic characters in a 190vp-high hero. The two characters are clustered in the CENTER, raising their hands toward each other. A small native cream caption is at the bottom center. Do not draw these people or the caption.
Subject/composition: two gently irregular rounded cut-paper backplates leaning toward each other, broad pale lilac on the left and muted butter-yellow on the right, with a subtle creamy overlap at center. They form one low, friendly rhythmic arch backdrop rather than separate bordered cards. A short teal dotted stepping rhythm meanders across the lower outside edges. Tiny hand-inked rhythmic ticks and limited teal halftone only at the far left/right fringes. Keep the central 55% uncluttered with flat, pale fill; keep lower center quiet for the caption. Edges are organic, NOT jagged, no starbursts. Let transparent margin surround the illustration; don't fill the whole canvas.
Style/medium: flat hand-inked pop-art editorial comic, lightly imperfect confident near-black #171B1F contours, sparse screenprint halftone, slightly tactile cut-paper edges, graphic and readable at 350px wide. No rendered perspective, glossy 3D, shadows/glows, gradients or realistic landscape.
Palette: oneBeat paper #FFF9EE, pale lilac #C5B7EB, light butter yellow #F4DC95, restrained teal #29B5AE, near-black ink #171B1F. Prefer pale large fields and small saturated teal accents so turquoise/pink/yellow existing characters remain the stars.
Text: NONE. No letters, numbers, logos, music notation, labels, watermarks, characters, UI controls, new mascots, frames or screen borders.
Transparency: true alpha transparent outside the cut-paper art, no baked checkerboard.

### Join

Use case: stylized-concept
Asset type: production transparent PNG decorative backdrop for the existing oneBeat mobile JOIN TEAM invitation hero, NOT a full UI screenshot.
Primary request: a fresh hand-inked invitation stationery composition, distinct from the homepage's coral explosion burst and distinct from radial speed lines.
Canvas: very wide horizontal landscape about 2.5:1. It will be displayed in a 142vp-high, roughly 330vp-wide rounded teal card. Native app renders black Chinese headline and two-line instruction copy on the LEFT, and a friendly full-body cloud mascot on the RIGHT. Do not draw text or mascot.
Composition constraints: the left 60% must be a completely clean light cream paper writing field, extending almost all the way to the left/top/bottom edges so existing headline and instructions remain readable. The field ends around 62% width with a softly scalloped or torn vertical paper edge. A very subtle vertical dashed invitation perforation runs at that right edge, never through the text field. The right 38% is mostly transparent, revealing the app's teal background, with one small pale-lilac folded stationery corner at upper right and a restrained patch of ink/teal halftone at lower right. A tiny coral circular blank seal near the top of the writing-field edge suggests an invitation, but no symbols inside. Keep all dense decoration on the dividing edge or outer corners, because the cloud mascot overlaps the right half. This is an invitation paper COLLAGE background, not a giant envelope icon and not a purchased subscription ticket.
Style/medium: same flat friendly hand-inked editorial comic language as oneBeat: confident slightly imperfect dark #171B1F contours, restrained sparse print halftone, subtle paper edge texture, crisp readable small-scale shapes, warm and welcoming. No photorealism, glossy 3D, glows, gradients, giant shadow slabs, spiky explosions, zigzag lightning or speed lines.
Palette: light cream #FFF9EE and #FFFDF8 dominant text field, pale lilac #C5B7EB for the small folded corner, tiny coral #FF7056 seal, teal #29B5AE, dark ink #171B1F.
Text: NONE. No letters, numbers, QR codes (real or fake), barcodes, labels, watermarks, logos, new characters, mascots, or UI controls. No overall outer card border; app already supplies its own border.
Transparency: true alpha outside the cream paper and small right accents; no baked checkerboard.

## Final American-comic revision prompts

### Team

Use case: precise-object-edit
Asset type: the transparent oneBeat TEAM PAGE hero background ONLY.
Edit target: Image 1 is the first background draft. It is rejected as too childlike. Rebuild its rounded blob art as a mature AMERICAN COMIC BOOK editorial collage while retaining the 2:1 landscape canvas, real alpha transparency, and central negative space for the app's existing two high-fiving figures.
Primary request: replace the soft round lavender/yellow toy-like blobs with two broad, subtly skewed, HARD-EDGED cut-paper comic panels that interlock side by side. Uneven but mostly STRAIGHT hand-inked edges, a shallow diagonal overlap, bold confident near-black contour and small hard offset ink shadows. Panels should be an open poster backdrop, NOT a fully enclosed outer frame, explosion, rays or speed lines.
Page context: the backdrop sits in a 190vp-high cream hero; native mismatch and wave characters are clustered in the central 55% and native slogan is at bottom center. Keep this central region light and quiet. Dense ink and screenprint halftone belong ONLY to outer margins. A short irregular stepping row of small rectilinear ink/teal marks at the lower outer edges suggests walking in unison. No bubbles, stars, round confetti, cute sticker seals, hearts, big music symbols, mascot additions or baby-book shapes.
American-comic rendering: adult-facing indie American comics / printed editorial poster; bold expressive black inking, flat color plates, a few coarse Ben-Day halftone dot wedges and hatching at OUTER corners, slight print registration texture. Strong structural graphic design, not chibi, kawaii, children's storybook, pastel watercolor or glossy vector stock art.
EXACT existing oneBeat palette only: paper #FFF9EE, ink #171B1F, lilac #C5B7EB, coral #FF7056, teal #29B5AE, blue #A9C9F2. Large panel field in lilac and cream/light blue; coral/teal as restrained angular accents. REMOVE ALL yellow / butter / beige-yellow patches. No gradients, airbrush, soft glows or new colors. The existing foreground turquoise/pink/yellow characters must remain dominant.
Keep the alpha background and wide canvas; do not render a checkerboard. No text, letters, numbers, logo, watermarks, UI, people, fake QR, or full scene. Only provide the revised background asset.

### Join

Use case: precise-object-edit
Asset type: the transparent oneBeat JOIN TEAM hero background ONLY.
Edit target: Image 1 is the initial invitation backdrop. Rework its linework, shape language and print styling into mature AMERICAN COMIC BOOK editorial graphics. Preserve the 2.5:1 wide canvas, LEFT 60% clean cream writing field, RIGHT roughly 38% mainly transparent, and genuine alpha.
Page context: app already supplies a teal card, 2vp ink border, corner radius, black Chinese text on left and large cloud mascot on right. Copy and mascot are NOT in this file. Leave ALL of the left 55% blank and flat cream for native text. No illustrative detail, shadows or dots across that writing field.
Design: a graphic invitation/dispatch slip with slightly slanted STRAIGHT cut-paper edges, not a wavy scalloped baby-book sheet. Its right vertical edge around 62% width has a bold ink perforation seam, like a removable comic dispatch stub. Replace the coral circular sticker with ONE small angular coral registration tab near this seam's upper end, no symbols. Right upper/lower outer corners get sparse lilac and teal comic print fragments with sharp folded geometry and coarse Ben-Day dots. REMOVE the rounded cloud-like teal doodles. Keep the right center transparent for the existing cloud figure. Do not draw an actual envelope, giant coupon, QR code (real or fake), barcode or badge text.
Style: adult-facing indie AMERICAN COMIC editorial stationery; bold confident near-black expressive outline, deliberately irregular hatching only at tiny outer corners, flat color plates, strong graphic simplification, slight screen-print registration. Not kawaii, soft children's illustration, rounded blobs, watercolor, 3D, neon or sticker-book decoration.
Existing oneBeat colors ONLY: paper #FFF9EE, white #FFFDF8, ink #171B1F, coral #FF7056, lilac #C5B7EB, teal #29B5AE; no added butter yellow, beige gradient, pink candy tints or new palette. Large copy field is flat unshaded cream; saturated coral/lilac details small.
No overall outer border because app already draws it. No text, letters, numbers, logos, watermarks, characters, UI controls or fake text marks. Genuinely transparent right areas, no checkerboard baked in.
