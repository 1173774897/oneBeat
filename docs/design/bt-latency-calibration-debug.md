# 蓝牙耳机时延校准调试记录

> 记录 OneBeat 蓝牙耳机（A2DP）相对外放**节拍提前 >200ms** 的问题定位过程、已采纳的改进、已回退的错误改进，以及当前对问题的理解。
>
> 关联模块：`MicLoopbackCalibrator`、`MetronomeEngine`、`AudioOutputMonitor`、`AudioLatencyPersistence`。

---

## 1. 问题

多设备同步节拍时，用蓝牙耳机播放的设备，其「可闻节拍」比用手机外放的设备**提前超过 200ms**（实测，非理论估算）。

校准链路走的是麦克风回环：先测「输出 + 输入」往返，再扣掉输入侧，得到输出补偿。补偿之后仍提前 >200ms，说明补偿值偏高（补偿偏大 → 节拍写得太早 → 提前出声）。

---

## 2. 校准链路与代数

### 2.1 三个量

| 量 | 含义 | 来源 |
|---|---|---|
| `roundTrip_speaker` | 外放回环：chirp 写入渲染流 → 外放出声 → 麦克风采到 | 实测（gapMs + onsetMs） |
| `resultMs` | 蓝牙回环：chirp 写入渲染流 → 蓝牙出声 → 麦克风采到 | 实测 |
| `getLatency_speaker` | 外放输出侧时延 | `renderer.getLatency(LATENCY_TYPE_ALL)` 静态平台值 |

### 2.2 输入时延的构成

```
inputLatency = median₃( roundTrip_speaker − getLatency_speaker )
```

`roundTrip_speaker` 的分解（`[LatencyProbe]` 日志）：

```
roundTrip = gapMs + onsetMs
gapMs   = captureStartMonoMs − renderStartMonoMs
onsetMs = onsetSamples / 44100 * 1000
```

### 2.3 输出补偿的代数（关键）

```
calibrated = resultMs − inputLatency
           = resultMs − (roundTrip_speaker − getLatency_speaker)
           = getLatency_speaker + (resultMs − roundTrip_speaker)
```

而 `resultMs − roundTrip_speaker` 里，**输入时延相互抵消**：

```
resultMs − roundTrip_speaker
  = (BT_output + input) − (speaker_output + input)
  = BT_output − speaker_output
```

因此：

```
calibrated = getLatency_speaker + (BT_output − speaker_output)
```

**结论**：`calibrated` 的正确性**不依赖输入时延**，也不依赖 onset 检测的共同系统偏差（该偏差同时出现在 `resultMs` 和 `roundTrip_speaker`，相减抵消）。要让 `calibrated == BT_output`，唯一条件是 `getLatency_speaker == speaker_output`。

也就是说，`calibrated` 的误差只能来自两个地方：

1. `getLatency_speaker`（静态平台值）相对真实外放输出时延的偏差；
2. `resultMs` 与 `roundTrip_speaker` 的**差异**没有正确反映 `BT_output − speaker_output`（例如两次测量条件不一致）。

---

## 3. 已采纳的改进

1. **方案一：分块异步互相关**（`findOnsetByCrossCorrelation` 分块 + `yieldToEventLoop`）
   避免互相关阻塞主线程；只让出事件循环，**不改变锚点语义**，不引入速率问题。

2. **每探针重锚 `nowMs − bufferMs`**
   采集流第 0 帧的墙上时刻由首个 `readData` 回调时刻减一个缓冲时长确定。`gapMs` 与 `onsetMs` 会反向漂移，在 `latencyMs = gapMs + onsetMs` 里正确抵消，结果稳定（~400ms）。

3. **queueDepth 分析**
   确认不存在「未上报 266ms 硬件缓冲」：`rendered` 增速精确等于 44100Hz（无漂移），BT 与 SPK 的 queueDepth 差值落在平台时延差附近，未出现额外队列膨胀。

4. **SNR 阈值 + 中位数**
   校准采样仅在高 SNR 时采信，多次取中位数，避免低 SNR 下互相关检错峰污染结果。

---

## 4. 已回退的错误改进

1. **方案二：样本计数时钟**
   曾尝试用 `captureSampleCount / 44100 * 1000` 换算墙上时刻，以「彻底摆脱 nowMs 依赖」。实测累计样本推进速率与墙上时钟对不上（约 -33%/秒），`latencyMs` 越漂越负、测不出结果。已回退，恢复 `nowMs − bufferMs` 重锚。

2. **「未上报 266ms 硬件缓冲」假设**
   曾假设 A2DP 有块 ~266ms 硬件缓冲未被 `getAudioTimestampInfo` 上报，导致 `rendered` 滞后。queueDepth 数据不支持该假设（见 3.3），已排除。

---

## 5. 对问题的理解（含两次纠正）

### 5.1 两次口径纠正

- **误差量级**：早期曾把蓝牙提前量估成 40ms，实际实测**提前 >200ms**。40ms 只是某一轮中间推算值，不代表真实误差。
- **API 名称**：早期误以为 `AudioLatencyType` 有 `FAST / NORMAL / ALL` 三档。实际枚举只有：

  | 名称 | 值 | 说明 |
  |---|---|---|
  | `LATENCY_TYPE_ALL` | 0 | 软件 + 硬件整体链路时延 |
  | `LATENCY_TYPE_SOFTWARE` | 1 | 软件侧时延（含软件音效） |
  | `LATENCY_TYPE_HARDWARE` | 2 | 硬件侧时延（HAL、驱动、硬件） |

  因此三粒度分解应打印 `ALL / SOFTWARE / HARDWARE`，而非 `FAST / NORMAL / ALL`。

