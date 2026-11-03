# 方向一：原有插图与功能动作

只使用项目已有 PNG，不重画手臂或改变人物姿势。丁香底、纸白机框、青绿偏移影保持为主视觉；角色安排在实际留出的侧栏，白屏与标题区保持可用。

| 页 | 主插图 / 原动作 | 选择理由 | 母版 x / y / width |
| --- | --- | --- | --- |
| 01 | Lilroll 坐着整理轮滑鞋 | 对应准备出发，坐姿与长凳有明确支撑 | -35 / 1400 / 385 |
| 02 | 条纹步客举两张入场票 | 呼应组队邀请，位于连续双机下方的空区 | 1060 / 1360 / 340 |
| 03 | 茶壶太太打手鼓 | 音色与节奏功能，翻转后手鼓朝向手机 | 2920 / 1400 / 320，flip=true |
| 04 | 云行者敲鼓 | 呼应鼓机，鼓和手部完整位于左侧栏 | 3240 / 1370 / 340 |
| 05 | Scooter 扶滑板、竖拇指 | 呼应行进与练习，翻转后滑板靠近机框 | 5080 / 1450 / 320，flip=true |
| 06 | 云行者举手机并挥手 | 呼应作品与分享，原动作自然，不强行握住大机框 | 5400 / 1380 / 330 |

每页另放一处原有花草。花草在后层，角色在前层，前层仍由构建脚本保护全部白屏。第 3–6 页机框采用 root 确认的 740 × 1640、y=620，左右交替位置：03/05 x=80；04/06 x=260。这样角色不必被挤进 134px 的窄缝。

## 素材来源

所有文件原样复制到 `assets/original/`，源图位于项目 `entry/src/main/resources/rawfile/`：

- `lilroll-preparing.png` ← `comic/poses/lilroll.png`
- `mismatch-invitation.png` ← `comic/poses/mismatch-ticket.png`
- `teapot-tambourine.png` ← `comic/poses/teapot.png`
- `cloud-drum.png` ← `comic/poses/cloud.png`
- `scooter-skateboard.png` ← `comic/poses/scooter.png`
- `cloud-sharing.png` ← `comic/poses/cloud-phone.png`
- `plant-flowers.png` ← `vegetation/plant_06.png`
- `plant-coral.png` ← `vegetation/plant_09.png`

`direction-sign.png` 复制为备选素材，当前未放入构图。

## 位置交接

首选修改 `direction-one-art.json` 的 `images[]`。每项 `x/y` 是 6480 × 1920 母版绝对坐标，增大 x 向右、增大 y 向下；增大 width 等比放大，height 始终按原图比例计算。所有主图当前 rotation=0；rotation 增大为顺时针。`flip` 只做水平翻转，不改变肢体形状。

物件当前值：01 花草 (10,1680,180)，02 灌木 (1200,1770,160)，03 花草 (3070,1640,160)，04 花草 (3260,1640,180)，05 灌木 (5230,1640,160)，06 花草 (5420,1640,180)。括号依次为 x/y/width。

主要限制是机框白屏蒙版、各页标题区与六张画布裁切线。改变角色位置后要检查脸、道具和手部仍落在屏外，避免被屏幕保护蒙版截断；改动整页应优先协调对应机框侧栏，而非单纯继续放大角色。

03–06 的人物原图矩形保持在各自 1080px 页内，避免相邻页边缘出现另一个角色的零碎肢体。首两页仍按共同构图布置。
