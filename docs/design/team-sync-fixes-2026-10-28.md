# 组队同步精度分阶段修复记录

日期：2026-10-28。本轮承接 [2026-10-27 精度评审与开源对比](team-sync-accuracy-review-2026-10-27.md)，保留 Wi-Fi P2P、队长权威、TCP 控制、各机生成 PCM 和共同未来起拍。没有引入第三方运行时库。

**当前代码已将测时数据契约、漂移拟合保护、严格起拍准入、共享音乐时钟与 PCM 播放反馈接入正常路径；`phaseCorrectionEnabled=true`，持续反馈默认开启。** 调试包保留暂停／空闲时的 `phase-off/phase-on` 对照与回退入口，独立精确帧映射开关仍关闭。

用户完成两台手机的外放和蓝牙耳机人耳测试，反馈体感偏差改善，没有漏拍或音质问题。本轮将其记为**双机外放＋蓝牙主观听感验收**，并据此默认启用持续反馈。共同录音与毫秒级误差统计尚未采集，量化验证方法见 §5。

早期默认关闭阶段的设备枚举与验证结果保留为历史记录；当前状态以本轮默认开启后的回归和用户双机听感反馈为准。

## 1. 正常路径：先让估计和 READY 有明确含义

实现位于 [ClockSync.ets](../../entry/src/main/ets/sync/ClockSync.ets) 和 [SessionController.ets](../../entry/src/main/ets/session/SessionController.ets)。

- 每个有效四时间戳测量保留自己的 `localMidpointMs`。批次仍筛选最快的至多一半、最多 3 个样本，再取实际存在的偏移下中位样本；`offsetMs`、`rttMs`、中点来自同一个测量，`validSampleCount` 记录整批有效数量。不再把平均／中位偏移配上另一个样本的最小 RTT。
- 空批次或全无效批次抛出 `ClockSyncMeasurementError`；无效、未来或乱序样本不改变旧映射。同一测量被准备流程复用时不重复增加拟合权重。
- 保留 RTT 加权和历史一致性重置。满足样本数、时间跨度、钟速范围和残差要求后才启用 skew；异常拟合退回 offset 模式，不把过大的斜率截断成一个看似可信的新映射。横纵轴都围绕参考样本计算，减少大 uptime 差值下的数值误差。
- 严格准备先检查新批次，再更新映射；等待音频准备后、发送 `TRANSPORT_READY` 前复查样本年龄和误差估计。调用返回成功不再自动等于 `clockReady=true`。READY 仍只描述发送 ACK 当时的准备状态，不能保证后续网络交付不会迟到。
- 周期复校也拒绝不满足准入条件的批次。收到劣质时间戳与连接超时分开处理：前者证明对端仍可达，保留旧映射及有效期限，不累计成断连。过期映射冻结，不无限外推，也不能准许新的严格起拍。

当前参数均在 `ClockSync.ets`；它们是本轮保护策略，不是测得的手机晶振边界或可闻精度保证。

| 参数 | 当前值 | 作用和调节取舍 |
|---|---|---|
| `CLOCK_FIT_MIN_SAMPLES` / `CLOCK_FIT_MIN_SPAN_MS` | 3 个批次 / 10000ms | 增大可减少短跨度噪声拟合，代价是更晚采用钟速估计。 |
| `CLOCK_FIT_WINDOW_MS` | 60000ms | 增大保留更多历史，同时更慢适应真实时钟变化。 |
| `CLOCK_FIT_MIN_WEIGHT_RTT_MS` | 4ms | 权重使用 `1/max(4,rtt)²`，避免一个近零 RTT 样本独占拟合。 |
| `CLOCK_FIT_MAX_RESIDUAL_MS` | 3ms | 更小会拒绝更多噪声拟合；拒绝后回到 offset 模式。 |
| `CLOCK_FIT_MAX_ABS_SKEW_PPM` | 1000ppm | 超限拒绝拟合；也用于样本老化的策略余量，不是已测硬件上界。 |
| `CLOCK_FIT_CONSISTENCY_MARGIN_MS` | 5ms | 新测量与历史投影的区间检查余量；调大会容忍更多不一致历史。 |
| `CLOCK_MAPPING_HOLDOVER_MS` | 15000ms | 最后有效测量后的最大外推期限；增大可延长短时失联可用性，也增大未观测漂移风险。 |
| `CLOCK_READY_MIN_SAMPLES` / `CLOCK_READY_MAX_AGE_MS` | 3 个有效 ping / 3000ms | 增大前者或减小后者会收紧起拍准入。 |
| `CLOCK_READY_MAX_ERROR_MS` / `CLOCK_TIMESTAMP_MARGIN_MS` | 10ms / 1ms | 准入预算与时间戳余量；10ms 不是跨机声学误差承诺。 |

