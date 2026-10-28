# 音频与多人同步回归

2026-10-27 的历史研究见 [评审与开源对比](../../docs/design/team-sync-accuracy-review-2026-10-27.md)，本轮状态见 [分阶段修复](../../docs/design/team-sync-fixes-2026-10-28.md)。历史缺陷数据 `clock-sync-accuracy-probe-results.json` 保留不覆盖。`clock-sync-accuracy-probe.cjs` 现在执行四组生产实现回归，并把当前源码 SHA256 与验证范围写入 `clock-sync-fix-validation-results.json`：

```bash
/Applications/DevEco-Studio.app/Contents/tools/node/bin/node scripts/tests/clock-sync-accuracy-probe.cjs /Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js
```

- `clock-sync-readiness.cjs`：真实 RTT/offset/中点配对、空批次、重复/乱序隔离、训练跨度、skew/残差/过期约束，以及真实 SessionController 的严格 READY 和音频等待后复核。
- `metronome-shared-clock.cjs`：十分钟 100 ppm 逻辑时钟轨迹、1 ms/s 连续吸收、过期冻结、共享计时器与试听/校准隔离。
- `metronome-phase-feedback.cjs`：真实 PCM 插/丢帧、已提交/已可听账本、首次硬件采样、尾音/过零点保护、恢复原点、按时间分配的有界修正额度、旧 transport/过期/回退时间戳隔离。
- `metronome-phase-drift.cjs`：40/60/120/240 BPM × 100/500/±1000 ppm 共 16 组十分钟实际 PCM 路径与理想硬件时钟；同时检查听到的内容偏差和已扣队列的控制残差。
- `phase-timestamp-quantization-probe.cjs`（研究探针，不在门禁内）：硬件帧位置按 HAL 周期跳变时，比较生产映射、残差中值、上包络和死区候选；结论见 [2026-10-28 再评审](../../docs/design/team-sync-optimization-review-2026-10-28.md)，设 `PROBE_OUT` 写入 `phase-timestamp-quantization-probe-results.json`。

这四组测试已加入统一门禁。时钟质量检查、共享时间轴与 PCM 反馈现均默认开启；`phaseCorrectionEnabled=true`，独立的 `EXPERIMENTAL_EXACT_PLAYBACK_FRAME_MAP=false` 保持关闭。调试包仅在已有会话 `idle/paused` 且输出停妥时接受 `phase-off/phase-on`，用于对照与临时回退；每端分别设置，不允许播放中切换，正常对照后用 `phase-on` 恢复默认行为。

用户双机外放及蓝牙耳机主观听感验收反馈为偏差改善、没有漏拍或音质问题；共同录音和量化统计尚未采集。上述测试使用模拟原生时钟，PASS 保护软件行为；缺少静音窗口时反馈仍可能无法持续校正，详见 [本轮记录](../../docs/design/team-sync-fixes-2026-10-28.md)。

修改 `MetronomeEngine`、`ClockSync`、`SessionController`、延迟保存或路由切换后，运行：

```bash
/Applications/DevEco-Studio.app/Contents/tools/node/bin/node scripts/tests/run-sync-regressions.cjs
```

也可使用其他 Node，并显式传入 TypeScript 编译器；命令可以从任意目录执行：

```bash
node /path/to/oneBeat/scripts/tests/run-sync-regressions.cjs /path/to/typescript/lib/typescript.js
```

入口依次运行所列回归脚本，任何脚本失败、超过 60 秒，或未完成断言就退出，整个命令返回非零。优先使用已安装的 TypeScript，其次查找 DevEco 自带版本，不联网或安装依赖。原生录音测试需要本地 C++17 编译器，macOS 默认使用 `clang++`，其他系统默认使用 `c++`，也可通过 `CXX` 指定可执行文件路径；缺少时明确失败，不跳过。播放基线测试需要本地 Git 中保留 `56c9e55`；缺少时直接报错，不跳过。

