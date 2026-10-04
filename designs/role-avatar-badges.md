# 队伍大厅头像角标（2026-10-02）

角色选择行使用黑白剪纸角标：原黑色图形外围加纸白轮廓和 1 vp 黑色硬阴影；限免用白色切角票签。所有标签贴在人像右下角，不恢复红蓝背景框。原头像资源、48 vp 尺寸、59×54 vp 单元、横向滚动、角色排序和选择权限保持不变。

头像图片本身也做圆角裁切：选择行 6 vp，队伍成员槽位沿用原 4 vp。只裁切头像层，角标和黑色阴影留在裁切层外。

## 显示规则

- 权益未解锁：显示锁头；人像继续使用原选角状态的淡化规则，头像框及其阴影、角标不淡化。
- 当前限免：显示限免票签，不显示锁头。沿用 `limitedFreeCharacterKeys` 的有效期与权益来源判断，不提前展示未来活动。
- 可被多人选用：显示多人图标；与限免独立判断，两者可以并排，间隔 2 vp。
- 可访问的独占角色已被其他队员选用：显示「单人＋确认勾」占用角标。使用 `isExclusiveTakenByOther(members, key, editingMemberId)` 排除正在编辑的队员；自己选中、普通可重复角色、仅因自己准备而禁用不显示占用。其他队员已准备时仍显示占用；未解锁角色继续优先显示锁头。
- 限免与占用同时存在：限免在左、占用在右，间隔 2 vp，总逻辑宽度 28＋2＋16＝46 vp。人像禁用淡化时两者仍保持不透明。
- 已准备、被其他队员占用等队伍状态仍通过现有选择逻辑禁止点击，不把它们误当成权益未解锁，也不隐藏权益标签。
- 角标 `HitTestMode.None`，不截获点击；头像的选择操作仍由整个原尺寸单元处理。

## 调整入口

代码在 [LeaderLobbyPage.ets](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/LeaderLobbyPage.ets)，优先调整以下常量（单位 vp）：

- `CHARACTER_BADGE_INSET = 2`：角标组从头像右、下边缘向内缩进；增大同时向左、上移，减小向右、下移。`characterBadges.position` 按实际角标组宽、高计算，不依赖屏幕宽度。
- `CHARACTER_BADGE_GAP = 2`：组合角标的间隔；增大拉开，同时左侧角标向左移动，右侧保持右边缘锚点。限免＋占用中右侧是占用，原多人＋限免中右侧仍是限免。
- `CHARACTER_BADGE_ICON_SIZE = 16`：锁头/多人/占用图形尺寸。`CHARACTER_BADGE_ICON_PADDING = 3` 是 SVG 原始画布的透明边距，不是位置调节入口；三个 SVG 当前都为 22×22，放大图标时应同步按比例调整边距。
- `CHARACTER_FREE_BADGE_WIDTH / HEIGHT = 28 / 17`：限免票签主体尺寸；增大从右下锚点向左/上扩张，需同时检查两字 10 vp 文案和并排组合是否仍适合 48 vp 头像。票签 `rotate = -4`，更负会加大逆时针倾斜。
- `CHARACTER_PICK_SHADOW_OFFSET = 2`：头像框背后的黑色实体层向右、下偏移，增大让硬阴影更明显；这是局部阴影，不改变全项目的 `CONTROL_SHADOW`。
- `CHARACTER_PICK_CORNER_RADIUS = 6`：头像图片及框、阴影层共用圆角，增大更圆、减小更方。头像 Stack 的 `clip(true)` 使 PNG 本身遵循圆角；不要改成整个单元裁切，否则角标轮廓和阴影会被切掉。队伍成员头像在 `rosterMemberSlot` 中沿用 `borderRadius(4).clip(true)`。
- `CHARACTER_PICK_AVATAR_SIZE / TOP = 48 / 6`：保留原头像大小和位置。增大 SIZE 放大，增大 TOP 下移；受原 59×54 单元、59+10 的行间距约束。外层单元及滚动区 `clip(false)`，行底部 padding 2 容纳当前阴影。

## 素材

- [lock-cutout.svg](/Users/lizhe/work/oneBeat/entry/src/main/resources/rawfile/comic/icons/lock-cutout.svg)：基于用户提供的 `lock.svg`，保持原路径，添加纸白轮廓和黑色阴影。
- [multi-person-cutout.svg](/Users/lizhe/work/oneBeat/entry/src/main/resources/rawfile/comic/icons/multi-person-cutout.svg)：基于用户提供的 `multi-person.svg`，保持原路径，添加同款轮廓和阴影。
- [occupied-person-cutout.svg](/Users/lizhe/work/oneBeat/entry/src/main/resources/rawfile/comic/icons/occupied-person-cutout.svg)：单人剪影叠加确认勾，沿用 16 vp 图形、3 vp 纸白轮廓、1 vp 黑色硬阴影和 22×22 源画布，表示被其他队员选用。
- [limited-free-ticket.svg](/Users/lizhe/work/oneBeat/entry/src/main/resources/rawfile/comic/icons/limited-free-ticket.svg)：28×17 主体加 1 vp 硬阴影，源画布 29×18；中文仍由 ArkUI Text 绘制，避免 SVG 字体差异。

图标描边直接使用 SVG path/stroke 层，不依赖 SVG filter。旧的两份用户 SVG 保留，不修改；新版本只用于本次头像角标。框阴影使用独立不透明底层，避免透明人像或其状态透明度影响框的硬边阴影。

## 验证边界

本次验证包含 ArkTS/HAP 构建、SVG 原路径一致性及资源打包、标签宽高/右下锚点/互斥组合、选角业务代码未改动的静态检查。尚未进行真机视觉验收，需要检查小屏横向滚动、深色人像、限免和准备/占用状态。

占用角标接入追加验证：执行现有角色目录判断及页面角标方法，覆盖未占用/他人占用/本人选中、双方准备状态、随机可重复、旧 `matchman` 别名、未解锁权益优先级和限免＋占用排列。选角禁用、抢选保护和同步业务逻辑未修改。
