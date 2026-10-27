# ComicButton 禁用外观试点

日期：2026-10-23。范围是 `entry/src/main/ets/components/ComicKit.ets` 的共享 `ComicButton`，现有调用为大厅主按钮和空作品库的返回首页按钮。其他按钮、场景卡和权益提示入口未迁移。

## 实现

- 原生 `Button.enabled(active)` 继续负责禁用语义。通过 API 12 的 `contentModifier` 绘制不透明按钮面，避免原生主题的禁用透明度再次叠乘。
- 实色背板和按钮面先合成，再统一按 `COMIC_BUTTON_DISABLED_OPACITY=0.68` 淡化；按压反馈使用不透明底色混入 `COMIC_BUTTON_PRESSED_TINT`，不会重新露出背板。
- 自定义内容将点击通过 `config.triggerClick` 转回原生按钮，宿主再检查实时 `active`。装饰内容隐藏于无障碍遍历，宿主保留 label 和 accessibilityText。
- 首轮真机发现：仅给 56vp 容器添加 `renderGroup(true)` 会裁掉边界外的阴影。最终按阴影四边溢出扩大内层合成区域，再用 padding 和反向 position 保持按钮面及点击区域的位置、宽度和 56vp 高度。原生阴影必须画在不透明按钮面上。

## 真机结果

设备：LMR-AL00，HarmonyOS `7.0.0.109(SP6C00E105R7P5)`，屏幕 1276×2848。使用临时独立页面，对照修改前实现、新实色阴影实现和新原生阴影回退。测试按钮仅累加本页计数，不调用组队、出发、商店或音频业务。

| 检查 | 结果 |
| --- | --- |
| 禁用外观 | 旧实现复现灰色偏移层；新实现按钮面颜色均匀，右下阴影完整 |
| 原生节点状态 | 两种阴影模式均为真正的 `Button`；禁用时 `enabled=false`，恢复后 `true` |
| 几何与命中范围 | 新按钮面与外层 bounds 相同；高度 196px=56vp；点击溢出的阴影不增加计数 |
| 禁用点击 | 两种阴影模式各连续点击 3 次，计数均保持 0 |
| 恢复可用 | 各点击 5 次，计数各增加 5，无重复回调 |
| 响应式更新 | 更新文字、底色和徽标后立即呈现；再次禁用后仍拦截点击 |
| 取消手势 | 按下后滑出不触发操作 |
| 按压反馈 | 按住期间底色变深，正常释放仅触发一次 |
| 中途禁用 | 按住期间异步禁用，最终释放不触发操作 |
| 键盘 | 禁用时 Tab 跳过；恢复后能获取 Tab 焦点，Enter 仅触发一次 |
| 正常应用 | 已覆盖安装正常调试包，确认首页和真实大厅正常；大厅“出发”节点及阴影正常；未触发出发 |

记录：[触摸检查](device-results.json)、[键盘检查](keyboard-results.json)。截图：[禁用对照](disabled-comparison.png)、[文字/底色/徽标更新](enabled-variant.png)、[按压反馈](pressed.png)、[恢复后的真实大厅](final-lobby.png)。

源码检查 `comic-button-disabled.cjs`、`comic-shadow-policy.cjs` 均通过；ArkTS 调试 HAP 构建通过。`home-button-shadow.cjs` 的旧首页布局断言仍失败：它要求 `Row({ space: HOME_ENTRANCE_GAP })` 包含小铺入口；使用修改前 ComicKit 和修改前测试也得到同一失败。本次未调整首页或放宽这条断言。共享按钮检查已独立成可单独运行的脚本，并由原首页脚本引用。

```sh
/Applications/DevEco-Studio.app/Contents/tools/node/bin/node scripts/tests/comic-button-disabled.cjs
/Applications/DevEco-Studio.app/Contents/tools/node/bin/node scripts/tests/comic-shadow-policy.cjs
```

当前验证覆盖一台较新系统的设备。未开启屏幕朗读核对实际播报，未在 API 12 设备或大量动态按钮列表中做兼容性、性能验证。节点可用状态和键盘行为通过，不将其表述为完整读屏验收。原生阴影缓存的模糊余量为 `3 × radius + 1px`，当前 1px 回退阴影截图通过；更大模糊或新的阴影类型需要另行检查。

## 后续调整

- 禁用淡化：`ComicKit.ets` 的 `COMIC_BUTTON_DISABLED_OPACITY=0.68`；增大更清晰，减小更淡。
- 大厅阴影位置：优先修改 `LeaderLobbyPage.ets` 的 `ComicButton.hardShadow.offsetX/offsetY`，当前两者取 `COMIC_CARD_INK_OFFSET=4vp`。增大 X 向右，增大 Y 向下。该常量在 `ComicInkSurface.ets` 定义并供其他纸面共用；只调大厅时应在大厅调用处设值。
- 合成区域由 `ComicKit.ets` 的 `shadowOutset()` 自动跟随偏移，配套 padding/position 只补偿绘制范围，不用于调整按钮位置。按钮高度仍为 `COMIC_BUTTON_HEIGHT=56vp`，圆角 `COMIC_BUTTON_RADIUS=7vp`。

临时验证页面保存在本目录的 `ComicButtonPilotPage.ets`，不在应用页面表或生产入口中。复测时须临时复制到主模块 `pages/` 并加载，结束后移除；普通应用包已恢复到 `pages/Index`。