| 保护点 | 主要测试 |
|---|---|
| 大厅蓝牙关闭时码位替换，二维码保留；真实蓝牙和广播双门槛、权限与设置回包隔离、开关事件合并，以及旧会话/邀请/广播结果不误报可用 | `lobby-bluetooth-invite.cjs`、`leader-invite-readiness.cjs` |
| 写音频回调不能生成整段倒数或重建主序列；预热后重复配置、开始和恢复不重新生成；音色异步乱序；准备失效时静音并可恢复 | `metronome-count-in-realtime.cjs`、`metronome-configuration.cjs` |
| 全员时钟准备成功后才发布共享开始；失败、超时、离开、旧回包与挂起发送不能误启动或破坏已排暂停；播放中改配置须先下发配置再准备，不能紧贴 TRANSPORT | `transport-start-readiness.cjs`、`transport-start-diagnostics.cjs`、`transport-restart-configuration-order.cjs` |
| 慢 ping 不能污染拟合；可靠新样本纠正失效历史；原始 ping 不提前进入 Session 的时钟估计 | `clock-sync-fit.cjs` |
| 保存补偿、共享目标、真实 PCM 首拍、预备拍强弱与衔接保持；日志不能改动播放或增加原生查询 | `metronome-start-timing.cjs`、`metronome-start-buffer-diagnostics.cjs`、`production-clock-diagnostics.cjs`、`metronome-playback-baseline.cjs` |
| 暂停恢复和长期播放保留流生命周期；蓝牙/外放双向切换重排但保留共享时间线；外放不套蓝牙保存值 | `metronome-audio-lifecycle.cjs`、`metronome-route-transition.cjs`、`latency-calibration-routing.cjs` |
| 鼓机从竖线的小数拍位置播放真实 PCM、保留完整循环，路由恢复保留位置；普通同步播放不继承试听定位 | `metronome-drum-preview-seek.cjs` |
| 鼓机准备与播放期间的队伍 UI 刷新不能替换为基础节拍或释放音频；失效加载不能启动；停止、正式播放、校准与退出隔离旧请求 | `drum-preview-session-ownership.cjs` |
| 整曲编辑保留当前小节、原点与播放归属，在后续小节边界切换真实 PCM；稳定段落／重复映射、增删、最新请求、失败保留旧音频、路由及普通音频恢复与共享配置隔离 | `drum-preview-live-update.cjs` |
| 4／3／6 细分的音频长度与落点；十音色事件、力度与空白节奏保存；十二风格编排与旧八行格子兼容；爵士 Swing／Shuffle／六连滚奏；叮叮镲跨小节尾音；旧版队员拦截 | `drum-subdivision-model.cjs` |
| 编辑器细分切换只改草稿；单个／全部菱形就近吸附、冲突合并；试听定位、停止续播、异步取消与横向跟随 | `drum-editor-preview.cjs` |
| 行进页鼓机拍点只显示并拦截穿透点击；节拍器拍点保留三态循环、队长权限、忙碌与退出保护；切换模式后旧回调不改鼓机重音 | `walk-beat-point-mode.cjs` |
| 队员只读控件保留 BPM／拍号文字、拍点与底栏阴影；队长忙碌和本机录制保持原禁用样式；保留阴影不授予操作权限 | `walk-member-appearance.cjs`、`action-button-disabled.cjs` |
| 行进页载入按上/下来源显示，编排同时显示卡内微环；原生延迟动画先提交帧，短任务防闪、长任务提示、并发/离页/旧回包隔离；本机PCM等待有界且不改变试听或transport归属 | `walk-loading-feedback.cjs`、`session-audio-configuration-readiness.cjs` |
| 出口试音完整播放一强一弱；打卡测量的倒数、保存、取消与会话归属 | `route-probe-playback.cjs`、`time-card-calibration.cjs` |
| 分享打卡按北京时间连续计日，同日幂等且只领一次、月卡期间不消耗领取机会；落盘后才投影 UI、崩溃重放与回拨边界；鼓机启动／恢复／试听到期验权且不异步切断播放 | `share-check-in.cjs` |

这些脚本将当前 ArkTS 源码转译后在隔离 VM 中执行，仅模拟平台、网络、单调时钟与原生音频接口。起拍用例检查实际 PCM，实时性用例注入确定的 120ms 生成成本并检查调用边界，不用桌面机器的执行速度或真机日志数值作为通过阈值。缓存内部字段只用于故障注入，结果仍以静音/首拍 PCM 和共享目标验证。

整曲试听与格子编辑浮层的用例检查播放归属：打开或关闭浮层、未应用的鼓点编辑和数字定位不会停止、重启或取消正在准备的整曲；点击浮层“试听”才切换为草稿乐句。旧整曲准备的迟到成功或失败不能影响新的草稿试听；关闭草稿试听不自动恢复整曲，退出整个页面仍停止所有试听。

段落卡片展开状态与编辑目标分开验证：A/B 可同时展开，编辑或应用 B 不收起 A；仅各自箭头切换展开／收起。新增、删除与重新编号保留存活卡片状态，载入新编排恢复首段展开。折叠只关闭本卡片的锚定菜单，不影响其他卡片菜单或任何试听请求、计时器和播放归属。

