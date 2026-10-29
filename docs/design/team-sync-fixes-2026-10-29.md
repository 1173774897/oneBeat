# 组队同步修复记录（2026-10-29）

设备：队长 3XC0225318009821，队员 4VH0225528018782。场景以「队长蓝牙耳机 + 队员外放」为主。
前一天的工作见 `team-sync-optimization-review-2026-10-28.md` §7。本文所有改动均在
`entry/src/main/ets/audio/MetronomeEngine.ets`，另有少量诊断入口（见 §8）。截至本文，改动均未提交。

## 0. 结论速览

| # | 问题（真机现象） | 根因 | 修复 | 真机验证 |
|---|---|---|---|---|
| 1 | 队员冷启动前约 3.5s 偏 75ms | 首次读数 framePos=0 时计数器还没走，按经过时间推算的基准偏了 | 先只在计数器开始走后重算（后被 #6 取代）；包络重算平移 ≥15ms 时立即重新对齐 | 8 次冷启动，后续包络重算 ≤3.2ms |
| 2 | 切换输出后读数来回跳 ±50ms；「开始播放时欠载」 | 欠载期间计数器仍在走，空白被算成已播放，映射超过已写入数据而被夹住 | 判定基准已坏（超出已写入 >20ms，或设基准后又欠载），下次开始前重建音频 | 暂停中切换后出现重启；正常暂停不误触发 |
| 3 | 打卡机结果大幅跳动（294/419/309/151） | 测量发生在基准已坏的流上；蓝牙队列深，超出检查看不到 | 设基准后有欠载即判坏（`reason=underflow`） | 同一连接 359/351 |
| 4 | 队长蓝牙 + 队员外放约 80ms 不齐（队长快） | 外放队员的新建 renderer 被按经过时间推算，多算了硬件启动延迟（约 124ms 里扣掉首读前的 ~46ms） | 新建 renderer 首次启动直接用计数器原点（played = framePos） | 用户确认对齐 |
| 5 | 打卡机测完后基准又被挪 26ms | 「计数器开始走再重算」在蓝牙下推迟到 20s 后才发生 | 重算仅限启动后 1s 内 | — |
| 6 | 停止→启动（同一 renderer）后起点每次不同 | 计数器从停住处续走，但停住时已计数未播出的部分不定（外放约 20ms，蓝牙相差 >100ms） | 生产路径的重启一律销毁并新建 renderer | 13:18–13:22 已验证（见 §10） |
| 7 | 蓝牙重启后整段晚 137ms | 重启时离目标拍只剩 158ms，不够 306ms 补偿，被夹住后硬播 | 夹住 >15ms 时改到共享网格上之后来得及的拍 | 11:37 漏两拍后对齐目标拍 |
| 8 | 新建 renderer 后打卡机测得 310/297（运行中的流测得 64），之后播放与试听都偏早 | 蓝牙新建 renderer 后计数器数百毫秒才开始走，冷启动在计数器未动时就定下目标，整条流晚了这段启动延迟，打卡机把它记进了补偿 | 冷启动等计数器开始走后再定目标 | 13:18–13:22 已验证（见 §10） |
| 9 | 播放中外放切蓝牙偶发队长晚约 100ms（6 次中 1 次） | 切换期间计数器停走，时间戳旧了 566ms；映射按「仍在走」外推最多 250ms，高估已播放量，目标排晚 | 重新对齐前等读数新鲜（≤60ms）且计数器在走 | 13:18–13:22 已验证（见 §10） |

## 1. 冷启动前几秒偏移（上午）

- 现象：08:13 队员冷启动，包络重算平移 77.8ms，3 次确认后才重新对齐，期间偏 75ms。
- 证据：首读 framePos=0（rawAgeMs≈0），170ms 后 cold-settle 读到非零值，按同公式得到的基准与后来包络重算只差 0.1ms。
- 修复：
  - `phaseResyncAfterRebase`：包络重算平移 ≥15ms（`AUDIO_PHASE_RESYNC_ENVELOPE_THRESHOLD_MS`）时，下一次检查直接重新对齐；偏差已 <15ms 则清除。
  - 「计数器开始走后重算」（`idle-counter-reanchor`）：基准先作临时值，首个移动读数时按同公式重算；超过 25ms（`IDLE_COUNTER_REANCHOR_MIN_MS`）才改；仅限启动 1s 内（`IDLE_COUNTER_REANCHOR_WINDOW_MS`，见 §5）。新建 renderer 已由 §4 的精确原点取代，此逻辑只剩无法确定原点时的兜底。

