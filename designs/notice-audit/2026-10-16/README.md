# OneBeat 提示盘点与精简评估

日期：2026-10-16。此文是提示评估，尚未按建议修改提示。

## 结论

最值得先改的是蓝牙提醒的出现位置和重复方式，而不是删除必要的失败反馈。建议正常进入、连接和播放时不弹蓝牙延迟提醒；加入页不要求勾选耳机说明；大厅只保留一个可选的耳机校准入口。测量途中耳机断开、结果失效、保存失败等明确影响当前操作的情况继续反馈。

其他提示也采用同一原则：页面状态已经能说明结果时，删除重复的成功 Toast；错误优先留在当前操作附近；支付结果、断线退队、覆盖已保存编排等重要结果保留明确反馈。

## 范围与计数

- 检查注册页面、共享组件、会话、加入权限、商店与校准入口中的 Toast、确认层、常驻说明、状态和错误出口。普通标题、商品名称、音乐描述、按钮名称、隐私正文和开发日志不作为待删提醒。
- 源码中有 **81 个 `showToast` 调用点和 1 个 `showDialog` 调用点**。这是调用位置数，不是独立文案数，也不是用户实际会看到的次数；自定义浮层和页面内文字另行评估。
- 其中旧 `AudioCalibrationPage` 有 7 个 Toast，`MicLoopbackCalibrationPage` 有 14 个 Toast；前者虽注册但当前正式页面未发现进入路径，后者未注册且未发现正式入口，不应算成日常流程正在出现的 21 次打扰。
- 鼓机 `saveLocal()` 中另有 1 个旧 Toast，未发现调用。剔除以上位置，剩余 59 个为正式流程中可能触发的 Toast 调用点，仍不代表每次使用会出现。
- 全量调用位置与原表达式见 [toast-call-sites.json](/Users/lizhe/work/oneBeat/designs/notice-audit/2026-10-16/toast-call-sites.json)；逐项处置建议见 [toast-review.md](/Users/lizhe/work/oneBeat/designs/notice-audit/2026-10-16/toast-review.md)。动态服务端和系统错误无法按文案穷举，按其 UI 出口统一评估。

## 蓝牙：优先精简

| 现状与触发条件 | 评估 | 建议 |
|---|---|---|
| 加入页无条件显示“蓝牙耳机同步提醒”“外放或有线耳机同步效果最佳……”及“我已知晓，继续加入”，扫码和输入加入码均受勾选门槛约束。见 [MemberJoinPage:243](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/MemberJoinPage.ets:243)。 | 删除 | 用户用外放、有线或已校准耳机时也会被要求确认；耳机输出与找房间是两件事，不能让耳机说明阻挡加入。保留真正影响加入的 Wi-Fi／蓝牙发现说明。 |
| 行进页连接为蓝牙输出时 Toast：“检测到蓝牙耳机输出，节拍可能延迟，建议外放或有线耳机”。见 [MainPage:652](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/MainPage.ets:652)。 | 删除 | 仅连接输出不需要用户处理；不区分是否已校准，也没有在此处提供处理动作。 |
| 行进页同时常驻“蓝牙耳机输出 · 节拍可能延迟”“建议外放 / 有线”。见 [MainPage:659](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/MainPage.ets:659)。 | 删除 | 与 Toast、大厅入口重复，占据播放画面。输出设备信息如需展示，可采用低干扰状态图标。 |
| 多人大厅的校准卡片，根据未校准／已校准／重连显示不同色块、补偿值和重测入口。见 [LeaderLobbyPage:247](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/LeaderLobbyPage.ets:247)、[卡片:306](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/LeaderLobbyPage.ets:306)。 | 保留现状 | 暂时保留现状。 |
| “测一次，让队伍听到同一拍”。见 [LeaderLobbyPage:257](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/LeaderLobbyPage.ets:257)。 | 改写 | 建议“声音不同步时，可校准耳机”。当前打卡包含个人跟拍触摸差值，不宜承诺测一次就能保证所有人的声学结果。 |
| 单人大厅已有“蓝牙耳机延迟校准（可选）›”等轻入口。见 [LeaderLobbyPage:286](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/LeaderLobbyPage.ets:286)。 | 弱化调整 | 保留一个“耳机设置 ›”或“声音不同步？校准 ›”入口；正常已校准仅显示状态；毫秒值和连接说明进入后再看。未校准不是错误，不需要警告式大卡片。 |
| 点击校准后，每次先出现“确认蓝牙声音出口”“确认后再开始延迟测量”及两声试音确认层。见 [LeaderLobbyPage:350](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/LeaderLobbyPage.ets:350)。 | 保留现状 | 暂时保留现状。 |
| 用户选择“声音在手机 / 其他设备”后又 Toast“未进入校准，请先把媒体声音切到蓝牙耳机”。见 [LeaderLobbyPage:239](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/LeaderLobbyPage.ets:239)。 | 改为当前步骤说明 | 原层内直接显示“请先把媒体输出切到耳机”，给继续试音的动作，避免关闭弹层再飘一条消息。 |
| 大厅未检测到输出、试音失败；路由恢复失败时跨页 Toast。见 [LeaderLobbyPage:181](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/LeaderLobbyPage.ets:181)、[AppSession:133](/Users/lizhe/work/oneBeat/entry/src/main/ets/app/AppSession.ets:133)。 | 保留，合并同次失败 | 确实影响当前试音／播放。文案说明结果和下一步，如“声音输出切换失败，请暂停后重试”；内部错误细节留日志。 |
| 保存测量后“已保存 … ms，请保持当前耳机连接”；结果区同时提示断开、重连或切换后重测。见 [TimeCardCalibrationPage:786](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/TimeCardCalibrationPage.ets:786)、[结果区:1075](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/TimeCardCalibrationPage.ets:1075)。 | 合并 | 保存按钮或结果区显示一次“已保存并生效”；连接变化说明放在测量详情，重连时入口状态提醒即可，不重复 Toast。 |

