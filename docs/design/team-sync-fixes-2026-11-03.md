# 起拍前等所有设备音频就绪（2026-11-03）

承接 [2026-10-29 修复记录](team-sync-fixes-2026-10-29.md) §7、§7.1、§10。截至本文，改动未提交，未上真机。

## 1. 问题

- 单人练习连耳机、组队练习都会出现「开头漏一两拍」。
- 来源是 10-29 §7 的 `clamp-rephase`：冷启动来不及，就跳到共享网格上之后来得及的拍。

## 2. 根因

起点固定为「READY 之后 + 650ms」（`TRANSPORT_PREROLL_MS`）。音频流是冷的时候，这 650ms 里要做完：

| 步骤 | 蓝牙耗时（10-29 真机） |
|---|---|
| 新建 renderer（首次起拍，或暂停中切换输出导致帧映射坏了要重建） | 数十～上百 ms |
| 等硬件计数器开始走（`waitForMovingCounter`） | 最多约 550ms |
| 3 次读延迟取中位数（`settleOutputLatency`） | 约 160ms |
| 新写入的帧排到队列末尾才出声 | 蓝牙队列约 480ms，外放约 290ms |
| 输出补偿 | 校准值 |

蓝牙加起来明显超过 650ms，目标被夹住，于是跳拍。单人练习走同一路径（只是没有队员 READY），所以也会跳。

已有的严格 READY 只证明时钟和 PCM 就绪，**不包含音频输出**；音频流要到收到起点之后才启动。

## 3. 改法

把「音频输出就绪」放进起拍前的准备阶段；起点按最慢设备的需要来定。

1. `MetronomeEngine.prepareOutputForSharedStart()`：在空闲／暂停时
   - 检查帧映射（读一次 + 欠载计数），坏了就重建 renderer；
   - 未运行就启动（只输出 dither）；
   - 等计数器在走且时间戳新鲜（复用 `waitForFreshMovingCounter`，最多 1.5s）；
   - 返回本机需要的提前量 `leadMs = 输出补偿 + 当前队列 + SHARED_START_LEAD_MARGIN_MS(100)`。
   - 日志：`[StartTimingDiag] stage=output-prepared rebuilt= leadMs= compensationMs= queueMs= waitedMs=`。
2. `AppSession.prepareOutputForSharedStart()`：PCM 就绪后由控制器调用（`setTransportOutputPreparationHandler`），并把 renderer 标记为本会话保活，避免准备期间被大厅空闲逻辑停掉。输出失败不算起拍失败，沿用旧路径。
3. `SessionController`：
   - 队员 `TRANSPORT_READY` 新增 `audioLeadMs`；旧版本不带时按默认 650ms。
   - 队长 `preroll = clamp(max(650, 本机 lead, 队员最大 lead + TRANSPORT_START_DELIVERY_MARGIN_MS(150)), ≤2500)`，用于首次开始和恢复。日志 `[TransportPrepareDiag] role=leader stage=preroll prerollMs= localLeadMs= peerLeadMs=`。
   - 准备仍在 `TRANSPORT_START_PREPARE_TIMEOUT_MS`（4s）预算内。
4. 起点到达时 renderer 已在运行，`startAudioStream` 走连续路径，不再经过冷启动和 `clamp-rephase`。
5. 交互：队长端原有「正在准备播放…」转圈覆盖整个准备。队员端新增同样的转圈：`AppStorage.memberTransportPreparingSinceMs`（收到严格 PREPARE 时写入，收到 TRANSPORT／RESUME 或准备失败时清 0），`MainPage` 在 300ms（`WALK_RELOAD_DELAY_MS`）后才显示，超过 5s 自动收起（队长准备失败不会通知队员）。

## 4. 预期数值（按 10-29 真机数据推算，未实测）

| 场景 | lead | 起点预留 |
|---|---|---|
| 外放，renderer 已运行 | 45 + 290 + 100 ≈ 435ms | 650ms（不变） |
| 蓝牙，renderer 已运行 | ~50 + 480 + 100 ≈ 630ms | 队长本机 650ms；队员 ≈ 780ms |
| 蓝牙冷启动 | 同上，但准备阶段多等 0.3～0.8s（转圈） | 同上 |

## 5. 未覆盖

- 行进中改 BPM／拍号（`TRANSPORT_RESTART_PREROLL_MS`）和播放中切输出仍走原路径，不在本次范围。
- 播放中帧映射坏掉仍要等下次开始才重建（10-29 §10 遗留）。

## 6. 测试

