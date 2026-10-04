# 漫画风界面更新与调整入口

## 当前保留与回退范围（2026-10-02）

按最新反馈，上一轮新增的布局、控件尺寸、间距、宽屏限制与统一圆角已回退，各页恢复原有局部圆角，不再使用统一的 14/9 vp 圆角。

- 首页恢复原插图、爆炸背景和布局，只保留白色“单人练习”按钮。
- 多人练习恢复原布局和爆炸背景，保留两个击掌人物；创建/加入入口的新动作素材继续保留。
- 队员加入页完整恢复原界面，仍使用原云行者图片。
- 大厅角色大图恢复原人物和 character_panel 背景；可用角色排序、权益状态、多人/锁定标识与 PRO 锁链不回退。
- 小铺恢复原月卡票券区域、连体 tabs、商品网格和场景卡片布局，角色商品仍使用新动作素材；兑换入口、价格/权益状态和“我的”中的恢复购买功能保留。
- 条纹步客手拿票券的插图移到口令兑换页。鼓机编辑器恢复整小节自适应格子，非主拍鼓点保留浅紫。
- 上述完整恢复的页面/区域使用原阴影，其余未要求回退的颜色、阴影和功能继续保留。原头像、行进动画、支付、组队与节拍播放业务逻辑未改动。

## 公共样式

[ComicKit.ets](/Users/lizhe/work/oneBeat/entry/src/main/ets/components/ComicKit.ets) 中保留 WHITE=#FFFDF8、BLUE=#A9C9F2、CARD_SHADOW（radius 0 / X 3 / Y 4 / INK）、CONTROL_SHADOW（radius 0 / X 2 / Y 2 / INK）。

增大阴影 X/Y 会使阴影更向右/下；radius 增大会柔化阴影。共享 ComicButton 圆角恢复为 7 vp、高度 56 vp、左右 padding 16/14 vp。首页通过 inkShadow 单独使用 HOME_BUTTON_SHADOW（radius 0 / X 2 / Y 3 / INK），其余页面仍用共享阴影。圆角按各控件原值设置，修改时直接调整该控件的 borderRadius，而不是重新引入全局圆角。

## 布局与插图调整入口

优先调整下表主控制项，再调整父容器。数值单位为 vp；百分比相对于父容器。ComicCharacter 使用 Contain，增大宽/高会扩大图片可容纳范围，但另一维和父容器仍限制实际尺寸。增加 padding 会压缩可用空间。

| 精确源文件 / 区域 | 主控制项与当前值 | 调整效果与次级约束 |
| --- | --- | --- |
| [Index.ets](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/Index.ets) 首页 | 角色 width 53%、height 240、rotate -8°/+8°；Row space -30；头图 height 245 | 增大宽/高放大角色；space 增大拉开角色。头图 clip(true) 会裁切越界部分，页左右 padding 20、Column space 16 |
| 首页字标 / 标语 | 字标 190×100；标语 BottomEnd 对齐、padding 5 | 增大字标尺寸会减少右侧标语可用空间。标语恢复原右下角位置，无新增 margin |
| [TeamPage.ets](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/TeamPage.ets) 击掌头图 | 角色 width 52%、height 190、rotate -7°/+7°；Row space -28；头图 height 190 | 增大宽/高放大角色，增大 space 拉开。Bottom 对齐、外层 clip(true)；背景 width/height 100%、Fill 随头图铺满 |
| 多人练习创建 / 加入入口 | 角色 94×94，margin right 6、bottom 7；文案 right padding 106；卡片 height 168/176 | 增大 right/bottom 将插图向左/上移；增大宽/高放大。卡片裁切限制越界，文案 padding 增大减少文字宽度；页左右 padding 18 |
| [MemberJoinPage.ets](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/MemberJoinPage.ets) 加入页 | 云行者 142×142、margin right 3 / bottom -8、rotate 5°；头图 height 142 | right 增大向左移，bottom 增大向上移；宽/高增大放大。文案 right padding 140、left 14，头图裁切；页左右 padding 20 |
| [LeaderLobbyPage.ets](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/LeaderLobbyPage.ets) 角色大图 | ComicCharacter width 82%、height 248；外层 height 250；标语 position x 72%、y 12 | 增大宽/高放大人物，标语 x/y 增大向右/下移。外层 clip(true) 限制越界，页左右 padding 18 |
| 大厅成员 / 场景 / 二维码 | 成员行 top/bottom padding 2；场景卡片 154×148、滚动区 height 151、行 bottom padding 2；二维码 150×150 | 增大 padding 内缩内容；放大卡片需同步放大滚动区。二维码恢复原尺寸与结构，无新增 168 外框 |
| [StorePage.ets](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/StorePage.ets) 月卡 | 云行者 72×118、条纹步客 84×126；Row space -22、width 38%；文案 width 62%；横幅 height 184 | 增大角色宽/高放大，space 增大拉开。两栏宽度需合计 100%；外层 padding left 10 / right 4 / top 14 / bottom 12，文案额外 left 13 |
| 小铺商品 / tabs | 角色 width/height 96%、图片区 height 150、信息区 height 84、整卡 234；两列 gap 10、行高 244；连体 tabs height 42、无间隔 | 增大图片百分比放大，受图片区裁切限制；改整卡高度需同步改网格行高。gap 增大拉开卡片、减小列宽；页左右 padding 16 |
| 小铺场景 / 购买框 | 场景卡片 height 240=图片 178+底栏 62；购买框 width 88%、padding 17 | 增大图片高度需同步放大整卡；对话框宽度百分比增大会变宽，padding 增大压缩内部空间。场景图层位置未改动 |
| 口令兑换页票券插图 | mismatch-ticket：width 38%、height 160；介绍 Row space 12，文字 layoutWeight 1；页左右 padding 18 | 增大 height 放大人物；增大 width/space 会压缩文字。标题 26、最小 20、最多两行。图在文字右侧居中，不遮挡输入框 |
| [DrumMachinePage.ets](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/DrumMachinePage.ets) 编辑格子 | 格子 height 25、layoutWeight 1、Row space 1、轨道行 height 28；名称 width 44、名称/格子间隔 5 | 增大格子高度需同步增大行高；增大格子间距减少每格宽度。全部格子随可用宽度均分，不横滑 |
| 鼓机编辑器 / 保存弹窗 | 编辑器 width 96%、padding 12；内部 padding left/right 8、top 9、bottom 10；保存/覆盖框 width 88% | 增大 width 放宽弹窗，padding 增大缩小格子空间；标题与按钮仍受整行宽度限制，无新增 maxWidth |
| [MainPage.ets](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/MainPage.ets) 行进面板 | BPM 字号 58、BPM 标签 20、节拍圆点 19、space 7、拍号字号 27 | 增大尺寸/间距占用更多行宽，已恢复原布局；顶栏左右 padding 14、top 8+安全区、bottom 8 |
| 行进底栏 / 退出框 | 底栏左右 padding 14、top 8、bottom 12+安全区；退出框 width 86%、padding 17 | padding 增大内缩内容；top 增大下移。对话框 width 增大更宽，无新增 maxWidth |