### 5.2 当前理解（随数据迭代）

- 三粒度分解实测 `getLatency(ALL)=45 = software(5) + hardware(40)`，**自洽且正常**。这推翻了「getLatency 高估真实外放输出」的早期假设——外放输出时延就是 45ms 左右。
- 关键线索转向 `delta = calibrated − platform`：实测蓝牙输出（172.8ms）比平台蓝牙 `getLatency`（285ms）**低 112ms**。
- 反推发现：`input_BT = resultMs − platform = 417.8 − 285 = 132.8ms`，而外放路由测得的 `input_SPK = 245ms`。**两者差 112ms，正好等于 delta**。说明麦克风输入侧时延**随输出路由变化**，当前「输入时延路由无关」的复用假设不成立。

### 5.3 方向冲突（待解）

- 按补偿代数，`calibrated=172.8 < platform=285` 意味着蓝牙应**晚 112ms**，而不是「早 >200ms」。因此「早 >200ms」不能单靠补偿值解释。
- 三个候选方向：输入时延路由相关性、补偿值落地到写帧时刻的链路、设备间时钟同步偏置。

---

## 6. 待办（三个调查方向 + 日志关键字）

| 方向 | 关键字 | 日志关键字段 |
|---|---|---|
| 1. 输入时延路由相关性 | `[LatencyDiag-InputRoute]` | `inputSPK` / `inputBT` / `diff` / `resultMs` / `platform` |
| 2. 补偿落地到写帧链路 | `[SyncDiag]`（已有） | `route` / `compensation` / `delta` / `frameLeadMs` / `queueDepth` |
| 3. 时钟同步偏置 | `[LatencyDiag-Clock]` | `offsetMs` |

1. **方向 1**：确认 `inputBT` 是否稳定偏离 `inputSPK`（约 −100ms 量级），坐实「输入时延路由无关」假设不成立。
2. **方向 2**：确认蓝牙路由下 `[SyncDiag]` 的 `compensation` 是否等于 172.8、`delta` 是否为负。
3. **方向 3**：确认设备间 `offsetMs` 量级，是否接近「>200ms 早」。

### 触发方法

- **方向 1**：完成一次蓝牙耳机校准（回环测量 → 保存），或切换输出路由到蓝牙触发 `refreshOutputLatency`。
- **方向 2**：蓝牙路由下正常播放节拍（开始/持续播放）。
- **方向 3**：组网（队长/队员建立连接）后开始/停止播放，触发 `setOffsetMs`。

---

## 7. 三方向调查结果（第二轮实测）

### 7.1 方向 1（输入时延路由相关性）—— 确认，真 bug

```
inputSPK=217 inputBT=104.8 diff=112.2   (第一次校准)
inputSPK=217 inputBT=122.2 diff=94.8    (第二次校准)
```

`inputBT` 稳定比 `inputSPK` 低 ~95~112ms。「复用外放 inputSPK 给蓝牙」的假设不成立。

⚠️ 注意：`inputBT` 是用 `platform=285` 反推的（`resultMs − platform`），所以这个结论**依赖「平台 getLatency(285) 准确」这个前提**。若平台值不准，方向会变。这是当前最大的未决点。

### 7.2 方向 2（补偿落地）—— 正常

- 蓝牙：`compensation=190.2ms delta=-94.8ms`，补偿值确实作用到写帧时刻。
- 外放：`compensation=45ms delta=0ms`，外放直接用 getLatency(45)。

补偿链路无问题。

### 7.3 方向 3（时钟同步）—— 正常，-11.7 天是开机时间差

- 蓝牙设备（队长）：`offsetMs=0`。
- 外放设备（队员）：`offsetMs≈-1014547985`（≈ -11.7 天）。

这个 -1014547985ms 是**两台设备单调时钟的开机时间差**，不是 bug。它稳定（漂移 ~60ppm，正常）且被正确抵消：

```
外放 audible 1169295572 − 1014547985 = 154747587 ≈ 蓝牙 audible 154747586   (对齐到 1ms)
```

### 7.4 核心矛盾与下一步

- 输入时延路由相关性（inputBT < inputSPK）按代数会让蓝牙**晚 ~95ms**，不是「早」。
- 时钟同步正确、补偿落地正确，三者都没解释「早 >200ms」。

**最可疑的新方向**：外放设备（队员）未做校准，直接用 `getLatency(45)`；若其**实际外放输出远超 45ms**，外放会晚出声，蓝牙相对就显得「早」。本质可能是「外放晚」而非「蓝牙早」。但该假设需要两设备外放时延不同才能成立（对称性约束），需实测验证。

**下一步**：用 `getAudioTimestampInfoSync` 帧映射，或声学实测，独立测两台设备的**实际输出时延**，打破「getLatency 准不准」与「inputBT vs inputSPK」的循环。

### 7.5 新增日志：独立实测输出时延

**关键字**：`[LatencyDiag-Actual]`

**关键字段**：`getLatency`（平台值）/ `actualOutput`（由 `queueDepthFrames` 换算的写→放真实时延）/ `diff`（`actualOutput − getLatency`，正数 = getLatency 低报）/ `compensation` / `queueDepthFrames`

