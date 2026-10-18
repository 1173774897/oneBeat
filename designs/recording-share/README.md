# 行进录制分享素材

2026-10-18：使用内置 imagegen 生成的正式透明 PNG，已用于应用作品分享页。没有将设计草案的线稿当作产品页面。

- 素材：`entry/src/main/resources/rawfile/comic/decor/recording_share_hero.png`
- 用途：录制作品页空态和分享面板的摄像机 / 麦克风 / 鼓垫插画。
- 插画是装饰图；实时波形由实际麦克风峰值绘制，录制/停止/分享交互由原生控件实现。
- 生成方式：内置 imagegen，透明背景，保留原 alpha。未使用 CLI 或外部模型。

最终提示词：

> Use case: illustration-story. Production decorative hero PNG for the recording library and share/check-in sheets in the oneBeat HarmonyOS music walking app. A polished full-color comic collage of a coral-red portable video camera with a round red recording light, a small handheld microphone and a lavender drum pad, with a flowing teal audio waveform curling between them. Contemporary editorial comic illustration with near-black ink contours, cream paper highlights, subtle screen-print halftone texture, fully colored volumes, crisp silhouettes and restrained hard ink shadows. Horizontal wide group about 2:1, camera dominant left, microphone right, drum pad slightly behind, all objects fully within canvas. Genuine alpha transparency outside objects and small energy accents. Palette coral #FF7056, lilac #C5B7EB, teal #29B5AE, cream #FFF9EE, ink #171B1F. No text, logos, letters, numbers, UI frame or watermark. Finished usable art, not a wireframe or line drawing.

采集使用系统 AVScreenCapture 原始流与硬件视频编码，内音和MIC分轨保存，不改变原节拍 renderer、时钟或延迟补偿；分享使用系统本地视频面板，发布后用户明确确认打卡，拉起面板不自动发奖。录屏开关对蓝牙真实输出时延、内录音轨与人物动作的相位关系必须真机对照验收。

## 当前实现与验证边界

- 行进页的“人”按钮与抽屉已删除，没有迁至上面板。录制按钮保留原底栏位置，录制中切为停止；舞台另有安全区外的停止按钮。点击舞台可重新展开/收起控制面板并继续操作，展开的面板也会入镜。录完不再弹 toast，而是显示保存位置弹窗；“退出去查看”先完整退出当前单人/多人练习并清空行进路由栈，再进入对应作品页选中刚录视频；“继续行进”只关闭弹窗，不暂停练习。录制开始、停止或系统采集失败也改用错误详情弹窗；若原始音轨已保留，则显示可重试/放弃的保存恢复弹窗，不再叠加失败 toast。
- 波形用Canvas绘制MIC真实峰值的上下双向包络；真实声波与停止控件是场景叠加层，系统录屏会将两者保留在成品中。生产播放 renderer、时钟同步、耳机校准与 WalkScene 坐标均未改动。
- 大厅锁定入口没有常驻活动内容；点击有回弹并打开交互提示，内部切换记录和玩法。试用/月卡状态小字也能查看同一提示。
- 分享采用系统本地视频分享面板；请选择小红书发布，返回后明确确认。没有接入需要 AppKey/公网视频的第三方 SDK，没有自动把拉起面板算作发布成功。
- 日记录、请求去重、试用截止和作品索引使用本机原子JSON文件，避免Preferences单字符串8KB上限；旧Preferences自动迁移。短分享请求与月卡摘要仍用Preferences。月卡摘要独立保存，未知状态保留待确认分享，不误发奖励。活动时间回拨下界不改变正式月卡的有效期判定。
- 成片索引失败保留 MP4 与恢复元数据，可在当前页重试；启动时从恢复元数据重建作品索引。作品删除与待确认分享互斥。
- 练习播放时不创建视频预览播放器，避免静音视频仍抢占音频焦点。只有队长明确暂停后可预览/分享；队员不能暂停全队。
- 作品页默认有声预览。新作品保留纯视频、应用内音PCM、MIC PCM与同源时间戳；MIC滑杆只改变MIC的0–200%增益，内音系数固定1，每次从原轨重混而非累积调整整段音量；松手后原生后台生成预览，保存/分享使用调整后的版本。旧版已混音作品无法分离MIC，需重新录制；旧版无练习类型的作品归入单人列表。
- 首页标题栏与人物主视觉保持原样；下方改为横排的多人/单人双面板，面板底部各自内嵌独立作品入口并显示数量。多人面板使用现有 `tree + plant_06 + plant_08`，单人面板使用现有 `sign`；下方紫色收藏小铺不放插图。分享日历放在作品页分享小红书按钮上方，两种练习共用连续打卡账本。
- API12录屏没有公开强制选择输入设备的接口。代码验证手机内置MIC与输出路由，发现不安全的耳机MIC/路由切换会拒绝或结束录制，不能据此承诺所有耳机组合均已验证。
- 内录请求使用 `OH_APP_PLAYBACK`，并排除通知音。应用音源的实际隔离由厂商系统实现，仍需真机验证；不能仅凭枚举名字承诺其他应用的后台音源一定被排除。