整曲播放段落高亮按实际播放计划验证：不同重复数的段落边界、循环回首、复合拍分母拍语义、预播放与无效进度；引擎记录写入音频流的小节边界，以本地呈现帧和生效计划历史返回当前可听段落的稳定标识，页面再映射到存活卡片。真实 PCM 用例覆盖非零输出补偿和队列、延迟起播、恢复相位变化，以及组队相位修正不能插入／丢弃本地试听帧，避免把逻辑墙钟或提前提交的 PCM 当成听到的位置。组队音频实际插/丢帧及其可听账本由 `metronome-phase-feedback.cjs` 单独验证。页面用虚拟时钟验证自适应边界刷新（最长 16 ms 复核）、不同音频与共享时钟偏移时的 A/B/C/循环首拍，以及恢复期间缺少锚点时编辑不会重播。打开／关闭浮层和手动折叠保留显示计时器，停止／页面退出／编辑器试听清理；旧异步回包及其他 transport 的 revision 不能恢复或驱动高亮。

整曲连续更新用例执行实际 `AppSession`、`MetronomeEngine` 和 `writeData`：新旧 PCM 在小节边界交接，编辑不暂停、不重排起播、不修改原点或 run token；按稳定段落与重复序号处理重复数变化、前面段落缩短和增删。冷音色加载、缓存、连续乱序请求、已准备计划撤销和失败均检查实际输出。停止、正式播放、校准、编辑器接管与退出取消更新；共享配置仍等待原 transport，音频回调不生成 PCM。页面用例另验证 150 ms 合并、首次加载／预备起播时撤销旧启动、晚回包隔离、未应用草稿隔离和速度／拍号的受控重启。独立段落的有限试听及格子草稿试听保持原有行为，本轮热更新只用于整曲。

累计高亮滞后另用真实 PCM 验证：原生帧／时间对延后 600 ms 且每 20 ms 量化，连续 20 次更新后继续播放 8 小节；对照 20 ms 正常年龄。还有 8 次原生帧原点回退、8 次单次 20 ms 的单调帧损失，以及停手 6 秒、单次低值后恢复、原生 API 短暂不可用／冻结和两轮暖流的停止／编辑器／整曲切换。断言按实际发出的段落首拍读取 key 和 repeatIndex，避免只检查“播放未暂停”而遗漏长期累积的高亮偏差。共享相位／帧映射缓存不被本地高亮读取改写。

会话归属回归同时运行实际 `AppSession` 与 `MetronomeEngine`，用可控采样加载和有辨识度的 PCM 触发原配置竞态，并检查真实 `writeData` 输出。普通 UI 同步在冷加载、缓存重入和已播放阶段均不能改回点击音色；失效配置明确返回未就绪，不能继续起播。停止／新请求、正式 transport、校准与会话退出都会撤销旧试听，旧成功或失败不能影响新播放。资源管理器未初始化时明确失败，不能使用空鼓组触发基础点击回退。

它们保护软件不变量，不能证明耳机声学完全对齐、没有原生欠载，或真机回调必然小于某个毫秒数。相关算法变更通过脚本后，仍需两端真机以同一可识别强拍录音验收。`metronome-frame-cap.cjs` 是调查用的反事实模型，可单独运行；它不属于这个回归入口，避免把尚未证实的声学模型固定成产品验收标准。

修改鼓机格子编辑器的试听、停止、定位、细分或自动滚动时，可单独运行下面的页面回归（已加入上述统一入口）。它直接执行页面业务方法，检查未保存草稿的单小节循环、异步启动取消、旧编排试听回包隔离、各退出入口清理、来自音频 transport 的进度，以及换屏、手动滚动和视口尺寸变化后的播放格可见性。停止用例在两个绘制回调之间推进 transport，验证先取最新进度再清理音频；竖线仍在当前屏时保留滚动位置，刚跨屏时仅跟随一次，停止后手动滚动不被抢回。试听始终从竖线开始，覆盖小数拍位置、播放中编辑后续播、不同拍号的步数换算、预热与失败保留起点、准备阶段停止不制造竖线、旧回调不能复活，以及退出时清除保留位置。数字区定位用例检查停止时静默移动、播放时立即换起点、连续定位的异步乱序隔离、无效位置拦截，以及定位不能修改鼓点或已保存段落。

```bash
/Applications/DevEco-Studio.app/Contents/tools/node/bin/node scripts/tests/drum-editor-preview.cjs /Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js
```

