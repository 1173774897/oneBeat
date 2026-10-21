# 停止采集后再显示保存弹窗

根因：行进页在调用 stop() 前主动打开保存弹窗，且 stopping 状态同时表示“原生采集尚未释放”和“已停止、正在导出”，状态观察也会过早打开弹窗。

改造：
- `RecordingSnapshot.captureActive` 明确原生采集的生命周期。仅在原生 stop/release Promise 完成后发布 false。
- `MainPage` 在停止请求发起时不打开保存弹窗，等待 captureActive=false 后才展示保存进度；不等待整个混音和入库完成。
- 保存结果层也受 captureActive=false 的绘制条件约束。停止期间原停止按钮暂时显示“正在结束…”，不会过早宣称正在保存。
- 没有修改 MetronomeEngine、组队时钟、音频排程、MIC 采集或三路对齐逻辑。

验证：
- recording-capture-lifecycle.cjs：通过，新增延迟原生停止的场景；停止等待期间 captureActive=true、尚未开始混音，完成后发布采集释放边界。
- recording-page-flow.cjs：通过，新增停止等待期间与反复轮询均不打开保存弹窗，采集释放后才打开，并验证不暂停或重新排程练习。
- Hvigor assembleHap：通过；Pura 80 Pro 已安装此版本。
- 用户于 2026-10-21 明确确认“我验证停止录制的顺序已经改好了”。不再打断用户的录制追加测试。

保存弹窗的位置、尺寸与原始品牌素材均未改动；本次品牌摆放只提供三个设计方案。