## 2. 欠载破坏帧映射

- 证据：两次「暂停中蓝牙切外放」后，计数器按真实时间走，已写入数据少了 297–368ms；`raw - base` 超出已写入 336ms，播放头被夹在已写入帧上，形成一个写块（约 93ms）宽的锯齿；相位反馈看不到约一个缓冲的真实误差。包络重算又因欠载被跳过，错误一直保留。
- 昨天认为的「蓝牙约 60ms 锯齿是测量本身的问题」，大部分是这个夹住造成的（08:43–08:45 那段从启动起就超出 21–107ms）。
- 修复：
  - `audioTimestampBaseBroken`：
    - 启动 1s 后（`FRAME_MAP_BROKEN_GRACE_MS`）超出已写入 >20ms（`FRAME_MAP_BROKEN_EXCESS_MS`）判坏（`reason=excess`）。门槛依据：健康流最大 +7ms，坏流 29–377ms。
    - 开始播放时，若设基准后欠载计数变了也判坏（`reason=underflow`）。蓝牙队列约 270ms，空白小于队列时超出检查看不到。
  - 开始播放时（`startAudioStream`）检查，坏了就重启（日志 `base-broken-restart`），复用本次开始本来就要做的那次读数，不增加原生调用。
- 已知未做：播放中途坏掉，要等下次开始才修。
- 另：三次「开始播放时欠载」其实是暂停期间路由切换产生的，计数只在每小节第一拍读，延后才报出。

## 3. 打卡机结果

- 打卡机结果 = 本流起点误差 + 链路延迟 + 人体偏置。测量和之后的播放在同一条流上时误差相抵，所以每次「测完都能对齐」，但换流就失效。
- `[CalibSaveDiag]`（`store/AudioLatencyPersistence.ets`）：每次保存记录旧值和新值，便于区分「重测」与「流变化」。
- 当天数值：294 → 419 → 309 → 151（基准坏）→ 359/351（同连接）→ 326/328 → 270/321/334/306（停止→启动流）→ 26（新建流）/288/419（停止→启动流）。

## 4. 新建 renderer 用计数器原点

- 证据：外放队员每次冷启动首读 framePos=0；cold-settle 显示硬件约 124ms 后才开始走。旧推算假定「start() 即出声」：首读处多算 ~46ms，包络重算/重算后多算 ~124ms，队员整体晚 ~80ms，蓝牙队长听起来偏快。文档记录的历史对齐（`bt-latency-calibration-debug.md` §9.8 的 `56c9e55`，`headphone-speaker-sync-debug-2026-10-22.md` 的 414ms）都早于包络重算。
- 修复：`rendererPhysicalStartCount === 1` 且 `0 ≤ framePos ≤ audioSubmittedFrames` 时基准 = 0（`baseUpdate=fresh-origin`，日志 `state=base-init origin=fresh`），不再重算、不做包络重算（`audioTimestampBaseExactOrigin`）。不满足时退回经过时间推算。
- 没有任何写死的毫秒常数；前提是系统保证新建 renderer 的计数与写入帧同从 0 开始（目前仅在这两台设备上验证）。
- 调试切换：`onebeatProbe=origin-on/off`（暂停时，下次新建 renderer 生效）。

## 5. 重算窗口

- 证据：10:22:42 打卡机测完后，蓝牙在启动 20s 后才有第二次读数，误差略超 25ms，基准被挪 26ms。
- 修复：重算只在启动后 1s 内进行。

## 6. 重启一律新建 renderer

- 诊断（`[RestartOriginDiag]`，仅调试版）：停止后读计数器报错（返回 undefined），所以改为停止前读；重启后前 1.5s 每回调记一次计数。7 次重启：停止耗时 57–194ms，期间计数继续走；重启后计数停在停住值，27–58ms 才继续；首读在 16–40ms。
- 先尝试「首读 ≤45ms 即视为停住值作原点」（`RESTART_ORIGIN_MAX_FIRST_READ_MS`，`restart-origin`）。复测：外放仍慢约 20ms；蓝牙两次重启后的打卡值 288 与 419 相差 131ms，起点不定。新建流测得 26 且对齐。
- 修复：`replaceRendererNow()`（release + create），用于：
  - `startAudioStream` 中需要物理重启且该 renderer 已启动过（`rendererPhysicalStartCount > 0`）时（日志 `renderer-rebuild reason=start`）；
  - `ensureSilentRendererRunning` 普通播放的重启（`reason=silent-restart`）；
  - 原有的麦克风重建和输入探针重建也改为调用同一函数。
