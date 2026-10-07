# OneBeat 多设备节拍同步方案

> 本文档描述 OneBeat（多设备同步节拍器）如何在多台 HarmonyOS 设备之间，把节拍声对齐到**亚毫秒级**。
>
> 涉及模块：时钟同步（`ClockSync`）、Transport 调度（`SessionController` / `AppSession`）、音频引擎（`MetronomeEngine`）、输出设备监测（`AudioOutputMonitor`）、绝对延迟校准（对齐法，方案）。

---

## 1. 概述

OneBeat 通过 WiFi P2P 组网，以一台设备为**队长（leader）**、其余为**队员（member / follower）**。核心目标只有一个：

> 让所有设备的「可闻节拍声」在同一时刻响起。

难点在于三处偏差要逐一消除：

1. **设备间时钟差**：不同设备晶振不同、起点不同，需先统一时间基准；
2. **音频输出时延**：从「写入音频帧」到「喇叭发声」有数毫秒到数十毫秒的路由时延（DAC / 无线耳机等）；
3. **渲染器启动抖动**：`renderer.start()` 后写回调的首次触发时机、以及硬件时间戳何时可用，都是不确定的。

同步方案分四层，逐层收紧误差。

---

## 2. 整体架构

```
┌──────────────┐   TRANSPORT 消息（startAtLeaderMonoMs, beatIndex, countIn, bpm, beatsPerBar）
│  队长 leader  │ ────────────────────────────────────────────────▶ ┌──────────────┐
│  (本地时钟)    │                                                     │  队员 member  │
└──────────────┘                                                     │  (本地时钟)    │
       │                                                              └──────────────┘
       │ 自身也按同一时刻调度                                                 │ 用 offset 换算回本地时间
       ▼                                                                  ▼
   MetronomeEngine.scheduleFromLeaderStart()                    MetronomeEngine.scheduleFromLeaderStart()
```

- **时钟同步层**：队员用 NTP 风格的往返测时估算「队长时钟 − 队员时钟」的 offset，并用线性 skew 拟合修正晶振漂移。
- **调度层**：队长挑一个「未来的整拍下拍」作为 `startAtLeaderMonoMs` 广播出去；每台设备把它换算成自己的 `localStart`。
- **时延补偿层**：`localStart` 前移一个 `getLatency()` 的输出时延，得到 `audibleStart`，保证「可闻」时刻对齐。
- **锁钟层**：用硬件时间戳（`getAudioTimestampInfo`）精确算出首拍内容要提前写入多少帧，并在行进中做闭环相位校正。

---

## 3. 时钟同步（`ClockSync.ets`）

### 3.1 NTP 风格 offset 估计

队员向队长发 ping，记录四个时间戳：

```
clientSendMs ──▶ serverRecvMs（队长收到）
clientRecvMs ◀── serverSendMs（队长回复）
```

对称假设下，单程时延 = RTT/2，于是时钟偏移：

```text
offsetMs = ((serverRecvMs - clientSendMs) + (serverSendMs - clientRecvMs)) / 2
rttMs    = (clientRecvMs - clientSendMs) - (serverSendMs - serverRecvMs)
```

约定方向：`leaderMono ≈ clientMono + offsetMs`（offset = 队长 − 队员）。

### 3.2 线性 skew 拟合

单纯用 offset 会在长时间行进中因晶振漂移而偏离。`ClockSyncEstimator` 保留一组带时间戳的样本，做线性回归：

```text
offset(t) ≈ skewRefOffsetMs + skewPpm * (t - skewRefAtMs) / 1e6
```

`getOffsetAt(t)` 按此投影，把「固定偏移」升级为「随时间漂移的偏移」。

### 3.3 采样与重采样

- `PING_SAMPLES = 11`：起拍前采足够多低时延样本，总耗时控制在 ~300ms 内。
- `RESYNC_INTERVAL_MS = 5000`：行进中每 5s 重采样，抑制晶振与网络变化的长期漂移。
- 网络质量分级：`rtt < 50` good / `< 150` fair / 其余 poor。

---

## 4. Transport 调度

### 4.1 队长侧（`SessionController.ets`）

队长在「改拍 / 恢复 / 起拍」时，先给所有队员发配置，再挑一个共享的未来下拍：

```text
nextBarBeatIndex = (floor(beatIndex / beatsPerBar) + 1) * beatsPerBar
restartAt        = nowMs + TRANSPORT_RESTART_PREROLL_MS   // 650ms
```

`restartAt` 就是 `startAtLeaderMonoMs`，随 TRANSPORT 消息广播。

