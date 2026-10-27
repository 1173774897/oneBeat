# 鼓机页面按设计稿对齐（2026-10-21）

基于用户提供的真机截图与方案 A 细节稿调整，只改视觉结构与组件呈现。

## 已调整

- 导航直接融入纸色页面，黑色标题、PRO 标签常驻顶部；移除整页的黑色外框、圆角和阴影。保存入口移到编排标题行的新建右侧。
- 拍号/BPM 直接排在导航下方并常驻，仅保留字段框和下方细分隔线，不再包成顶部卡片。
- 正文 Scroll 明确 align(Alignment.TopStart)，单段落时也从参数下方开始排列，避免短内容在剩余视口中垂直居中。
- 拍号箭头靠右；BPM 改为正常体数字并加数值框，不再裸露在两侧加减按钮之间。
- 移除设计稿没有的“每分钟…”说明及其分隔留白。
- “编排”改为更醒目的斜体标题，补“风格跟着段落走”和 info 说明入口。
- 段落左上使用随风格着色的切角标题签，标题与卡片边缘连接；折叠态补小节数。
- 折叠态小节数放在风格左侧，风格按钮统一84vp宽并由右侧删除区定位，展开/折叠及不同风格都保持同一列。
- 四行加入细分隔线，缩小字段和图标比例；重复次数有独立数值格。
- 频率字段与节奏型、加花字段使用同一列宽，不再只有半截。
- 段落、新增段落、整曲试听、应用和保存卡片使用实体黑色偏移背板。
- “我的编排”作为普通页面分区，去掉包围整个分区的圆角框，内部方格卡片仍可横向滑动。
- 新增段落跟随最后一个段落；整曲试听、应用到队伍独立固定在底部，正文视口自动让出其高度，末项可完整滚入视口。
- 段落标题行34vp、表单行40vp、字段30vp，分块间距12vp，首屏增加可读留白。
- 节奏型、加花与频率气泡优先对齐触发字段左边缘、跟随实际字段宽度，最小180vp；风格面板从触发按钮右边缘向左展开，首选320vp。
- 风格色块在面板宽度达到300vp时用三列四行，窄屏回退两列六行；选项行高30vp、间距4vp。只有风格保留20vp标题区，其余气泡直接显示选项。
- 气泡底色与段落卡片一致，普通选项纯白、选中珊瑚红；风格继续使用各自色块。所有选项恢复900字重，选中项的文字及对勾都在Text上显式设置白色，避免依赖Button的颜色继承。
- 格子编辑页细分和就近保留按钮改为2vp实体硬阴影，试听/应用按钮为4vp，鼓点格子为1vp。格子用已知尺寸直接画背板，避免为每个格子增加尺寸测量；编辑行列尺寸、定位与光标计算不变。
- 拍号与BPM允许编辑本地草稿，队员编辑不会发布队伍BPM；队长的速度发布仍沿用原会话流程。BPM加减按页面当前值累加，避免快速点击丢增量。
- 重复小节数不再向@Builder传入冻结的普通数字，在Text观察回调内直接读取当前段落，1/16边界按钮明确禁用。
- 段落渲染键使用播放身份和位置，移动后的卡片不复用旧索引闭包；退场渲染读取允许缺项，过期控件操作直接返回。段落卡片面层启用clipContent，折叠标题签被裁进8vp圆角中，黑色背板仍可伸出。
- 我的编排横向Scroll显式TopStart，首张卡片左侧padding=1vp。载入后标题行以14号字显示名称（与“编排”间距5vp，超长省略）；同一已载入/已保存ID再次保存直接覆盖，删除该记录后回到命名保存流程。
- 编排标题行右侧常驻“＋ 新建 / 保存”，共用紫色底、6vp圆角和2vp硬阴影；风格数/段落数和玩法提示放到下一行。有名称时标题显示“编排 · 名称”，未命名时不显示分隔点。新建后名称显示“新编排”，取消原保存ID关联，首次保存需命名。
- 用当前可序列化编排与进入/载入/保存后的基线比较判断修改，撤销回原内容不再提示。BPM不纳入脏标记，因为本机库没有存BPM且新建会保留当前速度。
- 有修改时弹“先保存当前编排吗？”，支持保存并新建、不保存直接新建和×取消。命名取消、返回改名、存储失败均保留当前草稿；只在成功保存后执行新建。
- 新建停止本地试听、清理段落上下文与编辑状态、回到滚动顶部，生成一个默认段落A并保留当前拍号/BPM；不写队伍编排或调用队伍配置更新。
- 命名输入框默认留空，仅展示提示文字；由DrumPaper提供2vp硬阴影和错误边框，TextInput本体透明、无描边。
- 命名弹窗中的取消/保存按钮同样使用DrumPaper的2vp硬阴影，维持原先1:1.4宽度比和42vp高度。