建议保留的蓝牙信息链：大厅一个入口 → 用户主动试音／测量 → 当前步骤的必要指导 → 保存结果。

## 加入、组队、行进与公共操作

| 当前提示类型与位置 | 建议 | 原因／推荐表达 |
|---|---|---|
| 昵称为空时的气泡“先给自己起个名字！不想费脑筋？点这里”。[TeamPage:197](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/TeamPage.ets:197) | 保留 | 。 |
| 建队 Wi-Fi 关闭时“建队前先打开 Wi-Fi”，并提供系统设置入口。[TeamPage:96](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/TeamPage.ets:96) | 保留 | 真正阻断建队，且有解决动作；不是普通说明型弹窗。 |
| 组队首页常驻“请先打开系统 Wi-Fi；手输加入码还需打开蓝牙。扫码加入建议保持蓝牙开启”。[TeamPage:391](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/TeamPage.ets:391) | 精简并去掉扫码蓝牙建议 | 扫码实际不需要蓝牙发现权限，与加入页现有说明冲突。正常状态不提前警告；在各加入方式旁保留对应条件。 |
| 加入页扫码说明与加入码蓝牙发现说明。[MemberJoinPage:169](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/MemberJoinPage.ets:169)、[204](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/MemberJoinPage.ets:204) | 保留，缩短 | 分别为“扫码需要相机和 Wi-Fi”“加入码需要蓝牙发现”；耳机输出信息移走。权限按实际操作申请。 |
| Wi-Fi、相机、蓝牙发现、麦克风授权失败说明。[TeamNetworkPermissions:82](/Users/lizhe/work/oneBeat/entry/src/main/ets/network/join/TeamNetworkPermissions.ets:82) | 保留按需反馈 | 只在缺少相应权限时显示。说明用途与替代方式，如相机被拒绝可输入加入码；避免每进页面重讲一遍。系统授权框不能用应用内提醒替代。 |
| “正在扫描附近 P2P 设备”“已建立局域连接，正在同步队伍”“已同步时钟，正在进入”等。[MemberJoinPage:313](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/MemberJoinPage.ets:313) | 暂时保留 | 。 |
| 加入／扫码失败、加入码未找到、设备不支持、连接超时；当前将部分原始异常直接拼进页面状态。[MemberJoinPage:338](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/MemberJoinPage.ets:338)、[371](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/MemberJoinPage.ets:371)、[395](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/MemberJoinPage.ets:395) | 保留错误，统一映射 | 提供重试／改扫码／打开设置。用户主动取消扫码应静默返回；协议不兼容、网络被占用等原因保留可操作说明，不直接输出底层错误码。 |
| 大厅“P2P 队伍已创建 · 可扫码或输入加入码”与邀请区重复。[LeaderLobbyPage:545](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/LeaderLobbyPage.ets:545) | 合并 | 正常创建成功无需底部再说明；邀请区本身已展示二维码和加入码。仅蓝牙发现不可用时局部提示“加入码暂不可用，可扫码加入”。 |
| 大厅加载／退出／创建失败及设置同步失败。[LeaderLobbyPage:498](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/LeaderLobbyPage.ets:498)、[566](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/LeaderLobbyPage.ets:566) | 保留局部状态／单次错误 | 加载和退出状态随按钮变化；创建失败留重试入口。角色、场景、拍号、出发、人机操作失败合并为统一短模板，避免 Toast 与错误卡重复。 |
| “仅可更换自己的角色”“已准备 · 不可换角”。[LeaderLobbyPage:1510](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/LeaderLobbyPage.ets:1510)、[1537](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/LeaderLobbyPage.ets:1537) | 保留条件状态 | 解释控件为何不可编辑，具有操作意义；不必再弹“不可换角”。 |
| 队员槽位上的已准备勾选、正在测时的耳机图标，以及出发／准备按钮状态。[LeaderLobbyPage:1113](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/LeaderLobbyPage.ets:1113)、[847](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/LeaderLobbyPage.ets:847) | 保留状态图标 | 表示队伍当前能否出发，属于协作进度；不需要另加队员开始／结束校准的 Toast。 |
| “点队伍槽位切换编辑对象”“点击选择 · 可左右滑动”“出发后全队进入同一场景”。[LeaderLobbyPage:1510](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/LeaderLobbyPage.ets:1510)、[1557](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/LeaderLobbyPage.ets:1557)、[1567](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/LeaderLobbyPage.ets:1567) | 前两项弱化保留；最后一项可删 | 槽位编辑和横滑是容易漏掉的操作；全队场景规则可在首次引导说明，不必重复常驻。 |
| 随机角色“正在准备／抽取／同步”“剪影已同步”。[RandomCharacterFilm:306](/Users/lizhe/work/oneBeat/entry/src/main/ets/components/RandomCharacterFilm.ets:306) | 保留局部状态，完成态可简化 | 进行中说明不能立刻操作的原因；完成时角色和勾选已可见，“剪影已同步”可改“已选定”或淡出。 |
| 行进页“已暂停 · 点击继续”“准备拍 · 舞台保持静止”“节奏由队长控制”。[MainPage:641](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/MainPage.ets:641) | 保留状态，缩短准备拍文案 | 建议“准备拍…”；“舞台保持静止”是实现规则，不需要额外讲。队员控制权限信息保留。 |
| 行进页播放／拍号／拍点／返回失败 Toast。[MainPage:214](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/MainPage.ets:214) | 保留，适度去重 | 用户动作失败需要反馈；相同错误连续出现时只保留一条，不能持续刷屏。 |
| 队员退出确认“要退出这支队伍吗？”与“本轮队伍进度不会保留”。[MainPage:382](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/MainPage.ets:382) | 保留确认，改准后果 | 建议“退出后需重新加入队伍”。当前没有持久化的“本轮队伍进度”概念，不宜暗示会丢失一份可保存成果。 |
| “队长已退出，队伍已解散”“与队长的连接已断开，已退出队伍”。[AppSession:364](/Users/lizhe/work/oneBeat/entry/src/main/ets/app/AppSession.ets:364) | 保留一次 | 页面被自动带回时必须解释原因；不再在返回页重复一条同义提示。 |
| “会话已退出，部分网络资源稍后释放”。[MainPage:342](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/MainPage.ets:342) | 删除用户提示，保留日志 | 用户已经成功离开，也没有可以处理资源释放的动作；如果仍阻断下次建队，再在下一次尝试时提示重试。 |
| BPM 越界“请输入 40–240 之间的 BPM”。[EditableBpm:36](/Users/lizhe/work/oneBeat/entry/src/main/ets/components/EditableBpm.ets:36) | 保留校验，移到输入旁 | 不需要全局 Toast；有效范围可在编辑态显示。 |
| “每分钟 … 个…音符拍点”、拍号编辑器的分子／分母与范围说明。[LeaderLobbyPage:1626](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/LeaderLobbyPage.ets:1626)、[EditableMeter:91](/Users/lizhe/work/oneBeat/entry/src/main/ets/components/EditableMeter.ets:91) | 保留低干扰说明 | 分母拍与复合拍的计速语义确实会影响使用，不属于可删的工程细节。 |