### 4.2 队员侧（`AppSession.ets` → `MetronomeEngine.scheduleFromLeaderStart`）

队员收到消息后，把队长时间换算回本地时间：

```text
localStart = startAtLeaderMonoMs - offsetMs
```

若消息到达时 `localStart` 已过（网络迟了），则顺延到未来的整拍：

```text
missedBeats = ceil((now - localStart) / interval)
localStart += missedBeats * interval
```

随后按 `audioDelay` 延迟启动音频流：

```text
audioDelay = max(0, localStart - now - AUDIO_PREROLL_MS)   // AUDIO_PREROLL_MS = 650ms
```

> 之所以留 650ms 的 preroll，是为了给「停旧渲染器 + 启动新渲染器 + 等硬件时间戳」留足余量（见 §6 和 §9.4）。

---

## 5. 音频输出时延补偿

「写入帧」到「喇叭发声」之间存在路由时延（DAC、无线耳机等）。若不做补偿，所有设备会统一地晚一个 `latency`。

### 5.1 运行时读取

```text
outputLatencyMs = renderer.getLatency(AudioLatencyType.LATENCY_TYPE_ALL)
```

`refreshOutputLatency()` 负责读取并缓存；`getLatency` 在流尚未路由时可能返回 0，此时**保留旧值**，避免把缓存清零。

### 5.2 提前提交

```text
audibleStart = localStart - outputLatencyMs   // 正值=提前提交
```

即音频内容时间轴整体前移 `outputLatencyMs`，使「可闻」节拍落在 `localStart`。UI 节拍仍以 `localStart` 为准。

> 实测两端设备 `getLatency(LATENCY_TYPE_ALL)` 均报 **45ms**，日志里 `acousticDelay=45`。

### 5.3 用 GAME 流规避低功耗大缓冲

渲染器用 `StreamUsage.STREAM_USAGE_GAME`。原因是低功耗（smart PA）通路有一个**不被 `getLatency` / `getAudioTimestampInfo` 上报的大缓冲**，会导致设备间数百毫秒的可闻偏差。GAME 流走普通/低时延通路，规避该问题。

### 5.4 蓝牙 A2DP 的限制与检测（已实现）

`getLatency(AudioLatencyType.LATENCY_TYPE_ALL)` 只覆盖**手机侧**链路（软件 + HAL + 硬件，到蓝牙芯片的 PCM 接口为止），**不含**蓝牙空中链路 + 耳机侧编解码缓冲 + DAC。因此普通蓝牙 A2DP（SBC/AAC）的可闻时延约 **150~250ms**，且不恒定（RF 干扰/重传带来 ±10~50ms 抖动），系统也没有 API 把它报出来。

已落地 `AudioOutputMonitor.ets` 做检测与提示：

- `getAudioManager().getRoutingManager().getDevicesSync(OUTPUT_DEVICES_FLAG)` 遍历判断是否含 `DeviceType.BLUETOOTH_A2DP`；
- `routing.on('deviceChange', ...)` 监听输出设备切换，首次与每次切换都回调当前是否为蓝牙 A2DP；
- `AppSession` 构造时 `start()`、`shutdown()` 时 `stop()`，结果写入 `AppStorage` 的 `btAudioActive`；`MainPage` 据此弹提示条 + toast。

> 结论：只能**检测到**「是不是蓝牙」，**拿不到蓝牙延迟数值**。要补偿蓝牙延迟，必须走 §5.6 的校准。

### 5.5 低时延流 ID（`getAudioStreamIdSync`，已实现）

`AudioRenderer` / `AudioCapturer` 提供读取框架分配的**流 ID** 的只读接口（`@since 12`，跨平台）：

```typescript
getAudioStreamId(callback: AsyncCallback<number>): void;
getAudioStreamId(): Promise<number>;
getAudioStreamIdSync(): number;
```

它是**纯只读诊断**：只返回该 renderer 的流 ID（一个 `number`），**不改变** `StreamUsage`、状态、缓冲、路由，因此不会影响已在使用中的 GAME 流。

实现位置 `MetronomeEngine.ets`：

```typescript
private rendererStreamId: number = -1;   // 字段

// ensureRenderer() 内、this.renderer = created 之后：
try {
  this.rendererStreamId = created.getAudioStreamIdSync();
  console.info(`MetronomeEngine streamId=${this.rendererStreamId}`);
} catch (e) {
  this.rendererStreamId = -1;            // 失败静默，绝不打乱传输
}
```