- 纯只读，不改变任何写入/补偿时序。
- 若 `diff` 稳定为正且量级大，即坐实「getLatency 低报实际输出时延」，进而解释「外放/蓝牙晚出声 → 蓝牙相对显得早」。

**触发**：蓝牙/外放路由下正常播放节拍（与 `[SyncDiag]` 同处触发）。

### 7.6 实测结果（`[LatencyDiag-Actual]`）

蓝牙设备（新代码）单次实测：

```
[LatencyDiag-Actual] route=BT getLatency=285ms actualOutput=439.6ms diff=154.6ms compensation=163.2ms queueDepthFrames=19387.8
```

- `getLatency=285` 低报实际输出（439.6）约 **154.6ms**。
- `compensation=163.2` 比实际输出低 **276.4ms** → 蓝牙**绝对晚 276ms**（不是「早」）。
- 「第三设备实测蓝牙比外放早 ~300ms」是**相对**结果，反推外放实际输出 ≈ 621ms、晚 ~576ms，正好是低功耗渲染器 1000ms 缓冲量级。

关键结论：

1. **getLatency 严重低报实际输出时延**（蓝牙低报 154ms，外放疑似低报 ~576ms）。
2. **外放设备跑的是旧代码**（其 `[SyncDiag]` 缺 frame 映射字段、无 `[LatencyDiag-Actual]`），极可能仍走 `STREAM_USAGE_MUSIC` 低功耗大缓冲。
3. **实际输出时延在漂移**：校准 `resultMs=389.2`（22:35:01）→ 播放 `actualOutput=439.6`（22:36:43），A2DP 缓冲随时间增长，静态补偿值会很快失效。

下一步：先更新外放设备代码拿到它的 `actualOutput`，并确认其是否仍用 `STREAM_USAGE_MUSIC`。

### 7.7 补偿模型纠正 + 日志精简

**补偿模型纠正（重要）**：`compensation` 对应的是「**播放 → 出声**」的硬件时延（DAC/A2DP），不是「写 → 播放」的缓冲时延。依据代码：

```ts
actualAudibleMs = now + (targetFrame - playedFramesNow) * 1000 / SAMPLE_RATE + outputCompensationMs
```

其中 `(targetFrame - playedFramesNow)` 是「现在 → 播放」时长，加上补偿才到「出声」。所以：
- `queueDepthFrames`（actualOutput = 219.8/439.6ms）是「写 → 播放」缓冲，**由缓冲自动吸收，不需要补偿**。
- 之前「补偿应该用 219.8/439.6」「蓝牙晚 100ms」均比错对象，作废。
- 方向：补偿偏大 → 早；补偿偏小 → 晚。蓝牙早 → 补偿（163.2ms）偏高。

**日志精简**：
- 移除 `[LatencyDiag-Clock]`（offsetMs 已并入 `[SyncDiag]`）。
- 移除 `[LatencyDiag-Actual]`（actualOutput/diff 已并入 `[SyncDiag]`）。
- `[SyncDiag]` 新增字段：`beat`、`leaderAudible`（= `localAudibleStart + offsetMs`，队长时间）、`offsetMs`、`actualOutput`、`actualDiff`。

**下一步**：用 `leaderAudible` 对比两台设备同一 `beat` 的队长时间，确认「计划出声时刻」是否对齐（排除时钟同步问题）。

### 7.8 根因：输入侧时延被缓冲污染 + 缓冲测量与 chirp 冷启动不一致

**实测（两轮）**：
- 第一轮：`回环 389.2ms − 输入测 397ms = −7.8ms`，补偿为负被拒。
- 第二轮（只减缓冲）：`inputLatencyMs` 在 −52~+112ms 间跳动，最终钳到 0ms —— 不正常。

**两层根因**：

1. `getLatency(ALL)` 只报 `software + hardware`（45ms = 5 + 40），**不计入实时缓冲（队列深度 ~257ms）**，所以 `inputSPK = roundTrip − getLatency(ALL)` 会把缓冲污染进输入侧。

2. 直接减「实时缓冲 + 硬件」又**过度校正**：chirp 在渲染流**冷启动**时写入，其「写入→播放」只有启动延迟（~90ms），远小于稳态队列深度（~257ms）。于是 `roundTrip(255.8) ≈ buffer+hardware(276.8)`，两者相减把麦克风链（~165ms）也抵消掉，得到 ~0ms。

**修复（完整版）**：
- `runLoopback` 正式 chirp 前**连续喂 1000ms 静音预热**（`LOOPBACK_WARMUP_MS`），让渲染流达到稳态，chirp 的「写入→播放」才等于稳态 `buffer + hardware`；
- 新增 `chirpSubmitMonoMs` 作为 chirp 首帧真正「提交」锚点（预热结束后的写时刻），`analyzeCaptured` 改用它（替代 `renderStartMonoMs`）；
- 输出侧时延 = `hardware + bufferMs`（`submittedFrames − framePos` 实测队列深度）；
- `inputLatency = roundTrip − (hardware + bufferMs)` → 纯麦克风链。

**预期**：`inputLatencyMs` 稳定在 ~165ms（麦克风链），`calibrated = resultMs − 165` 为正值可保存。

---

## 8. 蓝牙持久探针：flush 冷启动 + mic 消失（当前进度）

### 8.1 现象

蓝牙持久探针（`runPersistentProbe`，复用会话 Renderer/Capturer）实测：

