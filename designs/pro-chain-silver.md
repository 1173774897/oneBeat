# PRO 银色锁链素材

解锁态使用用户手工处理的 `/Users/lizhe/Downloads/onebeatprocessing/chains.png`；未解锁态使用 `/Users/lizhe/Downloads/onebeatprocessing/chains_lock.png`。两张图都原样复制，不重新生成或修改像素，均为 400×600 透明 PNG。

- 解锁态资源：[pro-chain-anchored.png](/Users/lizhe/work/oneBeat/entry/src/main/resources/rawfile/comic/decor/pro-chain-anchored.png)
- 未解锁态资源：[pro-chain-locked.png](/Users/lizhe/work/oneBeat/entry/src/main/resources/rawfile/comic/decor/pro-chain-locked.png)
- 上一版生成素材保留：[pro-chain-silver-star.png](/Users/lizhe/work/oneBeat/entry/src/main/resources/rawfile/comic/decor/pro-chain-silver-star.png)
- 编辑参考原图保留：[pro-chain-silver.png](/Users/lizhe/work/oneBeat/entry/src/main/resources/rawfile/comic/decor/pro-chain-silver.png)
- 接入：[LeaderLobbyPage.ets](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/LeaderLobbyPage.ets)，两种权限状态共用 `proChain` / `proDrumMachineEntryWithChain` 的锚点几何；无 PRO 权益时显示锁头铁链，解锁后显示原星形链。
- 上下对齐锚点分别为源图片 y=45 px / y=235 px，间距 190 px。两个值指向按钮外边缘，不包含阴影。
- PRO_DRUM_BUTTON_HEIGHT=56 vp，同时控制按钮底板、标题点击区和锁链缩放。增大该值会同步放大按钮与锁链；减小会同步缩小。不要独立修改图片宽高或使用按屏宽百分比缩放，否则会破坏上下对齐。
- 等比缩放 scale=56/(235-45)=0.2947368，图片显示为约 117.8947×176.8421 vp，不拉伸、不裁切。屏幕宽高只改变按钮的页面位置与宽度，不参与锁链的纵向锚点计算。
- PRO_DRUM_ENTRY_PADDING=4 vp：按钮顶部在容器 y=4，下边缘在 y=60。图片 y 偏移自动计算为 4-45×scale，约 -9.2632 vp；因此源图 45/235 两条线分别映射到 4/60 vp。增大 padding 会将按钮与锁链一起下移，并增加容器上下留白；减小则相反。
- PRO_CHAIN_OFFSET_X=-20 vp：右侧 Alignment.TopEnd 对齐后左移 20；增大（趋近 0）向右，减小（更负）向左。大厅右侧留白 18 vp，继续向右可能导致屏幕边缘裁切。没有独立的可调 Y 偏移，纵向位置由锚点自动推导。
- 按用户要求不为链尾增加占位：容器仍高 56+4×2=64 vp，clip(false)，zIndex(1)。链尾会绘制在下方状态文字和“出发”按钮上方；图片不拦截触摸，只有原按钮的 56 vp 点击区会触发 PRO 提示。
- 标题绘制在锁链上方；锁链不接收触摸。权限状态只切换图片和按钮明度，不切换几何、点击范围或已有权限校验。

## 上一版生成素材提示词（历史记录）

