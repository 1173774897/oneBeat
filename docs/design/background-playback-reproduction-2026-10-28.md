# 队长后台静音与回前台不同拍：复现日志

日期：2026-10-28，时间为手机日志显示的本地时间（Asia/Shanghai）。本记录保存用户协助复现时采集到的证据。用户随后要求停止后台保活修复；本文件仅归档已采集日志，不表示修复或真机验收完成。

## 场景与结果

两台手机组队播放，队员保持前台，队长切到后台后出现静音。队长返回前台恢复声音，用户听到双方节奏不同拍。用户此前体感约两分钟；本次有完整日志的复现从后台到原生静音为 **66.120 秒**。

## 操作与事件时间线

| 时间 | 已观察事件 |
|---|---|
| 14:56:29.738 | 起播诊断已显示硬件时钟样本不可用；起拍采用 fallback 路径。 |
| 14:56:39.723 | `EntryAbility onBackground`。 |
| 14:56:39.763 | 原生任务存在、未挂起，模式为 `audioPlayback,multiDeviceConnection`。 |
| 14:56:39.778 | 应用输出后台准备 `stage=ready`。 |
| 14:57:39.828 | 系统检查后台任务，报告 `multi device detect fail`。 |
| 14:57:39.831 | 系统报告使用了未声明的 `mode 5`。 |
| 14:57:39.836 | 系统撤销长时任务：`cancelReason 2 detailedCancelReason 11`。 |
| 14:57:39.839 | 应用取消监听收到 `stage=cancelled reason=2`。距退后台 60.116 秒。 |
| 14:57:39.842 | 音频系统记录媒体会话存在，后台任务已不存在。 |
| 14:57:45.838 | 系统记录进程冻结；运行锁出现代理与释放记录。 |
| 14:57:45.843 | Renderer 因 `background control` 被静音。 |
| 14:57:52.378 | 音频欠载计数增加 18。 |
| 14:57:52.414 | Renderer 解除后台静音，报告静音持续 `6495 ms`。 |
| 14:57:52.419 | `EntryAbility onForeground`。 |
| 14:57:52.451 | 应用查询确认后台任务不存在。 |
| 14:57:52.477 | 重新申请成功；前台连续性检查报告 `phaseMs=0.0`，未观察到 `audio recovery`。 |

## 关键日志脱敏摘录

以下仅保留与本应用相关的诊断正文。进程、用户、流、任务和跟踪标识以占位符替代；不收录其他应用、网络凭据、图片数据或业务载荷。

```text
14:56:29.738 [ProductionClockDiag] stage=continuous-play state=sample-unavailable
14:56:39.723 EntryAbility onBackground
14:56:39.763 [BackgroundPlaybackDiag] stage=verify taskPresent=true suspended=false modes=audioPlayback,multiDeviceConnection
14:56:39.778 [BackgroundPlaybackDiag] stage=ready
14:57:39.828 [DumpCheckTaskInfo] backgroundMode:6,isBatchApi:true, backgroundModes:2, 6
14:57:39.828 [CheckIsDisSchedScene] multi device detect fail. uid: <app-uid> not use MultiDevice
14:57:39.831 [CheckAppUseUnclaimedModes] new task, uid <app-uid> use unclaimed mode 5
14:57:39.836 [OnContinuousTaskStop] abilityname EntryAbility continuousTaskId <task-id> cancelReason 2 detailedCancelReason 11
14:57:39.839 [BackgroundPlaybackDiag] stage=cancelled reason=2
14:57:39.842 [NotifyBackgroundTaskStateChange] hasSession: 1, isBack: 1, hasBackgroundTask: 0, isFreeze: 0, isSystem: 0
14:57:45.838 [NotifyFreezeStateChange] hasSession: 1, isBack: 1, hasBackgroundTask: 0, isFreeze: 1, isSystem: 0
14:57:45.843 [Mute] StreamClientState for Renderer::Mute for background control. id: <stream-id>
14:57:52.378 MetronomeEngine audio underflow: 18
14:57:52.414 [Unmute] StreamClientState for Renderer::Unmute for background control. id: <stream-id>
14:57:52.414 [ReportWriteMuteEvent] MutePlaying for 6495 ms, muteState:5
14:57:52.419 EntryAbility onForeground
14:57:52.451 [BackgroundPlaybackDiag] stage=verify taskPresent=false suspended=false modes=none
14:57:52.477 [BackgroundPlaybackDiag] stage=ready
14:57:52.477 [ForegroundPlaybackDiag] writeGap=false stalled=false state=2 phaseMs=0.0
```

## 可以确定与尚不能确定的内容

本轮静音发生在系统撤销后台任务并冻结之后。媒体会话实际存在，单独持有 AVSession 和运行锁并未阻止这条系统管控路径。取消回调只给出了通用 `reason=2`，原生系统日志提供了更具体的 `detailedCancelReason=11` 及类型检测失败信息。

本轮未观察到音频焦点中断事件、硬件帧回退或恢复重启日志，不能将其写成已证实原因。起播时硬件样本不可用，前台检查的 `phaseMs=0.0` 因而不能作为真实跨机零偏差的证据；本次没有共同录音，无法给出实际毫秒误差。系统日志中的 `mode 5` 与具体蓝牙活动的对应关系尚未通过独立实验确认。

本机原始采集来源：`/tmp/onebeat-background-round2-process-a.log`、`/tmp/onebeat-background-round2-system-a.log`，以及辅助应用日志 `/tmp/onebeat-background-round2-live-a.log`。临时文件可能被清理，本文件中的时间线及脱敏摘录作为持久记录。采集已经停止。