```
[LatencyProbe] latencyMs=544.8 = gapMs(-927.7) + onsetMs(1472.5)
[LatencyProbe] latencyMs=416.6 = gapMs(-485.2) + onsetMs(901.8)
[LatencyProbe] latencyMs=410.6 = gapMs(-396.1) + onsetMs(806.7)
[LatencyProbe] latencyMs=408.0 = gapMs(-288.0) + onsetMs(696.0)
[LatencyProbe] latencyMs=411.9 = gapMs(-302.0) + onsetMs(713.8)
```

`latencyMs` 收敛到 ~411ms，恰好等于稳态队列深度量级，**mic 那一段（~232ms）没被吃到**。于是 `calibrated = resultMs − inputLatency` 等于把 mic 又减了一遍（双倍扣减），calibrated 偏小 ~232ms。

### 8.2 根因一：flush 冷重启 → 队列半空

`scheduleCalibrationSignal` 的 `ensureSilentRendererRunning()` 做 stall 检测：`lastWriteProgressMs` 距现在超过阈值则 `haltRendererNow()` 冷重启（清空 `audioSubmittedFrames`）。随后 chirp 立即按 `targetFrame` 排入，此时队列还是空的：

```
[CalibDiag] renderer NOT healthy, flush+restart, state=3 lastWriteAge=30376ms
[CalibDiag] schedule targetFrame=25313 playedFrames=0 submittedFrames=0 leadMs=574.0
[CalibDiag] renderer healthy, keep buffer, queueDepthFrames=0 submittedFrames=110592
[CalibDiag] schedule targetFrame=127294 playedFrames=101010 submittedFrames=110592 leadMs=596.0
```

队列从 0 慢慢追（0 → 217 → 297 → 430ms），chirp 始终落在「半空队列」里，`resultMs` 只反映队列深度、吃不到 mic。

**修复**：`scheduleCalibrationSignal` 在 `ensureSilentRendererRunning()` 之后、排 chirp 之前，插入 `await this.warmUpRenderQueueForCalibration()`，固定暖机 1200ms（与输入侧 `LOOPBACK_WARMUP_MS=1000` 同思路），让 writeData 先把 dither 队列填到稳态，再推进一次 `queueDepthFrames` 测量。关键字 `[CalibDiag] warm-up done`。

### 8.3 根因二：mic 消失（待查）

数学上 `latencyMs = gapMs + onsetMs`，`captureStartMonoMs` 在两者之和里**精确抵消**——锚点错只会改 gapMs/onsetMs 的分配，不会改变它们的和。所以 `resultMs` 缺 232ms mic，只可能是 `gapMs`（submit 锚）或 `onsetMs`（互相关检测）之一本身测错：

- H1：`chirpSubmitMonoMs`（submit 锚）偏晚 ~232ms；
- H2：`findOnsetByCrossCorrelation` 锁到真峰前 ~232ms 的副峰（电串扰/早反射）。

**判别**：双 chirp 间距法——两 chirp 固定间隔 800ms，其 onset 位置差是锚无关声学真值。若间距 ≈800ms 则 onset 检测准（→ H1），否则 onset 检测有系统偏置（→ H2）。

### 8.4 新增诊断日志

| 关键字 | 位置 | 作用 |
|---|---|---|
| `[CaptureAnchorDiag]` | `readDataCallback` | 打印首个 readData 回调的 `nowMs / bufferMs / n / captureStartMonoMs`，验证「首帧 = 回调时刻 − 缓冲时长」锚定是否被 mic 流水线时延破坏 |
| `[CorrPeaksDiag]` | `findOnsetByCrossCorrelation` | 打印相关序列前 3 强峰（粗域 lag），判断真峰前 ~232ms 是否有副峰（H2） |
| `[LatencyProbe]`（扩字段） | `analyzeCaptured` | 新增 `lenSamples / tailMs / capStart / chirpSubmit`，检查 chirp 是否被 1300ms 采集窗口截断、submit/capture 锚绝对时刻 |

**验证目标（重跑一轮）**：看暖机后 `queueDepthFrames` 是否到稳态、`tailMs` 是否 >50ms（未被截断）、`[CorrPeaksDiag]` 是否在真峰前 ~232ms 出现副峰。

### 8.5 数据判读（暖机后第一轮）

**暖机生效**：`queueDepthFrames` 从 0/217/297 → 18416/22512/23394（≈417–530ms 稳态）。

**但 mic 消失未解决，且暴露更硬的证据**：稳态 `latencyMs ≈ 384–400ms < queueDepth ≈ 510ms`——回环比输出队列还短，物理不可能；chirp 被「采到」的时刻在它出声前 ~110ms。

- `[CorrPeaksDiag]` top3 峰都在 ±20ms 内（单一主瓣）→ H2（锁副峰）**排除**。
- `tailMs ≈ 900ms` → 截断**排除**。
- `[CalibDiag] schedule leadMs=509–510ms` 是独立已知量（chirp 提交后 ~510ms 才出声），submit 锚 `calibrationSignalSubmitMonoMs` 正确 → 结论：**capture 锚 `capStart = firstReadDataTime − bufferMs` 偏早 ~340ms**。

**顺带发现第二个 bug**：`runLoopback` 的 `rendererInfo = { usage: STREAM_USAGE_GAME, rendererFlags: 0 }`，未指定路由，临时 renderer 继承当前默认路由 = 蓝牙而非外放。证据：输入侧 `outputLatencyMs=267ms`（外放平台值才 45ms）。这让 `inputLatency = roundTrip − 267` 也混进蓝牙量，基准不干净。

