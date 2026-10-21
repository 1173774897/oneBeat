# 双票券多人练习与加入页实施

实施日期：2026-10-20。按本目录最终两张设计图落地，页面控件均为 ArkUI 原生交互，不以整图覆盖界面。

网点已随后单独重绘，以下旧网点定位请以 [网点重绘与调节](halftone-redraw.md) 为准。

## 最终效果

| 设备 | 多人练习 | 加入队伍 |
| --- | --- | --- |
| Pura X | [真机截图](device-checks/pura-x-entry.jpeg) | [真机截图](device-checks/pura-x-join.jpeg) |
| Pura 80 Pro | [真机截图](device-checks/pura-pro-entry.jpeg) | [真机截图](device-checks/pura-pro-join.jpeg) |

多人练习采用一红一白的队长/队员双票券、浅紫按钮、黑色硬阴影，保留大块网点和小植物。昵称、随机昵称与未填昵称提示保留。整张票券只有一个点击目标，底部操作区不会重复跳转。

加入页采用原云朵手机角色及同风格纵向票券，扫码为主操作，六位数字加入码为第二操作。加入码仍为一个原生输入框，支持粘贴、删除、数字键盘和无障碍；空白横线仅作装饰。少于六位时禁用，六位时启用；扫码、连接中同时禁用相关操作。按钮直接读取页面状态，避免 ArkUI 部分运行时把 Builder 的基础类型参数保留为初始快照。

加入码按钮禁用时整体采用与 PRO 定制鼓机入口相同的 `JOIN_DISABLED_OPACITY=0.68`，连同文字、描边和阴影一起淡化。通过包装容器的 `enabled(false)` 屏蔽整块点击区域，按钮同时关闭 `stateEffect` 和焦点；这避免了系统对原生禁用按钮再次叠加淡化，也不会出现点击闪烁。恢复六位后重启点击和按压反馈。禁用阴影 `JOIN_DISABLED_SHADOW_RADIUS=1`，偏移 X=2、Y=3；增大半径使阴影更柔，增大偏移分别向右/下移动，透明度数值调大更清晰、调小更淡。正常态仍使用原有实色底层阴影。

沿用原角色 PNG、植物与品牌素材。新增网点、Wi-Fi、扫码、下划线和节拍短线使用 SVG，以保持多密度下的清晰边缘。无须重新生成或修改角色原设。

## 调整布局

以下单位均为 vp。优先改页面顶部常量，不改全局安全区；安全区由系统提供。小屏高度不足时页面可滚动。

### 多人练习

源文件：`entry/src/main/ets/pages/TeamPage.ets`。

| 调节项 | 当前值 | 调大 / 调小的效果与约束 |
| --- | --- | --- |
| 页面左右 `TEAM_PAGE_SIDE_INSET` | 18 | 调大使整页左右留白增加、两票券变窄；调小相反。 |
| 页面顶部 `TEAM_PAGE_TOP_INSET` | 8 | 在系统安全区之外调大，整页下移；调小上移。 |
| 页面底部 `TEAM_PAGE_BOTTOM_INSET` | 24 | 调大给底部手势条更多留白，在自适应高度范围内同时缩短票券。 |
| 票券间距 `TEAM_TICKET_GAP` | 12 | 调大使两票券分得更开并各自变窄。 |
| 票券高度 `TEAM_TICKET_MIN_HEIGHT` / `TEAM_TICKET_MAX_HEIGHT` | 336 / 448 | 优先调最大高度来改变长屏票券长度；中短屏由 `ticketHeight()` 根据剩余空间计算，最低高度不压缩，必要时滚动。 |
| 昵称后间距 `TEAM_NICKNAME_BOTTOM_GAP` | 14 | 调大把票券起点下推；自适应高度下会相应缩短票券。 |
| 头图占位 `TEAM_HERO_HEIGHT` | 70 | 调大把昵称及下方内容下推，并占用票券可用高度。 |
| 品牌 `TEAM_BRAND_WIDTH` / `TEAM_BRAND_HEIGHT` | 110 / 82 | 调大放大品牌；受右侧空间及标语右留白 106 限制。 |
| 品牌 `TEAM_BRAND_X_OFFSET` / `TEAM_BRAND_Y` | 3 / -23 | X 调大右移；Y 调大下移。X 以内容区右缘减去品牌宽度为基点。 |
| 角色纵向 `TEAM_ROLE_CHARACTER_Y` | 0 | 调大向下、调小向上；角色受插画区裁切，底部应保留脚部。 |
| 角色大小 `characterHeight()` | `min(插画区高度, 票券宽度 × 1.5)` | 优先改乘数：调大增加窄票券角色高度，仍受插画区高度限制；宽度固定为票券宽，图片等比完整显示，底部对齐。 |
| 植物 `TEAM_ROLE_PLANT_SIZE` | 52 | 调大左侧花丛；其 Y 根据尺寸抵消以保持底部落地。右植物 42×42，位置 X=票券宽−47、Y=插画高−45，X/Y 增大向右/下。 |
| 底栏前距 `TEAM_FOOTER_TOP_GAP` | 16 | 调大使底栏与票券距离增加，自适应票券相应缩短。 |