## 图片资源与运行时入口

资源目录为 [comic/poses](/Users/lizhe/work/oneBeat/entry/src/main/resources/rawfile/comic/poses)，通过 ComicCharacter.pose 选择同名 PNG。未设置 pose 时使用 comic/characters；portrait=true 时仍用 comic/avatars。

| 资源路径 | 当前使用位置 / 尺寸入口 |
| --- | --- |
| [entry_burst.png](/Users/lizhe/work/oneBeat/entry/src/main/resources/rawfile/comic/decor/entry_burst.png) | 首页、多人练习、加入页背景；各自头图 Image width/height 100%、Fill |
| [character_panel.png](/Users/lizhe/work/oneBeat/entry/src/main/resources/rawfile/comic/decor/character_panel.png) | 大厅大图背景；Image width/height 100%、Fill，外层 height 250 |
| [subscription_ticket.png](/Users/lizhe/work/oneBeat/entry/src/main/resources/rawfile/comic/decor/subscription_ticket.png) | 月卡原背景；Image width/height 100%、Fill，外层 height 184 |
| [characters](/Users/lizhe/work/oneBeat/entry/src/main/resources/rawfile/comic/characters) | 首页 teapot/cloud、加入页 cloud、月卡 cloud/mismatch、大厅当前角色；尺寸见上表 |
| [teapot.png](/Users/lizhe/work/oneBeat/entry/src/main/resources/rawfile/comic/poses/teapot.png)、[cloud.png](/Users/lizhe/work/oneBeat/entry/src/main/resources/rawfile/comic/poses/cloud.png) | 坐着演奏：小铺商品；96%×96% 的 150 高图片区 |
| [mismatch.png](/Users/lizhe/work/oneBeat/entry/src/main/resources/rawfile/comic/poses/mismatch.png)、[wave.png](/Users/lizhe/work/oneBeat/entry/src/main/resources/rawfile/comic/poses/wave.png) | 击掌：多人练习头图、小铺商品；Wave 保留最终无眼镜、无嘴版本 |
| [matchman.png](/Users/lizhe/work/oneBeat/entry/src/main/resources/rawfile/comic/poses/matchman.png) | 指挥：多人练习创建入口（94×94）、小铺商品 |
| [scooter.png](/Users/lizhe/work/oneBeat/entry/src/main/resources/rawfile/comic/poses/scooter.png)、[lilroll.png](/Users/lizhe/work/oneBeat/entry/src/main/resources/rawfile/comic/poses/lilroll.png) | 候场 / 整理装备：小铺商品 |
| [cloud-phone.png](/Users/lizhe/work/oneBeat/entry/src/main/resources/rawfile/comic/poses/cloud-phone.png) | 查看邀请：多人练习加入入口（94×94），不再用于队员加入页 |
| [mismatch-ticket.png](/Users/lizhe/work/oneBeat/entry/src/main/resources/rawfile/comic/poses/mismatch-ticket.png) | 口令兑换页，width 38%、height 160 |

生成提示词和来源保留在 [character-pose-prompts.json](/Users/lizhe/work/oneBeat/designs/character-pose-prompts.json)。Wave 以 final_identity_constraints 为准，不恢复初次生成的眼镜或嘴。未删除暂时未用的动作素材，便于后续调整使用场景。

PRO 锁定入口后续换为透明银色锁链，叠在按钮右半边，允许上下和右侧伸出；按钮本身的布局与点击校验不变。素材、当前叠放参数和最终生成提示词见 [pro-chain-silver.md](/Users/lizhe/work/oneBeat/designs/pro-chain-silver.md)。

## 验证边界

队伍大厅角色选择行的三种角标已统一为右下角黑白剪纸图标/限免票签，头像框补上独立黑色硬阴影；显示规则、素材和调整参数见 [role-avatar-badges.md](/Users/lizhe/work/oneBeat/designs/role-avatar-badges.md)。

回退验证包含布局/圆角源代码对照、关键业务方法未改动检查、ArkTS/HAP 编译及资源打包检查。真机视觉验收仍需检查不同宽度、长文字与整小节鼓点点选；编译不代表已完成真机屏幕验证。