**下一步**：用 `AudioCapturer.getAudioTimestampInfoSync()`（返回 `framePos` + `timestamp`）独立锚定采集流，替代 `now − bufferMs` 估算，直接验证 capStart 偏早量。

### 8.6 数据判读（第二轮：拿到 capture 锚日志）

**capture 锚 buffer 尺寸假设没问题**：`[CaptureAnchorDiag] firstReadData bufferMs=20.0 n=882`——`bufferMs = 882/44100 = 20ms` 正确，`capStart = nowMs − 20ms`。之前「偏早由 bufferMs 高估导致」的猜测**排除**。

**核心矛盾依旧，且更硬**：稳态 `latencyMs ≈ 410ms`（异常稳定），但 `queueDepth ≈ 524ms`。回环比输出队列还短 ~114ms，声学上不可能。

**两个候选解释**：
- (a) **电/数字串扰**：loopback 采到的是 renderer→capturer 的非声学串扰（~410ms 是串扰路径延迟，不是声学往返）。
- (b) **queueDepth 高估**：`renderedFrames`（`getAudioTimestampInfoSync().framePos − audioTimestampBaseFrame`）被低估 → `queueDepth = submitted − rendered` 被高估。真实 output ≈ 180ms，则 `410 = 180 + 230(mic)` 其实**是对的**，`calibrated = 178.5ms` 也近似真实输出。

**判别实验（决定性）**：把耳机音量调到 0 重跑一轮。
- 相关峰仍在 ~410ms → (a) 串扰，loopback 不可信；
- 峰消失/大幅变弱 → (b) 声学，`latencyMs=410` 可信、`queueDepth` 诊断错，校准值本身可能没问题，问题在外放侧（外放 `calibrated=0`、只补偿 45ms，其真实输出 ~378ms → 外放晚 ~333ms，蓝牙相对就显得「早 333ms」）。

**顺带确认的第二个 bug**：`runLoopback` 的 `rendererInfo = { usage: STREAM_USAGE_GAME, rendererFlags: 0 }`，未指定路由 → 临时 renderer 走蓝牙默认路由（输入侧 `outputLatencyMs=267ms`，外放平台值才 45ms），`inputLatency` 被蓝牙量污染。

### 8.7 音量=0 判别实验（决定性）+ 路由修复受限

**音量=0 重跑结果**：相关峰**消失**——`snrDb` 从 64dB 掉到 17dB、`peak` 从 0.02 掉到 0.0036、`[CorrPeaksDiag]` 峰位四处乱跳（108/467/647/1055/1521…ms）、`latencyMs=-662.7`（负值=噪声）。

**结论**：loopback 采到的是**声学信号**，不是电串扰。`latencyMs≈410ms` 是真实声学往返，`calibrated = resultMs − inputLatency = 178.5ms` 即真实蓝牙输出（≈180ms）。**串扰假设（8.6-a）排除，queueDepth 高估假设（8.6-b）成立**：`queueDepth=524ms` 是 `renderedFrames` 低估导致的诊断虚高，真实输出只有 ~180ms。

**路由修复受限（已回退）**：想在蓝牙连接时强制输入侧走外放，
- `setDefaultOutputDevice(SPEAKER)`（API 12）只改「无外设时的默认」，蓝牙接入后**蓝牙仍优先** → 无效；
- 真正能强制外放的是 `setMediaOutputDevice(SPEAKER)`（**API 26**），但工程 target 是 API 20 → **不可用**。

即：在当前 SDK 上，普通应用**无法**在蓝牙连接时把输入侧临时 renderer 强制切到外放。

**真正的结论与下一步**：~~蓝牙侧 `calibrated=178.5ms` 基本正确，「蓝牙比外放早 ~333ms」实质是外放侧晚 ~333ms~~ **（此结论错误，见 8.8 更正）**。

### 8.8 更正：外放不晚，蓝牙是真提前（关键数学矛盾）

**用户澄清**：外放设备没有校准逻辑，`platform=45ms` 就是准的，天然音画同步 → 外放**不会晚**。所以「蓝牙早 333ms」是蓝牙**真的提前了**，8.7 的「外放晚」结论不成立。

**关键数学矛盾**：补偿应用为 `hardware = audible − compensation = audible − 178.5ms`。即使蓝牙输出为 0ms（瞬时出声），最多也只能提前 **178.5ms**，到不了 333ms。要「早 333ms」，必有一笔 ~155ms 的额外提前量，不是补偿值本身能产生的。

**代码已埋线索**（MetronomeEngine 414 行附近注释）：`calibrated = resultMs − inputLatency` 会把 mic 双倍扣减，导致蓝牙比外放快——作者早知道此症状。

**真正要查的**：不是「外放为何晚」，而是蓝牙的 `localAudibleStart` / `offsetMs`（leader-follower 时钟对齐）本身是否提前了 ~333ms，或 `estimateTargetStreamFrame` 帧映射是否有偏移。需对比两台机器完整 SyncDiag 的 `leaderAudible` 与 `offsetMs` 字段。

### 8.9 根因修正：submit 队列被重复补偿

> 状态：**代码已修正，待真机复测**。本次只改 mic 回环及它的输入侧辅助校准；
> 打卡机的测量、保存和正式播放入口均未改。

#### 8.9.1 已定位的参考系错误

