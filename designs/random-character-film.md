# 随机角色 · 拍点胶片

2026-10-04，已接入 ArkUI 大厅页面。

## 行为

- 大厅初始化完成、真实编辑队员存在且胶片完成测量后，尚未完成的默认随机角色自动播放一次；这两个条件完成的先后顺序不影响触发。已有完成状态的队员直接展示停靠剪影，不重播。
- 每次可用的随机角色点选都递增播放请求，包括当前已经选中随机时。普通队伍快照、权益刷新和窗口宽度改变不重播。
- 横向胶片约 1600 ms 连续减速，中央定位框不移动；最终停靠完成后通知队长，统一显示抽中人物的黑色剪影。中间卡片和队伍槽位的问号同时按共享状态替换，配色仍留到出发后揭晓。普通角色预览和胶片都保留原来的 250 vp 高度，选角行不跳动。
- 队员发送请求可能先于队长快照返回。从普通角色切换随机时，在确认随机之前保留胶片，避免中途卸载后再次播放；同步失败清理临时展示并沿用原有提示。
- 普通角色点选立即取消旧动效；切换编辑队员、隐藏/离开页面会使旧定时器和动画回调失效。未完成且没有切换 active 的随机预览返回页面时仍自动播放；已完成或已切换中断的队员只恢复静态停靠结果。
- 播放中切换 active（包括成功增加人机后的自动切换），先完成原队员的本次抽取：已存在的结果直接发布到队伍头像，联机仍按统一校时时刻同步。切回该队员不再播放或重抽；只有明确点选随机角色才生成新版本并重新播放。
- 如果切换时新抽取仍等待队长确认，保留该队员需要的最小抽取版本，迟到快照到达后即使该队员不再 active 也发布结果。快速切走/切回不降低所需版本，旧结果不能冒充新一轮；移除队员、主动选择新角色或离开页面会清理对应临时状态。
- 删除后重新添加的人机使用新的成员身份与抽取版本，不复用已删除队员的完成缓存；新随机角色正常播放胶片，结束后更新头像。人机 ID 在当前 SessionController 生命周期内递增（即使清空人机也不回退），不是可复用槽位编号。
- 新队员 ID 与 skipPlayback 属性的 watcher 无论谁先到，都只启动一次新预览：旧完成标记解除后补启动；若结果属性已启动新队员，后到的成员 watcher 不再取消其启动定时器。快速删除/添加即使合并为一次渲染也会按新成员身份播放，旧回调失效。
- 选角权限、独占/准备禁用、随机池、配色槽和出发揭晓规则均不改变。实际结果只取 SessionController 的 resolvedAvatarKey；迟到的结果先进行 240 ms 剪影停靠校正，再通知完成，不增加抽取或揭晓彩色角色。

## 队伍剪影同步

- 每轮随机角色都有队长生成的 `randomDrawId`；再次抽中同一人物也生成新版本并清除之前的显示状态，避免旧动画结束通知揭晓新一轮结果。
- `RANDOM_PREVIEW_COMPLETE` 只携带版本，不接受队员自报人物或替换他人的成员 ID。队长根据已认证连接定位队员，验证版本后发布 `randomAvatarRevealAtLeaderMs`；队长仅能完成自己的或单人模式下人机的预览。
- 全队使用已有单调时钟校时，在同一队长时刻将问号替换为剪影。联机预留 `SessionController.ets` 中 `RANDOM_AVATAR_REVEAL_LEAD_MS = 250` ms，让快照在显示前到达；增大缓冲可容忍更慢网络，但胶片结束后的等待也变长。单人模式不等待。
- 网络延迟超过缓冲时，晚到设备收到快照后立即补显；真实网络不能保证零毫秒误差。新加入设备从快照恢复已经显示的剪影，不依赖之前的动画事件。
- 显示状态按抽取版本单向锁定，轻微校时回调不使已显示的头像退回问号；重新抽取/换普通角色清理旧状态，断开会停止显示定时器。
- `RandomCharacterFilm.skipPlayback` 从队员的已发布截止时刻或当前页面的中断记录读取。重新挂载和恢复完成结果只进行 0 ms 停靠，不调用角色抽取；明确重抽的 `selectionPending` 仍允许完整播放。切换的结果发布复用现有完成消息与控制器鉴权，不改变协议、随机池或配色。
- `ComicCharacter.mysteryAvatar` 仅接受有效随机池人物，队伍槽位仍为 `LeaderLobbyPage.ets` 中 `.width(43).height(43)`，位置和裁切未变；增大宽/高放大头像且可能增加槽位占用。图片容器为 100%×100%、ImageFit.Contain；使用下方既有 mystery 资源，不加载彩色头像配色。

## 代码入口

