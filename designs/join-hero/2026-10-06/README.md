# 加入队伍头图背景三版

内置 image_gen 生成。三版均为完整不透明横幅背景，避免现有资源右半侧透明缺口造成的断裂感。候选设计尚未接入页面。

- v1-invitation-ticket.png：邀请票券。完整奶油白票券与右侧淡紫票根自然连接。
- v2-rhythm-impact.png：节拍放射。右侧粗墨线放射色块与动势线衬托云行者。
- v3-comic-paper-collage.png：美漫拼贴。右侧硬边纸片和黑色硬阴影，左侧充分留白。

## 生成提示词

共同要求：OneBeat 加入队伍头图背景，约 2.5:1 横幅，仅画背景，不含人物、文字、二维码、UI 或水印。左侧 60% 为浅奶油白安静文案区，右侧 35% 用于衬托现有云行者。完整连续的不透明画布，不得出现透明缺口、黑色空洞或独立悬浮角片。明确美漫/波普漫画印刷风格，粗黑墨线（2000像素宽约6–10像素）、硬边平涂色块、明显Ben-Day网点、短动势线和错位黑色硬阴影；禁止水彩、纤细粉彩插画、柔化渐变。奶油白 #FFF9EE、青绿 #29B5AE、淡紫 #C5B7EB、浅蓝 #A9C9F2、珊瑚橙 #FF7056、墨黑 #171B1F。无写实或 3D，无柔和投影，无外边框。适合 142 高的手机头图。

1. INVITATION TICKET：完整奶油白美漫入场票横贯全幅，右侧三分之一为淡紫票根，70%横向位置为粗黑穿孔虚线，右上珊瑚橙胶带、右下青绿Ben-Day网点角片及少量动势短线。左侧干净。
2. RHYTHM IMPACT：以横向83%、纵向55%为中心的非对称美漫放射背景，限制在右侧40%区域。珊瑚橙粗射线与浅蓝、淡紫楔形交替，粗黑动势线及明确Ben-Day网点，下沿细青绿线。左侧60%平静奶油白。
3. COMIC PAPER COLLAGE：右侧三分之一重叠浅蓝与淡紫硬边纸片、粗黑轮廓和约5像素错位黑色硬阴影，小珊瑚橙斜胶带，右下青绿Ben-Day三角网点。左侧65%完整干净奶油白，无接缝或缺口。

## 当前运行时入口

资源：entry/src/main/resources/rawfile/comic/decor/join_invitation_paper.png。
代码：entry/src/main/ets/pages/MemberJoinPage.ets。背景 Image 宽高 100%、ImageFit.Cover；JOIN_HERO_HEIGHT=142 控制容器高度。云行者在右侧，margin right=3、bottom=-8，rotate=5；左侧文案 padding left=14、right=140。以上当前参数未修改。