## 为什么改阴影实现

当前真机截图没有呈现 radius=0 的原生 shadow。新增组件 DrumPaper 用随内容尺寸测量的黑色 Rect 背板实现硬阴影，不依赖阴影模糊算法。尺寸变化时更新测量，滚动时不逐帧更新尺寸或开定时器。

位置/大小都由代码绘制，无新增位图素材。下拉仍在主 Scroll 的内容坐标中，滚动与关闭逻辑保持；向上展开时按实际滚动视口顶部判断，避免进入常驻导航区域。

## 后续调节入口

首选修改 /Users/lizhe/work/oneBeat/entry/src/main/ets/pages/DrumMachinePage.ets 顶部常量：

| 参数 | 当前值 | 增减效果 |
| --- | --- | --- |
| DRUM_HEADER_HEIGHT | 48vp | 增大常驻导航高度，下方参数与滚动区域起点下移 |
| DRUM_SETTINGS_HEIGHT | 42vp | 增大拍号/BPM条高度，后续内容下移；内部控件26vp，不能缩得低于控件 |
| DRUM_PAGE_SIDE_INSET | 16vp | 增大使导航与正文同时左右内缩；也限制气泡最大可用宽度 |
| DRUM_BODY_INSET | 0vp | 增大使编排区额外内缩；首选修改外层16vp以保持导航和正文对齐 |
| DRUM_CONTENT_TOP_INSET | 12vp | 增大使编排标题与正文下移，离参数栏更远 |
| DRUM_CONTENT_BOTTOM_INSET | 20vp | 增大使滚动到底时末项离底部操作区更远，不增加首屏顶部空白 |
| DRUM_FOOTER_INSET | 12vp | 增大上下留白，底部操作区变高、按钮向上移；底部另加系统安全区 |
| DRUM_ACTION_HEIGHT | 44vp | 增大底部试听/应用按钮高度，正文可用高度减少 |
| DRUM_ADD_SECTION_HEIGHT | 36vp | 增大新增段落按钮高度，后续我的编排区域下移 |
| DRUM_BLOCK_GAP | 12vp | 增大拉开段落/按钮/保存区之间距离 |
| DRUM_ARRANGEMENT_TITLE_HEIGHT | 32vp | 增大标题行高度，下一行信息与段落卡片下移 |
| DRUM_ARRANGEMENT_META_HEIGHT | 18vp | 增大统计信息行高度，下方卡片下移 |
| DRUM_ARRANGEMENT_HEADING_GAP | 4vp | 增大标题与统计信息之间的距离 |
| DRUM_ARRANGEMENT_ACTION_WIDTH | 74vp | 两个按钮共用；增大使操作区向左扩张，节奏名可用宽度变小 |
| DRUM_ARRANGEMENT_ACTION_HEIGHT | 28vp | 两个按钮共用；增大按钮高度，标题行32vp需同时容纳边框和2vp阴影 |
| DRUM_ARRANGEMENT_ACTION_GAP | 8vp | 增大使新建按钮向左移动、离保存更远；保存仍靠右 |
| DRUM_NEW_PROGRAM_DIALOG_MAX_WIDTH | 360vp | 次级宽度上限；首选调整弹窗外层width=88%，增大任一数值会在另一约束允许时变宽 |
| DRUM_NEW_PROGRAM_DIALOG_PADDING | 18vp | 增大使弹窗内部内容向内缩、弹窗变高 |
| DRUM_NEW_PROGRAM_DIALOG_BUTTON_HEIGHT | 42vp | 增大两个处理按钮的高度，弹窗总高增加 |
| DRUM_SECTION_TAB_WIDTH | 96vp | 增大彩色切角标题签向右延长；会压缩右侧风格与删除区域 |
| DRUM_SECTION_HEADER_HEIGHT | 34vp | 增大段落标题行与切角色签高度 |
| DRUM_SECTION_STYLE_WIDTH | 84vp | 增大使风格按钮向左变宽，右边界由删除区固定；同时压缩左侧标题/小节数空间 |
| DRUM_FORM_ROW_HEIGHT | 40vp | 增大四行行高，段落卡片变高 |
| DRUM_FIELD_HEIGHT | 30vp | 增大节奏型/加花/频率框高度；需保持不超过行高 |
| DRUM_FIELD_LABEL_WIDTH | 42vp | 增大使字段起点右移，字段变窄 |
| DRUM_PHRASE_ICON_SIZE | 18vp | 增大播放/编辑图标尺寸，点击区域另由32vp控制 |
| DRUM_PHRASE_ACTION_WIDTH | 32vp | 增大图标点击区域宽度，并压缩字段 |
| DRUM_SAVED_CARD_SIZE | 112vp | 增大保存卡片宽高，一屏可见数量减少 |
| DRUM_STYLE_POPOVER_WIDTH | 320vp | 增大风格面板宽度，优先向左延伸；受页面16vp边距和3vp阴影约束 |
| DRUM_STYLE_POPOVER_THREE_COLUMN_MIN | 300vp | 增大使面板更晚切到三列，窄屏更容易使用两列 |
| DRUM_POPOVER_MIN_WIDTH | 180vp | 增大使窄字段的普通下拉变宽；首选宽度仍跟随字段实测值 |
| DRUM_POPOVER_GAP | 2vp | 增大使气泡远离触发字段，上方展开时上移、下方展开时下移 |
| DRUM_POPOVER_TAIL | 6vp | 增大气泡尖角的高和半宽，主体离字段更远 |
| DRUM_POPOVER_PADDING | 8vp | 增大使标题和选项内缩，同时气泡变高 |
| DRUM_POPOVER_HEADER_HEIGHT | 20vp | 仅风格气泡使用；增大标题区高度，选项下移且气泡变高 |
| DRUM_POPOVER_HEADER_GAP | 8vp | 仅风格气泡使用；增大标题与选项间距，气泡变高 |
| DRUM_POPOVER_OPTION_GAP | 4vp | 增大选项纵向间距与风格列间距；会增加气泡高度、缩窄风格色块 |
| DRUM_POPOVER_ROW_HEIGHT | 30vp | 增大选项高度，面板总高随行数增加 |
| DRUM_POPOVER_SHADOW_OFFSET | 3vp | 增大使气泡背板向右下延伸，并减少右侧可用宽度 |