打卡机正常而 mic 回环异常，差异不在保存或正式播放链路。两者都写入
`outputCompensationMs`，但旧 mic 测量以 chirp 进入 `writeData` 的 **submit 时刻**为起点，
正式播放却以 Renderer 的 **presentation/frame 时钟**调度。

记：

- `Q = presentation − submit`：已提交、尚未写入硬件的可变队列；
- `H = audible − presentation`：HAL / 驱动 / 蓝牙链路 / 耳机的真正可闻时延；
- `I`：麦克风输入处理到 `readData` 的时延。

旧耳机回环实际测得：

```text
chirpCaptured − chirpSubmit = Q_BT + H_BT + I_BT
```

正式播放的 `estimateTargetStreamFrame()` 已经把 Q 吸收在「当前播放帧 → 目标帧」映射中，
应用层只需补偿 H。把 `Q + H` 存进 `outputCompensationMs` 会在正式播放时又提前一次 Q。
A2DP 的 Q 会随暖机、路由重连和队列水位变化，因此这个错误同时解释：

1. 校准后耳机比外放早 200ms 以上；
2. 每次测量的提前量都不同；
3. 增加 1200ms 暖机只能稳定队列，不能修正参考系。

#### 8.9.2 最终修复

`MetronomeEngine.scheduleCalibrationSignal()` 仍等待 chirp 真正进入 `writeData`，但 submit
时刻只用于诊断。返回值改为 `targetFrame` 在 Renderer 帧时钟上的
`presentationMonoMs`。耳机回环现在测：

```text
headphoneRoundTrip = chirpCaptured − chirpPresentation
                   = H_BT + I_BT
```

这个 presentation 锚必须来自有效的 Renderer hardware timestamp。若暖机后连续查询仍拿不到
`framePos + timestamp`，本轮直接失败并提示重试；不能退回墙钟加 `queueDepthFrames` 猜测，因为
新路由的 queue depth 可能仍是 0 / 旧值，fallback 会再次把 Q 混入结果。

旧的独立 `runLoopback()/measure()` Renderer 路径已删除，避免以后误调用时又回到 submit 基准。
当前页面只能通过 `AppSession.scheduleMicLoopbackSignal()` 使用会话持久 Renderer。

输入侧校准也通过 `AppSession.metronome` 的持久 Renderer 播放外放 chirp，使用同一
presentation 帧时钟。`AudioTimestampInfo` 的帧已经过软件处理并写入硬件，
所以这里只扣 `LATENCY_TYPE_HARDWARE`，不扣包含已经过去的 SOFTWARE 段的 `ALL`：

```text
inputLatency = speakerRoundTrip − H_SPK
             = (H_SPK + I_SPK) − H_SPK
             = I_SPK

savedCompensation = headphoneRoundTrip − inputLatency
                  = H_BT + (I_BT − I_SPK)
```

当外放与蓝牙下的 MIC/AEC 处理链相同时，`I_BT ≈ I_SPK`，保存值就是正式播放需要的
`H_BT`。

#### 8.9.3 路由切换不得复用旧帧基准

mic 流程会主动经历 `BT 断开 → SPK 输入校准 → BT 重连 → 耳机回环`。
同一 Renderer 可以跨路由存活；若只看 Renderer 已运行时长，重连后的第一个探针会错误地
认为旧路由已暖好，并继续使用旧 `audioTimestampBaseFrame`。

现在 `AudioOutputMonitor` 用首选输出的 `deviceType + deviceId` 组成路由签名；`AppSession` 检测到
签名变化后会标记 mic 校准帧纪元失效。因此不只 SPK↔BT，A2DP↔SCO/NearLink 以及同类型的
耳机 A↔耳机 B 也会失效。新路由上的第一个 mic 探针必须：

1. stop 并 flush 旧路由队列；
2. 重置 Renderer timestamp/frame 映射；
3. 重启并完成 1200ms 暖机；
4. 至少观察到两个 hardware timestamp 样本且 `framePos` 确实前进，再选 chirp 的
   presentation target。

stop / flush 任一步失败都会中止本轮，不能只清本地计数后继续；否则物理旧队列仍在，Q 又会被
伪装成输出时延。硬件时间戳连续查询仍未推进时也同样失败关闭，而不是猜测 queue depth。

输入校准期间若用户提前连回蓝牙，本次输入结果直接丢弃。
输入侧开始前和完成后还会确认首选输出确实是手机内置 `SPEAKER`；有线、USB、听筒或查询失败
都不能冒充“手机外放”。
耳机回环完成后、保存前若蓝牙断开，尚未保存的结果也立即作废；重连后必须重新测，不能把旧路由
结果绑定到新连接。保存的 preferences flush 期间也会二次核对 measurement token；若路由在异步
保存中变化，则恢复保存前的共用输出补偿，不激活本次旧路由结果。

#### 8.9.4 无效输入值不得被伪装成 0

旧 UI 会把负的 `inputLatencyMs` 用 `Math.max(0, value)` 钳成 0 并保存。这会把整段真实
MIC 输入时延留在 `savedCompensation` 里；若 MIC 链路约 200ms，恰好会再造成约 200ms 早出声。

现在输入侧：

- 3 次探针至少 2 次必须同时定位成功、得到 `1..1000ms` 的物理可行值，并形成极差不超过
  30ms 的稳定簇；3 次中只允许剔除 1 个明显离群值；
- 负值、0、非有限数或过大值只记 `[MicInputCalibration] reject`，不进入中位数；
- UI 不再 clamp；持久化层也拒绝 `<= 0` 的值。

