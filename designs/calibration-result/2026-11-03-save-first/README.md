# Pura X 结果页：保存优先效果图

设计图已确认，并落实到应用结果页。这里的PNG仍为设计预览，非真机截图。画布按用户截图的Pura X比例设计：440×706.67逻辑像素，3倍输出PNG。7ms与波动±22ms沿用用户截图，仅用于还原该次页面示例，应用继续显示真实测量值。

顺序为：时间卡及结果 → 稳定度与待保存 → 保存并生效 → 前后试听 → 同步指示 → 测量说明与重新测量。删除“本次跟拍测得的本机补偿”，保存按钮保持普通内容流。结果画面按现有插画组合缩到宽288、高344，完整保留纸卡、32孔及机器，使用已重绘的固定轴座。

源文件：[preview.html](/Users/lizhe/work/oneBeat/designs/calibration-result/2026-11-03-save-first/preview.html)。首选样式调整点：

| 参数 | 当前值 | 调整方向 |
| --- | --- | --- |
| `--scene-width` / `--scene-height` | 288px / 344px | 同比例增大可放大插画，并把下方保存区向下推；减小则给操作更多首屏空间 |
| `--save-gap` | 12px | 增大保存按钮与状态行间距，并下移按钮及后续内容 |
| `--section-gap` | 16px | 增大保存按钮到试听区域的间距；保存按钮自身不移动 |
| `.save height` | 54px | 增大保存按钮更高，推低后面的试听区 |
| `.content` 左右内边距 | 18px | 增大使按钮变窄、向内收；减小更贴近屏幕边缘 |

插画资产为 [result-art.png](/Users/lizhe/work/oneBeat/designs/calibration-result/2026-11-03-save-first/result-art.png)，由现有项目分层预览中的真实PNG组合和文字生成，未替换原始人物或机械素材。使用CSS `object-fit:contain`，插画完整显示。

浏览器核对：保存按钮位于y482—536，低于首屏可见底部约684的边界；完整显示试听区与次要操作。字体使用本机SDK原装鸿蒙黑体，未改写字体文件。检查记录见`preview-qa.json`。

HTML交互仅为本地设计演示，不实际播放音频、保存补偿或进入新测量。

## 应用实现

源文件：[TimeCardCalibrationPage.ets](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/TimeCardCalibrationPage.ets)。结果状态显示“待保存”，保存控制移到试听之前；测量说明与低调的重新测量入口放在同一行。保存或试听失败的提示紧邻保存按钮显示，展开说明不会把错误推到页面底部。保存仍位于Scroll内容流，测量和试听算法、1000ms阅读等待、700ms松手静默和新手势确认保持原规则。

应用尺寸调整优先使用以下常量：

- `RESULT_SCENE_MAX_WIDTH = 288`：结果插画宽度上限；增大放大插画并下移保存区，减小上移后续内容。实际宽度还受左右18vp边距和Scroll剩余高度限制。
- `RESULT_PRIMARY_CONTENT_HEIGHT = 148`：为状态、保存及底部留出的高度；增大后短窗口插画更小，保存位置更靠上。`RESULT_SCENE_MIN_WIDTH = 180` 保留可读下限；更短窗口继续允许滚动。
- `RESULT_SAVE_GAP = 12`：增大下移保存及试听区域；`RESULT_PREVIEW_GAP = 16` 增大仅下移试听与次要操作。

插画继续使用 `entry/src/main/resources/rawfile/calibration/time-card-v2/` 内的分层PNG，整体尺寸统一经 `sceneDisplayWidth()` / `q()` 作用于纸张、孔位及机器。`resultSceneProgress`在原有收卡动画中从0变为1，缩小与抬卡同步。打卡、失误和空白卡阶段继续使用原来的场景尺寸。

验证：`scripts/tests/time-card-calibration.cjs`通过，包含Pura X、窄屏、短窗口和底部安全区几何边界，以及原有32拍采样、保存防误触和试听生命周期回归；DevEco `product=default assembleHap`签名构建通过。尚未进行本次布局的真机结果页验证。
