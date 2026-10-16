# 提示精简实施记录

2026-10-17，依据用户修订后的 [评估文档](/Users/lizhe/work/oneBeat/designs/notice-audit/2026-10-16/README.md) 实施。

## 已实施

| 区域 | 最终行为 |
|---|---|
| 多人大厅 | 保留明显的蓝牙校准卡片、状态配色、补偿数值和重测入口；仅将承诺式说明改成“声音不同步时，可校准耳机”。 |
| 单人大厅 | 保留低调的“耳机设置 ›”；正常已校准只显示“耳机已校准”，重连时显示“耳机已重连 · 校准 ›”。 |
| 蓝牙试音确认层 | 保留两声试音与人工确认步骤。输出不正确、试音失败和耳机断开在当前层说明，可以直接重新试音，不再关闭后重复 Toast。 |
| 加入页 | 删除通用蓝牙耳机提醒与勾选门槛。相机、Wi-Fi 和蓝牙发现权限按实际操作申请；后台发现预热只读取已有授权。扫码、加入码各保留简短条件说明。原加入进度文案保留。 |
| 组队页 | 未取名气泡、脉冲动效、随机取名操作全部保留。建队 Wi-Fi 阻断确认与系统设置入口保留；底部通用说明缩短。 |
| 行进页 | 删除进入/路由变化时的蓝牙延迟 Toast 和常驻横幅；保留播放状态、队员控制权限与真实操作失败。“准备拍…”和退出后果改用准确短文案。 |
| 大厅状态 | 正常建队不再额外显示创建成功说明；蓝牙发现不可用在邀请区提示“加入码暂不可用，可扫码加入”。失败、准备状态和受限控件的原因保留。随机选角完成态改为“已选定”。 |
| 鼓机 | 删除载入、删除、格子应用的重复成功 Toast，保存和应用到队伍保留一次确认。空名称在字段旁提示；1/8 段边界禁用删除/新增。覆盖确认保留并简化标题，移除未调用的旧保存方法与实现说明。 |
| 鼓机试听 | 最新有效修改未能进入试听时，在整曲试听按钮附近保留“修改未进入试听，正在播放上一版”，直到当前更新成功或停止。过期回包、旧试听 owner 和旧页面不能修改当前反馈。原有乐句说明、菱形鼓点和吸附帮助保留。 |
| BPM | 编辑时在输入下方显示范围，越界时恢复已提交值并在原处提示。提交/失焦不重复提交，失去编辑权限后不能继续提交。 |
| 商店 | 场景选择由选中态反馈；月卡限制、有效期、续费/不续费说明放详情。购买失败保留在购买层并可重试或恢复购买；购买成功仅一次提示。兑换确认后立即切换成功卡片，显示有效期和不自动续费；后续权益刷新失败保留成功结果，只重试更新权益。恢复购买有完整局部结果。价格和系统支付确认保留。 |
| 正式校准页 | 保留阶段指导、32 次进度、质量信息、结果试听与保存前审阅。重复指导合并，长解释收进“测量说明”。错误就地显示且不暴露底层异常；保存后一次“已保存并生效”。失败不覆盖已有校准。 |
| 统一出口 | 同操作、同文案在 2 秒内去重，不压掉其他操作/不同失败。仅 SDK 明确取消码静默处理；已知错误映射为可操作文案，未知异常使用操作兜底。日志只记录操作域和数值错误码，避免记录口令、令牌或购买内容。 |

## 有意保留

- 权限系统弹窗、支付价格和权益信息、覆盖编排确认、断线退队原因、测量失效及真实失败反馈。
- `AudioCalibrationPage` 和 `MicLoopbackCalibrationPage` 的旧/调试实现。正式入口仍为 `TimeCardCalibrationPage`，本次未将旧页算作日常精简效果。
- 原评估的 `toast-call-sites.json` 与 `toast-review.md` 作为实施前快照。集中封装后的调用点数与原始调用点不具有一一对应关系，不用源码数量冒充实际打扰次数。

## 验证

- `run-sync-regressions.cjs`：20/20 套件，通过实际音频/会话/页面业务源码覆盖整曲连续编辑、声音与段落进度、PCM 边界、路由恢复、试听所有权和时间卡测量。
- `run-notice-regressions.cjs`：6/6 套件，覆盖局部校验、取消码、去重、加入授权、迟到回包、页面/会话替换、购买验单、兑换幂等与恢复结果。
- DevEco `assembleHap`：成功生成 `entry-default-signed.hap`；`git diff --check` 通过。
- 这些自动化测试使用受控的系统接口与服务替身，不代表真机声学或原生支付验收。建议在设备上核对单/多人大厅、扫码取消、校准失败/保存、整曲编辑失败提示以及支付/兑换/恢复状态。

额外检查发现三项既有视觉/资源断言失败：`monthly-pass-layout.cjs` 仍要求旧月卡分层标题方法；`redemption-hero-layout.cjs` 的数值正则不接受当前已有的负数常量；`random-character-catalog.cjs` 的资源哈希期望与现有资源不同。已用 HEAD 基线对照复现同样失败，本次没有改动这些插画、场景资产或旧断言。复核日志：`/private/tmp/onebeat-notice-existing-visual-baseline.log`。

## 界面调整位置