顶部导航与参数容器在主 build 中 padding.top = topSafeInset + 8vp，增大8使整个顶部区域下移；padding.bottom = 4vp，增大会加大参数与正文之间的间隔。“我的编排”padding.top = 12vp，增大使标题离上方分隔线更远。新建/保存共用arrangementHeaderAction，按钮由DRUM_ARRANGEMENT_ACTION_WIDTH/HEIGHT统一控制。

arrangementHeader的标题Row.space=5vp，增大使编排、分隔点、名称之间更远，名称可用宽度随之缩小。sectionCard标题行padding.right=5vp，增大会让右侧风格/删除区整体左移；行内space=6vp，增大则拉开相邻控件。折叠小节数仅占用风格左边的可伸缩空间。

字体直接在 pageHeader / sectionCard / arrangementHeader 中调整：标题26、段落标题20、编排标题24。增大字体会占用更多可用宽高，尤其长风格名与小屏幕时需要留意。

新建提示弹窗在newProgramDialogOverlay中：外层width=88%（上限360vp），内容Column.space=14vp，增大间距会拉开内部区块并增高弹窗。标题与×之间Row.space=8vp，增大使标题可用宽度减少。

命名输入框在saveDialogOverlay中：TextInput.height=44vp，padding.left/right=10vp，增大高度会拉高弹窗，增大水平留白使文字内缩。DrumPaper.offsetX/offsetY=2/2，增大分别使黑色阴影向右/下延伸。

同一函数的按钮Row.space=9vp，宽度权重为1/1.4；增大间距会压缩按钮，调整权重会改变两者宽度分配。按钮height=42vp，DrumPaper.offsetX/offsetY=2/2，增大高度会拉高弹窗，增大偏移会向右/下加厚阴影。

硬阴影入口：/Users/lizhe/work/oneBeat/entry/src/main/ets/components/DrumPaper.ets：
- offsetX=4、offsetY=4：增大分别向右、向下偏移。
- 字段与小控件调用时覆盖为1、1，以保持设计稿较薄的控件底边。
- cornerRadius默认8；内层控件传6。增大更圆，减小更方。
- paperLineWidth默认1.5；小字段传1。增大边框更粗，可能压缩内部空间。
- clipContent默认false，段落卡片传true：只裁切面层，使标题色块遵守cornerRadius=8；增加圆角会裁掉更大的角部区域，不裁黑色背板。
- 格子编辑页的三个偏移入口在 DrumMachinePage.ets：DRUM_EDITOR_CONTROL_SHADOW_OFFSET=2、DRUM_EDITOR_ACTION_SHADOW_OFFSET=4、DRUM_EDITOR_CELL_SHADOW_OFFSET=1。增大均使阴影向右下延伸；格子偏移应小于现有4vp列间隙，避免遮挡相邻格子。

## 验证

本轮ArkTS/HAP构建及drum-editor-preview、drum-new-arrangement回归通过；此前drum-multi-style-page亦通过。本轮只调整操作按钮位置/样式、标题分隔点和折叠态排版；新建、命名、保存及试听流程保持。没有修改音频时间线、编排解析或组队同步代码。更新已连接的 Pura X 与 Pura80 Pro，依照用户偏好由用户自行进行真机交互验收。

