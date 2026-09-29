# OneBeat

多人同步节拍器（HarmonyOS NEXT · ArkTS）。多人模式通过 Wi-Fi P2P 建立附近设备直连，用二维码或 BLE + 六位加入码交换临时邀请；队员校准队长单调时钟后在本地调度播放。主界面为横向卷轴「节拍走路」场景。

## 开发环境

- DevEco Studio（API 12+）
- 真机调试（Wi‑Fi P2P 与低延迟音频建议双机实测）

## 素材

```bash
./scripts/sync-assets.sh
```

默认从 `~/Downloads/onebeatprocessing` 拷贝精灵、步道与路边物体到 `entry/src/main/resources/rawfile/`。

## 功能概览

- 队长：**单人队伍**（本机直接开练，无需队员）或创建临时 Wi-Fi P2P 组、BPM/音色、开始/暂停/继续、QR/BLE 邀请
- 队员：扫码获取完整邀请，或用 6 位码通过 BLE 查找附近房间；完成 P2P 连接后通过队长 `goIpAddress:9527` 进入大厅
- 连接：不依赖云服务、公共路由器、同一 Wi-Fi 子网或队长手机热点
- 同步：多次 RTT 测时 + 中位数 offset，播放中定期轻量复校；音频始终在设备本地播放
- 主界面：步道双图循环、路边物体视差（0.9 / 1.0 / 1.1）、全员 cloud/mismatch 精灵按拍换帧

## 音频提示

外放或有线耳机效果最佳。蓝牙耳机存在额外延迟且因型号而异，应用内加入说明需勾选确认。

## 构建

在 DevEco 中打开本目录，配置签名后 Build Hap。命令行可参考同机其他 HarmonyOS 工程的 `hvigorw assembleHap`。

多人连接架构、权限边界与真机测试步骤见 [连接方案](designs/network-connection-plan.md)。

## 商店 API

商店服务端已拆分为同级独立工程 [`oneBeatBackend`](../oneBeatBackend/)，当前提供 HTTPS
测试接口与健康检查。