本次没有改动图片资产、人物位置或场景图层。下表列出本次文字合并、就地反馈影响的布局控制点；优先调局部间距，再调外层约束。

| 位置与源码 | 优先控制点与当前值 | 增减效果及次级约束 |
|---|---|---|
| 单人耳机入口：[LeaderLobbyPage.ets](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/LeaderLobbyPage.ets) 的 `soloLatencyCalibrationEntry()` | `SOLO_CALIBRATION_VERTICAL_PADDING = 6`；`SOLO_CALIBRATION_FONT_SIZE = 12` | 增大 padding 增加上下留白和入口高度；减小则更紧凑。增大字号使文字更醒目。多人卡片尺寸与配色控制点未改。 |
| 加入页：[MemberJoinPage.ets](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/MemberJoinPage.ets) 的 `build()` | 主 `Column.space = 12`；两种加入方式内部 `Column.space = 10` | 增大使后续区域向下展开，减小则收紧。外层左右 padding 均为 `20`，top 为 `12 + topSafeInset`，bottom 为 `28 + bottomSafeInset`；左右 padding 增大会缩窄文字宽度。删除的耳机卡片不再占位。 |
| BPM 输入旁帮助：[EditableBpm.ets](/Users/lizhe/work/oneBeat/entry/src/main/ets/components/EditableBpm.ets) | `Column.space = 4`；帮助 `lineHeight(14)`、`fontSize(11)` | 增大 space 将帮助向下推，增大行高增加占高；反向则收紧。输入高度由 `controlHeight` 控制，默认 `50`、鼓机传入 `38`；帮助最多 `2` 行，窄容器会更早换行。 |
| 鼓机命名错误：[DrumMachinePage.ets](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/DrumMachinePage.ets) 的 `saveDialogOverlay()` | 字段组 `Column.space = 4`，错误 `lineHeight(16)` | 增大 space 将错误移离输入框，减小则贴近。外层居中，`space = 12`、宽 `88%`、padding `16`；增大外层 padding 会缩窄内部可用宽度。 |
| 鼓机覆盖确认：同文件 `overwriteDialogOverlay()` | `Column.space = 12`，宽 `88%`、padding `17` | 增大 space 扩大行间距离和弹层高度，减小则紧凑。宽度增加使弹层左右扩展；居中锚点不变。 |
| 鼓机横滑帮助：同文件“横滑查看更多”所在 Row | `Row.space = 3`；文字字号 `10`、箭头字号 `16`，新增 padding 为 `0` | 增大 space 拉开文字和箭头，增大字号增加所占空间。删除原装饰底框后使用内容自身高度。 |
| 鼓机试听失败说明：同文件 `build()` 中 `songPreviewMessage` | 外层 `Column.space = 14`；消息 `lineHeight(18)`、`fontSize(12)` | 增大外层 space 使整曲按钮后的说明及后续内容向下展开，减小则收紧；行高控制消息本身高度。消息只在整曲试听且有失败时占位。 |
| 商店购买局部结果：[StorePage.ets](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/StorePage.ets) 的 `purchaseDialog()` | `Column.space = 12`；宽 `88%`、padding `17` | 增大 space 拉开结果、权益和按钮，增大宽度向两侧扩展；增大 padding 缩窄内部内容。弹层按屏幕居中，长错误/续费说明会增加高度。 |
| 商店兑换字段反馈：同文件 `redemptionCard()` | 输入组 `Column.space = 9`；消息 `lineHeight(17)`、`fontSize(11)` | 增大 space 将反馈和兑换按钮向下推，减小则贴近。外层卡片 `Column.space = 14`；输入高度 `46`，整块按内容自动增高。 |
| 商店兑换成功卡片：同文件 `redemptionResultCard()` | `Column.space = 12`、padding `20`；返回按钮高 `46`、其他口令按钮高 `36`；父级 `redemptionPage()` 的 `Column.space = 24` | 卡片内 space 增大拉开内容，padding 增大缩窄内部宽度并增加上下留白。调卡片与页头距离优先用父级 space，增大会下移卡片；页面左右 padding 各为 `18`。成功态不再占用原输入插画区域。 |
| 商店恢复结果：同文件 `build()` 中恢复购买按钮下方 | 主 `Column.space = 14`，消息字号 `12` | 增大 space 将结果及后续内容向下展开，减小则更紧凑；主区域左右 padding 均为 `16`。在购买层内发起恢复时使用购买层自己的间距。 |
| 校准说明与局部错误：[TimeCardCalibrationPage.ets](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/TimeCardCalibrationPage.ets) 的 `resultDetails()`、`startOrRetryActions()` | 结果区 `Column.space = 12`；开测区 `space = 10`；说明按钮高 `32`；展开文字 padding `11` | 增大间距会将后续内容下移，减小则收紧。页级优先用 `CONTENT_ACTIONS_GAP = 12` 调按钮上方空隙；`PAGE_SIDE_PADDING = 18` 增大会缩窄内容并影响可用场景宽度，避免用它单独调整文字间距。 |

行进页的蓝牙横幅已从 [MainPage.ets](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/MainPage.ets) 的 `build()` 删除，不留空白占位。现有底部控制条仍由 `bottomPanel()` 的 padding 控制（left/right `14`、top `8`、bottom `12 + bottomSafeInset`）；增加 bottom 会向上推起控件并增加底部留白。人物及舞台坐标未改。
