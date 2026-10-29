# Toast 与系统应用弹窗逐项评估

对应主报告：[提示评估](/Users/lizhe/work/oneBeat/designs/notice-audit/2026-10-16/README.md)。调用点不等于独立文案或实际弹出次数。`message` 等变量的取值见该方法和主报告中的流程评估。旧校准页单独标明，避免把未显示的源码算成打扰。

| 编号 | 来源 | 当前消息表达式 | 评估 |
|---|---|---|---|
| T001 | [AppSession.ets:133](/Users/lizhe/work/oneBeat/entry/src/main/ets/app/AppSession.ets:133) | err.message | 保留真实路由恢复失败；用户文案映射，单次展示 |
| T002 | [AppSession.ets:364](/Users/lizhe/work/oneBeat/entry/src/main/ets/app/AppSession.ets:364) | reason === 'leader_exit' ? '队长已退出，队伍已解散' : '与队长的连接已断开，已退出队伍' | 保留一次断线／队伍解散原因 |
| T003 | [EditableBpm.ets:36](/Users/lizhe/work/oneBeat/entry/src/main/ets/components/EditableBpm.ets:36) | \`请输入 ${BPM_MIN}–${BPM_MAX} 之间的 BPM\` | 保留校验，改为输入框附近反馈 |
| T004 | [AudioCalibrationPage.ets:157](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/AudioCalibrationPage.ets:157) | '当前没有检测到蓝牙耳机输出，请返回大厅重新确认' | 非主流程：旧／未注册校准页。保留必要故障语义，优先不在本轮产品流程中复制；21处不计日常打扰 |
| T005 | [AudioCalibrationPage.ets:162](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/AudioCalibrationPage.ets:162) | '当前没有可用会话，请从队伍大厅进入' | 非主流程：旧／未注册校准页。保留必要故障语义，优先不在本轮产品流程中复制；21处不计日常打扰 |
| T006 | [AudioCalibrationPage.ets:353](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/AudioCalibrationPage.ets:353) | '蓝牙耳机已断开，本次结果没有保存' | 非主流程：旧／未注册校准页。保留必要故障语义，优先不在本轮产品流程中复制；21处不计日常打扰 |
| T007 | [AudioCalibrationPage.ets:363](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/AudioCalibrationPage.ets:363) | \`已保存 ${this.resultMs} ms，请保持耳机连接；蓝牙重连后推荐重测\` | 非主流程：旧／未注册校准页。保留必要故障语义，优先不在本轮产品流程中复制；21处不计日常打扰 |
| T008 | [AudioCalibrationPage.ets:368](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/AudioCalibrationPage.ets:368) | \`保存失败：${(err as Error).message}\` | 非主流程：旧／未注册校准页。保留必要故障语义，优先不在本轮产品流程中复制；21处不计日常打扰 |
| T009 | [AudioCalibrationPage.ets:375](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/AudioCalibrationPage.ets:375) | '当前没有检测到蓝牙耳机输出' | 非主流程：旧／未注册校准页。保留必要故障语义，优先不在本轮产品流程中复制；21处不计日常打扰 |
| T010 | [AudioCalibrationPage.ets:414](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/AudioCalibrationPage.ets:414) | \`试听启动失败：${(err as Error).message}\` | 非主流程：旧／未注册校准页。保留必要故障语义，优先不在本轮产品流程中复制；21处不计日常打扰 |
| T011 | [DrumMachinePage.ets:144](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/DrumMachinePage.ets:144) | 'PRO 定制鼓机包含在畅游月卡中' | 保留权益守卫兜底，入口先体现锁定状态 |
| T012 | [DrumMachinePage.ets:221](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/DrumMachinePage.ets:221) | '请填写节奏名称' | 改为名称字段错误 |
| T013 | [DrumMachinePage.ets:256](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/DrumMachinePage.ets:256) | replaced ? '已更新我的编排' : '已保存到我的编排' | 保存结果择一轻反馈，避免列表与Toast叠加 |
| T014 | [DrumMachinePage.ets:273](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/DrumMachinePage.ets:273) | '已删除这个节奏' | 删除重复成功Toast，列表变化已可见 |
| T015 | [DrumMachinePage.ets:290](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/DrumMachinePage.ets:290) | \`已载入 ${saved.name}\` | 删除重复成功Toast，编排已直接切换 |
| T016 | [DrumMachinePage.ets:624](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/DrumMachinePage.ets:624) | '最多编排 8 个段落' | 用新增按钮禁用与局部上限状态表达 |
| T017 | [DrumMachinePage.ets:641](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/DrumMachinePage.ets:641) | '至少保留一个段落' | 只剩一段时禁用删除，避免反复Toast |
| T018 | [DrumMachinePage.ets:1065](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/DrumMachinePage.ets:1065) | '试听启动失败' | 保留试听失败，统一短文案 |
| T019 | [DrumMachinePage.ets:1137](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/DrumMachinePage.ets:1137) | this.editorMode === 0 ? '节奏型已编辑' : '加花已编辑' | 删除重复成功Toast，已编辑标签已反馈 |
| T020 | [DrumMachinePage.ets:1297](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/DrumMachinePage.ets:1297) | '试听更新失败，继续播放原编排' | 保留：新版修改未进入试听；优先当前试听区域反馈 |
| T021 | [DrumMachinePage.ets:1330](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/DrumMachinePage.ets:1330) | '试听启动失败' | 保留试听失败，合并同一操作反馈 |
| T022 | [DrumMachinePage.ets:1408](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/DrumMachinePage.ets:1408) | '切换试听失败' | 保留切换失败，合并同一操作反馈 |
| T023 | [DrumMachinePage.ets:1461](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/DrumMachinePage.ets:1461) | '切换试听失败' | 保留切换失败，合并同一操作反馈 |
| T024 | [DrumMachinePage.ets:1468](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/DrumMachinePage.ets:1468) | '已保存编排' | 未调用旧saveLocal方法；代码清理时移除，不计当前打扰 |
| T025 | [DrumMachinePage.ets:1512](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/DrumMachinePage.ets:1512) | '鼓机编排已应用到队伍' | 保留跨页应用结果或由大厅已应用状态反馈，择一 |
| T026 | [DrumMachinePage.ets:1515](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/DrumMachinePage.ets:1515) | '应用失败，请重试' | 保留失败并留在当前操作区 |
| T027 | [LeaderLobbyPage.ets:181](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/LeaderLobbyPage.ets:181) | '当前没有检测到蓝牙耳机输出' | 当前校准入口就地说明，不重复全局Toast |
| T028 | [LeaderLobbyPage.ets:195](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/LeaderLobbyPage.ets:195) | '当前没有检测到蓝牙耳机输出' | 试音步骤就地显示未连接 |
| T029 | [LeaderLobbyPage.ets:210](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/LeaderLobbyPage.ets:210) | \`试音失败：${(err as Error).message}\` | 保留试音失败，统一短文案／同次去重 |
| T030 | [LeaderLobbyPage.ets:241](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/LeaderLobbyPage.ets:241) | '未进入校准，请先把媒体声音切到蓝牙耳机' | 改为校准步骤内说明和重试动作，避免关闭后再弹 |
| T031 | [LeaderLobbyPage.ets:572](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/LeaderLobbyPage.ets:572) | '退出队伍失败，请重试' | 保留真实操作失败，统一短文案；一次操作仅一个主要反馈出口 |
| T032 | [LeaderLobbyPage.ets:612](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/LeaderLobbyPage.ets:612) | '拍号修改失败，请重试' | 保留真实操作失败，统一短文案；一次操作仅一个主要反馈出口 |
| T033 | [LeaderLobbyPage.ets:754](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/LeaderLobbyPage.ets:754) | '随机头像同步失败，请重试' | 保留真实操作失败，统一短文案；一次操作仅一个主要反馈出口 |
| T034 | [LeaderLobbyPage.ets:817](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/LeaderLobbyPage.ets:817) | '角色同步失败，请重试' | 保留真实操作失败，统一短文案；一次操作仅一个主要反馈出口 |
| T035 | [LeaderLobbyPage.ets:920](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/LeaderLobbyPage.ets:920) | '出发同步失败，请重试' | 保留真实操作失败，统一短文案；一次操作仅一个主要反馈出口 |
| T036 | [LeaderLobbyPage.ets:927](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/LeaderLobbyPage.ets:927) | '请先在奇遇小铺解锁这个场景' | 保留真实操作失败，统一短文案；一次操作仅一个主要反馈出口 |
| T037 | [LeaderLobbyPage.ets:934](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/LeaderLobbyPage.ets:934) | '场景同步失败，请重试' | 保留真实操作失败，统一短文案；一次操作仅一个主要反馈出口 |
| T038 | [LeaderLobbyPage.ets:969](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/LeaderLobbyPage.ets:969) | 'PRO 定制鼓机包含在畅游月卡中' | 保留权益守卫，一次操作不重复提示 |
| T039 | [LeaderLobbyPage.ets:1026](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/LeaderLobbyPage.ets:1026) | '进入行进页失败，请重试' | 保留真实操作失败，统一短文案；一次操作仅一个主要反馈出口 |
| T040 | [LeaderLobbyPage.ets:1056](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/LeaderLobbyPage.ets:1056) | '添加人机失败' | 保留真实操作失败，统一短文案；一次操作仅一个主要反馈出口 |
| T041 | [LeaderLobbyPage.ets:1069](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/LeaderLobbyPage.ets:1069) | '移除人机失败' | 保留真实操作失败，统一短文案；一次操作仅一个主要反馈出口 |
| T042 | [MainPage.ets:214](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/MainPage.ets:214) | '播放操作失败，请重试' | 保留真实操作失败，统一短文案；一次操作仅一个主要反馈出口 |
| T043 | [MainPage.ets:227](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/MainPage.ets:227) | '拍号修改失败，请重试' | 保留真实操作失败，统一短文案；一次操作仅一个主要反馈出口 |
| T044 | [MainPage.ets:241](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/MainPage.ets:241) | '拍点修改失败，请重试' | 保留真实操作失败，统一短文案；一次操作仅一个主要反馈出口 |
| T045 | [MainPage.ets:323](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/MainPage.ets:323) | '返回队伍大厅失败，请重试' | 保留真实操作失败，统一短文案；一次操作仅一个主要反馈出口 |
| T046 | [MainPage.ets:342](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/MainPage.ets:342) | '会话已退出，部分网络资源稍后释放' | 删除用户提示，资源释放详情留日志 |
| T047 | [MainPage.ets:348](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/MainPage.ets:348) | '返回首页失败，请重试' | 保留真实操作失败，统一短文案；一次操作仅一个主要反馈出口 |
| T048 | [MainPage.ets:654](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/MainPage.ets:654) | '检测到蓝牙耳机输出，节拍可能延迟，建议外放或有线耳机' | 删除蓝牙连接时通用延迟Toast；大厅保留可选入口 |
| T049 | [MicLoopbackCalibrationPage.ets:134](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/MicLoopbackCalibrationPage.ets:134) | '当前没有检测到蓝牙耳机输出，请返回大厅重新确认' | 非主流程：旧／未注册校准页。保留必要故障语义，优先不在本轮产品流程中复制；21处不计日常打扰 |
| T050 | [MicLoopbackCalibrationPage.ets:140](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/MicLoopbackCalibrationPage.ets:140) | microphonePermissionDeniedHint() | 非主流程：旧／未注册校准页。保留必要故障语义，优先不在本轮产品流程中复制；21处不计日常打扰 |
| T051 | [MicLoopbackCalibrationPage.ets:145](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/MicLoopbackCalibrationPage.ets:145) | '当前没有可用会话，请从队伍大厅进入' | 非主流程：旧／未注册校准页。保留必要故障语义，优先不在本轮产品流程中复制；21处不计日常打扰 |
| T052 | [MicLoopbackCalibrationPage.ets:234](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/MicLoopbackCalibrationPage.ets:234) | '请把媒体输出切到手机扬声器后再测输入侧时延（只需测一次）' | 非主流程：旧／未注册校准页。保留必要故障语义，优先不在本轮产品流程中复制；21处不计日常打扰 |
| T053 | [MicLoopbackCalibrationPage.ets:240](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/MicLoopbackCalibrationPage.ets:240) | microphonePermissionDeniedHint() | 非主流程：旧／未注册校准页。保留必要故障语义，优先不在本轮产品流程中复制；21处不计日常打扰 |
| T054 | [MicLoopbackCalibrationPage.ets:245](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/MicLoopbackCalibrationPage.ets:245) | '当前没有可用会话，请从队伍大厅进入' | 非主流程：旧／未注册校准页。保留必要故障语义，优先不在本轮产品流程中复制；21处不计日常打扰 |
| T055 | [MicLoopbackCalibrationPage.ets:279](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/MicLoopbackCalibrationPage.ets:279) | \`输入侧时延 ${this.inputLatencyMs} ms 已保存\` | 非主流程：旧／未注册校准页。保留必要故障语义，优先不在本轮产品流程中复制；21处不计日常打扰 |
| T056 | [MicLoopbackCalibrationPage.ets:296](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/MicLoopbackCalibrationPage.ets:296) | '回环值小于输入侧值，本次差分结果无效，请重测两步' | 非主流程：旧／未注册校准页。保留必要故障语义，优先不在本轮产品流程中复制；21处不计日常打扰 |
| T057 | [MicLoopbackCalibrationPage.ets:298](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/MicLoopbackCalibrationPage.ets:298) | '还没有足够的有效测量结果' | 非主流程：旧／未注册校准页。保留必要故障语义，优先不在本轮产品流程中复制；21处不计日常打扰 |
| T058 | [MicLoopbackCalibrationPage.ets:303](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/MicLoopbackCalibrationPage.ets:303) | '蓝牙耳机已断开，本次结果没有保存' | 非主流程：旧／未注册校准页。保留必要故障语义，优先不在本轮产品流程中复制；21处不计日常打扰 |
| T059 | [MicLoopbackCalibrationPage.ets:307](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/MicLoopbackCalibrationPage.ets:307) | '请先完成输入侧校准，再保存耳机输出补偿' | 非主流程：旧／未注册校准页。保留必要故障语义，优先不在本轮产品流程中复制；21处不计日常打扰 |
| T060 | [MicLoopbackCalibrationPage.ets:349](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/MicLoopbackCalibrationPage.ets:349) | '保存期间播放基准发生变化，本次结果已丢弃' | 非主流程：旧／未注册校准页。保留必要故障语义，优先不在本轮产品流程中复制；21处不计日常打扰 |
| T061 | [MicLoopbackCalibrationPage.ets:356](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/MicLoopbackCalibrationPage.ets:356) | \`已保存输出补偿 ${outputMs} ms，蓝牙重连后推荐重测\` | 非主流程：旧／未注册校准页。保留必要故障语义，优先不在本轮产品流程中复制；21处不计日常打扰 |
| T062 | [MicLoopbackCalibrationPage.ets:359](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/MicLoopbackCalibrationPage.ets:359) | \`保存失败：${(err as Error).message}\` | 非主流程：旧／未注册校准页。保留必要故障语义，优先不在本轮产品流程中复制；21处不计日常打扰 |
| T063 | [StorePage.ets:315](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/StorePage.ets:315) | \`已切换到 ${item.name}\` | 删除重复切换成功Toast，保留选中状态 |
| T064 | [StorePage.ets:373](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/StorePage.ets:373) | message | 权益状态／购买入口附近说明，不反复Toast |
| T065 | [StorePage.ets:377](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/StorePage.ets:377) | '当前暂不能购买自动续费月卡' | 入口附近保留不可购买原因 |
| T066 | [StorePage.ets:462](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/StorePage.ets:462) | '购买成功，权益已到账' | 保留一次购买成功及到账结果 |
| T067 | [StorePage.ets:477](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/StorePage.ets:477) | '已同步华为账号中的购买记录' | 保留一次权益同步结果 |
| T068 | [StorePage.ets:483](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/StorePage.ets:483) | this.purchaseFailureMessage(e) | 页面状态与Toast择一；取消支付静默，真实失败保留 |
| T069 | [StorePage.ets:547](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/StorePage.ets:547) | '口令兑换成功，畅游月卡已到账' | 兑换区到期状态与Toast择一，推荐局部结果 |
| T070 | [StorePage.ets:551](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/StorePage.ets:551) | detail | 保留兑换字段／任务错误，不与状态重复 |
| T071 | [StorePage.ets:607](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/StorePage.ets:607) | toastMessage | 用户主动恢复需有一个明确结果 |
| T072 | [StorePage.ets:611](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/StorePage.ets:611) | detail.length > 0 ? detail : '恢复购买失败，请稍后重试' | 恢复失败仅一个主要出口，给账号／网络检查与重试 |
| T073 | [TimeCardCalibrationPage.ets:423](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/TimeCardCalibrationPage.ets:423) | '请先连接蓝牙耳机，再开始打卡' | 未连接状态＋禁用开始；瞬时断开再明确反馈 |
| T074 | [TimeCardCalibrationPage.ets:432](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/TimeCardCalibrationPage.ets:432) | '当前没有可用会话，请从队伍大厅进入' | 会话失效留一个原因与返回入口 |
| T075 | [TimeCardCalibrationPage.ets:472](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/TimeCardCalibrationPage.ets:472) | '请先重新连接蓝牙耳机' | 耳机未重连在当前状态区说明 |
| T076 | [TimeCardCalibrationPage.ets:476](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/TimeCardCalibrationPage.ets:476) | '当前会话已结束，请返回大厅重新进入' | 会话结束在当前状态区说明 |
| T077 | [TimeCardCalibrationPage.ets:769](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/TimeCardCalibrationPage.ets:769) | '蓝牙耳机已断开，本次结果没有保存' | 保留断开导致本次未保存的明确结果 |
| T078 | [TimeCardCalibrationPage.ets:786](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/TimeCardCalibrationPage.ets:786) | \`已保存 ${result} ms，请保持当前耳机连接\` | 保存并生效只反馈一次；连接说明放详情 |
| T079 | [TimeCardCalibrationPage.ets:790](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/TimeCardCalibrationPage.ets:790) | \`保存失败：${(err as Error).message}\` | 保留保存失败，映射工程错误 |
| T080 | [TimeCardCalibrationPage.ets:804](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/TimeCardCalibrationPage.ets:804) | '当前没有检测到蓝牙耳机输出' | 试听区显示未连接状态，避免重复Toast |
| T081 | [TimeCardCalibrationPage.ets:837](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/TimeCardCalibrationPage.ets:837) | \`试听启动失败：${(err as Error).message}\` | 保留试听失败，统一短文案 |

## 应用调用的系统样式弹窗

| 来源 | 文案与条件 | 评估 |
|---|---|---|
| [TeamPage:96](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/TeamPage.ets:96) | Wi-Fi关闭时“建队前先打开 Wi-Fi”；提供暂不创建／去打开 Wi-Fi | 保留，有真实前置条件和解决动作。权限系统框与支付框由系统处理，另见主报告。 |
