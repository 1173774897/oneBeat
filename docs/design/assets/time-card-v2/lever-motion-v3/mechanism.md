# 扳手机构重绘：固定轴座与独立活动杆

2026-11-02。旧 `lever.png` 将青绿握柄、银杆、大黄铜圆柱与银色螺钉画在同一张图片中；整张图随握柄转动，黄铜外壳缺少固定在机身上的支承关系。现将活动件与固定件拆开，并对齐机身已有的右侧轴孔。

## 结构与运动

- [lever-crank.png](/Users/lizhe/work/oneBeat/entry/src/main/resources/rawfile/calibration/time-card-v2/lever-crank.png)：青绿握柄、细银杆、根部圆孔耳板，整件围绕孔心转动。
- [lever-bearing.png](/Users/lizhe/work/oneBeat/entry/src/main/resources/rawfile/calibration/time-card-v2/lever-bearing.png)：紧接蓝色机壳的钢制固定轴座，两颗安装螺钉与中央银色轴盖；位于活动杆前方，遮住耳板连接处，保持静止。

静止角度0°，轻敲后向左下压至-32°，再回弹；不是向下平移整个手柄。共同场景轴为机身实际孔心约(1159,669)。绘图后重新测量源图孔/银盖轮廓中心，活动杆为(700.1,1063)，固定座为(680.5,640.3)，没有沿用生成提示里的预期坐标。

握把检查点(610,300)在场景内：静止(1100.435,173.05)，半压(966.001,208.405)，压到底(846.520,279.445)，走连续圆弧。360vp场景下总计左移约73vp、下移约31vp，轴心不动。冲头同时沿原竖直行程压下，不随侧面固定轴座旋转或横移。

原60ms下压、90ms后开始回位、80ms回程、12设计像素冲针行程及32次采样流程均保留。采样先于动画，动作队列仍独立于音频和采样时钟。

## 接入与位置调整

源码：[TimeCardCalibrationPage.ets](/Users/lizhe/work/oneBeat/entry/src/main/ets/pages/TimeCardCalibrationPage.ets:72)。所有坐标按1254设计画布，经`machineScale * q()`同步换算。原`lever.png`与机身PNG保留，未手工修改位图。

| 首选参数 | 当前值 | 增大/减小的效果与约束 |
| --- | --- | --- |
| `LEVER_AXIS_X` / `LEVER_AXIS_Y` | 1159 / 669 | 增大分别将活动杆和固定座共同右移/下移；需继续对准机身右侧轴孔，勿分开挪两个图层 |
| `LEVER_SCALE` | .65 | 增大使握杆以共同轴为中心放大；减小缩短握杆，注意上端及-32°扫过范围 |
| `LEVER_BEARING_SCALE` | .2 | 增大使固定座以共同轴为中心放大；减小更紧凑，需仍覆盖活动耳板与原轴孔 |
| `LEVER_PIVOT_X` / `LEVER_PIVOT_Y` | 700.1 / 1063 | 这是活动源图的实测前孔圈中心，不是位置调节量；改错会绕错中心 |
| `LEVER_BEARING_PIVOT_X` / `LEVER_BEARING_PIVOT_Y` | 680.5 / 640.3 | 固定源图的银盖中心；改变会使盖帽相对共同轴反向偏移，应该保持与素材一致 |
| `LEVER_PRESS_ANGLE` | -32° | 更负向左下压得更深；接近0减小行程，仍需与原冲头动画同步 |
| 整机 `frameY` / `machineScale` | 初始0 / 1 | 增大分别使整机下移/放大；结果退卡时两个新图层会随整机一起移动、缩小及淡出 |

层级为前盖5、活动杆6、固定座7；取出的纸从7提高为8，确保高于全部机械层。倒数仍为40。固定座无旋转，也不依赖`carriageColumn`或`ramDrop`。

## 生成与验证

两张均为内置 imagegen 生成/编辑的1254×1254 RGBA透明PNG，原始输出直接复制接入。完整提示词见[prompts.json](prompts.json)，素材来源和SHA见[assets.json](assets.json)。使用旧扳手与蓝色后机身作参考，保留青绿、银灰和蓝色的原有漫画材质。

[三态组合图](motion-review.png)展示静止、半压、压到底；[motion-qa.json](motion-qa.json)验证浏览器实际矩阵：三态两个轴心偏差均小于.001设计像素、固定座矩阵完全不变、握柄向左下运动，取卡纸高于固定座。更新后的`asset-preview.html`可点击敲击、退卡和重试，使用同一套素材与位置参数。

`time-card-calibration.cjs`通过，保留真实32次跟拍、样本先提交、孔位与结果、保存和异步生命周期保护。DevEco `product=default assembleHap`构建成功（8.639秒），新增图层、资源及ArkUI代码通过编译，`git diff --check`通过。尚未安装到设备验证；浏览器矩阵与预览不能代替真机显示。