- `restart-origin` 逻辑保留给仍走停止→启动的路径（如麦克风 flush 路径）。

## 7. 来不及就跳到下一拍

- 证据：11:07:24 蓝牙重启，provisional headroom 158ms，补偿 306ms；cold-settle `clampMs=136.94`，此后整段晚 137ms，暂停再开始（不重启）后对齐。
- 修复：冷启动后若目标被夹住 >15ms（`START_CLAMP_REPHASE_MS`），记录 `stage=clamp-rephase`，在渲染队列外调用 `rescheduleForOutputRouteChange()`，改到共享网格上之后来得及的拍。代价是开头少响一两拍。

## 7.1 冷启动等计数器开始走（12:15 追加）

- 证据（12:09–12:13）：
  - 12:09 测得 64：测量开始时流已运行约 6s，走的是已有流的路径，此后对齐。
  - 12:11 测得 310、12:13 测得 297：两次都是 renderer 刚新建（首读 18–23ms，framePos=0）就开始测量。随后在已有流上播放和试听，队长耳机偏早，试听时声音也早于亮灯。
  - 12:09 那条流在启动 1.5s 后首读，计数只走到约 1.0s，说明蓝牙新建 renderer 的计数器约 550ms 后才开始走。
- 根因：冷启动在计数器停在原点时就按「下一帧立即开始播放」定下目标，整条流晚了这段启动延迟。打卡机测量时把它记进了补偿；之后在已有流上播放会按正在走的计数器重新定目标，不再晚，补偿就多出这一截，所以偏早。
- 修复：`waitForMovingCounter()`，在冷启动 `settleOutputLatency()` 之前轮询计数器，等它离开首读值再定目标。
  - 每 10ms 一次（`COLD_START_COUNTER_POLL_MS`）；最晚等到目标硬件时刻前 150ms（`COLD_START_COUNTER_WAIT_LEAD_MS`），最多 80 次（`COLD_START_COUNTER_MAX_POLLS`）。
  - 等到来不及时，仍由 §7 的跳拍处理。
  - 日志 `[StartTimingDiag] stage=counter-wait moved= waitedMs= sinceStartMs=`。
  - `[RestartOriginDiag] stage=startup` 的启动轨迹扩展到所有物理启动（含新建）。
- 撤回：一度在已有流的开始播放路径也加上跳拍判断，但牵动多个按旧行为记录诊断的测试；而那几次夹住的根因是补偿偏大（本节），所以撤回。
- 测试：`frame-map-broken-restart.cjs` 模拟计数器 300ms 后才开始走，验证目标按计数器真正开始走的时刻计算。

## 7.2 播放中切换输出：等计数器恢复再对齐（13:00 追加）

- 复测结果（12:45–12:57）：
  - 打卡机三次分别测得 55、52、18，每次都对齐；
  - 暂停中切换：重新开始后 1～2 拍不齐，随后对齐；
  - 播放中直接切换 6 次，只有 12:55:40 外放切蓝牙那次不齐（外放早、耳机晚，约 100ms）。
- 证据：失败那次重新对齐时读到的时间戳旧了 566ms（`rawAgeMs=566.6`，`sampleFresh=false`），排队估计只有 82ms；成功的几次时间戳新鲜（0～5ms），蓝牙排队 310–360ms。
- 根因：切换期间计数器停走。旧映射按「仍在走」外推，最多外推 250ms，因而高估了已播放量，目标排晚。之后读数恢复，但映射认为内容已经在拍上，不会再修正。
- 修复：`waitForFreshMovingCounter()` 放在 `prepareOutputRouteRenderer()` 的最后，要求时间戳 ≤60ms 内（`ROUTE_REPHASE_FRESH_AGE_MS`）且计数器比上次读数前进了。
  - 每 20ms 一次，最多等 1.5s（`ROUTE_REPHASE_COUNTER_WAIT_MS`）。
  - 超时仍继续对齐，不放弃切换，并记日志 `stage=counter-unsettled`。
  - 等待超过一次轮询时，记日志 `stage=counter-ready`。
- 测试：`phase-resync.cjs` 模拟时间戳旧 566ms 持续 400ms，验证程序等到计数器恢复后才继续。

