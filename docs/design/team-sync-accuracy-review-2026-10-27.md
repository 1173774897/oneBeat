# 组队节拍同步精度评审与最小验证

> 后续实现见 [2026-10-28 分阶段修复记录](team-sync-fixes-2026-10-28.md)：estimator/readiness、共享时钟与 PCM 反馈现已默认开启，精确帧映射开关仍关闭。用户报告双手机外放及蓝牙耳机体感偏差改善、没有漏拍或音质问题，记为主观听感验收反馈；未提供录音、量化数值、持续时长或开关切换记录，不据此宣称量化达标。下文缺陷、行号和 JSON 结果保留为 2026-10-27 基线记录，不代表修复后代码仍有完全相同的行为。

评审日期：2026-10-27。代码基线：`8f66535c1cbd591a5a117d679ddbed54e3ce741a`。本次新增研究脚本和结果，不改变正式播放行为，不增加运行时依赖。外部资料为当日读取的官方分支源码，链接可能随上游变化；没有把分支内容冒称为固定 release 的实现。

**建议保留 Wi-Fi P2P、队长权威、各机本地生成音频和共同未来起拍。先补齐“可信共享时间 → 音频内容位置 → 实际输出”的持续闭环，再决定是否优化网络传输。现在不能承诺跨机可闻节拍达到亚毫秒。** 最直接的优化来自 IRCAM 的稳健逻辑时钟、Ableton Link 的音乐时间映射，以及 Snapcast 的播放位置反馈，不需要整体引入任一项目。

## 1. 要保证的究竟是什么

当前产品最多 9 人（含队长），附近设备通过 Wi-Fi P2P 建网，TCP 交换控制与测时消息，音频在每台设备本地生成。队长控制开始、暂停和配置；不需要公网协作或传输现场演奏音频。播放使用 ArkTS `audio.AudioRenderer` 的 `writeData` 和硬件时间戳接口；现有 C++ OHAudio 采集模块不能直接视为原生播放后端。

验收对象应是**两台设备同一拍实际出声时间之差**，而不是 RTT、画面同拍、`SyncDiag delta` 或音频 API 调用时间。近似误差账本为：

```text
设备对可闻差 = 共享时钟估计差 + 播放时间映射差
             + 输出补偿残差 + 随时间增长的未补偿漂移
录音测得的差还包含两声源到麦克风的传播距离差。
```

用户已确认优先级：**先保证两台手机外放，再验证耳机混用**。有线输出可作辅助对照，不替代外放验收。尚无指定的数值指标，建议候选门槛为：10 分钟稳定播放的同拍绝对差 P95 ≤ 2ms、P99 ≤ 5ms，同时报告最大差、首拍差和首尾漂移；这是待真机确认可达性的目标，**不是本轮已经达到的结果**。普通 A2DP 的输出缓冲及打卡校准误差必须单独计入，不能把此门槛直接承诺给任意耳机。

## 2. 当前实现值得保留的部分

- `SessionController.ets` 已在首次/恢复前等待严格准备 ACK，再发布未来 650ms 的共同目标；队长也按同一目标播放，避免按收包时刻开拍。
- `ClockSync.ets` 使用四时间戳、低 RTT 样本过滤、`1/max(4,rtt)^2` 加权、历史一致性重置；应继续保留加权与异常隔离。
- `MetronomeEngine.ets` 在持续 renderer 中按目标帧切换内容，暂停输出底噪，避免每次重建蓝牙流。
- 网络校时、输出补偿和诊断已经分层，现有 `StartTimingDiag`、`ProductionClockDiag` 可用于验证，不必新建另一套日志链路。

这些机制正确但不等于持续同步闭环已经工作。

## 3. 影响精度的缺口，按实施优先级排列

### P0：普通播放的相位锁尚未启动，且更新后的共享时钟没有进入播放时间轴

存在两个独立问题：

