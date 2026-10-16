# B · 节拍工作台实施

## 行为

编辑器采用居中浮层，保留墨色标题、纸色格子区域和固定操作栏，以及八个音色、段落、拍号、小节及原有格子编辑功能。浮层四周露出半透明遮罩，外层承载圆角描边和硬阴影，内层裁切圆角标题。左侧音色标签固定，横向仅滚动格子；短屏可纵向滚动标签与格子，操作栏保持可见。

试听从竖线当前位置开始，支持停在两个格子之间的小数位置。停止前先读取最新 transport 快照，再停止音频并保留竖线与当前可见区域。若停止采样恰好跨屏，仅跟随一次以显示新位置；停止后允许自由查看格子。点击上方步编号可定位，停止时仅定位，试听中定位会重启到所选位置。修改正在试听的草稿时也从当前进度播放新内容。小节末尾保持完整小节循环。

关闭、应用、返回、离页或打开新的编辑器会清理试听与位置。底部保留试听和应用，退出编辑统一使用右上角关闭按钮。过期的异步加载、失败或计时回调不能覆盖新试听。音频 PCM 本身按起点定位，视觉与实际播放使用同一时间轴。

## 布局调整入口

源文件：`entry/src/main/ets/pages/DrumMachinePage.ets`。

| 主调整项 | 当前值 | 增减效果与约束 |
| --- | --- | --- |
| `DRUM_EDITOR_OVERLAY_SIDE_INSET` / `OVERLAY_VERTICAL_INSET` | 16 / 24 vp | 优先调浮层四周留白；增大左右值会使浮层收窄，增大上下值会使浮层变矮，上下另加系统安全区；减小相反 |
| `DRUM_EDITOR_PANEL_MAX_WIDTH` / `PANEL_MAX_HEIGHT` | 560 / 720 vp | 居中面板填充遮罩内留出的可用空间，受这两个最大值限制；增大仅在可用空间足够时扩大面板 |
| `DRUM_EDITOR_PANEL_RADIUS` | 16 vp | 增大面板四角更圆，减小更方；外框和内层裁切使用同一半径 |
| `DRUM_EDITOR_CELL_WIDTH` | 22 vp | 优先调格子宽度：实际按钮、步编号、拍子分组、竖线和翻页都跟随此值；增大更宽、每屏更少，减小更窄、每屏更多 |
| `DRUM_EDITOR_CELL_GAP` / `BUTTON_WIDTH` | 间隙 4 vp；按钮宽 `max(1, CELL_WIDTH - CELL_GAP)`，当前 18 vp | 按钮宽度自动从列宽扣除总间隙，不再独立固定，避免列宽调小后重叠；增大 GAP 会缩窄按钮、扩大间隔，减小相反 |
| `DRUM_EDITOR_CELL_RADIUS` | 8 vp | 增大格子更圆，减小更方；边框半径与背景裁切一致 |
| `DRUM_EDITOR_LABEL_WIDTH` | 64 vp | 增大标签栏更宽、格子区域起点右移并减少可见步数 |
| `DRUM_EDITOR_MIN_ROW_HEIGHT` / `MAX_ROW_HEIGHT` | 36 / 56 vp | 增大会提高行高下限／上限，格子更高，后续音色向下移动；短窗口通过纵向滚动显示完整八行 |
| `DRUM_EDITOR_ROW_HEIGHT` | 初始 40 vp | 仅为首次测量前的行高；优先调整上面的上下限。实际行高由 `updateEditorGridViewport()` 随可用高度计算 |
| `DRUM_EDITOR_HEADER_HEIGHT` / `BEAT_HEIGHT` | 56 / 24 vp | 增大前者会增高编号区域并使音色行、竖线顶部下移；编号点击区域为两者之差，当前 32 vp |
| `DRUM_EDITOR_PLAYHEAD_WIDTH` | 2 vp | 增大竖线更粗；横坐标由 `editorPlayheadX()` 按步进与格宽计算，并限制在格子范围内 |
| 竖线高度与起点 | `editorTracksHeight()`，`y = HEADER_HEIGHT` | 高度随八行总高度变化，确保贯穿所有音色；增大 y 会下移竖线 |
| `DRUM_EDITOR_PLAYHEAD_CAP_WIDTH` 与 `Polygon` | 宽 10、高 7；`y = BEAT_HEIGHT - 7` | 增大宽度会扩大三角；增大 y 会下移。三角在编号上方，不遮挡文字，也不截获点击 |
| 标题 `Column.padding` | 左 20、右 16、上 14、下 18 vp | 增大上边距使标题下移；增大左右边距使内容内缩。系统安全区由遮罩外边距统一留出，标题不再占据状态栏 |
| `DRUM_EDITOR_ACTION_HEIGHT` / 底部 `Row.space` | 48 / 8 vp | 增大前者使按钮更高，增大后者拉开按钮并压缩按钮宽度 |
| 试听／应用 `layoutWeight` | 1.2 / 2 | 增大某个权重会让该按钮占更多宽度；整行受屏幕宽度和左右内边距限制 |
| 底部 `Row.padding` | 左 12、右 14、上 14、下 16 vp | 增大下边距使按钮上移，减小则下移；上边距增大会加大分隔线和按钮的距离。系统底部安全区已移至浮层外层，内部不重复留出 |

播放／停止图标使用已有的 `entry/src/main/resources/rawfile/comic/icons/play.svg` 与 `stop.svg`，由操作栏中 `Image.width(17).height(17)` 控制图标大小。

## 验证

- `scripts/tests/drum-editor-preview.cjs`：草稿、数字定位、连续定位竞态、小数位置续播、停止采样与保留、循环跟随、退出清理和响应式布局。
- `scripts/tests/metronome-drum-preview-seek.cjs`：实际 PCM 起点、完整小节循环、视觉时间轴、路由恢复及普通同步播放复原。
- `scripts/tests/run-sync-regressions.cjs`：16 个音频／同步套件。
- ArkTS 编译与签名 HAP 打包。

以上软件检查已通过。已确认有两台设备连接，但本轮未切换其前台应用、安装或操作新界面，尚未完成真机画面与触摸验收。