图片路径：

- 品牌：`entry/src/main/resources/rawfile/comic/brand/onebeat_wordmark.png`，位置/大小由上述 `TEAM_BRAND_*` 控制。
- 队长/队员：`entry/src/main/resources/rawfile/comic/poses/mismatch.png`、`entry/src/main/resources/rawfile/comic/poses/wave.png`，由 `roleArtwork()` 的 `width(ticketWidth())`、`height(characterHeight())` 和 `TEAM_ROLE_CHARACTER_Y` 控制。
- 植物：`entry/src/main/resources/rawfile/vegetation/plant_06.png`、`plant_08.png`，由 `roleArtwork()` 的尺寸和 `position` 控制。
- 网点：`entry/src/main/resources/rawfile/comic/decor/ticket-halftone-{ink,lilac,coral}.svg`。`roleArtwork()` 左图 110×170，位置 (-38,-16)；右图 120×190，位置 (票券宽−90,插画高−190)，水平镜像。X/Y 调大右/下移，宽高调大放大网点；插画区会裁切越界部分。页头珊瑚网点 76×108，X=内容宽−68、Y=-28。
- 标语下划线：`entry/src/main/resources/rawfile/comic/icons/ticket-underline.svg`，`slogan()` 中 104×9，位置 (64,47)。X/Y 增大右/下移。

### 加入队伍

源文件：`entry/src/main/ets/pages/MemberJoinPage.ets`。

| 调节项 | 当前值 | 调大 / 调小的效果与约束 |
| --- | --- | --- |
| 页面左右 `JOIN_PAGE_SIDE_INSET` | 18 | 调大左右留白、缩窄票券和输入框。顶部为安全区+8，底部为安全区+12。 |
| 邀请区 `JOIN_HERO_HEIGHT` | 180 | 调大把票券及底栏下推，植物随底边下移；小屏可滚动。 |
| 云朵 `JOIN_HERO_ART_WIDTH` / `JOIN_HERO_ART_HEIGHT` | 230 / 276 | 调大放大；图片等比显示。插画区高度 180，刻意裁掉下半身。 |
| 插画组 `JOIN_HERO_ILLUSTRATION_X_OFFSET` / 云朵 `JOIN_HERO_ART_Y` | 0 / -12 | 优先调整组的 X 偏移：调大整组右移，调小左移；Y 调大只将云朵下移。组本身在文字之外的剩余列居中。 |
| 左侧文字 `JOIN_HERO_TEXT_WIDTH_RATIO` | 0.56 | 保持原 56% 文字占位。调大将插画组的居中基点右移，调小左移；不要用它代替整组 X 偏移微调。 |
| 票券总高 `JOIN_TICKET_HEIGHT` | 360 | 与扫码 156、分隔 24、输入 180 三项之和保持一致；单改总高不会自动放大内容。 |
| 扫码/分隔/加入码高度 | `JOIN_SCAN_HEIGHT=156` / `JOIN_DIVIDER_HEIGHT=24` / `JOIN_CODE_HEIGHT=180` | 调大前一区域会把后一区域下推，需同步总高；撕线跟随扫码区和分隔区中线。 |
| 票内左右 `JOIN_CONTENT_INSET` | 20 | 调大输入及按钮向内收窄，左侧内容右移。 |
| 按钮 `JOIN_ACTION_HEIGHT` | 46 | 调大增加点击高度，需同步预留区域高度避免挤压提示。 |

