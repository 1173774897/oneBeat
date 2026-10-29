# 组队同步再评审：硬件播放位置测量与暂停路径

> **实施状态（2026-10-28 当日更新）**：§4-A 上包络已实现并**默认开启**，可用调试命令 `envelope-off/on` 回退；§5 第 1、3 条已实现。详见 §7。下文 §1–§6 保留为实施前的评审记录。

日期：2026-10-28。承接 [10-27 精度评审](team-sync-accuracy-review-2026-10-27.md)（已对比 Ableton Link、Snapcast、IRCAM sync）和 [10-28 分阶段修复](team-sync-fixes-2026-10-28.md)。本轮没有改动正式播放行为；新增一个研究探针和结果文件，不进入回归门禁。

**结论：网络校时已经不是主要误差来源。当前最大的可改进点在“读硬件播放位置”这一步：设备上的帧位置按 HAL 周期跳变，时间戳却是查询时刻，生产算法把这种单向滞后当成真实相位误差，持续反馈因此几乎每拍都在追噪声。** 建议下一步把播放位置估计改为“多次读数取上包络”，但它会改变各机的绝对起拍位置，必须先放在调试开关后做双机声学 A/B，再决定是否默认开启。暂停路径有约 0.35–0.5s 的可省等待，精度损失可以忽略。

## 1. 设备证据（两台手机，2026-10-28 实时 hilog）

| 观察 | 数据 | 说明 |
|---|---|---|
| 网络校时稳定 | 队员 100s 内 offset 从 `-1052513428.23` 变到 `-.30`ms | 漂移约 0.07ms／100s，远小于下面的音频测量噪声 |
| 相位反馈在追噪声 | 队长 219 次修正：负 108、正 111；残差 P10 −820 帧、P50 +44、P90 +283 | 正负几乎抵消；−820 帧（18.6ms）测完只修 44 帧，下一拍却测到 +62，说明那次读数本身不对 |
| 相邻读数不自洽 | 若残差真实，下一拍应≈本拍−本次修正；实测差值 P50 约 2ms、P90 约 18–19ms | 接近一个 20ms HAL 周期 |
| 修正带来游走 | 队员一次 4 分钟播放内，累计插删在 −8ms 与 +12ms 之间来回，无线性趋势 | 真实晶振漂移应单向线性；来回摆动是噪声驱动 |
| 时间戳语义 | `ProductionClockDiag`：`rawAgeMs≈−1~0`，`rawFrame` 与 `previousRawFrame` 相同；冷启动 `rawFrame=0`、`rendered=1764` | 时间戳≈查询时刻，帧位置却停在上一个周期边界 |

上述日志只在残差超过 44 帧（1ms）时打印，统计口径偏向较大的残差，但正负平衡与无趋势游走不受这一点影响。

生产代码位置：`MetronomeEngine.ets` 的 `readRenderedStreamFrames()`（生产分支用首个样本冻结 `audioTimestampClockOffsetMs`，按 `[0,250]ms` 截断年龄外推）、`readPhaseErrorFrames()`、`checkAudioProgress()`。`MonotonicClock.nowMs()` 返回整数毫秒的 STARTUP 时钟，单次读数就有 ±1ms（44 帧）误差，恰好等于修正阈值 `AUDIO_PHASE_LOCK_THRESHOLD_FRAMES=44`。

## 2. GitHub 参考项目：本轮新增