- `transport-start-readiness.cjs`：队员 READY 带 lead、起点 = 最大 lead + 150；单人按本机 lead；lead 小时仍 650；队员准备标记在 TRANSPORT 后清除。
- `frame-map-broken-restart.cjs`：蓝牙式冷流（映射坏、计数器冻结 300ms、队列 400ms）先准备再起拍，不重启、无 `clamp-rephase`、`clampMs=0.00`、首拍为第 0 拍。
- 门禁 `run-sync-regressions.cjs` 75/75；`default@CompileArkTS` 成功。

## 7. 真机复测要点

1. 单人练习，连蓝牙耳机：进入行进页首次开始；暂停中拔／连耳机再开始。应从第一拍准备拍开始，无漏拍。
2. 组队（队长蓝牙 + 队员外放，及反过来）：首次开始、暂停恢复。
3. 日志：`stage=output-prepared`（看 `rebuilt`、`leadMs`、`waitedMs`），`stage=preroll`，且不应出现 `stage=clamp-rephase`。

## 8. 开始／暂停按钮转圈（追加）

- 队长点击开始、恢复或暂停后，按钮图标换成 32vp 的 `LoadingProgress`（`PLAY_BUTTON_SPINNER_SIZE`），与底部提示同样延迟 300ms 才出现，操作结束恢复图标。
- 队员在等待起拍期间（`memberTransportPreparingSinceMs` 期间）按钮也显示转圈。
- 转圈期间按钮仍不可点，但保持完整墨色（`preserveDisabledAppearance`），无障碍文本为「正在准备」。
- 测试：`walk-member-appearance.cjs` 新增转圈状态断言。

## 9. 行进中改 BPM／拍号也跳拍（10:00 日志）与修复

- 证据：上一轮日志里，行进中每次改配置后都会重启 transport；两台手机在 40 BPM 时都出现 `clamp-rephase`（4VH 4 次、3XC 2 次，夹住 239～438ms）。
- 链路：广播新配置 → 各设备在 JS 线程同步生成新 PCM → `writeData` 卡住（`[EnvelopeDiag] stage=stall-reset dropMs`：3XC 114～131ms，4VH 131～310ms）→ 欠载 → 帧映射判坏 → 重启时在 650ms 内冷启动重建 → 来不及，跳拍。120/134 BPM 时没有跳拍：生成量与总帧数成正比。
- 修复一（`SessionController.restartRunningTransportAfterConfiguration`）：仍在停手 350ms 合并后进入，改为每次都走严格准备，内容与 §3 相同（PCM → 输出修复，期间静音 → 回报提前量 → 取最大值定起点）。BPM／拍号／音色准备失败时仍按 650ms 切换；鼓机编排保持失败即不切换。大按钮在准备期间转圈。
- 修复二（根因）：配置 PCM 改在 TaskPool 后台线程生成。
  - `PcmRender.ets`：纯函数生成器，同步路径和后台线程共用，输出逐样本一致。
  - `PcmRenderTask.ets`：`@Concurrent` 入口，由 `EntryAbility.onCreate` 注册；`PcmRenderOffload.ets` 是无平台依赖的注册表，没有注册执行器时（单元测试）走同步路径。
  - 引擎：`setBpm`／`configure`／拍点修改／鼓机编排改为异步生成；结果回来之前旧节拍照常循环。起拍、切换或构建试听计划前，如果结果还没回来，就同步补算同一个任务（`[PcmRenderDiag] stage=sync-fallback`），保证不会用旧速度的 PCM 去切换。
  - `waitForPcmReady()`：严格准备会等后台生成完成后才回 READY。
  - 日志：`[PcmRenderDiag] stage=offload renderMs= roundTripMs=`、`stage=offload-failed`、`stage=sync-fallback reason=`。
- 预期：改速度不再卡住 `writeData`，也就不会欠载和重建，正常情况下不再静音；重建逻辑保留作兜底。
- 测试：新增 `pcm-render-offload.cjs`，用 `structuredClone` 模拟跨线程复制，覆盖：结果逐样本一致、包含准备拍、就绪等待、过期结果丢弃、起拍时同步补算、后台失败回退。门禁 76/76。
- 真机待确认：`stage=offload` 是否出现（若只有 `offload-failed`，说明 TaskPool 跨线程传输受限，届时再考虑分段生成）；行进中改 BPM 时不应再出现 `stall-reset` 和 `clamp-rephase`。
- 真机第一轮（11:00）：队长蓝牙试音失败。日志显示 `offload-failed ... Serialize don't support detached array buffer`。原因是 TaskPool 默认**转移**参数里的 ArrayBuffer：第一次后台生成把主线程的点击音缓冲转移走了，之后每次生成都失败，试音也用不了点击音。Pura 80 的第一次后台生成成功（`renderMs=92 roundTripMs=102`），说明 TaskPool 方案本身可行。
  - 修复：`PcmRenderTask` 对 `pcmJobArrayBuffers(job)`（点击音 + 鼓机采样）调用 `setCloneList`，改为复制。新增缓冲字段时必须同步加进这个清单。
  - 测试：`pcm-render-offload.cjs` 的模拟执行器按 TaskPool 默认行为转移不在清单里的缓冲；清空清单时，测试会复现真机上的同一个报错。