```text
Use case: precise-object-edit
Input image 1: EDIT TARGET and shape/style reference — the current pro-chain-silver.png provided with this request.
Asset type: transparent PNG chain overlay for the right half of a locked comic-style button.
Primary request: remake this chain arrangement with the SAME overall silhouette as input 1, but change the LOWER-RIGHT free strand into a natural hanging tail with ONE silver four-pointed star pendant attached at its very end.
Keep unchanged: the long upper-left strand sweeping downward into the crossing, the short lower-left curved strand, the rising upper-right strand, the crossing slightly right of center, elongated interlocking links, silver/pewter material, cool white metallic highlights, dark comic ink contours and subtle angular gothic bevels. Do not return to the earlier wide horizontal bow shape; follow this supplied image's diagonal crossing and downward right-side tail.
Specific edit: from the crossing, the lower-right tail hangs freely downward under gravity, nearly vertical with a slight gentle curve. It must be a visibly continuous chain attached to the crossing, not a disconnected strand. Its last closed link connects via a tiny silver bail to one pendant at the bottom. The star is a single elegant FOUR-point sparkle-shaped metal charm, with concave sides, top/bottom pointed rays slightly longer than the left/right rays, small faceted center and the same silver highlights and black outline. Exactly four points, NOT a five-point star, NOT a religious cross, NOT a plus sign. Make it legible at small UI size without turning it into the main subject.
Composition: preserve the landscape 1536x1024 canvas and the main chain proportions. Shorten the hanging tail just enough if needed to fit the pendant, and keep the pendant and all chain tips fully inside the canvas with a small transparent safety margin. Do not clip the hanging star or any links. Keep the central and left empty areas airy.
Backdrop: truly transparent alpha throughout the background and every chain-link hole. No solid black backdrop, no gray backdrop, no painted checkerboard.
Constraints: only the silver chains and the one lower-right four-point star pendant. No button, no text, no lock, no characters, no scenery, no unrelated ornaments, no gold, no glow or particles, no watermark. Retain the supplied American-comic UI style, not photorealistic jewelry photography.
```

## 初版生成提示词（历史记录）

```text
Use case: stylized-concept
Asset type: transparent PNG overlay for a mobile app's locked "PRO custom drum machine" button, not a UI mockup.
Primary request: ONLY a silver metal chain arrangement, with a very subtle gothic feeling, giving the illusion of winding around the RIGHT HALF of a shallow horizontal button. The user's supplied illustration is a mood reference for its sweeping, linked chain paths; do not reproduce its character, sword, golden light or scene.
Scene/backdrop: genuinely transparent alpha everywhere except the chain links, including all link holes and the space between the chains. No painted background.
Subject: two connected sweeping runs of elongated oval interlocking silver chain links. They cross diagonally in a loose asymmetric X, curve around at the upper-right and lower-right, with one short loose tail, suggesting two turns wrapping around an invisible horizontal bar. Keep the central area airy and the link structure legible at small UI size. No lock, no badge, no charm, no skull, no cross pendant.
Style/medium: polished hand-drawn American comic game UI asset, confident near-black ink contours, restrained cel shading, silver/pewter facets and cool white metallic edge highlights. Slight gothic elegance in the elongated link silhouettes and a few restrained angular bevels, not horror. Match a cream, lilac and coral comic UI. Avoid photorealistic 3D rendering.
Composition/framing: landscape canvas around 3:2 aspect ratio. Center the isolated winding chain silhouette in the canvas with a small transparent safety margin on every edge. The winding form is wider than tall, and can protrude above and below a button when displayed. Do NOT draw the button or invisible bar itself. All link tips fully visible, no cropped chains.
Palette: silver gray, pewter, cool white highlights, charcoal ink shadows. Absolutely no gold or green. Restrained highlights, no glow halo or magic particles.
Constraints: output a single finished transparent-background chain asset, only chains, crisp clean alpha edges, no text, no characters, no scenery, no UI/button, no frame, no watermark, no decorative background, no checkerboard painted into the pixels.
```

当前素材已检查 RGBA alpha、实际尺寸与复制前后 SHA-256 一致；用户提供的像素未被改动。

当前锚点布局已通过 ArkTS/HAP 编译与资源打包检查；几何验证覆盖 320×568、390×844、768×1024、1024×768 四类屏幕模型、1/2/3/3.5 四种像素密度，以及 40/56/72 vp 三种按钮高度，共 48 组上下锚点对齐断言。几何验证不替代 HarmonyOS 真机视觉与点击验收。

历史初版曾在浏览器合成中检查 248/354/684 px 按钮宽度；该记录不代表当前素材的真机验收。
