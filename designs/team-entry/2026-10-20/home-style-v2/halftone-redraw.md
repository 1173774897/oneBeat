# 网点重绘与调节

2026-10-20 按最终两张设计图重新绘制网点。本说明替代 `implementation.md` 中旧版网点的定位说明；角色、植物、文字、按钮和连接逻辑沿用本轮开始时的工作区内容。

## 形状

旧版使用直立三角形、逐行变大、底部大圆点直接截断，并在多个位置重复镜像。新版采用 -27° 的错行点阵，按倾斜椭圆和独立角部轮廓逐渐缩小圆点，保持中心实色，边缘形成弧形渐隐；云朵背后额外对左右边缘收点，避免独立插画出现矩形切边。

素材均为原生 SVG 圆形几何，未改角色原设。素材目录：`entry/src/main/resources/rawfile/comic/decor/`。

票根当前在 `TeamEntryVisuals.ets` 通过 `Image.fillColor` 统一着色：创建队伍 `CAPTAIN_HALFTONE_COLOR=#FFC1AF`（浅珊瑚），加入队伍 `MEMBER_HALFTONE_COLOR=#D7C5F2`（浅紫，含加入页票根）。修改这两个常量即可调整颜色。下列 SVG 为原色底稿，着色不改变其点阵几何，页头与云朵背后的网点继续使用素材原色。

- `ticket-halftone-ink.svg`：队长左上黑色点阵。
- `ticket-halftone-ink-corner.svg`：队长右下与队员左下黑色点阵。
- `ticket-halftone-lilac.svg`：队员右侧及加入票券右侧紫点阵。
- `ticket-halftone-lilac-corner.svg`：加入票券左下紫点阵。
- `ticket-halftone-coral.svg`：品牌与云朵背后的珊瑚色斜向点阵。
- `ticket-halftone-ink-cloud.svg` / `ticket-halftone-lilac-cloud.svg`：云朵背后独立黑/紫点阵。

## 票券位置与大小

优先修改 `entry/src/main/ets/components/TeamEntryVisuals.ets` 的 `printedHalftone()`；单位为 vp。

- `TICKET_HALFTONE_SCALE=1`：控制所有票券网点的宽高。增大放大，减小缩小；右侧点阵同时按宽度向内扩展。可用区域受票券轮廓裁切限制。
- 队长上方：72×126，`CAPTAIN_HALFTONE_TOP_X=-16`、`CAPTAIN_HALFTONE_TOP_Y=25`。X 增大右移，Y 增大下移；不要移入标题笔画的主要区域。
- 队长右下：100×122，X=票宽−92、Y=撕线−137，水平镜像。X 增大右移；将 137 调大则上移，调小则下移。
- 队员右侧：96×168，X=票宽−90，`MEMBER_HALFTONE_TOP_Y=72`。Y 增大下移；减小 90 使点阵右移。
- 队员左下：70×85.6，X=0、Y=撕线−108。108 增大则上移。
- 加入票券右侧：70×122.5，X=票宽−62、Y=撕线−55。55 增大则上移。
- 加入票券左下：82×100，X=-6、Y=票高−100。X 增大向右；末尾 100 增大则向上。

`TeamTicketBackdrop.halftone` 由页面传入 `captain` / `member` / `join`。网点在纸面填色之后、描边之前绘制，并使用与票券完全相同的 `PathShape` 轮廓裁切。调整缺口或票券大小时不需要另设一个网点裁切轮廓；装饰不参与点击或无障碍焦点。

## 页头与云朵位置

- `entry/src/main/ets/pages/TeamPage.ets` 的 `slogan()`：珊瑚色素材 `ticket-halftone-coral.svg` 显示为 78×124.8，X=内容宽−82、Y=-42。Y 增大下移；减小 82 使点阵右移，宽高增大放大。
- `entry/src/main/ets/pages/MemberJoinPage.ets` 的 `invitationHero()`：插画由人物、植物和网点组成一组，保留原 246vp 完整占位宽。`JOIN_HERO_TEXT_WIDTH_RATIO=0.56` 保持左侧文字宽度，`invitationArtworkX()` 用 `文字宽 + (内容宽 − 文字宽 − 246) / 2 + JOIN_HERO_ILLUSTRATION_X_OFFSET` 将整组在右侧剩余区域居中。优先调 `JOIN_HERO_ILLUSTRATION_X_OFFSET=0`：增大向右、减小向左，不改变任何图片的大小。
- 组内珊瑚网点 `ticket-halftone-coral.svg` 仍为 142×227.2，局部位置 (8,-28)；黑网点 `ticket-halftone-ink-cloud.svg` 104×94.5，局部位置 (10,5)；紫网点 `ticket-halftone-lilac-cloud.svg` 120×200，局部位置 (94,-8)。局部 X/Y 增大分别右/下移，宽高增大放大。各层以插画组左上角为原点。
- 人物素材 `entry/src/main/resources/rawfile/comic/poses/cloud-phone.png` 保持 `JOIN_HERO_ART_WIDTH=230`、`JOIN_HERO_ART_HEIGHT=276`，组内位置 (0,`JOIN_HERO_ART_Y=-12`)；植物 `entry/src/main/resources/rawfile/vegetation/plant_06.png` 保持 92×92、组内 (7,102)，`plant_11.png` 保持 84×84、组内 (162,110)。整体水平移动统一使用前述组偏移，单张图的位置只是次级调整点。
- 插画总高度仍为 `JOIN_HERO_HEIGHT=180`。`RectShape` 维持原竖直裁切，右侧裁切放宽至原页面 18vp 留白，避免保留原尺寸后切掉手机；最终仍受物理屏幕边界限制。

## 重绘点阵

生成脚本：`designs/team-entry/2026-10-20/home-style-v2/redraw_halftones.py`。

运行 `python3 designs/team-entry/2026-10-20/home-style-v2/redraw_halftones.py` 可重建七张 SVG。

- `DOT_PITCH=15`：增大使点阵更稀，减小更密；不直接改变整张图片的显示尺寸。
- `GRID_ANGLE=-27`：改变点阵排列方向；角度更大为顺时针旋转。
- `PATCHES[].max_dot_radius=5.0–5.7`：增大加重核心墨点，减小更轻；宜小于半个点间距，避免相邻点连片。
- 各素材的 `center_x/center_y` 控制浓密中心，增大分别向右/下；`radius_x/radius_y` 增大扩大覆盖，`tilt` 改变弧形区域倾斜。

## 真机与验证

最终截图：`halftone-device-checks/`。Pura X、Pura 80 Pro 已更新并检查多人练习及加入页面，包含票券缺口裁切、标题周边留白、紫色点阵的边缘渐隐。编译通过，页面生命周期、昵称和建队/扫码/加入码连接方法与修改前一致。
