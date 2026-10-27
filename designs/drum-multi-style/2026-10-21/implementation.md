# 多风格编排实现交接（2026-10-21）

## 已完成

- 一个编排的每个段落独立持有风格，主节奏、加花、编辑器、单段试听、整曲试听和最终播放按该段解析预设与音色。
- 所用音色统一预加载；分段切换保持统一节拍/渲染时钟，保留跨段落镲尾与手写鼓点的精确位置、力度。
- 段落标题旁选风格；新段继承上一段；换风格有手写鼓点时可保留或换预设。
- 四类气泡：风格无描边彩色块、选中白字白勾；其余无描边白底、选中珊瑚底白字白勾；删除底部“只修改这一段”。外框8、内框6，硬阴影blur0。
- 气泡和字段同属主Scroll的内容Stack，因此拖动页面时一起移动。没有全屏拦截滚动的遮罩。页面移动手势不关闭气泡；点击空白或返回关闭。
- 主节奏与加花右侧改为直接绘制的播放/停止、铅笔图标；保存卡片112×112横滑，风格按首次出现去重，最多两种加省略号。
- 大厅鼓机卡片显示多风格摘要，保留原权限、试用截止时间、拍号、BPM、段落数与按钮。
- 行进页左下改“编排”；本编排固定保留进入行进页时的快照，右侧横滑选择库中编排。切换保持BPM，不同拍号先确认。
- 拍号与编排一次提交，经配置和音频准备就绪后统一切换，避免两个独立配置请求重复重启；取消、失败、快速替换不会显示虚假的已选状态。
- 按用户最新要求不做旧数据迁移，保存库仅使用明确带分段风格的新记录。协议7沿用原版本匹配机制，旧客户端不能静默播错音乐。
- 全部图标用现有组件/Path直接绘制，无新增位图资产。

## 代码入口

- [编辑页](../../../entry/src/main/ets/pages/DrumMachinePage.ets)
- [大厅](../../../entry/src/main/ets/pages/LeaderLobbyPage.ets)
- [行进页](../../../entry/src/main/ets/pages/MainPage.ets)
- [编排模型](../../../entry/src/main/ets/audio/DrumMachineCatalog.ets)
- [音频引擎](../../../entry/src/main/ets/audio/MetronomeEngine.ets)
- [共享库](../../../entry/src/main/ets/audio/DrumProgramLibrary.ets)
- [原子切换](../../../entry/src/main/ets/session/SessionController.ets)
- [音频准备屏障](../../../entry/src/main/ets/app/AppSession.ets)

## UI 位置、尺寸后续调节

下列均为实际源码值，优先改常量而不是改生成图。所有位置还受设备安全区、可用宽度与字体倍率约束。

| 文件 | 首选参数/当前值 | 增大/减小的效果及约束 |
| --- | --- | --- |
| DrumMachinePage.ets | DRUM_PAGE_SIDE_INSET=16 | 增大使整页内容左右内缩，也缩小气泡最大可用宽度；减小相反 |
| 同上 | DRUM_POPOVER_WIDTH=224 / DRUM_STYLE_POPOVER_WIDTH=280 | 增大对应菜单宽度，仍限制在屏宽减两侧留白内 |
| 同上 | DRUM_POPOVER_GAP=8 | 增大使气泡离字段更远；下方气泡向下、上方气泡向上 |
| 同上 | DRUM_POPOVER_TAIL=9 | 增大尖角高度/宽度与菜单总高度 |
| 同上 | DRUM_POPOVER_ROW_HEIGHT=40 | 增大选项高度与整个气泡高度，可能触发上翻 |
| 同上 | DRUM_SAVED_CARD_SIZE=112 | 同时增减保存卡片宽高，增大使单屏可见卡片更少 |
| 同上 | DRUM_OUTER_RADIUS=8 / DRUM_INNER_RADIUS=6 | 增大更圆，减小更方 |
| 同上 | DRUM_CARD_HARD_SHADOW offset(4,4)，radius0 | x增大向右，y增大向下；blur保持0 |
| 同上 | DRUM_CONTROL_HARD_SHADOW offset(2,2)，radius0 | x增大向右，y增大向下；blur保持0 |
| 同上 | sectionCard Column space=10、padding=12 | 增大分别拉开行距、使内容内缩；父级可用宽度限制字段宽度 |
| 同上 | phraseAction width=36 / height=38，内部icon24 | 增大按钮宽度会压缩字段；图标大小与点击区域分别控制 |
| 同上 | dropdownAnchorX/Y | 由字段相对dm-scroll-content坐标计算，勿改成固定窗口坐标，否则页面滚动时脱离字段 |
| LeaderLobbyPage.ets | DRUM_CARD_PADDING=14 | 增大卡片内容向内缩 |
| 同上 | DRUM_CARD_CONTENT_GAP=12 | 增大拉开卡片内部行列间距 |
| 同上 | DRUM_ARRANGEMENT_ICON_SIZE=68 | 增大图标并压缩右侧摘要宽度 |
| 同上 | DRUM_STYLE_CHIP_GAP=6 / HEIGHT=28 | 增大分别拉宽标签间距、提高标签 |
| 同上 | DRUM_CARD_SHADOW offset(3,4)，radius0 | x/y增大分别向右/下，blur保持0 |
| MainPage.ets | PROGRAM_DRAWER_HEIGHT=116 | 增大伸出条向舞台上方占更多空间；隐藏偏移会加入此高度 |
| 同上 | PROGRAM_CARD_WIDTH=100 / HEIGHT=68 | 增大宽度减少右侧可见项目，增大高度会压缩条内留白 |
| 同上 | PROGRAM_DRAWER_GAP=10 | 增大卡片间距，可见项目减少 |
| 同上 | PROGRAM_CARD_SHADOW=3 | 增大卡片实体黑色背板向右下的偏移 |

## 验证范围

最终ArkTS/HAP构建通过。四项新增多风格相关套件通过，覆盖实际PCM、冷加载准备、精确事件持久化、分段与试听、事务失败/竞态、气泡坐标与滑动手势，并已加入run-sync-regressions统一入口。

统一入口共41项：39项通过后，在第40项 recording-save-dialog 的“关闭保存中弹窗后轮询不重新打开”断言失败。使用 Git HEAD 中未改的 MainPage 复跑同一断言，结果相同；这是已有问题，本轮没有修改保存弹窗逻辑。第41项 saved-recording-page 单独运行通过，故逐项结果为40通过、1项既有失败。没有为让测试通过而放宽这一断言。

用户明确选择自行验证，停止了真机页面操作；最终HAP更新到Pura X供其测试。**没有完成真机交互验收或真实双机对照**，不能把本地回归当作这两类验证。

本轮未提交Git commit。