输入/输出持久化都改为 preferences `flush()` 成功后才更新内存与页面状态，避免磁盘保存失败时
本会话却继续使用一个只存在于 UI / 内存中的新补偿。

输入侧持久化语义版本升为 **3**。旧值使用 submit/队列估算或 `ALL` 扣减，升级后
自动视为未校准，必须断开蓝牙用手机外放重测一次。只失效 mic 的输入侧值，
**不清除共用的输出补偿**，因此不会破坏已经正常的打卡机结果。

#### 8.9.5 新诊断与真机验收

新增 `[CalibAnchor]`：

```text
submitMonoMs=... presentationMonoMs=... submitToPresentationMs=...
```

`submitToPresentationMs` 就是旧算法会多算的 Q。它可以随 A2DP 队列波动，但修复后保存的
mic 补偿不应再跟着它同幅漂移。

路由切换后的首个探针还会出现
`[CalibDiag] renderer NOT healthy, flush+restart, routeReset=true ...`，用来确认 SPK / BT
没有复用同一套 timestamp/frame 基准。

真机复测顺序：

1. 升级后确认输入侧显示为未校准；
2. 断开蓝牙，用手机外放重测输入侧；
3. 重连同一耳机，连续做 3 轮 mic 回环；
4. 对比每轮 `[CalibAnchor].submitToPresentationMs`、`[MicLoopback] selected/spread` 和最终保存值；
5. 与同路由上的打卡机结果及外放实际听感交叉检查。

验收重点不是要求 Q 不变，而是：Q 变化不再被写入补偿，且校准后不再出现
`>200ms` 的早出声。

#### 8.9.6 仍保留的限制

公式中仍有 `I_BT − I_SPK`。即使两步都固定使用 `SOURCE_TYPE_MIC`，系统在外放和蓝牙路由下
仍可能采用不同的 AEC / 降噪 / 输入缓冲。本次修复去掉了可变的 submit 队列和无效 0 值，
但不能从理论上保证 `I_BT == I_SPK`。

当前采集首帧仍以 `first readData callback time − buffer duration` 估算，因此 `I` 也包含
readData 投递与 ArkTS 调度项。每个探针重新取首个新鲜缓冲、两阶段使用相同 MIC 配置并各自取
中位数，可以压低其随机影响；但这部分不会在单次 `gapMs + onsetMs` 内自动抵消，路由间差异仍会
留在 `I_BT − I_SPK` 中。

若复测后 mic 与打卡机仍存在「稳定、可重复」的差值，且该差值已不再跟
`submitToPresentationMs` 变化，下一调查对象应是 `AudioCapturer.getAudioTimestampInfoSync()` 的输入帧映射，
或同路由下的输入侧测量；不应再把 Renderer 队列 Q 加回补偿。

---

## 9. 验收问题

### 9.1 验收问题一：输入侧校准往返时延锚点漂移

按 8.9.5 真机复测顺序第 2 步「断开蓝牙，用手机外放重测输入侧」，页面稳定报
`未定位到输入侧时延，请把手机麦克风对准外放出声点后重试`。日志：

```text
[LatencyProbe] latencyMs=338.5 = gapMs(-1312.3) + onsetMs(1650.8) ... snrDb=62.2 peak=0.566
[LatencyProbe] latencyMs=11.2  = gapMs(-629.0) + onsetMs(640.2)  ... snrDb=62.8 peak=0.566
[LatencyProbe] latencyMs=-61.2 = gapMs(-626.0) + onsetMs(564.8)  ... snrDb=63.0 peak=0.562
[MicInputCalibration] reject inputLatencyMs=-28.8  roundTripMs=11.2  hardwareLatencyMs=40
[MicInputCalibration] reject inputLatencyMs=-101.2 roundTripMs=-61.2 hardwareLatencyMs=40
[MicInputCalibration] samples=298.5ms selected=298.5ms
```

判读：

1. `snrDb=62~63dB`、`peak≈0.56`：chirp 被稳定锁定，**排除**「蓝牙未断开 / 外放未出声 /
   麦克风未对准」等物理原因。
2. 三次 `roundTripMs` 剧烈漂移（338.5 → 11.2 → -61.2），而 `hardwareLatencyMs` 固定 40ms。
   `inputLatencyMs = roundTrip − hardware` 两次为负（-28.8 / -101.2）被判无效，仅第一次
   298.5ms 有效。有效样本 = 1 < 2 → `detected: false`。
3. `gapMs`（采集锚→参考）第一次 -1312.3、后两次 ~-628：暖机后首拍锚点错位。
4. `onsetMs`（chirp 在采集缓冲内位置）1650.8 → 640.2 → 564.8，第 2、3 次 onset 落在
   参考时刻之前（+11.2 / -61.2ms），真实外放声学往返不可能为 0 或负——互相关锁到错误峰，
   或 presentation 锚与采集时钟未对齐。

后续连续重试提供了决定性证据：

```text
gapMs    -788.7  -944.8  -1020.3  -991.4  -1110.2  -1127.8  -1110.1  -1118.9  -1118.9
onsetMs   386.0   323.1    302.7   415.3    312.0    312.0    432.1    310.1    310.1
latency  -402.6  -621.8   -717.6  -576.1   -798.1   -815.7   -678.0   -808.8   -808.8
snrDb      62.4    59.1     65.0    63.0     65.9     65.9     62.9     63.1     64.1
```

记 `C=captureStartMonoMs`、`L=onsetMs`、`P=presentationMonoMs`，则：

