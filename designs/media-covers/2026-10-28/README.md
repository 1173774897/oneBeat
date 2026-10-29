# 后台媒体卡片封面概念

日期：2026-10-28。三个独立方形方案。用户已选择 02「节拍唱片」，原图复制到 `entry/src/main/resources/rawfile/comic/brand/media_session_cover.png`，并通过 `SessionBackgroundKeeper.ets` 的 `setAVMetadata.mediaImage` 接入媒体卡片。

| 方案 | 图片 | 设计方向 |
|---|---|---|
| 01 双人同频 | [01-duo-in-sync.png](01-duo-in-sync.png) | 双人角色与品牌字标组成贴纸，米白底、橙绿笔触，与应用图标保持识别关联。 |
| 02 节拍唱片 | [02-pulse-record.png](02-pulse-record.png) | 深色背景、唱片圆形与大字标，图形较少，适合通知栏缩略图。 |
| 03 日落行进 | [03-sunset-walk.png](03-sunset-walk.png) | 双人沿海边同行，日落与海水延续行进场景的氛围。 |

三版使用现有 `同拍 / ONEBEAT` 字标，保留珊瑚橙、青绿与黑色粗描边。画面不包含固定 BPM，供不同节拍共用。原始生成图片保持完整，适配系统媒体卡片时再按目标规格导出。

使用内置 `image_gen` 生成；完整提示词、参考素材路径与方案名称见 [generation-prompts.json](generation-prompts.json)。生成参考为项目的 `onebeat_wordmark.png` 和 `app_icon.png`。以上图片为概念稿，不作为品牌字标的源文件替换。
