oneBeat sunset 六张透明屏幕模板

01.png—06.png：每张1080×1920，屏幕区域为真正透明通道，机框、阴影和场景背景保留。
master-transparent.png：6480×1920共享透明母图，保持首两张及其余页面的拼接边缘。
checkerboard-preview.jpg：仅供查看；棋盘格用于显示透明区域，不在交付PNG中。

使用时将应用屏幕截图放在对应PNG下面，再按手机角度与位置调整。

透明开口几何由上级 phone-frames.json 控制：frame.inset当前24，增大缩小开口、减小扩大开口；frame.radius当前100，屏幕圆角为radius-inset=76。机框的位置、尺寸和角度本次均未改变。
