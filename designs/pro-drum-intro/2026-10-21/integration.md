# 月卡方案中的定制鼓机介绍

在 `StorePage.ets / purchaseDialog()` 内，将权益介绍两处“PRO 定制鼓机”做成带下划线的珊瑚色文字入口。点击后在方案之上打开图片预览，关闭后保留原方案及购买状态。系统返回先关闭图片，再处理原方案返回。进行中的购买和恢复购买页面不打开预览。

## 图片

- 运行素材：`entry/src/main/resources/rawfile/comic/store/pro-drum-intro.png`
- 来源：`designs/pro-drum-intro/2026-10-20/pro-drum-comic-v4.png`
- 两文件 SHA-256 相同，未重新绘制或压缩。保留用户确认的小卡片文案“反拍开镲”“重音滾奏”。

## 位置与尺寸调整

首选调整 `entry/src/main/ets/pages/StorePage.ets` 顶部的常量：

- `DRUM_INTRO_SIDE_INSET = 12vp`：左右留白；增大让图片变窄，同时右上角叉叉左移；减小则相反。
- `DRUM_INTRO_CLOSE_TOP = 8vp`：叉叉相对顶部安全区的距离；增大将叉叉和图片一起下移，减小上移。
- `DRUM_INTRO_CONTENT_GAP = 10vp`：图片与叉叉行之间的距离；增大仅使图片下移。
- `DRUM_INTRO_CLOSE_SIZE = 44vp`：叉叉按钮点击区域大小，图标字号 29；增大按钮及图片顶部预留空间随之增大。
- `DRUM_INTRO_IMAGE_RATIO = 2 / 3`：图片按原始 1024×1536 比例，`width('100%')`、`ImageFit.Contain`；增大比例会让固定宽度下的显示区域变矮，减小变高，因此应随图片原始比例设置。
- 图片的实际顶部：顶部安全区 + 8 + 44 + 10vp；底部保留底部安全区 + 12vp。短屏可在竖向 Scroll 内滑动查看，关闭按钮保持固定。
- 弹层 `zIndex = 110`，高于方案的 100。使用默认触摸命中规则，允许叉叉及滚动子节点接收事件。

## 验证

- Hvigor assembleHap：通过。
- `scripts/tests/store-user-feedback.cjs`：通过，新增验证嵌套图片预览的返回优先级、关闭保留方案、购买期间阻止打开，以及预览不会触发账号、支付或商城接口。
- Pura 80 Pro 已安装最终版本：两处文字入口均可打开；右上角叉叉关闭有效；系统返回先关闭图，再关闭方案；支持重复打开。未进行购买或保存操作。
- 同目录保留方案页、图片预览页真机截图。