## 鼓机

| 当前提示 | 建议 | 原因／推荐表达 |
|---|---|---|
| “PRO 定制鼓机包含在畅游月卡中”。[LeaderLobbyPage:969](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/LeaderLobbyPage.ets:969)、[DrumMachinePage:144](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/DrumMachinePage.ets:144) | 保留一次，入口体现权益 | 大厅阻止后不会再进入鼓机，因此这两个守卫不是一次操作必弹两次。可以把入口锁定状态做好，路由守卫保留为兜底。 |
| “请填写节奏名称”。[DrumMachinePage:221](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/DrumMachinePage.ets:221) | 改为字段错误 | 名称输入框附近显示“请输入名称”，不漂浮。 |
| “已保存／已更新我的节奏”。[DrumMachinePage:256](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/DrumMachinePage.ets:256) | 保留轻反馈或保存态 | 持久化结果值得确认；和列表更新、按钮状态三者择一，不要叠加。 |
| “已删除这个节奏”“已载入 …”。[DrumMachinePage:273](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/DrumMachinePage.ets:273)、[290](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/DrumMachinePage.ets:290) | 删除重复成功 Toast | 列表消失或编排切换已经直接可见。 |
| “最多编排 8 个段落”“至少保留一个段落”。[DrumMachinePage:624](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/DrumMachinePage.ets:624)、[641](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/DrumMachinePage.ets:641) | 用边界控件状态表达 | 达到上限禁用新增、只剩一段禁用删除；必要时在控件附近给短说明。 |
| “节奏型已编辑／加花已编辑”。[DrumMachinePage:1137](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/DrumMachinePage.ets:1137) | 删除成功 Toast | 关闭浮层、名称变“已编辑”已经能反馈应用成功；编辑频繁，打扰累积明显。 |
| “试听启动失败”“切换试听失败”“试听更新失败，继续播放原编排”。[DrumMachinePage:1065](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/DrumMachinePage.ets:1065)、[1297](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/DrumMachinePage.ets:1297) | 保留，合并同一次失败 | 尤其连续更新失败时，画面是新版、声音仍是旧版，必须解释。建议按钮附近可保留“修改未进入试听，正在播放上一版”，不重复弹失败 Toast。 |
| “鼓机编排已应用到队伍”及“应用失败，请重试”。[DrumMachinePage:1512](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/DrumMachinePage.ets:1512) | 保留结果反馈 | 跨页、跨设备同步属于重要结果；成功可在大厅“已应用”状态中确认，失败明确保留在当前页。 |
| 覆盖同名节奏的“这个名字已经存在／继续保存会覆盖原有编排”。[DrumMachinePage:1780](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/DrumMachinePage.ets:1780) | 保留确认，标题缩短 | 覆盖已有数据需要明确后果；“同名警告”可改“覆盖已有节奏？”，避免重复三个标题。 |
| 节奏型／加花名后的微时值、八格、混合细分说明。见 [editorPatternLabel:574](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/DrumMachinePage.ets:574) | 保留 | 用户之前明确要求；解释为何出现菱形游离鼓点，是当前乐句信息。 |
| “点格子编辑 · 点数字定位”“就近保留 N 个其他细分鼓点”。[DrumMachinePage:1853](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/DrumMachinePage.ets:1853) | 保留简短帮助和条件操作 | 数字定位不容易发现；游离鼓点操作只在确实有游离点时出现，不能当通用提醒删掉。 |
| “横滑查看更多”、我的节奏空态、命名说明。见 [DrumMachinePage:2013](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/DrumMachinePage.ets:2013)、[2111](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/DrumMachinePage.ets:2111) | 保留低干扰／条件说明 | 空态帮助用户完成首次保存；横滑说明可仅在首次使用显示，命名说明可并入占位文字。 |
| “节奏、加花与段落会作为轻量事件同步；每台设备使用本地鼓组采样播放。”[DrumMachinePage:2101](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/DrumMachinePage.ets:2101) | 删除或移到帮助 | 纯实现说明，对应用编排的决策没有帮助。 |
| 旧 `saveLocal()` 的“已保存编排”。[DrumMachinePage:1466](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/DrumMachinePage.ets:1466) | 清理未调用代码时删除 | 当前不是用户打扰来源，不作为精简效果计数。 |

