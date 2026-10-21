# MIC 串音与录制对齐评估

日期：2026-10-19。本轮只做代码、资料与既有测试审查，未改应用实现，也未重新采集或试听本次故障的原始双轨。

## 结论

需要分别解决声学回声和录制时序：MIC 中被扬声器重新收回的节奏，是另一份经过延迟、反射和设备处理的声音。将整个 MIC 手动平移只能改变两份节奏的相对位置，不会去掉副本。录制时钟对齐、用于回声消除的参考延迟、用户实际听到节奏的输出延迟，应分别建模。

推荐先在录后支路提高回声净化与时序诊断能力，保留当前播放引擎、多人共享时钟和耳机校准；系统 AEC 与精确播放 PCM 旁路另做受控验证。

## 现状证据

| 机制 | 当前实现与边界 |
|---|---|
| 采集 | `entry/src/main/cpp/recording_native.cpp:171` 使用 AVScreenCapture 的 `OH_MIC` 与 `OH_APP_PLAYBACK`，48kHz 双声道，没有显式启用独立 AudioCapturer 的 AEC/NS/AGC 模式。不能由此断言所有设备底层完全没有 DSP。 |
| 保留原轨 | 内音、MIC 分轨保存；净化 MIC 缓存在版本化 float32 旁文件。原始 MIC 包含扬声器拾音并不意外，成品使用的净化轨仍需降低残余。 |
| 去串音 | `RecordingMixer.ets:53` 只在识别为内置扬声器录制时开启；其他路由关闭。查询输出失败时也可能保守地关闭。 |
| 房间响应模型 | `recording_echo_filter.h:258` 每声道 256 tap FIR，在 48kHz 下约 5.33ms；`recording_native.cpp:550` 整体延迟另搜 ±300ms。延迟搜索范围不等于混响尾长。 |
| 更新速度 | `recording_native.cpp:542,590` 以 1.6 秒窗口拟合，每秒更新并交叉渐变预测回声；移动手机或说话位置变化时可能失配。 |
| 保护外部声 | 模型训练和独立验证需证明改善。强人声/乐器使模型失效时保留 MIC；已有最近 8 秒可靠形状的一维增益复验，不是待新增方案。拟合少减 2%，且无独立残余回声抑制器。 |
| 视频时间轴 | `recording_native.cpp:230` 使用真实视频首帧原点，MIC/内录保留首帧硬件时间戳偏移，已修复 Surface ns/us 单位问题。 |
| 连续 PCM | `recording_audio_math.h:68` 顺序连续写入，避免把块级时间戳抖动转成插零/裁样本。后续 drift 只观测，没有稳定时钟斜率估计或漂移校正；这不是当前确有漂移的证据。 |
| 自动 MIC 基准 | `recording_echo_filter.h:308` 至少 4 个有效样本、偏移 ≤30ms、MAD ≤3ms，才接受小而稳定的估计；耳机/无泄漏路径没有这类声学自动基准。手动范围 ±300ms。 |
| 编辑隔离 | 净化拟合使用原始物理时间轴，编辑只移动净化后的 MIC；内音保持 1 倍，视频压缩包原样透传。 |
| 路由边界 | `RecordingCoordinator.ets:55,153,417` 目前要求手机 MIC，输入/输出路由改变会结束录制，避免录制混入两套延迟；应保留该边界。 |

历史记录 `designs/recording-share/README.md:90` 曾在 11.542 秒作品中定位到约 172ms 的右 MIC 弱节奏残余。它是既往真机分析记录，不能当成本次故障已重新复现。该次问题引出的旧模型复验已存在，继续优化需有新对照。

## 唱歌类应用的可核验证据