- 真机第二轮（11:14，Pura 80 当队长，16 小节鼓机）：节拍模式改善明显，鼓机模式对不齐。
  - 证据：40→120 BPM 时，队长 11:14:15.397 判定就绪，但自己的 PCM 还在后台生成；起拍时只能同步补算（`sync-fallback renderMs=2173`，队员 Pura X 为 2796），主线程卡住期间错过起点并重建音频流，随后 `clamp-rephase` 426ms／195ms。
  - 根因一：`waitForAudioConfiguration` 在鼓机模式只等 `configureProgram`。编排已加载时它会立即返回，不会等 BPM 变化触发的后台生成。修复：所有节奏模式都再等 `waitForPcmReady()`。
  - 根因二：鼓机生成很慢（16 小节、40 BPM 约 96 秒音频，后台 5.2～5.8 秒），超出 4 秒的严格准备预算。修复：队长先等本机 PCM（`TRANSPORT_PCM_PREPARE_TIMEOUT_MS = 15000`），再发 PREPARE，4 秒时钟准备预算不变；队员从收到快照起就在并行生成。队员的 PCM 拖得较久导致时钟样本过期时，再测一次。界面等待上限也改为 15 秒。
  - 测试：`session-audio-configuration-readiness.cjs` 新增鼓机 BPM 生成未完成的用例（恢复旧写法时会失败）；`drum-arrangement-switch.cjs`、`transport-start-readiness.cjs` 改为新约定（先本机 PCM、后时钟准备）。门禁单测试超时从 60 秒提到 120 秒：`drum-preview-live-update` 在改动前后都要 51～67 秒。
  - 遗留：鼓机生成本身慢，长编排在低速下改 BPM 要转圈约 5 秒。可以继续优化生成速度，或改成先生成前几小节、其余后台续算。

## 10. 鼓机：先生成开头几小节，其余后台续算

- 背景：第三轮（11:47）日志对齐正常，但 16 小节鼓机后台生成要 2.3～6.4 秒，用户每次改速度都要转圈等这么久。
- 依据：起拍和行进中重启都从编排第 0 小节开始。限幅器按样本顺序处理（`DRUM_BUS_LOOKAHEAD_FRAMES = 219` 帧前瞻，状态从第 0 帧重新开始），所以前 K 小节加上下一小节开头 219 帧，就能得到和整段生成完全一致的结果。镲片尾音（包括循环回绕到第 0 小节的部分）由所有小节计算，但只写入前 K 小节。
- 实现（`PcmRender.ets`、`MetronomeEngine.ets`）：
  - 编排超过 3 小节时，同时派发开头任务（K = max(2, ⌈N/8⌉)，`pcmHeadBarCount`）和完整任务。真机上生成速度约为播放速度的 16 倍，N/8 留了 2 倍余量。
  - 开头任务回来就算就绪，后面小节先用占位：长度与真实小节一致，内容是后台生成的同一段抖动底噪（不是纯 0，纯 0 会触发功放静音检测）。
  - 完整任务回来后按对象身份替换占位，包括带准备拍的副本序列和正在播放的那一小节；帧位置不变，所以不影响对齐。日志：`stage=offload-head bars=K/N`、`stage=offload-tail`。
  - 起拍时开头任务还没回来：只在主线程同步算开头几小节（`sync-fallback headBars=K`），完整任务继续在后台跑。只有后台失败时才同步算整段。
  - 完整任务失败时，占位小节只放底噪，时间轴照常推进，不会错位（`offload-failed part=tail`）。本地试听构建计划前会先补齐尾部（`sync-tail`）。
