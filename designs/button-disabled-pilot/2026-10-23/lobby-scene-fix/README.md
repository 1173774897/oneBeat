# 大厅场景卡淡化与文字对齐修复

2026-10-23，同试点真机 LMR-AL00，1276×2848，3.5px/vp。生产入口调试包覆盖安装验证。

- `sceneCard` 的旧 `.opacity(0.55)` 分别淡化不透明卡面与实色背板，导致背板透出；现在在包含右/下各4vp阴影的158×152vp范围先合成，再使用共享 `ACTION_DISABLED_OPACITY=0.68`。对应负外边距抵消装饰空间，卡面仍154×148vp、卡间距10vp。
- 选中态的布局边框3vp比普通1vp多挤入2vp，导致内容向右下偏移。现在布局边框固定1vp，选中覆盖层在内部补2vp，保持总3vp墨线与原圆角轮廓。覆盖层不接收触摸、不进入无障碍遍历。
- 真机两标题顶边均2034px，两说明顶边均2103px。横滑末端后Y坐标仍一致，右/下阴影完整。锁定标题点击显示“请先在收藏小铺解锁这个场景”，夕阳仍选中。
- 调试HAP构建通过。相关既有回归通过：action-button-disabled、comic-button-disabled、drum-lobby-editor-settings、lobby-initial-render、comic-shadow-policy、solo-roster-reorder。未修改权益数据以模拟解锁切换。

证据：[修复前](before.png)、[修复后](after.png)、[横滑末端](last-card.png)、[锁定点击提示](locked-notice.png)、[文字布局坐标](text-bounds.json)。

调整入口均在 `entry/src/main/ets/pages/LeaderLobbyPage.ets`：

- 文字上下优先调 `sceneCard` 文案容器 `padding.top=6vp`：增大下移，减小上移；左右 `padding.left/right=8vp` 增大会将文字向内缩。卡高148vp、预览高96vp限制底部可用余量。
- `LOBBY_SCENE_BORDER_WIDTH=1vp` 是所有卡片固定内容缩进，增大会把内容向内及下方推、减小反之。选中总墨线 `LOBBY_SCENE_SELECTED_BORDER_WIDTH=3vp` 增大只向内加粗、减小变细，不改变内容坐标；应不小于固定边框宽度。
- `LOBBY_AREA_SHADOW_OFFSET=4vp` 同时控制硬阴影X/Y，增大向右/下，减小向左/上；合成范围的padding和负margin、Scroll的末端padding和高度都跟随它，避免缓存裁切。
- 禁用透明度在 `components/ActionButton.ets` 的 `ACTION_DISABLED_OPACITY=0.68`，增大更清晰，减小更淡。预览图片资产及其分层位置未改。