## 8. 诊断与调试入口

- 日志：`state=base-init`（origin、首读、停止前计数）、`state=base-broken reason=excess|underflow`、`base-broken-restart`、`renderer-rebuild`、`idle-counter-reanchor`、`stage=clamp-rephase`、`[RestartOriginDiag]`（调试版）、`[CalibSaveDiag]`。
- 调试命令：`hdc -t <id> shell aa start -a EntryAbility -b com.onebeat.app --ps onebeatProbe origin-on|origin-off`（`TeamAcousticProbe.ets`、`AppSession.configureFreshOriginExperiment`）。

## 9. 测试

- 新增 `scripts/tests/frame-map-broken-restart.cjs`：超出判坏、启动宽限、欠载判坏、重建 renderer 后精确原点、夹住 >15ms 重新对齐。
- `playback-position-envelope.cjs` 新增：零/冻结计数重算、移动首读不重算、新建 renderer 原点与 origin-off、重算仅限启动、重启首读冻结原点。
- `phase-resync.cjs` 新增：大幅包络重算后立即重新对齐。
- 调整（新检查对原用例设定的合理反应）：`metronome-count-in-realtime.cjs` 队列 0 → 150ms（120ms 渲染耗时下 0 队列即欠载）；`metronome-start-buffer-diagnostics.cjs` 首启夹住用例放入启动宽限；`production-clock-diagnostics.cjs` 区分首启/重启的基准原因；`metronome-audio-lifecycle.cjs`、`metronome-route-transition.cjs` 的模拟对象支持 release/create；`team-acoustic-probe.cjs` 覆盖 origin 命令。
- 门禁：`node scripts/tests/run-sync-regressions.cjs`，68/68。

## 10. 最终复测（13:18–13:22）与未完成

用户反馈：各种切换都能对齐。日志确认如下。
- 打卡机：12:48–12:51 分别测得 55、52、18，13:18 测得 30，13:20 测得 24，每次都对齐。不再出现 26～419 的大幅跳动。
- 播放中直接切换输出：13:18:51–13:19:43 外放和蓝牙来回切换 9 次，全部完成重新对齐，没有出现 `counter-unsettled`。
  - 13:19:43 切到蓝牙时等了 258ms，计数器恢复后才定目标（`counter-ready waitedMs=258.0`），正是 12:55 那类情况。
  - 切到外放后有两次大偏差重新对齐（-15.4ms、-19.6ms），属于包络路由的正常修正。
- 基准已坏时：都新建了 renderer（`renderer-rebuild`），新流都用精确原点（`origin=fresh`）。
  - 13:19:51：计数器 238ms 内没开始走（`moved=false`），目标被夹住 445ms，于是跳到第 138 拍（`clamp-rephase`）。
  - 13:21:08：计数器 92ms 后开始走，目标被夹住 198ms，跳到第 6 拍。
  - 用户听到的「开头漏一两拍」就是这两种跳拍。

未完成：
- 播放中基准坏掉（日志 `base-broken ... streaming=true`）时，要等下次开始播放才会新建 renderer；当次靠重新对齐保持在拍上。
- 蓝牙下目前仍不启用包络读数和大偏差重新对齐。昨天禁用它们的依据，大部分其实是 §2 说的「播放位置被截到已写入量」；是否重新启用，需要另外评估。
- 新建 renderer 的精确原点只在这两台设备上验证过。
- 调试日志 `[RestartOriginDiag]` 仍保留，只在调试版输出。

## 11. 蓝牙包络评估与试验（13:30 起）

- 评估（日志 12:00–13:22）：
  - 23 次启动的前 1.5s 轨迹里，蓝牙计数器和外放一样，按 20ms 一格前进，与回调间隔一致。排队深度稳定（蓝牙新建流 480–497ms，外放 280–297ms），波动约 ±7ms，没有看到整块超前。
  - 计数器开始走时有一次 75ms 的跳变，蓝牙和外放都有，发生在启动 1s 的预热期内，不进入包络。
  - 12:40 之后，蓝牙旧映射的偏差读数共 45 次：中位数 −1ms，p10/p90 为 −14/+6ms。只在切换后几秒短暂出现 −15～−18ms。昨天的约 60ms 锯齿已经不再出现。
  - 结论：昨天把蓝牙排除在包络之外的两条依据，都来自 §2 的夹住问题；可以试验在蓝牙下开包络。