- [唱吧官方帮助](https://changba.com/now/help/prob_content_page.php?helpid=97) 明确承认手机间录音与伴奏合成存在时差，并提供人工移动人声校准。因此这类产品也存在对齐问题，不能把干净成片等同于原始 MIC 没有伴奏。
- [唱吧官方修音教程](https://changba.com/commonreport/testsrc/view2.php?msgid=4775) 要求佩戴耳机。该教程发表于 2018 年，能证明这种录制条件，不能用来推断当前所有平台的内部算法。
- 耳机减少空气中的伴奏串入 MIC；数字伴奏与外录分别处理，最终再混合，是可行的工程路线。全民 K 歌具体私有处理链路本轮未获得足够公开证据，不断言其采用某个特定 AEC 或 AI 模型。
- [WebRTC 官方 AudioProcessing 接口](https://webrtc.googlesource.com/src/+/refs/heads/main/api/audio/audio_processing.h) 明确以采集流和实际播放参考流协同处理，AEC 需要正确时序，普通 MIC 单轨降噪不等同于 AEC。
- [腾讯 TRTC 官方资料](https://trtc.io/document/50754) 提醒自定义采集可能使 AEC 失效，原因包括采集与播放时序依赖；接入 SDK 仍需验证真实链路。

## 建议路线

### 第一阶段：原轨诊断与录后 A/B，破坏面较小

1. 对同一次录制保留纯内录、原始 MIC、净化 MIC、最终混音四个对照；MIC=0 成片用于检查是否仍有重复。记录路由、录制格式、削波比例、模型启用/拒绝原因、延迟轨迹及残余相关度，不记录或转写用户语音内容。
2. 保存稀疏的各轨 `{timestampNs, 累计帧数}` 锚点，分别比较起、中、末段，区分固定偏移、平滑漂移、时间戳批处理和突然断点。先验证硬件时间戳语义，不按每个抖动的时间戳修音频。
3. 用现有双轨 A/B 比较当前 FIR 与成熟自适应 AEC（如 WebRTC AEC3 或合适的频域分块算法），评估更长响应尾、双讲保护和温和残余回声抑制。候选实现必须按真实采集/参考关系重放，不能任意把两轨喂给 AEC 就宣称有效。
4. 保护与节奏同步的拍手、脚步、演奏：这些目标声音本来就可能相关，不能仅依据相关性扣除。避免把强语音降噪、自动增益或只保留人声当成默认处理。
5. 先消串音，再根据可信时钟/测量补偿纯采集偏差。低置信度保持原时序，手动位移留作兜底；不能简单放宽自动 ±30ms，把声学回声 lag 当成整条外部声音应移动的量。
6. 真正证实采样时钟斜率差后，再做录后平滑重采样；不能回到逐块补零、剪样本的旧方式。

主要改造点：`recording_native.cpp`、`recording_echo_filter.h`、录制元数据与净化缓存版本。变化优先隔离于录制/导出支路；处理放后台且限制负载，记录/保存期间也需测播放 underrun 和同步偏差。

### 第二阶段：独立 MIC + 系统 AEC，风险中等至较高

[OpenHarmony AudioCapturer 指南](https://github.com/openharmony/docs/blob/master/zh-cn/application-dev/media/audio/using-audiocapturer-for-recording.md#回声消除功能) 与[能力查询 API](https://github.com/openharmony/docs/blob/master/zh-cn/application-dev/reference/apis-audio-kit/arkts-apis-audio-AudioStreamManager.md#isacousticechocancelersupported20) 提供 `SOURCE_TYPE_LIVE` 与 `isAcousticEchoCancelerSupported`，API 20 起可按设备检测。支持不等于每条路由和所有素材都能达到无损净化。

当前 SDK 的 ScreenCapture 音源枚举只有 OH_MIC/PLAYBACK，无法把 OH_MIC 参数直接换成 LIVE。需要关闭录屏 MIC、另建独立 AudioCapturer，并重新建立输入帧到视频单调时钟的映射，波形读取也接入新源。

优先验证 LIVE。语音通话模式会影响音频焦点、路由与处理策略；不得为了 AEC 修改节拍播放的 usage 或切到通话耳机链路。必须检查蓝牙 A2DP/星闪输出是否保持、真实输入是否仍为手机 MIC、录制启动是否重建 renderer、音量是否被压低、拍手/脚步是否被吞。原始轨需要保留以支持回退。

### 第三阶段：精确数字播放参考，涉及播放回调需慎重

从 `MetronomeEngine.handleWriteData` 填充完成的实际 PCM 建只读旁路，保存 renderer epoch、提交帧位置及到单调时钟的映射。不能仅按 BPM 事后重造理论节奏，变速、段落切换、暂停恢复和晚到跳拍都必须和实际输出一致。

播放端当前为 44.1kHz 单声道，录制端为 48kHz 双声道；需带限重采样与时间映射。不同采样率本身不说明现有系统重采样有错误。旁路不得执行文件 I/O、编码、AEC 或阻塞等待；应以有界缓冲交给后台，测量实际开销。

## 时延复用边界

已有 `MicLoopbackCalibrator` 的探针方法可借鉴，输入延迟数值不能直接套到录屏：它用独立 44.1kHz 单声道 AudioCapturer，其样本锚点含回调交付估计；录屏是 48kHz 双声道并使用其硬件时间戳。直接再减该数值可能重复补偿。若校准录制，应在真实录制路径建立独立 captureTimingProfile，禁止写回原耳机输出校准。

真实人声/脚步的提前或滞后是用户演奏的一部分。校正设备延迟不应自动把用户动作强行拉到节拍上，也不能令声音移动后与视频中人物动作/已入镜声波失配。

## 验证与通过条件

现有 `recording-echo-filter.cpp` 和 `recording-audio-math.cpp` 本轮均以 clang++ C++17 编译到 `/private/tmp` 并通过。它们覆盖短线性多径、固定延迟、部分双讲和复验、分块一致性、极性及最终限幅；未覆盖完整真实房间与持续移动。

验收矩阵：

| 维度 | 最低对照 |
|---|---|
| 路由 | 外放、有线/USB 耳机、蓝牙 A2DP、星闪；确认实际 MIC 与录制中切换行为 |
| 内容 | 仅节奏、仅外部声音、节奏+说话、节奏+同步拍手/脚步/乐器、多人外放 |
| 环境 | 安静、反射明显环境；静止与持续移动手机；多档输出音量及削波 |
| 时长 | 15 秒、2 分钟、10 分钟，分别看起中末段 |
| 节奏变化 | 不同 BPM/鼓机音色、段落切换、暂停恢复 |
| 基线 | 不录制/录制中/保存处理中的多人跨设备、跨耳机听觉同步及 renderer underrun |

分别评估副本节奏残余、外部瞬态保留、声画对应、固定偏移和随时长增长的误差。候选 AEC 不应以损坏拍手/脚步换取低残余指标。

[WebRTC 音频处理标准](https://www.rfc-editor.org/rfc/rfc7874.html#section-5) 特别指出音乐对非线性抑制的敏感性和不同采放时钟问题；[Speex AEC 手册](https://speex.org/docs/manual/speex-manual/node7.html) 也说明正确播放参考和非线性失真的限制。耳机提供最可靠的物理隔离；外放场景追求显著改善，不能预设任何设备、音量、房间下都能完全无损消除。