鼓机模型回归核对十二种风格 × 全部 80 种有效拍号 × 3 种节奏型 × 4 种加花选择，共 11,520 组新编排的事件范围、音色键、力度及同音色同时间唯一性。4/4 用例验证三种节奏型和三种加花彼此不同，以及反拍、四拍底鼓、嘻哈后靠、Trap 半拍与六连滚镲、拉丁 3+3+2、雷鬼 One Drop 等可辨识的编排特征。旧八行主节奏和自定义加花在所有 80 个拍号下，对比扩展音色前捕获的生产事件摘要，保护拍手、通鼓和打击乐的原音色对应、时间和力度；新十行辅助函数及叮叮镲／沙锤事件可准确往返。

48 组真实 `renderBar` 用例用单帧脉冲检查三种细分的音频落点、力度与完整小节长度；真实保存事件的三连／六连位置进一步经过试听定位及原生写音频路径。叮叮镲尾音使用可解析的 PCM 验证跨小节衔接、循环接缝、超过一整圈的叠加、非循环末尾、原打击声 PCM 不变、静音／重音规则，并禁止在写音频回调里重新合成或计算尾音。协议版本 4、5 的队员会在邀请校验时被明确拒绝，避免缺音色或播放不同编排。

页面回归还覆盖切换细分时不保存、不重启试听且保留真实拍位置；单个／全部菱形就近落格，正中间取前格、小节末尾夹在最后有效格，同音色落同格只保留最大力度，其他鼓点不动。旧 6/8 格子按原来的每拍两格导入；保存后事件位置和力度不变，主节奏与加花分别保留细分。十条音轨逐条验证格子编辑对应正确音色，并验证新增叮叮镲和沙锤的应用与重新打开。

内置节奏打开时按实际事件选择游离鼓点最少的 4／3／6 网格；匹配程度相同则保留乐句的偏好。Trap“三连滚镲”在普通与复合拍号下默认六连音、全部音轨落格，其他两种 Trap 预设的原位置保持不变。页面用例同时保护已保存自定义网格优先、空自定义谱不回退、旧行谱显示与实际主节奏／加花前缀，以及选网格不保存、不改变音符或试听位置。真实混合细分仍显示游离点。

## 行进录制、分享与本地试用

统一入口还运行以下真实业务状态回归：

- `recording-native-audio.cjs`：编译并执行生产 C++ 音频辅助函数。覆盖安静人声补偿、启动尖峰不压低整条录音、持续峰值保护、正常音量/静音/底噪不放大、软限幅连续性、左右声道和分块一致性、原轨不改写、伴奏增益不变，以及 PCM/时间戳转换。
- `team-acoustic-probe.cjs`：调试包固定命令、暂停时 phase-on/off 开关、录制/权限/会话边界、10 秒被动 MIC 采集、输出变化取消与发布包拒绝；现场抓取步骤见 `docs/design/headphone-speaker-sync-debug-2026-10-22.md`。
- `recording-capture-lifecycle.cjs`：系统授权 STARTED 握手、运行时 MIC 权限、实际输入能量、停止幂等、后台/路由/电话中断与保存失败重试。
- `recording-share-storage.cjs`：系统分享不自动打卡，显式发布确认、pending恢复与重复确认、成片索引失败的恢复文件、首帧封面提取/补齐/删除、相册复制；团队播放/连接与录制长时任务的联合所有权。
- `recording-page-flow.cjs`：实际页面业务方法的授权隐藏/销毁差异、取消准备、停止不暂停练习、真实录制层状态、保存重试、播放中不创建视频播放器、队长明确暂停后再预览/分享、队员不能暂停全队，以及MIC音量/提前延后编辑的串行合并与续播。
- `share-check-in.cjs`：北京时间自然日连续与断签、同日幂等、24h非累计、月卡跳过/到期、冷启动会员摘要、未知状态保留pending、旧bootstrap响应不覆盖新状态、交易与崩溃重放。

这些模拟测试不证明打开麦克风或系统录屏后蓝牙实际输出不变，也不证明系统内录时序与可闻时间一致；必须用两台真机、已校准耳机做录制关→仅MIC开→关→完整录制开→关的声学对照，并检查成片画面、内音、MIC首尾相位。

收音/AEC/混音算法或系统版本变更时，真机额外覆盖两种机型的“外放／耳机 × 普通节拍／鼓机”。每组保持同一声源、距离和说话音量，录下伴奏关闭和开启的同一句话；用共同内录事件和轨道起始偏移对齐后比较同源 MIC 电平，不能只比较整段 RMS 或成片总音量。记录输出及输入路由、原轨活跃电平、峰值、自动补偿和用户 MIC 音量。安静设备应补偿，正常设备不得被改响；伴奏开启前后若近端人声被系统抑制，保留原轨单独分析，不用提升伴奏或更改组队时间线来掩盖。