## 商店、支付与兑换

| 当前提示 | 建议 | 原因／推荐表达 |
|---|---|---|
| 已选场景后的“已切换到 …”。[StorePage:315](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/StorePage.ets:315) | 删除重复成功 Toast | 卡片选中状态足以表达。 |
| “畅游月卡已生效”“赠送月卡生效期间不能购买自动续费月卡”“当前暂不能购买自动续费月卡”。[StorePage:367](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/StorePage.ets:367) | 保留权益限制，改为入口状态／详情 | 显示有效期和不可购买原因，避免用户点已生效卡片反复弹消息。 |
| 购买确认层的商品／价格／权益说明及华为支付确认。[StorePage:1114](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/StorePage.ets:1114) | 保留必要决策信息 | 不能为“少提示”而隐去价格、权益和续费状态。应用层说明可简短，系统支付确认仍由系统处理。 |
| “最终权益以华为支付结果与 OneBeat 服务端验单结果为准”。[StorePage:1135](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/StorePage.ets:1135) | 改为用户操作说明 | “支付后权益未到账，可点击恢复购买”。验单与服务端是实现细节，价格和到账状态要清楚。 |
| “正在连接华为支付并核验订单…”“账号已拥有，正在同步权益”。[StorePage:436](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/StorePage.ets:436) | 保留单一进行态 | 推荐“正在完成购买…”／“正在同步已购权益…”，放按钮或当前操作区。 |
| “购买成功，权益已到账”“已同步华为账号中的购买记录”。[StorePage:462](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/StorePage.ets:462)、[477](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/StorePage.ets:477) | 保留一次明确结果 | 金钱和权益结果值得确认；不同时再显示重复横幅。 |
| 购买失败目前同时写 `serviceStatus` 并 Toast；部分底层异常直接拼接错误码。[StorePage:190](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/StorePage.ets:190)、[481](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/StorePage.ets:481) | 合并为可恢复错误 | 一处显示并给重试／恢复购买入口；用户主动取消不当作失败告警。保留真实未到账、账号与网络异常。 |
| 兑换成功同时更新到期状态和 Toast；兑换失败同时写状态和 Toast。[StorePage:546](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/StorePage.ets:546) | 合并到兑换区 | 成功显示“已兑换 · 有效至 …”，错误显示在输入框下；输入口令说明与“不自动续费”信息保留。 |
| 恢复购买的进行态、成功 Toast、失败时页面状态 + Toast。[StorePage:562](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/StorePage.ets:562) | 保留一处完整反馈 | 用户主动点击恢复，不能无声结束。统一“权益已同步”／“恢复失败，请检查账号和网络后重试”。 |
| “开发配置：请填写测试与生产 API 地址”。[StorePage:214](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/StorePage.ets:214) | 用户版删除工程文案 | 用户无法处理 API 配置；显示“商店暂时不可用，请稍后重试”，详情仅开发环境和日志保留。 |
| “商店服务暂时不可用，已使用本机最近一次权益”。[StorePage:241](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/StorePage.ets:241) | 条件保留，缩短 | 如果确实影响购买，显示“暂时无法连接商店，已保留现有权益”。恢复后自动消失，不每次刷新 Toast。 |
| 登录华为账号、价格加载／不可用、续费和有效期状态。[IapCatalogService:56](/Users/lizhe/work/oneBeat/entry/src/main/ets/store/IapCatalogService.ets:56)、[StorePage:665](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/StorePage.ets:665) | 保留对应状态 | 是用户能否购买、是否仍有权益的关键信息；不合并成泛泛“网络错误”。 |