- 试验开关：`bluetoothEnvelopeEnabled`，默认关闭，不持久化。调试命令 `onebeatProbe=bt-envelope-on|bt-envelope-off`，在暂停或空闲时下发（`AppSession.configureBluetoothEnvelopeExperiment`）。
  - 打开后，蓝牙也使用包络，大偏差重新对齐（15ms，`shouldResyncPhase`）也在蓝牙下生效。
  - 两条路由都允许包络时，切换路由不会改变「是否允许」，因此改为按 `wireless` 变化清空采样窗口，日志 `stage=route active= wireless=`。
- 判据：打开后重新打卡；然后组队播放、播放中切换、暂停再开始，看以下几点：
  - 蓝牙下 `[EnvelopeDiag] stage=max-jump` 是否出现超前读数（`shiftMs` 明显为正）；
  - `summary` 的 `spreadMs` 是否稳定；
  - `stage=resync` 是否只在真实偏差后出现；
  - 听感是否对齐。
- 测试：`playback-position-envelope.cjs` §14、`phase-resync.cjs`（试验开启时蓝牙会重新对齐）、`team-acoustic-probe.cjs`。
- 试验结果一（14:00–14:06）：外放切蓝牙 3 次，每次开头约两小节不齐，之后自行对齐。
  - 证据：重新对齐时排队估计为 0（`queueMs=0.0`，`base-broken excessMs=189.7`），残差 −377ms；约 5s 后包络最大值过期，`max-jump shiftMs=-591/-730`，触发重新对齐后才对上。
  - 14:06 重启应用后每次都对齐：重启后试验开关恢复默认关闭，蓝牙回到旧映射。
- 根因：切到蓝牙时计数器停了约 590ms，恢复后一直落后于墙钟。包络假定计数器与墙钟同速，取窗口最大值时一直沿用停之前的读数，直到 2s 后过期。
- 修复：
  - 新读数比窗口内（2s 以内的）最大值低超过 50ms（`PLAYBACK_ENVELOPE_STALL_DROP_MS`）时，清空窗口重来，日志 `[EnvelopeDiag] stage=stall-reset dropMs=`。正常读数的滞后分布最多约 30ms。
  - 时间戳超过 60ms 的读数不进入包络（`PLAYBACK_ENVELOPE_MAX_SAMPLE_AGE_MS`）。
  - 测试：`playback-position-envelope.cjs` §15，模拟停 590ms 后确认估计立即跟上计数器。
- 试验结果二（14:26–14:30）：播放中外放与蓝牙互切 8 次，全部对齐。
  - 切到蓝牙时出现 `stall-reset`（61–72ms），重新对齐时排队估计 367–381ms，正常。
  - 暂停中切到蓝牙再开始（14:28:59、14:29:54）：第一拍不齐，3～4 拍后对齐。
- 根因（暂停中切换）：开始时重建 renderer，冷启动等计数器开始走期间，蓝牙在计数器冻结时就接受了写入，临时目标约 260ms 后被写出（`applied`，此时 `counter-wait moved=false`），于是响了一个错拍；随后判定夹住 438–502ms，跳到 4 拍之后对齐。
- 修复：等计数器期间，若临时目标还没写出，先把它压住（targetFrame 置为最大值，只写静音），由 settle 装入真正的目标；日志 `counter-wait held=true`。效果：不再先响一个错拍，代价是开头安静几拍后直接在拍上开始。
- 测试：`frame-map-broken-restart.cjs` 模拟冻结期间写入约 400ms，验证 settle 之前没有任何拍被写出。
- 结论（14:40）：按用户决定，蓝牙改为默认使用包络。已删除试验开关（`bluetoothEnvelopeEnabled`、`bt-envelope-on/off`、`configureBluetoothEnvelopeExperiment`）。
  - `playbackEnvelopeActive()` 对所有路由都返回 true，只在 `wireless` 变化时清空采样窗口。
  - 大偏差重新对齐对蓝牙同样生效（15ms）。
  - 原有的 `envelope-on/off` 仍可整体回退到旧的单次读数。
  - 测试：`metronome-phase-feedback.cjs` 的额度用例改为 12ms 偏差，因为 25ms 在蓝牙下也会触发重新对齐；`playback-position-envelope.cjs` §7 改为蓝牙使用包络、切换路由清窗；`phase-resync.cjs` 改为蓝牙会重新对齐、关闭包络后不会。
  - 暂停中切到蓝牙时「压住临时拍」的修复，在开关删除前还没在真机上复测。

