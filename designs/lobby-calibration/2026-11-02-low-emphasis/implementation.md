# 单人大厅耳机校准 · 设置卡内收纳

2026-11-02，按选定方案落地到 `entry/src/main/ets/pages/LeaderLobbyPage.ets`。

入口位于普通“队长设置”卡底部；使用 PRO 鼓机时，位于鼓机编排卡底部。原来鼓机与出发之间的单人文字入口已移除。保持可选、低强调：灰字、细分隔线、整行可点，不改变出发条件或既有试音确认流程。

## 状态

| 条件 | 标题 | 辅助说明 | 操作 |
| --- | --- | --- | --- |
| 当前耳机输出，没有与连接绑定的校准 | 蓝牙耳机校准 | 声音与画面不同步时使用 | 校准 › |
| 当前连接已校准，补偿可为0 | 蓝牙耳机已校准 | 保持当前连接，需要时可重测 | 重测 › |
| 有校准记录，耳机重新连接 | 蓝牙耳机已重连 | 已保留原校准，可按需重测 | 重测 › |
| 无当前无线耳机输出 | 整个入口及分隔线隐藏 | — | — |

显示门槛为 `shouldShowSoloCalibrationEntry()` 中的 `soloTeam && btAudioActive`。`btAudioActive` 来自当前首选无线音频输出，不以蓝牙开关或配对列表代替。有线、外放不显示此无线播放补偿入口。校准状态沿用 `hasBluetoothCalibration()`：保存值非负且绑定当前会话连接；仅有历史持久化数值不会误报当前连接已校准。

## 位置、字号和图片调整

首选源码均为 [LeaderLobbyPage.ets](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/LeaderLobbyPage.ets:150)。`soloLatencyCalibrationEntry()` 是共用布局入口，两个卡片仅分别调用，不应只修改其中一处。

| 参数 | 当前值 | 调整效果与次级约束 |
| --- | --- | --- |
| `SOLO_CALIBRATION_DIVIDER_GAP` | 8vp | 增大让分隔线下方校准行下移并拉高卡片；减小收紧。分隔线上方还受普通设置 `Column.space=13` 或鼓机 `DRUM_CARD_CONTENT_GAP=12` 影响 |
| `SOLO_CALIBRATION_MIN_HEIGHT` | 48vp | 增大整行触控区更高；文字增大或换行时仍可继续增高，避免改为固定高度裁切 |
| `SOLO_CALIBRATION_VERTICAL_PADDING` | 上下各6vp | 增大增加行内留白；受48vp最小高度影响，小幅变化不一定改变整行高度 |
| `SOLO_CALIBRATION_CONTENT_GAP` | 8vp | 增大拉开图标、文案、右侧操作的横向间距，压缩文案可用宽度 |
| `SOLO_CALIBRATION_FONT_SIZE` / `SOLO_CALIBRATION_HINT_SIZE` | 12 / 11 | 增大分别放大主文案及说明，必要时行高会增加 |
| `SOLO_CALIBRATION_ICON_SIZE` | 16vp | 增大放大耳机图标，素材为 [headphones-calibration.svg](/Users/lizhe/work/oneBeat/entry/src/main/resources/rawfile/comic/icons/headphones-calibration.svg) |

铁链已按用户反馈恢复原定位：单人和组队统一使用 `proChain()` 的按钮上下沿锚点缩放，链尾可以自然垂到“出发”按钮上，不增加避让留白。素材为 `entry/src/main/resources/rawfile/comic/decor/pro-chain-locked.png`（锁定）及 `pro-chain-anchored.png`（解锁）。源码 `PRO_CHAIN_SCALE=56/(235-45)`，按原400×600等比得到约117.895×176.842vp；不要单独限制铁链宽度，否则素材中45/235像素的绕边位置会与按钮上下沿错开。按钮高度 `PRO_DRUM_BUTTON_HEIGHT=56vp` 增大会使按钮和铁链一起放大。横向首选调 `PRO_CHAIN_OFFSET_X=-20vp`，增大向右；纵向由 `PRO_CHAIN_TOP_OFFSET=4-45*PRO_CHAIN_SCALE≈-9.263vp` 自动对齐，不应独立调整。父框保持64vp、外层间距14vp，`clip(false)`与`zIndex(1)`允许链尾叠在下一按钮上方。

## 验证

- `route-probe-dialog.cjs` 通过，覆盖入口状态、0及正补偿、无连接绑定、普通/鼓机模式的耳机断开隐藏、试音确认与旧回包隔离。
- `time-card-calibration.cjs` 通过，保留32次跟拍、结果确认与保存、离页及断开保护。
- DevEco `product=default assembleHap` 构建成功，新增 ArkUI 布局和 SVG 通过编译。
- `git diff --check` 通过。
- `mic-calibration-retirement.cjs` 的旧页面清单断言失败：期望清单未包括已存在的 `SavedRecordingPage`、`MicCaptureExperimentPage`。该测试文件和 `main_pages.json` 均与本轮修改前的 HEAD 一致，未修改这项无关历史预期。

未进行真机显示与耳机连接实测，本轮未改动校准算法或音频补偿生命周期。