```text
roundTrip = C + L - P
P - C     = -gapMs
```

每轮在拿到新采集 buffer 后只请求 `now + 600ms`，而 `C≈now−20ms`，所以暖机完成后的
`P−C` 应在约 620ms 附近。实际却从 789ms 继续涨到 1119ms。与此同时，相关峰稳定出现在
`C+310~432ms`，SNR 一直为 59~66dB。也就是说代码一边已经录到了当前 chirp，一边却声称
该 chirp 还要 400~800ms 才呈现，违反因果。问题在 Renderer 的 `P` 晚报，不在声学检测。

先前“把 target 从 `now()` 改绑到 `probeCaptureStartMonoMs`”的初步结论因此作废：两者只有
一个约 20ms 的采集 buffer 差，无法解释数百毫秒且持续增长的误差。

#### 9.1.1 根因

旧校准复用了正式播放的启发式 Renderer 帧映射：

```text
baseFrame = rawFramePos - min(submittedFrames, rendererRunningElapsedFrames)
played    = rawFramePos - baseFrame + timestampAgeFrames
target    = max(submittedFrames, played + requestedLeadFrames)
P         = queryNow + (target - played) / 44100
```

这里有三处不满足校准精度要求：

1. 路由切换只对同一 Renderer 做 stop / flush，随后用“运行墙钟经过量”猜 `baseFrame`。这个
   guess 不等于硬件实际播放帧数；一旦偏小，`submitted−played` 就表现为不断膨胀的假队列。
2. 稳定性只检查两次 `raw framePos` 有增长，没有检查
   `ΔframePos / Δtimestamp ≈ 44100Hz`；错误坐标仍会被当成稳定硬件时钟。
3. 音频 timestamp 使用 ACTIVE monotonic 时钟，业务调度使用包含深睡的 STARTUP uptime。
   旧代码把第一个音频 timestamp 强行对齐到查询 `now`，会吞掉 timestamp 的真实 age；之后再以
   query time 插值 `P`，不是以 timestamp 对应的硬件帧插值。

假队列一旦超过请求的 600ms lead，`max(submittedFrames, desiredFrame)` 就把 chirp 排在队尾，
并用膨胀后的 `submitted−played` 计算 `P`，因此 `P` 越报越晚，产生本次负往返时延。

固定 1300ms 采集窗口还是一个独立问题。chirp 自身长 500ms；当 `P−C` 已到 1119ms 时，若按
第一次合理往返约 338ms 计算，至少要约 `1119+338+500=1957ms` 才能录完整当前 chirp。
旧窗口会在当前 chirp 尚未完整到达时结束，使错误帧映射进一步演变成截断或旧峰风险。

#### 9.1.2 修复（只作用于麦克回环）

1. 路由切换后的首个 mic 探针不再复用旧 Renderer：stop 后 release，并按同一
   `STREAM_USAGE_GAME / 44.1kHz / mono` 配置重建。新 Renderer 后续仍由正式播放复用；
   `framePos` 与 `audioSubmittedFrames` 从同一流原点开始。非路由切换但需要重建校准时钟时，
   也会先 flush，再把两侧计数同时归零。
2. 新增严格的 `[CalibClock]` 校验。至少跨 100ms 读取两个递增 timestamp 样本，要求帧速率在
   44.1kHz 的 ±2% 内、frame/timestamp 不回退、实时队列在物理合理范围内；失败就让本轮失败并
   要求重建，绝不回退到墙钟猜队列。
3. 使用同时读取的 `STARTUP−ACTIVE` 差把硬件 timestamp 转到业务单调时钟，再直接从
   `(framePos, timestamp)` 插值 chirp 的目标帧：

   ```text
   presentationMonoMs = timestampMonoMs + (targetFrame - framePos) / 44100
   ```

   query `now` 只用于诊断 timestamp age，不再充当 presentation 时刻。
4. 探针采集截止时刻改为相对已验证的 `presentationMonoMs` 动态计算，覆盖最大预期往返、完整
   500ms chirp 和 150ms 尾部余量，不再使用固定 1300ms。

打卡机的测量、保存、补偿公式和页面均未改。改动只发生在
`scheduleCalibrationSignal()` / `runPersistentProbe()` 这条麦克回环链路。

#### 9.1.3 复测判据

输入侧重新测 3 次时应同时满足：

- `[CalibClock] rateHz` 接近 44100，`queueMs` 不再逐轮单向膨胀；
- `[LatencyProbe]` 的 `roundTripMs` 为正，且不再出现“onset 已发生、presentation 仍在未来”的
  负因果关系；
- `[MicInputCalibration] samples` 至少有 2 个值，所选稳定簇极差不超过 30ms；
- 首轮若发生 Renderer 暖机可以比后续更慢，但不能改变同一路由的测量值。

当前仍保留 `first readData callback − buffer duration` 的 Capturer 锚。它会把 readData 投递和
ArkTS 调度并入输入侧基线，但 SPK / BT 两阶段使用相同 MIC 配置并分别取中位数，现阶段仍按
`I_BT−I_SPK` 相消。若 Renderer 修复后仍剩“稳定且可重复”的路由差，下一步才是用
`AudioCapturer.getAudioTimestampInfoSync()` + 从 capturer start 起不重置的全局帧游标重建输入帧
时钟；不能只把某个 callback buffer 生硬绑定到即时 `framePos`，也不能继续沿用 `<=0` 必为无效
的“输入时延”语义。