误差估计包含 `rtt/2 + 时间戳余量 + 拟合偏差/残差 + 样本老化余量`。固定上下行不对称仍不能从四时间戳中辨识；`good/fair/poor` 仍只是 RTT 响应速度标签。不能把“READY 通过”解释为已达到评审提出的 P95 ≤ 2ms 候选声学目标。

## 2. 默认开启的共享时钟与 PCM 反馈

[AppSession.ets](../../entry/src/main/ets/app/AppSession.ets) 将 offset、skew 和有效期限传给 [MetronomeEngine.ets](../../entry/src/main/ets/audio/MetronomeEngine.ets)。反馈开启时，起拍按目标时刻投影 offset；播放中在原音乐网格上吸收后续共享时钟变化，拍点计时、画面位置、恢复和路由重排使用同一调整量。原始 `transportStartLocalMs` 不因复校反复改写。

`phaseCorrectionEnabled=true` 是每个新引擎实例的默认值；无需调试命令即可启用持续共享时钟与 PCM 校正。调试时切为 false 会回退到原本地持续时间线，但仍保留新的 estimator/readiness。另一个开关 `EXPERIMENTAL_EXACT_PLAYBACK_FRAME_MAP=false` 保持独立关闭，避免同时替换生产帧映射和沿用旧耳机补偿。

反馈先获取本轮 transport 的新鲜硬件时间戳，再建立播放锁，解决旧版 false 状态挡住首次采样的问题。音频时间仍通过当前生产帧映射解释，输出延迟残差并未因此自动消失。已插入／丢弃的内容帧按提交位置记账，只有到达预计可闻位置才计入听到的内容进度；计算待修正量时同时扣除在队列中及尚待执行的修正，避免重复追逐同一误差。

| 调整点（均在 `MetronomeEngine.ets`） | 当前值 | 边界 |
|---|---|---|
| `transportClockAdjustmentAt()` 的 `limit=elapsed/1000` | 1ms/s | 共享逻辑时间的最大渐变速度；更快收敛会更明显改变节拍速率，不等于 PCM 每秒一定能完成同样修正。 |
| `AUDIO_PHASE_LOCK_THRESHOLD_FRAMES` | 44 帧，约 1ms | 每拍评估超过阈值的残差；调低更容易追逐时间戳噪声。 |
| `AUDIO_PHASE_LOCK_MAX_STEP_FRAMES` | 16 帧，约 0.36ms | 单次静音剪接上限，也是首次反馈的额度；不再限制每拍累计只能修正 16 帧。 |
| `AUDIO_PHASE_CORRECTION_RATE_PPM` | 2000ppm | 后续额度按经过时间计算，约 2ms/s，超过共享逻辑时间的 1ms/s 渐变上限；调大会提高允许追赶速率，也增加单位时间的剪接量。 |
| `AUDIO_PHASE_CORRECTION_MAX_INTERVAL_MS` | 2000ms | 每次计算额度最多累计 2 秒，避免回调长时间停顿后一次积攒过大修正。待执行量限制为本次额度，不因缺少静音窗口无限累积。 |
| `AUDIO_PHASE_CLOCK_MAX_AGE_MS` | 250ms | 更旧的硬件观测不用于反馈；原生帧坐标回退后等待新锚点。 |
| `AUDIO_PHASE_CORRECTION_CAPACITY` | 128 项 | 预分配修正账本；达到容量时等待消费，不覆盖尚未出声的记录。 |
| `AUDIO_PHASE_QUIET_SAMPLE_LIMIT` / `AUDIO_PHASE_QUIET_GUARD_FRAMES` | PCM 绝对值 ≤4 / 两侧各 16 帧 | 剪接两侧以及全部待丢弃帧都必须满足低能量条件；不是看到零交叉就可剪接。 |

后续反馈额度为 `floor(min(经过毫秒数, 2000) × SAMPLE_RATE × 2000 / 1e9)` 帧，每拍评估后可在合格静音窗口内分多次、每次最多 16 帧执行。这修正了旧候选固定 16 帧／拍在低 BPM 下追赶速度不足的问题；首次评估尚无时间间隔时额度为 16 帧。按时间分配的是允许校正量，不表示任何音频内容下都能实际执行完。

**持续镲声、长音或密集鼓点可能没有合格静音窗口，此时保留有界的待执行量，不剪断尾音。因此当前机制不能保证任意鼓谱都可持续收敛。** 残差仍可观测，但 pending 不超过本次时间额度，避免把长期缺少静音的误差转成无限排队的插／丢帧任务。若设备实验表明这类内容也必须长期紧密跟随，应另行评估平滑重采样的音质、实时开销及延迟；本轮不借提高静音阈值掩盖这个缺口。