- 预期：16 小节、40 BPM 时，就绪时间约从 5.8 秒降到 1.1 秒以内（只算 2 小节加 219 帧）。
- 测试：`pcm-render-offload.cjs` 新增 16 小节用例（底鼓触发限幅器、镲片尾音跨小节并回绕），检查开头小节与整段生成逐样本一致，以及占位的就地替换、过期结果丢弃、起拍兜底只算开头。两个变异（去掉尾音混合、去掉限幅前瞻）都会让测试失败。门禁 76/76。
- 分块续算（取代"开头任务 + 完整任务"并行）：开头完成后，后续每次在后台生成 `pcmTailChunkBars(N)` 小节（与开头相同），生成好一块就替换一块占位，所以播放很少会碰到占位。
  - 限幅器新增 `limitDrumBusChunk` 和 `DrumBusLimiterState`（普通数字数组，跨 TaskPool 时复制）。块与块之间接力传递限幅状态，结果与一次处理逐样本一致。原 `limitDrumBus` 不变。
  - 某块失败时，在后台重试同一块（`stage=tail-retry`）；仍失败则标记 `failed`，占位继续放底噪。下一次准备起拍或切换时，`waitForPcmReady()` 接着限幅状态同步补齐剩余小节（`stage=sync-tail reason=tail-failed`）。补齐放在定起点之前，不放在起拍那一刻（`preparePlaybackBuffers`），避免起拍时卡住主线程。
  - 起拍时开头还没回来：同步生成开头块，然后续算链照常在后台进行。
  - 日志：`offload-head bars=K/N`，之后依次是 `offload-tail bars=a-b/N`。
  - 测试：`drum-bus-limiter.cjs` 覆盖随机混音（含过载、循环和非循环）在 5 种切分点下与一次处理一致，以及"释放过程跨到下一块"的情形；`pcm-render-offload.cjs` 覆盖分块逐块替换、正在播放的小节就地替换、重试、两次失败后准备阶段补齐、旧续算链丢弃、开头兜底后续算继续。两个变异检查（重置限幅状态）都会让测试失败。门禁 76/76。
- 真机第四轮（12:27，分块续算）：16 小节鼓机就绪时间降到 0.2～1.2 秒（之前 2.3～6.4 秒）；后续每块 0.2～0.8 秒，都在播放到之前替换完成；没有出现 `tail-retry` 或生成失败。
  - 唯一一次跳拍（12:27:29，`clamp-rephase` 173ms）：连续两次修改（第二次是拍号改为 3/4），间隔超过 350ms 合并窗口。第一次重启的本机准备因配置被第二次修改取代而失败，随后按"准备失败也按 650ms 切换"的兜底被发布出去；两台手机只能在起点处同步补算最新 PCM（530ms／673ms），卡住期间欠载、重建并跳拍。紧接着的第二次重启正常。
  - 修复（`restartRunningTransportAfterConfiguration`）：准备失败时，如果已有更新的配置在排队（`configurationRestartTimer >= 0`），就不发布这次重启（`stage=restart-superseded`），由排队的那次在准备好之后发布。没有排队时，仍保留 650ms 兜底。测试：`drum-arrangement-switch.cjs`（去掉这个判断时测试会失败）。
- 真机第五轮（12:40–12:43）：分块续算与 `restart-superseded` 均生效，但还有两处问题：
  - 12:40:47 的准备针对旧配置成功完成，随后速度改为 40 BPM 并进入排队；重启仍被发布，带出的最新配置两台手机都还没生成，只能同步补算（队长 944ms、队员 1203ms），导致欠载、重建。修复：只要有新配置在排队（`configurationRestartTimer >= 0`），不论这次准备是否成功都不发布。准备成功时返回 `true`，因为这次的配置会随排队的那次一起发布，鼓机编排的严格路径不会被误回滚。
  - 12:43:05 修复生效后，界面误报了两次"速度修改失败"，实际配置已在 05.920 正常切换。原因：行进中的严格准备会调用 `preemptDrumPreview()`，它即使没有在试听也会给 `drumPreviewToken` 加一（用于取消尚未开始的延迟试听），而界面等待用这个令牌判断"是否被试听接管"。修复：界面等待改用新增的 `drumPreviewStarts`，它只在真正开始试听时增加。
  - 测试：`drum-arrangement-switch.cjs`（准备成功但被取代的情况）、`session-audio-configuration-readiness.cjs`（取消延迟试听不影响并行的界面等待；"中途开始并结束一次试听"改为同时增加两个计数）。两个变异检查都会让测试失败。门禁 76/76。
- 真机第六轮（13:09 起）：没有跳拍、音频流重建、生成失败或误报；`restart-superseded` 出现 5 次，均按预期跳过过期的重启。唯一一次 67ms 同步补算来自打卡校准开始：`scheduleLatencyTapMeasurement` 切到 120 BPM 点击配置后立即开拍，点击小节还没在后台生成完。修复：开拍前先 `waitForPcmReady()`（页面提前量 1300ms，生成约 60ms）；如果等待期间测量被取代（`latencyRouteProbeToken` 变化或已退出校准），就不开拍。测试：`latency-calibration-routing.cjs`。