## UI 位置与尺寸交接

下列值均位于应用源码，增大/减小的方向相反；人物和道路的原锚点无需调整。

| 源文件 | 首选属性 / 当前值 | 调整效果与次级约束 |
|---|---|---|
| `entry/src/main/ets/components/RecordingOverlay.ets` | `WAVEFORM_TOP='27%'` | 增大声波下移；避开倒数数字和人物 |
| 同上 | `WAVEFORM_HEIGHT=70`、`WAVEFORM_SIDE_INSET=20` | 增大高度更高；增大两侧间距则变窄 |
| 同上 | `RECORD_STOP_BOTTOM=24` | 增大停止按钮上移，另叠加 bottomSafeInset |
| `entry/src/main/ets/pages/MainPage.ets` | `RECORD_INTRO_WIDTH='88%'`、`RECORD_INTRO_HERO_HEIGHT=140` | 增大说明弹层更宽、插画更高；受屏幕可用范围限制 |
| 同上 | `RECORD_RESULT_WIDTH='86%'`、`RECORD_RESULT_Y_OFFSET=0` | 增大宽度会让录制成功/失败弹窗变宽；增大 Y 偏移会下移，减小会上移。成功弹窗的双按钮各占一半，过窄会先挤压按钮文字 |
| `entry/src/main/ets/pages/RecordingLibraryPage.ets` | `LIBRARY_SIDE_INSET=20` | 增大内容向内收、可用宽度变窄 |
| 同上 | `LIBRARY_HERO_HEIGHT=154`、`VIDEO_PREVIEW_HEIGHT=242` | 增大空态插画或视频预览区域更高 |
| 同上 | `SHARE_SHEET_WIDTH='90%'`、`SHARE_SHEET_MAX_HEIGHT='88%'` | 增大分享弹层宽度或可见高度，超出高度的内容滚动 |
| `entry/src/main/ets/components/ShareCalendarSheet.ets` | `SHARE_CALENDAR_SIDE_INSET=18`、`SHARE_CALENDAR_BOTTOM=28` | 增大提示左右内缩、变窄；增大底距上移，另叠加 bottomInset |
| 同上 | `SHARE_CALENDAR_MAX_HEIGHT='88%'` | 增大记录/玩法弹层可见高度，超出内容滚动 |
| `entry/src/main/ets/pages/LeaderLobbyPage.ets` | `PRO_DRUM_TRIAL_LABEL_SIZE=10` | 增大试用状态字更大，受原入口56vp高度限制 |

图片素材路径：`entry/src/main/resources/rawfile/comic/decor/recording_share_hero.png`。运行时优先调整 Main 的 `RECORD_INTRO_HERO_HEIGHT` 与 Library 的 `LIBRARY_HERO_HEIGHT`，均为 Contain；Library 分享面板另有108vp插画高度、作品卡片48vp高度。原鼓机锁链素材 `comic/decor/pro-chain-locked.png` / `pro-chain-anchored.png` 的位置与缩放未改。

首页入口由 `pages/Index.ets` 的 `HOME_TEAM_ENTRY_WEIGHT=58` / `HOME_SOLO_ENTRY_WEIGHT=42` 控制左右宽度比例；增大其中一项会让对应卡片变宽。`HOME_PRACTICE_HEIGHT=176`（增大双面板更高）、`HOME_PRACTICE_GAP=10`（增大两卡间距并压缩卡片可用宽度）、`HOME_WORKS_PILL_WIDTH=78` / `HOME_WORKS_PILL_HEIGHT=34`（增大作品与小铺胶囊）和 `HOME_STORE_HEIGHT=86`（增大紫色小铺入口高度）控制整体尺寸。多人插图素材为 `scenes/sunset/entities/tree.png`、`vegetation/plant_06.png`、`vegetation/plant_08.png`，首选分别调整 `HOME_TEAM_TREE_HEIGHT=64`、`HOME_TEAM_PLANT_06_WIDTH=62`、`HOME_TEAM_PLANT_08_WIDTH=36`；增大即放大对应素材。单人插图为 `scenes/sunset/entities/sign.png`，由 `HOME_SOLO_SIGN_HEIGHT=44` 控制，增大会放大路牌。

分享日历由 `components/ShareCalendarSheet.ets` 的 `SHARE_CALENDAR_SIDE_INSET=18`（增大变窄）、`SHARE_CALENDAR_BOTTOM=28`加安全区（增大上移）、`SHARE_CALENDAR_MAX_HEIGHT=88%`（增大更高）、`SHARE_CALENDAR_CELL_HEIGHT=37` / `SHARE_CALENDAR_CELL_GAP=3`（增大单元高度/间距）控制。