1. `MetronomeEngine.ets:4044` 的 `measurePhaseErrorFrames()` 在 `audioClockLocked=false` 时直接返回。唯一将其设为 true 的位置在 `readAudioPlayheadMs()`（3849），而调用它的路径在上述检查之后。`primeAudioTimestamp()` 只读取帧，不启动该锁。旧方案 §7 已记录此问题，本轮核查仍然存在。
2. 即使人为使该锁可用，`SessionController.ets:1880` 的周期校时经 `AppSession.ets:389` 只调用 `setOffsetMs()`；该方法（1278）只赋值。播放继续使用起拍时的 `transportStartLocalMs`（1857）和本机 `60000/BPM`，相位检查的目标仍为 `nowMs - transportStartLocalMs`（4052）。本机 DAC 完全跟随本机时钟时，队长时钟漂移仍不可见。

100ppm 的假设相对钟速差在 600 秒产生 60ms 偏离。这是模型算例，不是两台现有手机的实测晶振值。默认锁关闭时，还需考虑 DAC 相对本机时钟的独立漂移。

**取舍：不要只删除 false 检查。** 当前 `playhead=(renderedFrames-audioTimelineLeadFrames)/SR`，插/丢内容帧未同步更新这个参考量；简单启用可能重复追逐同一误差。所谓拍内安全区也只是越过 click 尾部，鼓机持续镲声并不一定静音。应先明确内容帧、提交帧、硬件呈现帧的映射，再在有效时间戳下启用校正。

最小设计方向是保存队长音乐起点 `leaderEpoch`，由连续单调的时钟映射求音乐位置：

```text
leaderTime(local) = a * local + b
elapsedLeader    = leaderTime(localNow) - leaderEpoch
beatPosition     = beatAtEpoch + elapsedLeader * bpm / 60000
localDeadline(T) = (T - b) / a
```

音频期望位置、下一拍时刻和画面应使用同一映射。音频帧的预计可闻时刻还须包含路由输出延迟。播放期间采用有上限的渐进修正，暂停/准备阶段才允许重新锚定；低可信新样本不能让正在播放的逻辑时钟突然跳变。有限鼓谱、倒数、暂停和改速必须保留其 transport token 与事件位置。

### P0：统计出来的可信度可能是假的，短跨度噪声可以被当作晶振漂移

`ClockSync.ets:147` 的 `medianFromSamples()` 取快样本的偏移中位数，却返回最快一个样本的 RTT（166）。两者可能不属于同一测量，随后 `rtt/2` 区间检查和加权便失去依据。

`fitSkew()`（112）只要求两个点；没有最小时间跨度、漂移范围、拟合置信度或读取时的外推有效期。样本时间又使用批处理完成的 `now`（85），并非该测量的中点。长采样批次和前后台恢复尤其应检查这些条件。

建议将测量结构保留为 `{localMidpoint, offset, rtt, uncertainty, validCount, sampledAt}`，偏移与区间必须来自一致数据；可以选同一原始快样本，也可以做有解释的区间聚合。网络不对称下的区间还须考虑时间戳分辨率与采样跨度。至少足够样本、足够时间跨度和合理拟合残差后才启用 skew；异常拟合退回偏移模式，陈旧估计进入有期限的 holdover（短时沿用旧映射），而非无限外推。

### P1：`clockReady` 表示“调用成功”，尚不表示精度准备就绪

空批次/全无效样本在 `ClockSync.ets:149/155` 返回 `{offsetMs:0,rttMs:999}`；准备处理器 `SessionController.ets:1747–1753` 在函数 resolve 后直接标记 success。RTT<50ms 的 `good` 标签也仅是网络质量，不能解释为同步误差小于几毫秒。

应显式返回有效/无效状态，严格起拍要求有效样本、足够新鲜、误差预算可接受。无效批次保留最后可信映射并阻止严格起拍；播放期间的短暂失败可有界沿用旧映射，连续失效再降级。准备阶段可立即采用可信新锚点，不能被播放期间的慢速收敛策略拖住。

### P1：硬件时间戳语义和输出补偿必须先用声学证据闭合

普通播放路径在 `MetronomeEngine.ets:3910` 用首次查询时间定义音频时钟偏移，并按 renderer 启动后的经过时间估计帧基准；首次样本年龄及启动排队可能混入映射。代码另有原始时钟诊断和实验精确映射分支，但当前后者关闭。