- `entry/src/main/ets/components/RandomCharacterFilm.ets`：纸卡、齿孔、中央框、节拍标记与动画生命周期。
- `entry/src/main/ets/pages/LeaderLobbyPage.ets`：`randomPreviewReady()`、`pickCharacter()`、`refresh()`、`onPageShow()/onPageHide()` 和角色预览分支。
- `entry/src/main/ets/session/SessionController.ets`：版本校验、完成通知、共享显示时刻及显示定时器。
- `entry/src/main/ets/protocol/messages.ets`：新增完成通知类型及两个可选快照字段，未更改既有消息和随机池。
- `entry/src/main/ets/components/ComicKit.ets`：随机角色的头像可显示已确认的剪影，选角入口本身继续显示问号。

## 调整入口（均在 RandomCharacterFilm.ets，单位 vp，时长为 ms）

| 控制项 | 当前值 | 调整效果与约束 |
| --- | --- | --- |
| `RANDOM_FILM_HEIGHT` | 250 | 增大预览区更高、下方选角行下移；普通角色共用该值。 |
| `FILM_SIDE_INSET` | 12 | 增大左右留白、缩小可见胶片窗口；中心使用实际测量宽度自动重算。 |
| `FILM_REEL_TOP` | 39 | 增大胶片整体下移；它是上方标题行高度，优先用它调整胶片纵向位置。 |
| `FILM_REEL_HEIGHT` | 181 | 增大胶片裁切窗口高度，页脚剩余高度随之减少；与总高度/标题高度共同限制可用空间。 |
| `FILM_CARD_WIDTH / HEIGHT` | 116 / 150 | 增大纸卡横向/纵向尺寸；间距和停靠位移自动使用同一宽度，但需同步调整定位框尺寸。 |
| `FILM_CARD_GAP` | 14 | 增大纸卡之间间隔，移动总距离同步增加，停靠仍居中。 |
| `FILM_CARD_TOP` | 14 | 增大纸卡在窗口内向下移动；中央框 `FILM_FOCUS_TOP` 应同步调整。 |
| `FILM_FOCUS_WIDTH / HEIGHT / TOP` | 120 / 154 / 12 | 增大宽/高使中央框扩大；增大 TOP 使框下移。珊瑚环 `FILM_FOCUS_RING = 6` 增大变厚。 |
| `FILM_ROLL_MS` | 1600 | 增大播放更慢，减小更快；节拍标记时点在 `startBeatTicks()` 的 delays 中。 |
| `FILM_RESULT_ALIGN_MS` | 240 | 增大迟到结果校正更慢；不触发完整重播。 |

剪影使用原资源（未改动）：

- `/Users/lizhe/work/oneBeat/entry/src/main/resources/rawfile/comic/mystery/braids.png`
- `/Users/lizhe/work/oneBeat/entry/src/main/resources/rawfile/comic/mystery/boonie.png`

`filmCard()` 中 `FILM_IMAGE_WIDTH = 102` / `FILM_IMAGE_HEIGHT = 126` 控制剪影容纳范围（ImageFit.Contain 保持比例），增大时图片可放大；`.position({ x: 5, y: 11 })` 增大 x/y 分别右移/下移。纸卡外层的位置与裁切窗口仍限制可见范围。问号为 65 vp、位置 `{ x: 0, y: 28 }`，不修改原图。

## 验证

- 方法级假时钟测试覆盖初始化/测量顺序、默认随机、重复点选、普通同步不重播、迟到结果、取消、切换队员、页面隐藏/返回、异步请求竞态、窄宽窗口居中与禁用选择。测试直接提取当前 ArkTS 的真实方法运行。
- 当前动画/页面测试 51 项、控制器/消息同步测试 19 项通过；使用真实 SessionController 与真实页面方法验证删除/添加、连续 5 轮、播放中删除、批量渲染、完成标记/身份 watcher 两种顺序；也保留切回无重播、显式重抽、迟到结果/旧版本保护与全队统一显示的回归覆盖。
- 现有限免/占用标签 15 项回归保持通过，限免在左、占用在右的实现未改动。
- 客户端 assembleHap 已成功；目录中已有的弃用 API 和可抛异常告警不在本次范围。
- 方法测试和编译不代替原生渲染验收；尚未在真机/模拟器目测动画帧率、字体和裁切。
- 完成通知与新显示字段需要全队设备运行当前新版客户端；未进行真实多设备局域网联调。

验证脚本及本轮记录：`/Users/lizhe/.codex/visualizations/2026/10/01/01a0f634-5a2d-7ce1-9fb7-7ca18dcc1ab3/random-selector-design/implementation/`。

队伍剪影同步追加验证：`/Users/lizhe/.codex/visualizations/2026/10/01/01a0f634-5a2d-7ce1-9fb7-7ca18dcc1ab3/random-selector-design/team-silhouette-sync-2026-10-04/`。

Active 切换行为追加验证：`/Users/lizhe/.codex/visualizations/2026/10/01/01a0f634-5a2d-7ce1-9fb7-7ca18dcc1ab3/random-selector-design/active-switch-2026-10-04/`。本轮没有修改位置、尺寸、素材或动画时长。

删除/重新添加追加验证：`/Users/lizhe/.codex/visualizations/2026/10/01/01a0f634-5a2d-7ce1-9fb7-7ca18dcc1ab3/random-selector-design/remove-readd-2026-10-04/`。同样未修改布局、资源或随机分配规则。
