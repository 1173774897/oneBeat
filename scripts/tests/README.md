# 音频与多人同步回归

修改 `MetronomeEngine`、`ClockSync`、`SessionController`、延迟保存或路由切换后，运行：

```bash
/Applications/DevEco-Studio.app/Contents/tools/node/bin/node scripts/tests/run-sync-regressions.cjs
```

也可使用其他 Node，并显式传入 TypeScript 编译器；命令可以从任意目录执行：

```bash
node /path/to/oneBeat/scripts/tests/run-sync-regressions.cjs /path/to/typescript/lib/typescript.js
```

入口依次运行 15 个测试脚本，任何脚本失败、超过 60 秒，或未完成断言就退出，整个命令返回非零。优先使用已安装的 TypeScript，其次查找 DevEco 自带版本，不联网或安装依赖。播放基线测试需要本地 Git 中保留 `56c9e55`；缺少时直接报错，不跳过。

| 保护点 | 主要测试 |
|---|---|
| 写音频回调不能生成整段倒数或重建主序列；预热后重复配置、开始和恢复不重新生成；音色异步乱序；准备失效时静音并可恢复 | `metronome-count-in-realtime.cjs`、`metronome-configuration.cjs` |
| 全员时钟准备成功后才发布共享开始；失败、超时、离开、旧回包与挂起发送不能误启动或破坏已排暂停；播放中改配置须先下发配置再准备，不能紧贴 TRANSPORT | `transport-start-readiness.cjs`、`transport-start-diagnostics.cjs`、`transport-restart-configuration-order.cjs` |
| 慢 ping 不能污染拟合；可靠新样本纠正失效历史；原始 ping 不提前进入 Session 的时钟估计 | `clock-sync-fit.cjs` |
| 保存补偿、共享目标、真实 PCM 首拍、预备拍强弱与衔接保持；日志不能改动播放或增加原生查询 | `metronome-start-timing.cjs`、`metronome-start-buffer-diagnostics.cjs`、`production-clock-diagnostics.cjs`、`metronome-playback-baseline.cjs` |
| 暂停恢复和长期播放保留流生命周期；蓝牙/外放双向切换重排但保留共享时间线；外放不套蓝牙保存值 | `metronome-audio-lifecycle.cjs`、`metronome-route-transition.cjs`、`latency-calibration-routing.cjs` |
| 出口试音完整播放一强一弱；打卡测量的倒数、保存、取消与会话归属 | `route-probe-playback.cjs`、`time-card-calibration.cjs` |

这些脚本将当前 ArkTS 源码转译后在隔离 VM 中执行，仅模拟平台、网络、单调时钟与原生音频接口。起拍用例检查实际 PCM，实时性用例注入确定的 120ms 生成成本并检查调用边界，不用桌面机器的执行速度或真机日志数值作为通过阈值。缓存内部字段只用于故障注入，结果仍以静音/首拍 PCM 和共享目标验证。

它们保护软件不变量，不能证明耳机声学完全对齐、没有原生欠载，或真机回调必然小于某个毫秒数。相关算法变更通过脚本后，仍需两端真机以同一可识别强拍录音验收。`metronome-frame-cap.cjs` 是调查用的反事实模型，可单独运行；它不属于这个回归入口，避免把尚未证实的声学模型固定成产品验收标准。