反馈还受 transport token/revision、待生效切换、路由恢复和流状态保护；校准、补偿覆盖、本地鼓机试听不参与这组反馈。暂停、停止和新起拍重置本轮修正状态，不能把上一轮尚在输出队列中的记账沿用给新内容。

## 3. 调试开关与回退

固定入口在 [TeamAcousticProbe.ets](../../entry/src/main/ets/audio/TeamAcousticProbe.ets)，先检查 `context.applicationInfo.debug === true`。发布包的持续反馈同样默认开启，但不响应这些调试命令。应用已有会话、录制空闲且队伍为 `idle` 或 `paused` 时才允许切换；校准、鼓机试听、会话关闭、正在播放或输出尚未停妥均拒绝。命令只修改当前设备的内存开关，不广播给其他成员，不会自动开始播放。

```sh
hdc -t <device-id> shell aa start -a EntryAbility -b com.onebeat.app --ps onebeatProbe phase-off
hdc -t <device-id> shell aa start -a EntryAbility -b com.onebeat.app --ps onebeatProbe phase-on
```

每端都需检查 `[TeamAcousticProbe] stage=phase-mode enabled=false/true`。如果返回 `phase-mode-requires-idle-or-paused-team`，等待共享暂停真正完成后再试，不能在播放中强改字段。完成正常对照后暂停全队，对每端执行 `phase-on` 并核实日志，恢复当前默认行为；若需要排查回归，则在暂停后对每端执行 `phase-off` 作为临时回退。新建引擎实例默认开启，不持久保存上次调试关闭状态；A/B 记录不能只凭上次发过命令推定当前模式。

## 4. 参考项目的本轮取舍