用途：诊断（区分低时延通路 / 蓝牙通路、多流对齐）。失败回落 `-1`，与 `getUnderflowCountSync` / `getAudioTimestampInfoSync` 同类，均不打断节拍。

**能力边界（SDK 现状，API 24 / HarmonyOS 6.1.1）**：

| 能力 | 状态 |
|---|---|
| `getAudioStreamId(Sync)` | ✅ 可用（`@since 12`） |
| `isFastPlaybackSupported` | ❌ 起始 **API 26**（当前 SDK 为 API 24，尚未提供） |
| `AudioLatencyType.LATENCY_TYPE_ALL` | ✅ 可用，但「硬件」只到手机蓝牙芯片，不含空中链路 |
| `createAudioGroup`（音频工作组） | ❌ HarmonyOS NEXT 无此接口（`openharmony` / `hms` 均搜不到） |

### 5.6 绝对延迟校准（对齐法，方案）

> 本节为**方案设计**，尚未落地代码。目标从「设备间相对同步」改为「每台设备补偿自己的**绝对延迟**」——因为蓝牙耳机要跟**画面**同步，而画面与外放都锁在同一个墙钟上，所以对齐蓝牙到外放/画面，就等于对齐到绝对墙钟。

**目标与公式**

```text
D_i(绝对) = D_phone + D_bt_link
D_phone   ：手机侧时延，可用 getAudioTimestampInfoSync / getLatency(LATENCY_TYPE_ALL) 已知化
D_bt_link ：蓝牙空中链路 + 耳机 DAC，系统不可见，需校准测得
补偿       ：把蓝牙流的调度时刻提前 D_i（audibleStart = localStart - D_i）
```

参考系是墙钟 T：画面闪烁、外放都调度在 T，所以对齐后三者同时到用户。

**交互设计（对齐法，一次性 ~30 秒）**

1. 进入校准页，触发一个低频「试验节拍器」（如 40 BPM），**画面闪烁 + 蓝牙 click 同时**按同一墙钟 T 调度。
2. 用户拖一个「偏移」滑杆（步进 1ms，范围 ±300ms），直到「看起来、听起来」同步。
3. 重复 3 轮，取**中位数**收敛（对齐是归零任务，无反应时，精度 ±5~15ms）。
4. 保存 `outputLatencyOffset`（绝对语义，单位 ms），按「设备型号 + 耳机型号 + 编解码器」为 key 持久化。
5. 提供「对齐前 / 对齐后」试听预览，让用户确认效果。

**音画感知不对称容差**

人对音画不同步的容忍是**不对称**的，直接影响滑杆默认方向与验收容差：

| 方向 | 可察觉阈值 |
|---|---|
| 声音**滞后**画面 | ~+125ms 才明显 |
| 声音**超前**画面 | ~−45ms 即察觉 |

因此：默认让音频**略微滞后**（宁可 +10ms，不要 −10ms）；验收容差设 **±10~15ms**。

**技术方案**

1. **数据结构**：`outputLatencyOffset: number`（ms，绝对延迟），持久化。
2. **校准算法**：滑杆值即 `D_bt_link` 的估计（画面已对齐墙钟，把蓝牙声对齐到画面 = 归零蓝牙相对画面的偏移）；多轮取中位数后写入 `outputLatencyOffset`。
3. **播放端接法（复用现有 phase lock 时间轴）**：在 `refreshOutputLatency()` 里，当 `AudioOutputMonitor.isBluetoothA2dpActive()` 为真时，`outputLatencyMs` 不再用 `getLatency(LATENCY_TYPE_ALL)`（它不含蓝牙），改用校准值 `outputLatencyOffset`，即 `audibleStart = localStart - outputLatencyOffset`。其余（锁钟 §6、相位锁定 §7）不变——它们本就作用在「前移后的时间轴」上。
4. **存值复用**：命中同「设备 + 耳机 + 编解码」缓存则跳过校准直接加载；未命中才引导校准。

**精度与局限**

- 精度 ±5~15ms（对齐法，归零任务无反应时）。
- 局限：蓝牙抖动 ±10~50ms **无法消除**，只能消除「恒定偏移」。
- 缓解：引导使用 LC3 / aptX LL / 星闪（NearLink，5ms 级）等低时延耳机，同时降低偏移与抖动。

---

## 6. 硬件时间戳锁钟（`lockAudioStartToPresentationClock`）

这是把首拍定位到亚毫秒的关键。`renderer.start()` 会**立即触发写回调**，而写回调可能一次性灌满多个缓冲，把首拍顶跑。锁钟用硬件时间戳来精确计算「首拍内容到底该提前多少帧写入」。

