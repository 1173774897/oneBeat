# PRO 定制鼓机新版功能漫画

面向畅游月卡“查看方案”的新版四分格介绍图。使用内置 image_gen 生成，成图为 pro-drum-multi-style-comic.png；完整提示词与参考图清单见 prompt.json。

## 四格内容

1. 一首编排，多种风格：12 种风格、最多 8 段，A 摇滚、B 爵士、C 放克。拍号与 BPM 由整曲共用，风格跟着段落走。
2. 选节奏型，搭配加花：展开段落按节奏型、重复、加花、频率四行展示，播放和编辑使用图标；非风格气泡不带标题，白底选项、段落风格色选中项、白色文字和对勾。
3. 点格子，写你的鼓点：10 种鼓声，4 等分、3 连音、6 连音。4/4 示例选择每拍 6 连音，4 个拍组共 24 格，橙色播放游标。
4. 存好编排，一起出发：我的编排横向方卡，最多两种风格再加省略号；试听整曲、应用到队伍，行进页通过本编排／我的编排抽屉切换。

新建与保存放在“编排 · 名称”行，未沿用旧顶栏右上角保存、全局单一风格、旧“我的节奏”名称和深色标题栏。人物保留条纹步客与 Wave 原设定。

## 核对依据

- DrumMachinePage.ets：arrangementHeader、sectionCard、myPrograms、editorOverlay、programActions。
- DrumMachineCatalog.ets：12 种风格、10 个鼓声音轨、分段风格。
- DrumProgramLibrary.ets：我的编排持久化，保存与应用独立。
- MainPage.ets：本编排／我的编排抽屉。

已接入畅游月卡“查看方案”的鼓机介绍入口，运行素材为 entry/src/main/resources/rawfile/comic/store/pro-drum-intro.png，与本目录成稿逐字节相同；同步更新 StorePage.ets 中的无障碍说明。旧版原图保留在 2026-10-20 设计目录。

原图 1024×1536，沿用现有 2:3 显示比例、竖向滚动和右上角关闭交互。

后续调显示尺寸优先修改 StorePage.ets 的 DRUM_INTRO_SIDE_INSET=12vp：增大让左右留白增加、图片变窄，减小相反；固定宽度下，DRUM_INTRO_IMAGE_RATIO=2/3 增大使图片区域变矮、减小变高，应与素材比例一致。图片顶部仍由顶部安全区 + DRUM_INTRO_CLOSE_TOP=8vp + DRUM_INTRO_CLOSE_SIZE=44vp + DRUM_INTRO_CONTENT_GAP=10vp 决定，增大这些值会将图片下移。

接入验证：assembleHap 构建通过，store-user-feedback.cjs 预览/方案返回优先级等回归通过；已核对签名 HAP 内图片与新版原图 SHA-256 一致。安装到 Pura X 与 Pura80 Pro，页面视觉效果留给用户查看。