这是**需要设备验证的风险**，不能仅凭公式认定它造成了某个声学偏差。此前 [耳机与外放调查](headphone-speaker-sync-debug-2026-10-22.md) 已说明：录音主要由外放主导，耳机信号不可可靠辨识，因此未证明两端毫秒级对齐。手动敲击值还包含人的反应和当前播放路径，不能当作纯耳机硬件延迟。

现存耳机补偿绑定当前生产帧映射（`MetronomeEngine.ets:3164`）。切换映射后必须重新核验校准有效性，不能自动沿用旧值并叠加第二次补偿。`MonotonicClock.ets` 当前使用 `getUptime(STARTUP)` 的毫秒返回模式；本机 SDK 声明支持 `isNanoseconds=true`。若继续追求亚毫秒目标，应测量实际分辨率和调用开销，再评估同一 STARTUP 时钟的纳秒结果换算为小数毫秒；纳秒单位本身不保证纳秒准确度，也不能混用 ACTIVE 与 STARTUP 时钟。

### P2：固定 650ms 预算和 TCP 测时可以优化，但不是第一步

目标帧不得落在已提交队列之前，延迟补偿越大，剩余调度空间越小。准备 ACK 可以增加路由版本、最早可提交的可闻时刻和时钟误差估计，再由队长选全员可达的共同目标。超期时安排明确的共同重试/未来拍点，不能把每台设备各自 clamp 后的“已开始”当作同步成功。

当前测时和配置共用 TCP。改 UDP 有助于隔离重传阻塞，但不会消除固定上下行不对称、应用线程调度或蓝牙输出残差；还增加端口、认证、重放/丢包和生命周期处理。先记录测时尾延迟与控制包排队，必要时先评估独立测时通道、靠近网络边界的时间戳及平台支持的低延迟选项。没有这些数据前不重写传输层。

## 4. GitHub 参考项目：场景、依赖与取舍