### 6.1 墙钟占位（fallback lead）

在 `renderer.start()` 之前，先用墙钟算一个「估计 lead」，让写回调先灌这段静音占位：

```text
fallbackFirstBeatFrame = max(0, round((localStart - rendererStartRequestedAtMs) * SAMPLE_RATE / 1000))
audioLeadSamples = fallbackFirstBeatFrame
audioStartAnchorPending = true
```

### 6.2 写回调（`fillAudioData`）

写回调每次填一个缓冲（4096 帧 ≈ 93ms）。在 `audioStartAnchorPending` 阶段，只写 `audioLeadSamples` 帧静音；写完就切到正式节拍内容。这防止写回调在锁完成前把整个大缓冲灌满静音（overshoot）。

### 6.3 锁循环

锁循环用 `getAudioTimestampInfoSync()` 反复采样，直到拿到有效时间戳：

```text
framePos  + timestamp          // 硬件帧位置 + 采样时的时间戳
```

第一次有效采样时建立时基对齐：

```text
clockOffsetMs      = timestampMs - now        // 硬件时间戳时基 → 应用单调时钟时基
timestampInNowBase = timestampMs - clockOffsetMs
```

### 6.4 已播帧数（playedFramesNow）

统一帧坐标系（以「流启动以来」的帧序号为基准）下：

```text
playedFramesNow = min(submitted,
                      (info.framePos - audioTimestampBaseFrame)
                    + min(250, now - timestampInNowBase) * SR/1000
                    + max(0, now - rendererStartRequestedAtMs) * SR/1000)
```

其中：

- 首样本时 `audioTimestampBaseFrame` 刚被重置为当前 `framePos`，`now ≈ timestampInNowBase`，两项都趋近 0；
- 因此补上 `(now - rendererStartRequestedAtMs) * SR/1000`（renderer 启动以来墙钟已播帧数），避免漏算导致 lead 下溢；
- 再用 `min(submitted, ...)` 钳制：**未提交的帧不可能已被播放**，避免 `played > submitted` 导致首拍提前。

### 6.5 剩余 lead 与首拍定位

```text
queueDepthFrames = max(0, submitted - playedFramesNow)
audioLeadSamples = max(0, round((localStart - now) * SR/1000 - queueDepthFrames))
```

等价于 `fallbackFirstBeatFrame - submitted`，即「还剩多少静音要写」。之后：

```text
actualFirstBeatMs = now + (submitted + lead - playedFramesNow) * 1000 / SR
dev               = actualFirstBeatMs - localStart
```

`dev` 即首拍定位误差（帧位置层面）。目标 `dev ≈ 0`，此时「可闻节拍」正好落在 `localStart`。

### 6.6 锁循环参数

| 常量 | 值 | 含义 |
|---|---|---|
| `AUDIO_CLOCK_LOCK_RETRY_MS` | 8ms | 采样失败后的重试间隔 |
| `AUDIO_CLOCK_LOCK_TIMEOUT_MS` | 300ms | 锁的总超时 |
| `AUDIO_CLOCK_LOCK_MIN_REMAINING_MS` | 80ms | 距 localStart 的最小剩余时间 |

锁的 deadline 取 `min(rendererStart + TIMEOUT, localStart - MIN_REMAINING)`。硬件时间戳拿不到时走 **fallback** 路径（用纯墙钟 `fallbackFirstBeatFrame` 定位）。

---

## 7. 行进中的相位锁定

锁钟只定位**首拍**。行进中因晶振漂移、缓冲抖动，音频播放头会慢慢偏离墙钟时间轴。`measurePhaseErrorFrames()` 持续测量：

```text
phaseError = round((playhead - expected) * SAMPLE_RATE / 1000)   // 帧
expected   = nowMs - transportStartLocalMs                        // 理想播放头
```

> 正值 = 音频偏快 → 需要**插帧**（延迟）；负值 = 音频偏慢 → 需要**丢帧**（追赶）。

相位校正只在节拍内容之间的「安全区」执行，避免打断正在发声的 click：

| 常量 | 值 | 含义 |
|---|---|---|
| `AUDIO_PHASE_LOCK_THRESHOLD_FRAMES` | 44（≈1ms） | 超过才触发校正 |
| `AUDIO_PHASE_LOCK_MAX_STEP_FRAMES` | 16（≈0.36ms） | 单次校正步进上限 |
| `AUDIO_PHASE_LOCK_SAFE_FRAMES` | — | 拍内安全区，越过才允许插/丢帧 |