图片路径与次级定位：

插画现在共用 `invitationArtworkX()` 的居中位置：`文字宽 + (内容宽 − 文字宽 − 246) / 2 + X偏移`。246 是原来人物、网点及右侧花丛的完整占位宽，不缩放各图片。整组垂直位置为 0，高度仍为 180；裁切范围向右覆盖原页面 18vp 留白，使居中后的手机不在内容区边界被切开，竖直裁切范围保持原样。最新局部定位见 [网点重绘与调节](halftone-redraw.md) 的“页头与云朵位置”。

- 云朵：`entry/src/main/resources/rawfile/comic/poses/cloud-phone.png`，由上述 `JOIN_HERO_ART_*` 控制。
- 邀请区植物：`vegetation/plant_06.png` / `plant_11.png`。`invitationHero()` 中 92×92、84×84；组内 X=7 / 162，Y=邀请区高−92+14 / 邀请区高−84+14。X/Y 调大向右/下，图片本次尺寸不变。
- 邀请区网点：使用 `ticket-halftone-coral.svg`、`ticket-halftone-ink-cloud.svg`、`ticket-halftone-lilac-cloud.svg`，尺寸及坐标见下面的最新重绘说明。整体移动优先调组的 X 偏移，不分别改每一层。
- 票内紫网点：`joinTicket()` 中右侧 72×110，位置 (内容宽−76,扫码区高−40)；左下 65×92，位置 (3,票高−104)。X/Y 调大向右/下，注意不要进入输入值和主文字区域。
- 扫码图标：`entry/src/main/resources/rawfile/comic/icons/ticket-scan.svg`，`scanMethod()` 44×44，外框 48×44；节拍短线 `ticket-beat-marks.svg` 20×18，平移 (11,-4)。调大平移 X/Y 向右/下。

### 共用票券和底栏

源文件：`entry/src/main/ets/components/TeamEntryVisuals.ets`。

- `TEAM_TICKET_SHADOW_X=4`、`TEAM_TICKET_SHADOW_Y=5`：分别调大使硬阴影向右、向下移动；注意页面边缘留白。
- `TICKET_CORNER=9`：调大增加切角长度；`TICKET_NOTCH=8`：调大加深票券两侧缺口。
- `firstNotchY` 默认 52；加入页传 96。调大向下移动第一组缺口。`tearY` 调大向下移动撕线及第二组缺口，页面已按操作区边界传入。
- Path 几何统一由 vp 转 px，避免两种屏幕密度下缺口和撕线错位。
- `TeamWifiFooter` 总高 28，内部两块间距 10，Wi-Fi 素材 `entry/src/main/resources/rawfile/comic/icons/ticket-wifi.svg` 显示 22×19。调大间距让两块更分开，需考虑窄屏总宽。

## 验证与范围

- `assembleHap --no-daemon` 成功，已安装到 Pura X 与 Pura 80 Pro。
- 真机检查：两页完整显示、网点/原角色/植物、空昵称阻止跳转、随机昵称、整卡进入加入页、队长进入原大厅、五位码禁用/六位码启用、原生数字输入、系统扫码打开及取消返回。
- `scripts/tests/member-join-session-reset.cjs` 通过：重置屏障、连接进度、扫码取消、失败提示、离页回调隔离。
- `scripts/tests/session-reset-lifecycle.cjs` 通过：并发清理、确认释放、失败重试、旧会话延迟退出。
- 与实施前备份比较，TeamPage 原昵称/跳转方法、MemberJoinPage 生命周期及扫码/加入码/P2P 连接方法保持原文；未改音频播放、时钟或同步调度。
- 本轮为入口界面改造，未重新测量双机音频同步误差。仓库已有首页、录制/AEC 等未提交工作均保留。