| 参考 | 本轮采用的思路 | 不直接引入的原因 |
|---|---|---|
| [IRCAM sync](https://github.com/ircam-ismm/sync) | 测量中点、先训练再估钟速、有效性边界、播放中连续调整逻辑时钟。 | JS 逻辑时钟不负责手机输出；其默认 120 秒训练和 160ppm 渐变不直接适合快速组队起拍。原包依赖 `debug`、BSD-3-Clause，本轮未添加该包。 |
| [Ableton Link](https://github.com/Ableton/link) | 共享音乐时间必须落实到音频采样和输出时刻。 | C++17/Asio 与平台接入、GPLv2+／专有授权路径及自由改速会话模型，均超出本轮最小修复。当前基础 Link 与 Link Audio 是不同模块，不因参考 beat sync 而引入音频串流。 |
| [Snapcast](https://github.com/snapcast/snapcast) | 以实际内容播放位置反馈少量插／丢帧，并区分排队与已呈现内容。 | 完整串流架构增加 Boost、可选编解码／重采样及平台音频后端，GPLv3+；oneBeat 已有本地 PCM。持续音频如何安全修正仍需独立设计。 |

上游依据、场景差异和完整依赖说明保留在 [原评审 §4](team-sync-accuracy-review-2026-10-27.md#4-github-参考项目场景依赖与取舍)。本轮是自行实现所需的小范围机制，没有把第三方性能自述当作本项目验收结果。

## 5. 主观听感反馈与后续量化 A/B

用户已报告双手机外放及蓝牙耳机听感改善、没有漏拍或音质问题。以下为补充量化证据的步骤，不表示用户已执行这些录音次数、持续时间或受控开关切换。采集顺序仍先两台手机外放，再耳机混用；有线输出仅作辅助对照。

1. 连接两台调试设备并确认设备 ID、包版本、机型和系统版本。保持网络、队长、BPM、音色、路由、音量、校准及距离不变。使用同一录音设备的共同采样时钟，优先双通道分别近距离采两端；先同源脉冲校验通道固定偏差。分别静音确认两个源都可识别，并记录传播路径差。
2. A 组暂停后在两端执行 `phase-off`，保存模式确认与 `snapshot`。记录冷启动和热恢复各 20 次、连续 10 分钟，以及后台恢复、网络负载、一次配置切换。A 组仍使用本轮新的 estimator/readiness，比较的是持续反馈开关，不是假称与旧版本所有行为完全相同。
3. B 组在同样条件下暂停、两端执行 `phase-on` 并确认；重复相同录制。交换 A/B 顺序再做一轮，减少设备温度或网络随时间变化带来的偏差。普通 click 和具有持续镲声的鼓机分别测量；没有静音窗口、修正累积时单独报告，不从 click 结果推广到所有鼓谱。
4. 按同一 beat 编号配对两路起点，报告有符号偏差、绝对差 P50/P95/P99/max、首拍与稳态分布、首尾漂移、漏拍／多拍和欠载。不要按最近峰强行匹配，也不要用两台各自录音的文件起点直接相减。任一路不可辨识即测量无效。
5. 完成外放量化采集后，再按耳机对外放、耳机对耳机、断开重连、路由切换和暂停恢复重复。耳机必须近距离可辨识或独立声学耦合采集；外放淹没耳机时不能给出精度结论。先记录原补偿，单独比较是否需重校准；不能同时改映射、校准和反馈开关后归因。

每端保存 `TransportPrepareDiag`、`ClockFitDiag`、`StartTimingDiag`、`ProductionClockDiag`、`PhaseLockDiag`、路由与欠载日志，以及原始 WAV 和操作时间线。重点核对样本年龄／误差预算、共享目标与实际 targetFrame、硬件观测年龄、待执行／排队修正量、输出补偿和最终声学残差。短时 `mic` 命令只采集 10 秒，不能替代连续 10 分钟的共同录音；其输出会被下一次采集覆盖，必须先归档。

原评审的 P95 ≤ 2ms、P99 ≤ 5ms 仍是待真机确认的候选外放目标，不是本轮结果，也不能直接承诺任意 A2DP 耳机。出现 READY 拒绝时记录原因，先判断预算和真实链路情况，不为完成一次播放而放宽门槛。

## 6. 验证记录与历史结果保护

本文件区分代码检查、模拟回归、用户主观听感反馈和后续量化采集。本轮新增／调整的 `clock-sync-fit.cjs`、`clock-sync-readiness.cjs`、`metronome-shared-clock.cjs`、`metronome-phase-feedback.cjs` 用于分别检查估计保护、READY 边界、共享时间线和实际 PCM 反馈。

[metronome-phase-drift.cjs](../../scripts/tests/metronome-phase-drift.cjs) 已使用实际生产 PCM 与理想模拟硬件时钟验证 16 组 10 分钟播放：40／60／120／240 BPM × 100／500／+1000／−1000ppm。按时间分配校正额度后，这些有静音窗口的受控用例不再持续发散。它验证算法在给定时钟和 PCM 条件下的行为，不覆盖真实时间戳量化、调度负载或声学输出，也不代表所有鼓谱均能收敛。本次这些离散采样点上，模拟可听内容偏差的最大绝对值为 **2.652ms**；它不是两台真机的声学误差，也不是 P95 结果。

[clock-sync-accuracy-probe.cjs](../../scripts/tests/clock-sync-accuracy-probe.cjs) 当前已改为运行 READY、共享时间线、PCM 反馈和长期漂移 4 组修复回归，输出 [clock-sync-fix-validation-results.json](clock-sync-fix-validation-results.json)，记录当前源码 SHA256、各组输出、默认开关和真机验证边界。默认开启后这 4 组已重新运行并全部通过；新引擎默认启用断言和显式关闭回退均被覆盖，JSON 的源码指纹与最终实现一致。

[clock-sync-accuracy-probe-results.json](clock-sync-accuracy-probe-results.json) 是 2026-10-27 旧生产实现与研究候选的历史证据，保留其原始输入、源码 SHA256 和结果，不用本轮代码覆盖。当前入口不再断言旧缺陷或写该历史文件。后续声学数据继续使用独立日期／运行标识存档。

默认开启后重新完成的集成检查：

- `run-sync-regressions.cjs` 共 61 组，前 59 组通过，随后在 `recording-save-dialog.cjs:54` 失败；门禁没有跳过该失败，也没有报告整体 PASS。失败断言是关闭“正在保存”弹窗后，轮询不应重新打开。
- 门禁中止后的最后一组 `saved-recording-page.cjs` 已单独执行通过，因此合计 **60/61 组通过**。该保存弹窗页面 `MainPage.ets` 及对应失败测试均与本轮开始的 HEAD 一致，`git diff --exit-code HEAD -- <这两个文件>` 返回 0；属于已有独立问题，本轮没有混入录制 UI 修改。
- 使用 DevEco SDK 运行真实 `default@CompileArkTS`，结果 `BUILD SUCCESSFUL`；存在既有平台 API 提示。没有执行签名、安装或发布。
- `git diff --check` 通过。用户已完成双机外放及蓝牙主观听感验收；默认开启版本尚未由本轮工具安装到设备。共同录音及实际毫秒级偏差仍需独立采集。

可复现命令（在仓库根目录）：

```sh
/Applications/DevEco-Studio.app/Contents/tools/node/bin/node scripts/tests/run-sync-regressions.cjs
/Applications/DevEco-Studio.app/Contents/tools/node/bin/node scripts/tests/saved-recording-page.cjs /Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js
DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk JAVA_HOME=/Applications/DevEco-Studio.app/Contents/jbr/Contents/Home /Applications/DevEco-Studio.app/Contents/tools/node/bin/node /Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw.js --mode module -p product=default -p module=entry@default -p buildMode=debug default@CompileArkTS --no-daemon
```