| 项目 | 解决的场景 | 依赖与许可 | 与 oneBeat 的差异 | 取舍 |
|---|---|---|---|---|
| [Ableton Link `HostTimeFilter`](https://github.com/Ableton/link/blob/master/include/ableton/link/HostTimeFilter.hpp) | 音频回调里的“采样时间↔主机时间”成对读数有抖动，用 512 点环形缓冲做线性回归，得到平滑映射 | C++ 头文件；整体 Link 为 GPLv2+／专有授权（见 10-27 评审） | 回归假设噪声零均值。我们的噪声是单向滞后（只会少算），均值回归仍保留约半个周期的偏差 | **借鉴“对多次读数建模，不信单次读数”**；估计方法改用上包络，不引入代码 |
| [shairport-sync](https://github.com/mikebrady/shairport-sync)（约 8.9k★） | AirPlay 多房间同步；按源时间戳播放每帧，用插删帧或 libsoxr 重采样修正漂移；AirPlay 2 用 NQPTP 校时 | C/autotools，NQPTP、ALSA 等后端，可选 libsoxr；GitHub API 返回 `NOASSERTION`，需看仓库 LICENSES | 默认漂移容差 `drift_tolerance_in_seconds=0.002`（2ms），偏差超 50ms 时静音并整体重同步；文档明说容差太小会“过度修正”。要求后端提供准确的 DAC 时序，否则只能部分同步 | **借鉴“容差必须大于测量噪声”的原则**；单独加 2ms 死区在我们的模型里收益很小（见 §3），根因仍在测量 |
| [Roc toolkit](https://github.com/roc-streaming/roc-toolkit)（MPL-2.0） | 网络串流接收端，用接收队列长度驱动 PI 控制器，再用重采样器微调播放速率，补偿两块声卡的晶振差 | C++，可选 speexdsp 等重采样后端；官方[说明](https://roc-streaming.org/toolkit/docs/internals/fe_resampler.html)记录实测约 55ppm、每小时 200ms 的漂移 | 它修的是串流队列，不涉及多机共同起拍；平滑重采样能处理没有静音窗口的持续镲声（10-28 修复记录中尚未解决的缺口） | **暂不实施**。先修好测量；测量不准时，再平滑的执行器也只会更平滑地追噪声 |
| [Beatsync](https://github.com/freeman-jiang/beatsync)（MIT，约 3.2k★） | 浏览器多设备同步播放，自称毫秒级 | Bun、Next.js、WebSocket，TypeScript monorepo；移动端标为实验性 | 校时用 Huygens 式“编码探测对”：间隔固定发两包，到达间隔不符就丢弃（`apps/client/src/utils/ntp.ts`），用来过滤排队、TCP 队头阻塞和 GC 停顿 | **暂不实施**。我们的校时已经不是瓶颈（§1）；若以后在 9 人负载下测到 TCP 尾延迟，再把它作为低成本过滤手段 |
| [Oboe / OboeTester](https://github.com/google/oboe)（Apache-2.0） | Android 音频时延测量；往返时延用归一化互相关在输入流中定位输出信号（见 [AOSP 说明](https://source.android.com/docs/core/audio/latency/measure)） | C++／NDK，Android 专用 | 蓝牙偏差现在用人工打卡（`TimeCardCalibrationPage.ets`）测量；麦克风回环方案已弃用（`MicLoopbackCalibrator.ets` 代码保留，同属互相关方法）。打卡值包含人的反应偏差，不是纯硬件时延 | **不借鉴**。手机麦克风难以可靠采到耳机里的声音（见 [耳机与外放调查](headphone-speaker-sync-debug-2026-10-22.md)）；但打卡的预定拍点同样取自生产帧映射，见 §4 |

外部内容为 2026-10-28 读取的默认分支，星数、许可来自 GitHub API；只记录许可标签，不作法律结论。

## 3. 最小验证：硬件播放位置量化探针

脚本：[`scripts/tests/phase-timestamp-quantization-probe.cjs`](../../scripts/tests/phase-timestamp-quantization-probe.cjs)；结果：[`phase-timestamp-quantization-probe-results.json`](phase-timestamp-quantization-probe-results.json)（含 `MetronomeEngine.ets` SHA256）。

方法：转译后运行真实 `MetronomeEngine`，只替换原生边界。模拟渲染器每 20ms 更新一次帧位置；`MonotonicClock` 按生产实现返回整数毫秒；每拍检查时刻带非整数抖动。真实漂移设为 0，因此理想的可闻误差是常数。“实际可闻误差”从引擎残差中扣除当次读数的映射误差得到。每种方案跑 12 次、每次 240 秒、120 BPM。候选算法只存在于脚本里。

**主模型：帧位置滞后、时间戳为查询时刻（与 §1 设备证据一致）**

| 方案 | 测得残差 SD | 每拍修正率 | 起拍固定偏差（12 次范围） | 运行内抖动 SD | 最坏 |
|---|---|---|---|---|---|
| 关闭反馈（参照） | 5.82ms | 0 | 7.4–7.5ms | 0.01ms | 7.5ms |
| **当前生产** | 5.36ms | 0.90 | 8.8–10.4ms | **2.16ms** | 16.9ms |
| 残差取 5 点中值 | 4.73ms | 0.83 | 9.0–10.3ms | 5.42ms | 31.2ms |
| **上包络（16 次读数）** | 1.40ms | 0.22 | **1.7–2.6ms** | 1.52ms | 12.5ms |
| 上包络 + 2ms 死区 | 1.15ms | 0.11 | 1.7–2.5ms | 1.70ms | 13.2ms |

对照模型（帧位置与时间戳一致）中，当前生产没有游走，但仍有约 7.5ms 的起拍偏差，来自冻结的首样本年龄；上包络为 0。

解读：

- 生产模型复现了设备特征：每拍都修正，相邻变化 P90 约 14ms（设备约 18ms）。
- 在真实漂移为 0 时，**当前反馈比关闭反馈多出约 2ms 的运行内抖动，最坏偏差翻倍**。持续反馈对真实晶振漂移仍然必要：按 Roc 文档的约 55ppm，10 分钟就是 33ms。所以不能简单关掉，要修的是输入。
- 中值滤波会让控制环滞后、引发振荡，**否决**。
- 上包络把单向滞后造成的固定偏差从约 9ms 降到约 2ms，修正次数降到约四分之一。剩下的运行内波动，一部分来自起拍时窗口还没填满造成的偏差收敛，一部分来自整毫秒取时；死区几乎没有额外收益。

边界：这是对原生边界的模型，不是声学测量。HAL 周期在不同机型和路由下不同（蓝牙更大），时间戳语义也可能随系统版本变化。模型证明了“这种测量方式会让当前算法追噪声，上包络能去掉它”，不能证明设备上的可闻误差就是这些数字。

## 4. 建议的实施方案（尚未实施）

**A. 播放位置改为上包络估计（优先，需开关加声学 A/B）**

1. 在 `readRenderedStreamFrames()` 的生产分支，记录 `framePos − timestamp×SR`，时间戳按 `readDrumPreviewNativeSample()` 的方式用 ACTIVE/STARTUP 括号换算（已有代码，纳秒精度）；取最近约 16 次读数的最大值作为“最少滞后”的映射。帧坐标倒退、换路由、物理重启时清空窗口，沿用现有失效判定。
2. 除每拍检查外，在 `writeData` 回调里也采样一次，让窗口在起拍后约 1–2 秒内填满（当前每拍一次要约 8 秒）。
3. `MonotonicClock` 增加小数毫秒读法（`getUptime(STARTUP, true)/1e6`），只用于音频映射和相位比较，不改 ClockSync 的契约。

风险：起拍目标帧和相位反馈都依赖这个映射；打卡校准也一样，它的测量值是“敲击时刻 − 预定拍点”，而预定拍点的声音由引擎按这个映射排到 `audioStartAtMs`（`AppSession.scheduleLatencyTapMeasurement()`）。所以旧映射下，打卡值会吸收测量那一次的随机映射偏差（0 到约一个 HAL 周期），这也是同一副耳机多次打卡结果有差异的来源之一。改动会把每台设备的绝对出声位置平移约半个 HAL 周期，平移量随机型和路由不同。**已保存的打卡校准值是在旧映射下测得的，开关切换后需要重新打卡，不能沿用旧值**。因此应像 `phase-on/off` 一样先做成调试开关，在两台设备上外放做共同录音 A/B，再按“外放→耳机混用”的顺序验收。

收益判断：模型中固定偏差从约 9ms 降到约 2ms，并去掉追噪声；而且旧映射下每次起拍的偏差还是随机的（取决于首次读数落在周期哪个位置），这是现有日志完全看不到的跨机误差，上包络同时消除它。打卡校准也会因此更可重复：映射偏差不再随每次测量变化，剩下的主要是人的敲击抖动。

**B. 暂不实施**：平滑重采样（Roc／soxr 路线）、编码探测对校时（Beatsync／Huygens）、UDP 校时通道。前提条件是 A 之后的声学数据显示剩余误差确实来自这些环节。

## 5. 暂停：声音与人物动作

当前路径：`AppSession.leaderPause()` → `SessionController.pauseTransport()` 先 `prepareConnectedMembersForTransport()`（非严格，最多 900ms），再广播 `pauseAtLeaderMonoMs = now + TRANSPORT_PAUSE_PREROLL_MS(650)`。各机 `MetronomeEngine.schedulePauseFromLeader()` 在硬件帧上把内容切成静音底噪；`setTimeout` 到点后才把 `running` 置为 false。`WalkScene` 的步伐和路面都由 `getVisualSnapshot()` 驱动，与声音共用一条共享时间线，`running=false` 后人物立即回到站立帧。

| 观察 | 数据 |
|---|---|
| 两机声音切换同步 | 队长 `transition[pause]` 16:43:18.269，队员 18.270 |
| 按下到停声 | 准备 354–514ms，加 650ms 预留，约 1.0–1.2s |
| 准备的实际作用 | 队员准备前后 offset 差 0.1–0.2ms（如 `−1052513428.48`→`−.30`） |
| 画面晚于声音 | 画面靠计时器停；设备 `timerLateMs` 多为 0–3ms，最高 23ms，再加 16ms 帧间隔 |

优化空间，按收益排序：

1. **暂停时跳过这轮准备（省约 0.35–0.5s，精度损失约 0.2ms）。** 周期复校每 5s 一次（`RESYNC_INTERVAL_MS`），映射有效期 15s（`CLOCK_MAPPING_HOLDOVER_MS`），而且现有暂停在准备超时后本来就会继续，正确性并不依赖它。可以改成只在队员映射过期时才等待。改后从按下到停声约 0.65s。
2. **预留量按路由自适应（再省约 0.2–0.3s，需改协议）。** 650ms 是按蓝牙队列加输出延迟留的余量；外放的实测提交领先量约 200–300ms（`audibleLeadMs=212/252/298`）。若准备 ACK 带回各机最小可调度提前量，队长可取全员最大值加余量。预留不足会让迟到的队员晚停、和别人错开，所以排在第 1 条之后。
3. **画面在共享暂停时刻精确停下（改动很小，收益 0–40ms）。** 在 `getVisualSnapshot()` 中，若 `scheduledPauseAtLocalMs` 已到，直接视为停止，不等计时器。0–40ms 的画面滞后一般感知不到，可以和第 1 条一起做。
4. **不建议“暂停对齐到下一拍”。** 这样能让人物停在完整的一步上、鼓声不在拍中被截断，但会增加最多一拍的延迟（60 BPM 时 1s），与第 1、2 条的目标相反。可作为产品选项另议。

## 6. 下一步验收

1. 先做第 5 节的 1 和 3：只影响暂停时机，回归加真机双机听感验证即可。
2. A 做成调试开关。两台设备外放，用同一录音设备做共同录音，分别在开关两种状态下录 10 分钟：比较同拍差 P50/P95/最大值、首尾漂移和 `PhaseLockDiag` 修正次数。若开启后修正次数明显下降、同拍差不变差，再验证蓝牙耳机混用：在开关的每种状态下分别重新打卡，并比较同一副耳机多次打卡的离散度，最后决定是否默认开启。
3. 每次运行保存 `PhaseLockDiag`、`ProductionClockDiag`、`StartTimingDiag`、`TransportPrepareDiag`，以及录音原始 WAV。

复现命令（仓库根目录）：

```sh
PROBE_OUT=docs/design/phase-timestamp-quantization-probe-results.json \
  /Applications/DevEco-Studio.app/Contents/tools/node/bin/node \
  scripts/tests/phase-timestamp-quantization-probe.cjs \
  /Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js
```

## 7. 实施记录（2026-10-28）

用户要求包络直接默认开启，以便两台真机测试效果。

**播放位置上包络**（`MetronomeEngine.ets`）

- 生产分支 `readRenderedStreamFrames()` 改用括号换算的 ACTIVE 时间戳（`readDrumPreviewNativeSample()`），记录 `framePos − timestamp×SR`，取窗口内最大值外推到调用时刻。窗口容量 `PLAYBACK_ENVELOPE_CAPACITY=16`，时限 `PLAYBACK_ENVELOPE_MAX_AGE_MS=2000`。帧位置与上一次相同的读数（同一 HAL 周期）合并为一条，不占窗口。
- `writeData` 回调每次补采一个样本（每回调多一次 `getAudioTimestampInfoSync`），使窗口在起拍后约 1 秒内填满。
- 每次物理启动在窗口积累 `PLAYBACK_ENVELOPE_REBASE_MIN_SAMPLES=8` 个不同周期后，用无滞后位置按原公式重算一次 `audioTimestampBaseFrame`。日志 `ProductionClockDiag ... reason=envelope-rebase deltaMs=…` 记录平移量；欠载启动不重算。
- 新渲染器、新物理启动、帧坐标倒退或 `resetAudioTimestampState()` 时清空窗口。括号读失败时，这一次退回旧的直接读法，播放时钟不会因估计器失效。
- 精确帧映射实验开关（`EXPERIMENTAL_EXACT_PLAYBACK_FRAME_MAP`）生效时不使用包络。
- 运行时开关：`setPlaybackPositionEnvelopeEnabled()`，仅在停止时允许切换；调试包命令 `envelope-off` / `envelope-on`（规则同 `phase-off/on`，需队伍空闲或暂停）。重新开启时允许温渲染器重算一次基准。

```sh
hdc -t <device-id> shell aa start -a EntryAbility -b com.onebeat.app --ps onebeatProbe envelope-off
hdc -t <device-id> shell aa start -a EntryAbility -b com.onebeat.app --ps onebeatProbe envelope-on
```

每端需看到 `[TeamAcousticProbe] stage=envelope-mode enabled=…`。**切换后需要重新打卡校准蓝牙偏差，不能沿用另一种模式下测得的值。** 新引擎实例默认开启，切换不持久化。

探针按设备回调节奏（约 93ms）喂数据后，引擎实现与旧算法的对比（帧位置滞后模型，12×240s，真实漂移 0）：

| 方案 | 起拍固定偏差 | 稳态抖动 SD | 稳态最坏 | 每拍修正率 |
|---|---|---|---|---|
| 旧算法（`envelope-off`） | 8.7–10.4ms | 2.14ms | 16.0ms | 0.90 |
| 引擎包络（默认） | 1.1–1.4ms | 0.68ms | 4.3ms | 0.24 |

仍是模型结果，不是声学测量。真机上应看到 `PhaseLockDiag` 的修正次数明显减少、正负不再成对出现，并出现一次 `envelope-rebase`。

**暂停**

- `SessionController.pauseTransport()`：所有已认证队员在 `PAUSE_SKIP_PREPARE_MAX_PING_AGE_MS = 2×RESYNC_INTERVAL_MS`（10s，小于 15s 映射有效期）内发过 `PING` 时，跳过准备直接广播暂停；任一队员超时（例如在后台被冻结）则仍先准备。阈值无效时保守地走准备。按下到停声预计从约 1.0–1.2s 降到约 0.65s。
- `MetronomeEngine.getVisualSnapshot()`：到达 `scheduledPauseAtLocalMs` 即视为停止，人物与路面和静音在同一时刻停下，不再等迟到的计时器。

**测试**

- 新增 `playback-position-envelope.cjs`、`visual-pause-instant.cjs`，纳入门禁；`transport-start-readiness.cjs` 增加“PING 新鲜时跳过准备”与“PING 过期仍准备”；`team-acoustic-probe.cjs` 覆盖 `envelope-on/off`。
- `production-clock-diagnostics.cjs`、`metronome-start-buffer-diagnostics.cjs`、`metronome-playback-baseline.cjs` 专门锁定旧帧映射，改为显式关闭包络运行，用来证明 `envelope-off` 与旧实现逐值一致。
- 门禁 66/66 通过，ArkTS 构建成功，已安装到两台调试设备。

### 7.1 真机复测后的修正（2026-10-28 晚）

用户在两台设备上连续按 +/- 改 BPM，两机产生明显偏差且长时间不消失；外放和蓝牙都能复现。日志结论与修正：

| 现象（日志证据） | 原因 | 修正 |
|---|---|---|
| 蓝牙下每次重新起拍，`StartTimingDiag` 的 `rendered` 都等于 `submittedAtEstimate`；随后残差 +19～+67ms | 蓝牙 A2DP 的帧位置在整块交给协议栈时跳涨，会超前于真实播放，违反“只会滞后”的假设；上包络取最大值选中超前读数，再被已提交帧数截住 | **蓝牙路由下不用包络**，回到旧的单次读数（路由判断缓存 500ms，`[EnvelopeDiag] stage=route active=…`）；外放和有线保留包络 |
| 外放下 `audio underflow: 11`（队长）／`4`（队员），回调间隔最长 211ms；随后队长残差约 −124ms，每拍只修约 1ms，鼓机节奏下要修几分钟 | 连续改 BPM 时重新生成音频占住 JS 线程，渲染欠载；欠载会把后续内容整体推后，两机推后量不同。包络正确测到了这个真实偏差，慢在修正手段 | **大偏差直接重新对齐**：连续 3 次同方向、彼此相差 ≤10ms、且超过 30ms 的残差，触发 `rescheduleForOutputRouteChange()`，在不重启渲染器的情况下把本机内容挪到共享时间线的下一个拍上，冷却 5s（`AUDIO_PHASE_RESYNC_*`，日志 `[PhaseLockDiag] stage=resync`）。参考 shairport-sync 超过 50ms 即重同步 |
| 行进中由蓝牙切到外放（用户要求对齐） | 包络在新路由上从空窗口开始；若路由重排先算目标帧、之后才重算基准，坐标会在重排后平移 | 路由切换时立即刷新路由缓存；路由重排在选目标前等待包络窗口积累 8 个周期并完成（或跳过）重算，最多 1.5s（`ROUTE_REPHASE_ENVELOPE_WAIT_MS`）。基准重算只在本次物理启动以来**没有欠载**时进行，否则保留原基准（原始帧计数连续，原基准仍有效），日志 `stage=rebase-skipped` |

另外修正：同一 HAL 周期内合并读数时不再刷新被保留读数的时间，确保计数器停住时 2s 时限生效。

欠载本身仍会造成一次可闻的卡顿，现在会在约 3 拍内重新对齐，不再长期错开。若要减少欠载，可考虑把连续改 BPM 合并成一次重启（防抖），尚未实施。

新增 `phase-resync.cjs`；`playback-position-envelope.cjs` 增加蓝牙回退用例；`metronome-phase-feedback.cjs` 的额度用例改用 25ms 偏差（低于重新对齐阈值）。门禁 67/67 通过，已安装到两台设备。

### 7.2 第二轮复测（一台蓝牙一台外放仍有小偏差）

日志：外放连按改 BPM 时，队长欠载后偏 −63ms，3 拍内重新对齐；蓝牙队长偏 −104ms 也已重新对齐。剩余的小偏差来自两处：

- 队员（外放）几次小欠载各偏 10–20ms，低于 30ms 门槛，只能每拍约 1ms 慢修，持续约 30s（21:34:44–21:35:16，−895→−75 帧）。**修正**：重新对齐门槛按路由区分：包络路由（外放/有线，测量噪声约 1ms）为 15ms（`AUDIO_PHASE_RESYNC_ENVELOPE_THRESHOLD_MS`），蓝牙旧算法仍为 30ms。
- 队员一段约 −88ms 的偏差没有触发：中间几拍拿不到新鲜读数，`measurePhaseErrorFrames()` 返回 0，把连续确认计数清零了。**修正**：拿不到读数时不改变计数（`lastPhaseErrorAvailable`）。

`phase-resync.cjs` 增加对应用例。蓝牙下仍使用旧单次读数，测量噪声约 ±20ms，这一路由的精度上限暂未改进。

### 7.3 第三轮复测

| 现象（日志） | 原因 | 修正 |
|---|---|---|
| 队长蓝牙下连续 3 次重新对齐（+52/+48/+38ms），每次之后残差又回到约 +50ms | 旧单次读数在蓝牙下有约 60ms 的锯齿形测量误差：残差在 13 拍内下降约 59ms，而期间实际只修了约 7ms。重新对齐把测量假象当成真实偏差，反而挪动了声音 | 重新对齐**只在包络路由（外放/有线）启用**，门槛 15ms；蓝牙只保留原来的有界慢修 |
| 队员（外放）冷启动后约 2s 测到 −69ms；`EnvelopeDiag` 起拍初期离散 81ms，随后 `max-jump −68.91ms` | 物理启动后约 1s 内硬件计数器不稳定（预填充），一次超前读数成为窗口最大值，过期时估计值骤降 | 物理启动后 `PLAYBACK_ENVELOPE_WARMUP_MS=1000` 内的读数不进包络，沿用与冷启动定位相同的旧读法 |
| 连按改 BPM 引发欠载 | 每次修改都立即广播快照，各机在 JS 线程同步渲染新 PCM | **播放中的设置修改合并**：BPM、音色、拍号、拍点、节奏型在最后一次操作 350ms 后只做一次广播加重启（`CONFIGURATION_RESTART_COALESCE_MS`），期间只刷新显示（`sessionEpoch`），不重渲染音频；等待中若有暂停、开始等其他传输请求或已停止，则只发布配置、不重启；断开时取消。鼓机编排的严格切换不合并 |

git 历史中没有找到 BPM 合并的旧实现，原有的只是“新请求取消旧请求”，它只能避免多次起拍，避免不了每次修改都重渲染。

测试：`transport-restart-configuration-order.cjs` 改为验证 350ms 合并窗口、三次连续修改只渲染和重启一次、等待中暂停不会被重启覆盖；`phase-resync.cjs` 改为蓝牙永不重新对齐；`playback-position-envelope.cjs` 增加启动预热排除；`walk-beat-point-mode.cjs`、`drum-lobby-editor-settings.cjs` 把合并函数桩为一次重启。门禁 67/67 通过，已安装到两台设备。
