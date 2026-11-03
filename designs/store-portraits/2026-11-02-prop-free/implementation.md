# 奇遇小铺：云行者与茶壶太太去道具立绘

使用内置 imagegen 编辑既有角色宣传图，参考实际站立和行进帧。最终两张均为1024×1536 RGBA透明PNG，直接复制生成结果，未进行手工抠图、缩放或像素重绘。

| 角色 | 最终资产 | 修正 |
| --- | --- | --- |
| 云行者 | [cloud.png](/Users/lizhe/work/oneBeat/entry/src/main/resources/rawfile/comic/store/cloud.png) | 空手站姿，去掉手鼓及凳子，保留实际角色的云头、单眼、翅膀、彩虹发夹、云腰圈和蓝色肢体 |
| 茶壶太太 | [teapot.png](/Users/lizhe/work/oneBeat/entry/src/main/resources/rawfile/comic/store/teapot.png) | 空手站姿，去掉铃鼓及凳子，按实际角色保留壶头、围裙和条纹裙、腿套及棕鞋；按追加要求补全右侧第二道卷曲烟雾 |

参考图片与完整最终提示词集见 [prompts.json](prompts.json)。第一轮生成用于去道具，第二轮补全茶壶右侧烟雾并清理透明边缘；原始生成结果均保留在工具默认生成目录，最终选择的文件和SHA-256见 [asset-report.json](asset-report.json)。

## 接入

[StorePage.ets](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/StorePage.ets:73) 的两条 `STORE_EXCLUSIVE_CHARACTERS` 配置新增 `photoAsset`，分别指向 `comic/store/cloud.png` 和 `comic/store/teapot.png`。商店“角色”和“我的”共用 `characterCard()`，因此同时使用新立绘；商品ID与动画角色键仍沿用原配置。保留了已有的“青柠滑手”名称修改。

没有改动 `comic/poses`、`comic/characters`、`avatars`、`stand` 或 `walk` 中的素材；加入页 `cloud-phone.png` 保留。`sync-assets.sh` 不会覆盖 `comic/store` 的专用图片。

## 显示尺寸与位置

首选调整点是 [StorePage.ets 的 characterCard()](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/StorePage.ets:1345)：`Image($rawfile(item.photoAsset)).width('96%').height('96%').objectFit(ImageFit.Contain)`。当前宽高均96%，增大百分比会放大，减小会缩小；保持 `Contain` 可完整显示烟雾、壶嘴及双脚。

父 `Stack` 高150vp，使用 `Alignment.Bottom` 底部居中，`clip(true)`；图片布局参数本轮未改。增大父高会扩大插画区域并改变卡片布局，需同时协调外层234vp总高及下方84vp文案区。需要单纯上下微调时应在图片层增加小幅 `translate.y`（当前未设置，即0）；增大向下，向下余量受父框裁切约束，优先调整96%的尺寸。

## 验证

- 两张均有真实透明通道，四角完全透明；半透明阈值128下的可见主体均在画布内，茶壶右侧烟雾、壶嘴、鞋子完整。
- `store-user-feedback.cjs` 通过，真实商店方法的购买、恢复、验证与权益流程不受两条图片配置影响。
- DevEco `product=default assembleHap` 构建成功，PNG资源与ArkTS接入通过打包编译。
- `git diff --check` 通过；实际站立、行进、头像和共用姿势素材均无差异。

尚未进行真机小铺显示验收。
