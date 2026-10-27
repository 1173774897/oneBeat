# 行进页按来源显示载入反馈

2026-10-24，实施用户确认的组合。

| 入口 | 反馈 |
| --- | --- |
| 上方 BPM 输入、拍号修改、节拍器拍点三态切换 | 拍点下方原状态行 |
| 下方 BPM 加减、音色、开始/恢复/暂停 | 播放键下方原状态行 |
| 编排确认并切换 | 目标卡固定状态槽微环＋底栏提示 |

打开/关闭编排抽屉不载入音频，不启动loading。录制继续使用现有的准备、停止及保存状态，避免和自动收起的控制栏重复反馈。鼓机拍点仍为只读。

提示不加遮罩、不改变播放图标或自动开关面板。两个状态行始终预留同样高度，切换文字不引起跳动。

## 时序与所有权

原生LoadingProgress常驻但在空闲时停止动画、透明且隐藏于辅助功能树。载入后注册延迟300ms的原生透明度动画，等 `WalkReloadFrame.onIdle` 确认一帧提交，再执行可能同步生成PCM的操作。这样不额外等待300ms才开始实际工作，也不依赖被PCM阻塞的JS定时器首次显示。

短操作会在延迟结束前取消提示。出现后的提示至少保留300ms，仅保留视觉，不延后声音生效或业务解锁。超过3秒在原位置改为“仍在处理，请稍候”。编排卡内微环与底栏共用透明度及视觉请求归属，中等时长操作也不会让卡内环过早消失。

上、下来源按请求聚合，某个旧请求完成不能清掉另一请求。离页会取消视觉计时器和待提交帧；同一房间已经提交的原生操作保留业务锁，回来后仍不重复提交。换房会撤销旧锁；旧回调不能解除新房间的锁或清掉新卡片状态。

`AppSession.waitForCurrentAudioConfiguration()` 等待真实本机PCM配置，最多4秒；配置、会话或音频归属变化不能误报ready，超时不取消底层后台资源加载。现有transport准备保持原严格预算，不叠加第二个计时器。等待返回true不代表共享的未来播放时刻已经听到，因此没有新增“已同步所有人”或虚假进度。同步音频工作仍可能占用JS，本次没有宣称已改善生成耗时。

## 调节入口

首选 `entry/src/main/ets/pages/MainPage.ets` 顶部常量：

- `WALK_RELOAD_DELAY_MS=300`：增大更晚出现，减小更早；`WALK_RELOAD_FADE_MS=120`：增大淡入更慢。
- `WALK_RELOAD_LONG_MS=3000`：增大更晚显示长等待文字；`WALK_RELOAD_MIN_VISIBLE_MS=300`：增大只延长提示最短停留，不延长业务操作。
- `WALK_RELOAD_SPINNER_SIZE=12vp`：增大圈更大，减小更轻。首选只调此值，不超过状态行高度；编排卡状态槽仍为 `PROGRAM_CARD_STATUS_SIZE=14vp`。
- `WALK_RELOAD_TOP_GAP=4vp`：增大使上方文字离左侧圈更远、向右移；`WALK_RELOAD_BOTTOM_GAP=5vp`：增大使底栏圈与文字彼此拉开，整体仍居中；减小反向。
- `WALK_RELOAD_ROW_HEIGHT=16vp`：增大预留的垂直空间，缩小会减少圈与文字的余量。上方行左对齐、底栏行居中；不要靠增大整栏padding来微调图标。大幅改高时同步检查 `TOP_PANEL_HIDDEN_OFFSET=204vp`、`BOTTOM_PANEL_HIDDEN_OFFSET=190vp` 及编排抽屉高度对隐藏范围的限制。

场景图片资源和分层位置未改。

## 本地验证

ArkTS调试HAP构建通过；相关回归覆盖：

- `walk-loading-feedback.cjs`：真实页面方法、原生动画参数、帧前置、上下来源、并发聚合、短任务、长等待、最短停留、成功/失败、暂停、换房和隐藏后重复提交，以及卡内/底栏一致性。
- `session-audio-configuration-readiness.cjs`：真实AppSession和引擎PCM、冷/热缓存、完整配置及音频归属、超时，不新增transport。
- `walk-beat-point-mode.cjs`、`drum-arrangement-switch.cjs`、`route-probe-dialog.cjs`：原交互权限、原生操作锁、编排原子切换与旧会话保护。
- `transport-start-readiness.cjs`、`transport-restart-configuration-order.cjs`、`metronome-configuration.cjs`、`drum-preview-session-ownership.cjs`、`latency-calibration-routing.cjs`、`session-reset-lifecycle.cjs`、`recording-page-flow.cjs`、`comic-shadow-policy.cjs`、`editable-bpm-feedback.cjs`。

上述相关回归通过。按当前选择仅完成本地验证，尚未补做真机首次绘制、实际转圈连续性、窄屏/大字体或读屏播报验收。
