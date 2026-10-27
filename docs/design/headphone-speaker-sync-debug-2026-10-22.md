# 耳机与外放节奏偏差：本次真机记录与复现步骤

## 本次结论

Pura X 使用蓝牙耳机，Pura80 Pro 使用外放；P80 为队长，X 为队员。用户重做耳机校准后，当前保存值为 414 ms，并反馈听感比之前一致。该值是当前播放路径下的敲击校准结果，不能解释为纯耳机硬件延迟。

新校准后的播放和短时采样中，X 的蓝牙输出为 `8:49`，硬件查询 280 ms、软件查询 5 ms、全部查询 285 ms。采样前后输出 stream、物理启动次数、焦点和路由保持一致，欠载计数均保持既有基线 2，未新增欠载。P80 正式播放使用的外放补偿为 45 ms。共享开始目标和原始时钟、生产帧坐标均已保存到本地诊断日志。

采样使用普通 `SOURCE_TYPE_MIC`，48 kHz 单声道、内置输入类型 15，报告 `aecSupported=false`、无溢出、时间戳读取无失败。前两段主要鼓点间隔约 500 ms，一次暂停恢复后弱拍/重拍包络相关约 0.994/0.989，没有明显新增分离的主起点。这只证明共同录音中的主要声音保持稳定，不能证明两个输出的绝对声学差小于某个毫秒数。

分别静音两端的对照显示：录音主要由 P80 外放主导，耳机单独发声段的节拍特征仍接近背景。因此此次不能可靠计算耳机与扬声器实际出声差，也不能把旧校准值、MIC 链路或某个时间戳分支认定为原始偏差的根因。测试结束已核验两台设备全部媒体相关音量恢复，停止采样和日志进程，全队恢复暂停，保留当前连接与校准。

本次未修改正式节奏调度、输出补偿公式或组队共享时钟。新增的是调试版短时被动采样入口，并将其保护用例加入统一回归入口。应用冷启动不再自动复制整条作品原轨；只有显式调试命令导出。

## 复现时先保留现场

1. 偏差出现后，先不要重校准、重连耳机、重启应用或更新安装。记录谁在耳机、谁在外放，以及谁更快。
2. 立即保存两端本应用当前 PID 的 `hilog`，至少保留 `TransportPrepareDiag`、`SyncDiag`、`StartTimingDiag`、`ProductionClockDiag`、`RecordingOutputDiag` 和路由日志。
3. 在相同状态下先执行一次只读 `snapshot`，保存当前校准、输出路由、renderer/stream 身份、原始帧和生产坐标。再做采样，不要为了日志更好看而重建或重置 renderer。
4. 如需声学绝对差，必须让同一麦克风确实收到两端声音。短暂分别静音几拍，先确认两个输出都能在样本中识别，再计算各自起点。若有一端接近背景，报告测量不可辨识，不用更强声源的单峰宣称两端已对齐。
5. 最后再分别比较暂停续播、重连及重新校准；每一步保存独立日志和样本，避免同时改变多个条件。

当前图像/内录/MIC 作品中的内录是数字音频 tap，不是耳机振膜实际发声。即便先使用 `micOffsetUs` 和 `innerOffsetUs` 对齐，内录与 MIC 的相关延迟仍含输出、输入/AEC 和空气传播影响；作品中用户手动 MIC 偏移也不得混入测量。

## 调试入口

仅调试包、应用已有实例可响应以下固定命令；普通发布包不响应。没有任意路径、时长或代码执行参数。

```sh
hdc -t <PuraX-id> shell aa start -a EntryAbility -b com.onebeat.app --ps onebeatProbe snapshot
hdc -t <PuraX-id> shell aa start -a EntryAbility -b com.onebeat.app --ps onebeatProbe mic
hdc -t <PuraX-id> shell aa start -a EntryAbility -b com.onebeat.app --ps onebeatProbe export
```

`mic` 要求当前队伍已在播放、MIC 权限已授予、没有作品录制正在进行。它被动采集 10 秒，不控制 renderer、音量、路由、校准或 transport；原会话/播放状态、路由、焦点、硬件延迟或欠载发生变化即取消，进入后台也取消。

成功日志为 `[TeamAcousticProbe] stage=mic-complete`，输出私有文件目录下 `mic-capture-experiment/mic.wav`、`mic.json`，供已连接调试设备读取。每次采样会覆盖这两个文件，必须在下一次开始前归档。`export` 仅显式复制最新作品已有的 MIC/内录原轨，不会更改作品。

回归测试：`scripts/tests/team-acoustic-probe.cjs`、`recording-playback-observer.cjs`、`production-clock-diagnostics.cjs`。本次量测原始日志、WAV、分段操作时序和分析位于 `/private/tmp/onebeat-headphone-speaker-sync-20261022/`；临时目录可能被系统清理，不作为永久作品存储。
