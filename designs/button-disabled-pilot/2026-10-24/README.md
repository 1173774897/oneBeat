# 加入码点击与自适应按钮阴影本地验证

2026-10-24。按用户选择先完成本地验证；本次修复尚未安装到真机核对触摸、键盘或阴影外观。

`MemberJoinPage.codeMethod` 的装饰Row使用 `HitTestMode.None`，该模式仅排除自身，子Text仍接收命中。现对每个短横线Text也应用None，使原生TextInput直接接收短横线及间隙位置的触摸；装饰树隐藏于无障碍遍历。输入框尺寸、单一数字编辑器、6位限制、过滤、光标/粘贴路径未改。

`ActionButton` 的空硬阴影Row在auto宽度下没有固有内容，之前大厅BPM加减按钮真机快照中按钮151px宽、背板约1px宽，导致阴影不可见。现由native Button的onAreaChange记录面宽高，背板使用该数值并绝对position偏移，避免背板参与固有宽高测量、阻止文字缩短后收窄。始终记录有限非负尺寸以支持动态加影，尺寸不变时不重复写状态。

ArkTS debug assembleHap构建通过，正常入口为pages/Index；没有临时测试页面进入生产页面表。7项相关回归通过，详见[本地结果](local-results.txt)。测量回归执行生产方法，覆盖增长/缩短/归零、auto高度、动态加影、非法值、同值不重复写入，并保留原点击事件/禁用时序/阴影边界回归。

后续真机检查：6个短横线中心及5处间隙均唤起输入，粘贴/删除/光标正常；BPM加减阴影完整，auto按钮标签增长后可缩回，禁用淡化无透影。未将本地检查表述为实际渲染或读屏验收。

调整阴影位置优先在 `entry/src/main/ets/pages/LeaderLobbyPage.ets` 的BPM ActionButton调用处设置 `hardShadow.offsetX/offsetY`，当前均取 `COMIC_CONTROL_INK_OFFSET=2vp`；增加X向右、增加Y向下，减小反之。常量定义在 `components/ComicInkSurface.ets`，修改它会影响其他小按钮。合成范围由 `ActionButton.shadowOutset()` 自动跟随，测量宽高只对应按钮面，不应用于挪动按钮或手工扩热区。加入码布局值未变。