## 校准页内部

正式入口目前进入 `TimeCardCalibrationPage`。`AudioCalibrationPage` 属于无正式入口的旧版本；`MicLoopbackCalibrationPage` 未注册为页面。旧页的麦克风权限、输入侧差分、回环公式、播放基准等内容应留在技术／调试流程，不再复制进普通测量页。

| 当前提示 | 建议 | 原因／推荐表达 |
|---|---|---|
| 开始前“先完整听一小节…从下一个滴开始…只跟着耳机里的声音轻敲”“8 小节 · 32 次敲击”。[TimeCardCalibrationPage:1033](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/TimeCardCalibrationPage.ets:1033) | 保留一个指导区 | 测量需要知道何时开始、持续多久；不要同时在上方、按钮下和底部重复同一句。 |
| 测量中的准备、倾听、敲击提示和 `N / 32`。[TimeCardCalibrationPage:842](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/TimeCardCalibrationPage.ets:842)、[1152](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/TimeCardCalibrationPage.ets:1152) | 保留随阶段切换 | 这是任务进度，不是打扰型提醒。 |
| 未连接耳机／会话结束时的开测、重测、保存和试听守卫，合计多处。[TimeCardCalibrationPage:423](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/TimeCardCalibrationPage.ets:423) | 用当前状态与禁用控件优先表达 | 正常状态不显示警告；操作进行中突然断开时，明确说明本次无效。相同原因无需每点一次弹一次。 |
| 测量失败的具体原因：“第一拍还没接到／节拍还没开始／两次敲击太近／节奏偏离”等，加下一步建议。[TimeCardCalibrationPage:855](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/TimeCardCalibrationPage.ets:855)、[874](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/TimeCardCalibrationPage.ets:874) | 保留原因 + 一个动作 | 推荐“从下一次首拍开始重试”“每拍只敲一次”，无需再追加同义 Toast。 |
| “本次不计算、不保存，已保存的校准不会被覆盖”。[TimeCardCalibrationPage:1047](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/TimeCardCalibrationPage.ets:1047) | 保留并缩短 | 建议“本次未保存，原校准仍有效”，解释失败不会覆盖已有结果。 |
| 测量值、波动、稳定度、结果试听、查看结果后才允许保存。[TimeCardCalibrationPage:940](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/TimeCardCalibrationPage.ets:940)、[1056](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/TimeCardCalibrationPage.ets:1056) | 保留结果与质量 | 用户需要评估是否保存；无需因为“少提示”跳过结果审阅。 |
| “这个数值包含耳机播放链路和你的跟拍触摸差值……”及重复连接重测说明。[TimeCardCalibrationPage:1073](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/TimeCardCalibrationPage.ets:1073) | 放“测量说明”按需展开 | 语义应保留，但不必成为结果区长段正文；默认可简写“本次跟拍测得的本机补偿”。 |
| 保存失败、试听启动失败、耳机断开未保存。[TimeCardCalibrationPage:769](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/TimeCardCalibrationPage.ets:769)、[790](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/TimeCardCalibrationPage.ets:790)、[837](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/TimeCardCalibrationPage.ets:837) | 保留单次明确错误 | 当前行为不能完成，需要说明下一步；工程详情保留日志，避免用户面对播放基准、时钟坐标等术语。 |

