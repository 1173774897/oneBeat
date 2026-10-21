# 正式录制使用系统 AEC

## 验收口径

MIC 与画面、内录仍允许用户手动提前/延后。此次不修改原伴奏的共享时钟、调度、节拍起点、耳机校准或输出恢复策略。重点验证录制开启、运行、停止期间，两台设备继续使用原组队播放流。

## 已接入

- `RecordingCoordinator` 在 API 20+ 查询 LIVE AEC 能力。支持时传 `systemAecMic=true`；旧系统、能力不支持或查询不可用时保留旧录屏 MIC，并在作品元数据区分模式。LIVE 启动失败不会暗中换成语音通话源。
- `CaptureSession` 在用户允许系统录屏后启动独立 OHAudio LIVE。录屏自身 MIC 关闭，其 MIC 回调与 mute/unmute 通知不再参与独立 MIC；画面和 `OH_APP_PLAYBACK` 内录保持原实现。
- 真实格式必须为 LIVE、48kHz、PCM16、单/双声道；单声道只复制为双声道，不重采样或增益。原生回调进入有界 PCM 队列，磁盘写入走已有 worker，原始样本连续保存。
- 原生 `GetTimestamp(CLOCK_MONOTONIC)` 的硬件帧/时间戳锁定一次流原点。后续不按时间戳抖动插帧/裁样。无可信硬件锚点时明确失败，不使用 JS 回调时间伪造时间戳。新来源采用映射版本 3，旧录屏 MIC 保持版本 2。
- MIC 停止/释放在原生异步工作线程执行。四个原生 MIC 回调有异常边界，释放失败会阻止新 AEC 采集并要求重启，避免悬垂回调。
- AEC 作品 `micCaptureMode=system-aec` 持久化到作品/失败保存恢复记录。混音跳过旧 FIR 和自动 MIC 偏移，缓存独立为 `.system-aec-v1.f32`；用户 MIC 音量和 ±300ms 手动偏移保留，内录仍为 unity。旧作品和 `.clean-v3.f32` 缓存继续原处理。
- `RecordingPlaybackObserver` 仅观察当前队伍已有 engine，250ms 检查输出；原生 start/stop 前后记录全量边界。它不暂停、不重建、不重新调度伴奏，不写校准。异常只请求结束本机录制，保留正常的原路由恢复逻辑。

## 兼容边界

仍使用现有“手机麦克风”约束，预检和输入设备监听按实际 LIVE/MIC 源查询。不会为了开启 AEC 强选输入/输出设备或切换到通话模式。蓝牙/有线/USB 耳机需要在实际物理接入条件下继续验证，不能由扬声器测试推断全部耳机行为。

Native 仅依赖 API10 OHAudio 基础构造/回调/格式/时间戳/start/stop/release 符号；LIVE 枚举值仅在上层能力门通过时使用，避免 API20 新符号使旧系统在加载 so 时失败。

## 真机验证

两台测试机通过正式多人练习加入同一队伍，120 BPM、4/4、电子节拍、扬声器输出。未修改系统音量、耳机校准或节拍设置。以下为系统可观测证据，不替代外部声学延迟测量。

### 队长端

录制 66.636 秒，成功保存到多人练习作品。录制开始前、native start 返回后、停止前、停止后均为：

| 观测项 | 四个阶段 |
| --- | --- |
| transport | playing |
| renderer epoch / stream | 1 / 100301 |
| physical starts | 1 |
| route / audio scene | 2:1 扬声器 / 0 |
| reported latency | 硬件40ms、软件5ms、总45ms |
| interrupt / underflow | 0 / 0 |

作品元数据确认 `scope=team`、`micCaptureMode=system-aec`、`captureMappingVersion=3`、`captureSyncValid=true`、原生 `micAecApplied=true`。MIC offset=222152us、内录 offset=235013us；自动 MIC 偏移为0且不标为自动可靠，手动偏移初值0。停止至结束输出边界约126ms，无重建流或欠载。

成品 ffprobe：H.264 1080×2410、48kHz 双声道 AAC，66.644秒。双方初始 SyncDiag 指向同一 leaderAudible=463781684ms，队员仅通过已有时钟 offset 换算到本地；录制期间未发布新的播放调度。

### 队员端

录制78.129秒，成功保存到多人练习作品并继续行进。四个边界均为playing、renderer epoch1/stream100765、physical starts1、扬声器2:1、scene0、硬件40ms/软件5ms/总45ms、焦点事件0/欠载0。native start至停止后的流保持同一实例，没有输出保护异常。

原生确认mapping3/divisor1000、micAecApplied=true、syncValid=true；保存索引同样持久化system-aec、team、mapping3，interrupted=false、stopReason=user。MIC offset=135366us、内录offset=229455us，自动MIC偏移0，手动初值0。停止至结束输出边界约100ms。

两端结构化结果见 [真机记录](production-system-aec-device-results-2026-10-20.json)。验证完成后由队长正常暂停并退出测试队伍，再更新两端最终包；保留两条本机多人练习测试作品供试听。最终包比功能实测版本仅增加原生回调异常加固和只读输出日志字段，未改变采集/播放策略。

## 检查

- 整包 `assembleHap` 编译通过。
- 同步回归门禁37项通过，包含旧播放PCM/路由/组队调度基线、录制生命周期、AEC混音/缓存/元数据恢复、只读输出保护。
- `recording-system-mic.cpp` 通过：帧/硬件时间戳映射、拒绝异域/错误单位、锁定原点抵抗后续抖动、单声道复制、双声道字节一致和非法帧。
- 四个 C ABI 回调做过临时故障注入，验证错误记录分配失败与 PCM 入队分配失败不会越过 C ABI，且回调计数会释放。

## 源文件

- `entry/src/main/cpp/recording_native.cpp` / `recording_system_mic.h`
- `entry/src/main/ets/recording/RecordingCoordinator.ets`
- `entry/src/main/ets/audio/RecordingPlaybackObserver.ets`
- `entry/src/main/ets/recording/RecordingMixer.ets` / `RecordingModels.ets` / `RecordingRepository.ets`

本次正式链路接入未调整页面位置、尺寸或素材。