| 项目 | 它解决的场景与可借鉴思路 | 引入的依赖与适配成本 | 与当前需求的差异、结论 |
|---|---|---|---|
| [Ableton Link](https://github.com/Ableton/link) | 局域网音乐应用共享 tempo/beat/phase；将系统时间映射为音乐时间，另外映射音频采样时钟并补偿输出延迟。 | C++17 header-only、Asio 子模块、CMake；部分示例另需 PortAudio/ASIO SDK。仓库提供 GPLv2+ 或专有授权路径。HarmonyOS 不在所列验证平台，需要平台网络与音频适配。 | oneBeat 有队长权威和私有房间，不需要所有节点自由改速。**借鉴持续音乐时间映射，暂不整体引入**；只有产品要互通 Link 生态时重新评估。当前另有 `LinkAudio.hpp` 音频传输模块，不能把整个项目概括为“只传节拍”。 |
| [Snapcast](https://github.com/snapcast/snapcast) | 多房间音频广播；发送带时间戳音频块，客户端持续校时、缓冲并通过少量插/丢样修正播放偏差。 | C++/CMake、Boost ≥1.74；编解码 FLAC/Vorbis/Opus、libsoxr、TLS、Avahi、音频后端依功能选择。GPLv3+；需新增 HarmonyOS 播放适配。 | oneBeat 各机已有相同音频，串流额外增加带宽、功耗和缓冲。**借鉴播放位置反馈，不迁移串流架构**。README “通常低于0.2ms”是项目自述，不能移作本项目承诺。 |
| [IRCAM sync](https://github.com/ircam-ismm/sync) | 客户端对服务器的应用层逻辑时钟；保留测量中点、选快样本、先训练 offset 再估钟速，并使逻辑时钟连续单调。 | 纯 JS；读取的 package.json 为2.1.0，运行时依赖 `debug ^4.3.1`；BSD-3-Clause。传输由调用方提供，WebSocket 只是示例；ArkTS 仍需类型和生命周期适配。 | 最接近当前主从校时模型。**优先借鉴小范围算法，不需要引入 npm 包**；它不解决 PCM 播放、硬件时间戳或蓝牙校准。 |

证据：[Link README](https://raw.githubusercontent.com/Ableton/link/master/README.md)、[公共时钟/节拍 API](https://raw.githubusercontent.com/Ableton/link/master/include/ableton/Link.hpp)、[HostTimeFilter](https://raw.githubusercontent.com/Ableton/link/master/include/ableton/link/HostTimeFilter.hpp)、[许可文件](https://raw.githubusercontent.com/Ableton/link/master/LICENSE.md)；[Snapcast README](https://raw.githubusercontent.com/snapcast/snapcast/develop/README.md)、[构建依赖](https://raw.githubusercontent.com/snapcast/snapcast/develop/doc/build.md)、[播放修正](https://raw.githubusercontent.com/snapcast/snapcast/develop/client/stream.cpp)、[时间估计](https://raw.githubusercontent.com/snapcast/snapcast/develop/client/time_provider.cpp)；[IRCAM package.json](https://raw.githubusercontent.com/ircam-ismm/sync/master/package.json)、[SyncClient 源码](https://raw.githubusercontent.com/ircam-ismm/sync/master/src/client/index.js)。这里记录许可标签与集成选项，不对项目实际分发方式作法律结论。

IRCAM 的默认训练120秒和渐变速率不可盲抄：oneBeat 需要很快准备起拍，但播放中又不能跳钟。其默认160ppm渐变纠正10ms约需62.5秒。应借鉴“准备与播放分阶段”的原则，通过真机数据确定参数。高精度时钟也不能替代输出校准；普通应用无硬件时间戳/PTP支持时，引入系统级授时方案也不会自动打通音频最后一段。

## 5. 已完成的最小验证

当日研究入口为 `clock-sync-accuracy-probe.cjs`。历史结构化结果保留在 [clock-sync-accuracy-probe-results.json](clock-sync-accuracy-probe-results.json)，含当时生产源文件 SHA256、输入和候选参数。**2026-10-28 同名入口已改为当前修复的 4 组回归，并写入独立的 [clock-sync-fix-validation-results.json](clock-sync-fix-validation-results.json)；不会重写本节历史结果。** 新增长期 PCM 验证与按时间分配校正额度见 [分阶段修复记录](team-sync-fixes-2026-10-28.md)。

当日脚本将真实 `ClockSync.ets` 与 `MetronomeEngine.ets` 转译后执行，用可控时钟隔离缺陷；候选估计器只存在于当时研究脚本。没有下载或运行上述第三方库，因此这是**借鉴思路的最小验证，不是三个库的性能跑分**。以下表格描述旧基线，不是当前修复回归的输出。

| 验证 | 真实生产方法的结果 | 候选/结论 |
|---|---|---|
| 默认播放相位锁 | `audioStreaming=true`、renderer存在，检查返回0；播放头读取次数0，locked仍false | 证实启动条件阻断采样，不代表真实误差为0 |
| 绕过上述条件，更新跨机offset | 注入60ms offset后，相位误差仍0，起点未变 | 即便本机DAC理想，当前比较器也看不到跨机漂移 |
| 3个输入样本的统计配对 | 真值0，输出offset20/RTT2，推得区间[19,21]排除真值 | 保持同一原始样本后为0/2；注意3个输入只选最快2个 |
| 5个输入样本的统计配对 | 真值0，输出40/2，推得区间[39,41]排除真值 | 配对后40/100，区间[-10,90]覆盖真值；**偏差仍40ms，修的是可信度** |
| 相隔100ms的两样本有4ms噪声 | 拟合40000ppm，5秒后误差204ms | 研究用最小跨度/样本门槛退回offset，误差4ms；仍非精度达标 |
| 固定去程9ms、回程1ms | RTT10ms，标为good，但偏移误差4ms | 与真偏移4ms、往返各5ms完全不可辨识；换库/配对都不能凭空消除此误差 |
| 全无效批次 | 聚合成0/999，直接apply将旧可信offset5000改为0 | 候选返回null并保留5000；严格READY整链路仍需另测 |
| 稳定100ppm漂移 | 65秒目标6.5ms，生产/候选误差均为浮点量级 | 正常漂移不应因抗抖动保护而丢失 |
| 慢包污染 | 生产加权误差约−0.474ms；等权对照−54.818ms | 保留已有RTT权重；候选同为−0.474ms |
| 高噪声下限制skew | 生产误差60ms；候选30ms | 限幅仅压制放大，不足以证明准确或可信 |

研究参数为至少3样本、跨度10秒、skew限幅1000ppm，仅用于证实保护机制可以阻止特定放大路径。它们没有硬件依据，不能直接作为正式参数；限制真实漂移过大会引入偏差。候选也没有补齐播放闭环、holdover和置信度准入。

当前修复回归入口如下；它执行 READY、共享时间线、PCM 反馈和长期漂移 4 组验证，**不再复现上表旧缺陷**。旧结果以历史 JSON 中的源码指纹和输入为准：

```sh
/Applications/DevEco-Studio.app/Contents/tools/node/bin/node \
  scripts/tests/clock-sync-accuracy-probe.cjs \
  /Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js
```

现有统一回归入口在未改动的生产代码上，前55项通过，第56项 `recording-save-dialog.cjs:54` 失败：关闭保存提示后轮询重新打开。第57项 `saved-recording-page.cjs` 已单独执行通过。因此是 **56/57通过，完整门禁未通过**；失败位于录制提示状态测试，本轮不混入无关UI修复。新精度探针PASS仅表示复现和候选断言成立，不能标记生产精度通过。

2026-10-27 当时本环境 HDC 设备枚举12秒超时，未获得可用于当次测量的双机状态；当次没有真机录音、原生性能测试或ArkTS设备构建。所有毫秒数均已区分合成输入、模型推导和过去现场证据。此处为历史边界，后续构建与用户双机听感反馈见 [修复记录](team-sync-fixes-2026-10-28.md)，不以当时工具枚举状态否定后续测试。

## 6. 最小落地顺序与真机验收

以下保留 2026-10-27 的阶段建议。2026-10-28 已在修复与用户双机外放／蓝牙主观听感反馈基础上默认开启持续反馈；受控录音和量化指标仍待补充，不能将当日的建议顺序误写成已经完成的验证步骤。

1. **先修数据契约和准备门槛。** 配对样本/区间/时间点，无效批次显式失败，增加采样年龄、残差与漂移训练保护。保留现有RTT加权和一致性重置；补严格READY端到端用例。
2. **再做播放闭环的独立开关实验。** 保存leader音乐锚点与仿射时钟映射；有效硬件时间戳驱动内容播放位置，累计插/丢帧必须进入反馈。用真实PCM测试正负漂移、相位收敛、不重复修正、鼓机尾音、有限段落、暂停/恢复、调速及路由切换。不能通过直接挪动起点掩盖已提交音频不可撤回的约束。
3. **双机声学A/B决定能否启用。** 按用户选择，先双机外放，再耳机混用；有线可作辅助对照。最后用3台和最大9人确认负载对尾延迟的影响。只有确认误差来源是网络尾延迟，才做TCP/UDP测时对照或动态preroll。

最小声学实验用同一录音设备的共同采样时钟，双通道分别近距离采两端声源；先同源脉冲校验通道固定偏差。没有双通道时可用一支麦克风，但必须分别静音确认两个源都可识别，并使用可区分的音色/脉冲以免把一端声音当成双方对齐。记录并校正不同的传播路径，不能比较两台手机各自未同步录音的文件起点。

保持机型、路由、校准、音量、距离、音色和BPM不变，录制冷启动/热恢复各20次、连续10分钟、后台恢复、网络负载与一次配置切换。按同一beat编号配对，不按最近峰强行匹配；报告有符号偏差、绝对差P50/P95/P99/max、首拍/稳态分布、首尾漂移、漏拍/多拍与欠载。任何一路不可辨识都标为测量无效。

同时保存每端有效样本数/RTT分布/offset/skew/样本年龄、时钟模式、共享目标、实际targetFrame/clamp、硬件时间戳年龄、输出路由/延迟和欠载。计算链路显示亚毫秒而录音不达标时，应追查音频映射与输出残差，不能调网络参数让日志好看。

蓝牙需要分别测试外放对外放、耳机对耳机、耳机对外放及重连前后；不把固定校准的改善等同于动态缓冲也已被补偿。只有这些输出边界的数据支持时，才定义可对用户承诺的设备/路由精度范围。