---

## 8. Dither floor（防智能功放静音检测）

节拍 click 之间的静音区不是纯数字零，而是铺了一层约 −80dBFS 的抖动底噪。原因是智能功放的静音检测（`CustStreamCheck → SmartpaPowerOff`）会在检测到纯零流时**关闭功放**，导致重新发声时产生可闻延迟/爆音。

---

## 9. 关键参数总览

### 9.1 音频引擎（`MetronomeEngine.ets`）

| 常量 | 值 | 含义 |
|---|---|---|
| `SAMPLE_RATE` | 44100 Hz | 采样率（44 帧 ≈ 1ms） |
| `AUDIO_PREROLL_MS` | 650 | 音频流启动预留 |
| `AUDIO_CLOCK_LOCK_RETRY_MS` | 8 | 锁采样重试间隔 |
| `AUDIO_CLOCK_LOCK_TIMEOUT_MS` | 300 | 锁超时 |
| `AUDIO_CLOCK_LOCK_MIN_REMAINING_MS` | 80 | 锁最小剩余 |
| `AUDIO_PHASE_LOCK_THRESHOLD_FRAMES` | 44 | 相位校正阈值（≈1ms） |
| `AUDIO_PHASE_LOCK_MAX_STEP_FRAMES` | 16 | 相位校正步进（≈0.36ms） |

### 9.2 会话层（`Constants.ets`）

| 常量 | 值 | 含义 |
|---|---|---|
| `TRANSPORT_PREROLL_MS` | 650 | 首次播放/恢复预留 |
| `TRANSPORT_RESTART_PREROLL_MS` | 650 | 行进中改拍预留 |
| `PING_SAMPLES` | 11 | 起拍前时钟采样次数 |
| `RESYNC_INTERVAL_MS` | 5000 | 行进中重采样间隔 |
| `COUNT_IN_BARS` | 1 | 准备拍小节数 |

---

## 10. 调试日志（`OneBeatSync`）

| 日志 | 关键字段 | 说明 |
|---|---|---|
| `schedule` | `offsetMs / startAtLeader / localStart / now / audioDelay / countIn / beat / bpm` | 调度决策 |
| `audio` | `localStart / audibleStart / acousticDelay` | 时延补偿结果 |
| `lockClock[hw]` | `expected / actual / dev / framePos / played / submitted / queue / lead / latency` | 硬件时间戳锁钟 |
| `lockClock[fallback]` | 同上 + `rendererStart / fallbackFrame / targetFrame` | 纯墙钟回退 |
| `restart[leader]` | `restartAt / beat / beatsPerBar` | 队长重启 |

**验收标准**：`dev` 稳定在 `±0.01ms` 量级，`acousticDelay = 45`，`audibleStart = localStart - 45`。

---

## 11. 踩坑记录与修复

按发现顺序记录，均已在代码中落地：

| # | 现象 | 根因 | 修复 |
|---|---|---|---|
| 1 | 可闻节拍统一晚 ~60ms | 输出时延用固定 `-20ms`，符号反且量级错 | 改用运行时 `getLatency(LATENCY_TYPE_ALL)`，`audibleStart = localStart - latency` |
| 2 | 偶发 `dev=55~75ms` 迟到 | 锁首样本 `playedFramesNow` 恒为 0，漏算已播帧导致 lead 下溢 | 补上 `(now - rendererStartRequestedAtMs)` 墙钟已播帧 |
| 3 | 偶发 `dev=-12~-26ms` 提前 | `playedFramesNow > submitted`（写回调未触发时 submitted=0） | `playedFramesNow` 钳制到 `submitted` |
| 4 | 偶发 `dev=+27ms` 迟到 | `haltRendererNow` 耗时吃掉 preroll，fallback lead 小于写回调 burst（185ms） | `AUDIO_PREROLL_MS` 450 → 650 |
| 5 | 设备间数百 ms 偏差 | 低功耗通路的大缓冲不被 `getLatency` 上报 | 改用 `STREAM_USAGE_GAME` |

---

## 12. 附：首拍定位时间线

```text
t0   schedule 到达，算 localStart / audioDelay
t1   startAudioStream：refreshOutputLatency → audibleStart = localStart - latency
t2   startAudioStreamNow：halt 旧渲染器 → 设 fallback lead → renderer.start()
t3   写回调触发：按 fallback lead 灌静音占位
t4   锁循环：getAudioTimestampInfo 采样 → 算 played / lead → 修正首拍位置
t5   首拍内容写入，dev ≈ 0；之后进入相位锁定闭环
```