作品页的分享日历入口高由 `pages/RecordingLibraryPage.ets` 的 `CALENDAR_ENTRY_HEIGHT=42` 控制（增大更高），宽度受 `LIBRARY_SIDE_INSET=20` 限制；非空时与分享按钮间距为内部 `Column.space=10`，空态与返回按钮间距为外部 `Column.space=16`。

舞台停止按钮高46vp，首选 `RECORD_STOP_BOTTOM=24`加底部安全区；面板展开时另叠加 MainPage 的 `RECORD_STOP_PANEL_CLEARANCE=140`（普通面板）或 `RECORD_STOP_DRAWER_CLEARANCE=207`（风格抽屉），增大避让值会继续上移，因此调底部距离前应先确认面板状态。

视频分辨率由 `recording/RecordingCoordinator.ets` 的 `MAX_FRAME_WIDTH_PX=720` 控制，保持原屏幕比例；增大提高成片尺寸与编码负载，减小降低负载，不移动行进场景。

## 回归命令

```sh
/Applications/DevEco-Studio.app/Contents/tools/node/bin/node scripts/tests/run-sync-regressions.cjs
```

统一回归共25项，包含原同步/真实PCM基线和新录制生命周期、页面业务状态、分享存储与本地奖励测试。构建使用 DevEco 的 `hvigorw --mode module -p product=default assembleHap --no-daemon`。模拟回归和编译不能代替耳机声学、系统录屏成片与真机页面的验收。

独立原生混音数学测试：`clang++ -std=c++17 -Wall -Wextra scripts/tests/recording-audio-math.cpp -o /private/tmp/onebeat-recording-audio-math`，然后执行产物；检查应用全16位范围不变、MIC双频0/1/2增益、末端饱和及正负时间戳映射。它直接调用生产混音数学函数，不能代替设备编解码链路验收。

接口单位参考：[OpenHarmony 原始采集回调](https://github.com/openharmony/docs/blob/master/en/application-dev/reference/apis-media-kit/capi-native-avscreen-capture-base-h.md#oh_avscreencapture_onbufferavailable) 的时间戳为纳秒。虽然[通用编码帧描述](https://github.com/openharmony/docs/blob/master/en/application-dev/reference/apis-avcodec-kit/capi-core-oh-avcodecbufferattr.md) 将 PTS 标为微秒，[Surface 编码实现](https://gitee.com/openharmony/multimedia_av_codec/blob/master/services/engine/codec/video/hcodec/hencoder.cpp) 会原样传递 Surface 时间戳；不能把该路径的纳秒值直接写入微秒封装器。

2026-10-18 真机故障已复现到文件时间元数据：约3秒的录制有176帧，旧视频却被写成3075.820833秒。修复在首个实际视频帧以单调时钟窗口唯一识别纳秒/微秒单位，锁定该次采集的单位，并在每帧入封装器之前转成微秒；时长及两条音轨偏移使用同一个真实视频首帧原点。回调到达时间只用于判别单位，不作为声画对齐锚点。未知原点、歧义单位或回退时间戳仍拒绝，不靠放宽阈值或各轨归零绕过。该故障与原节奏 renderer、输出补偿和多人时钟无关。

修复前的失败作品只有已归零的视频和无头PCM，没有持久化原始绝对时间映射；虽然文件仍被保留，不能据此保证事后重建两条音轨的首帧偏移。新版在合成之前保存带版本和同步校验结果的采集恢复元数据，支持启动后继续处理。单位归一化回归与构建通过仍不等于硬件链路相位已通过声学验收。

同日音质修复：AVScreenCapture 已按顺序交付连续 S16 PCM，块级硬件时间戳只保留首帧用于跨轨对齐，不再按每次回调抖动插零、裁样本或主动结束录制；真机 AudioCapturer 的硬件时间戳可能按较粗批次推进，后续跳变仅作观测。真正的缓冲格式错误、队列过载和文件写入失败仍会结束采集。内置扬声器场景不再固定减去一整份内音，也不再在每个 1024 帧 AAC 输入块重置延迟；导出会在高能量窗口估计声学延迟、相关度和实际泄漏系数，低相关时不做破坏性相减，并按绝对帧读取跨块参考。MIC 在内录轨出现前保持原声，不因消泄漏而整段静音。纯 C++ 回归覆盖时间戳抖动、延迟/系数估计、无相关信号拒绝、257/1024/4096 帧分块不变性及大于单块的 1536 帧延迟；源码契约另锁定回调容量逐字节追加。最终仍需用外放真机分别验收纯内音、纯人声及两者同时存在的成片。