## 统一提示规则建议

1. 正常连接、进入页面、切换场景、载入节奏和应用格子，优先让界面自身状态反馈；不连续弹成功 Toast。
2. 同一次操作同一个原因，只使用一个主要反馈位置。字段问题在字段旁，任务失败在任务区，跨页退队等重要结果才用一次 Toast 或结果页。
3. 不需要立即操作的限制和建议放详情／帮助；正常播放画面不常驻警告色文字。
4. 反复点击、异步回包或自动重试不产生提示连发；只有当前仍有效的操作可以展示失败。相同错误建议按操作归属合并，而不是压掉所有后续不同错误。
5. 用户取消扫码、关闭弹层、取消支付等主动退出优先静默返回；覆盖编排、支付与退出队伍的真实后果仍明确说明。
6. 对用户不能处理的 API、渲染器、验单、P2P、时钟基准等细节做产品文案映射，原始详情保留在日志。

## 建议实施顺序

- 第一批：删除加入页耳机勾选门槛与通用提醒卡；删除行进页蓝牙 Toast 和横幅；大厅多人不动，单人收敛为一个可选入口。
- 第二批：减少鼓机编辑／载入／删除和场景切换的成功 Toast；购买／兑换／恢复失败只保留一个主要出口；把开发文案改为可操作错误。
- 第三批：合并校准页重复说明、统一权限与失败文案、按错误归属防重；确认旧校准页是否还需要保留后再清理代码。

本评估没有要求删除权限申请、支付信息、数据覆盖确认、断线退队原因、测量结果失效或真实操作失败反馈。
