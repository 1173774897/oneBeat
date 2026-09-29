# OneBeat 多人连接方案

## 1. 方案结论

OneBeat 多人模式不再使用云端房间、同一 Wi-Fi 局域网发现或队长手机热点。当前的唯一数据通道是：

```text
二维码或 BLE 获取房间邀请
              ↓
      Wi-Fi P2P 建立直连
              ↓
  goIpAddress:9527 上的 TCP 会话
              ↓
   令牌认证、时钟校准、节拍同步
```

蓝牙只用于「六位加入码找到附近房间」，不传输节拍和队伍状态。扫码时二维码已包含完整邀请，因此不强制打开蓝牙。

## 2. 权限与系统能力边界

应用申请的组队相关权限只有：

- `ohos.permission.INTERNET`：P2P 组内 TCP 通信。
- `ohos.permission.GET_WIFI_INFO`：检查 Wi-Fi/P2P 状态和读取当前 P2P 组信息。
- `ohos.permission.ACCESS_BLUETOOTH`：加入码模式的 BLE 广播、扫描和短时 GATT 交换。
- `ohos.permission.CAMERA`：用户主动扫描二维码时使用。

本方案不申请下列系统/企业级权限：

- `ohos.permission.GET_WIFI_PEERS_MAC`
- `ohos.permission.GET_WIFI_LOCAL_MAC`
- `ohos.permission.MANAGE_WIFI_CONNECTION`
- `ohos.permission.MANAGE_ENTERPRISE_WIFI_CONNECTION`

因此有下列约束：

- 应用不能自行开启 Wi-Fi，只能提示「请先打开 Wi-Fi」并跳转系统无线设置。
- 不依赖真实 MAC。队员连接时原样使用 `getP2pPeerDevices()` 返回的 `deviceAddress` 和 `deviceAddressType`。
- 队长创建组时使用 `RANDOM_DEVICE_ADDRESS`、临时组 `netId: -1` 和 `GO_BAND_AUTO`。
- P2P 建立后才从 `getCurrentGroup().goIpAddress` 获取 TCP 队长地址；不在邀请中携带 IP。

## 3. 队长创建流程

1. 检查 `SystemCapability.Communication.WiFi.P2P` 和 `isWifiActive()`。
2. 读取 `getP2pLinkedInfo()`。如果设备已经在未知 P2P 组中，提示先结束投屏、互传或附近共享，不删除其他应用的组。
3. 生成 `roomId`、6 位 `code`、随机 `groupName`、强随机 `passphrase`、`authToken`、协议版本和过期时间。
4. 创建临时 P2P 组，然后通过 `getCurrentGroup()` 确认 `isP2pGo === true`。
5. 在 `0.0.0.0:9527` 启动 TCP 服务。
6. 尝试开启 BLE 房间广播。广播只携带「协议版本 + 6 位 code」；完整邀请在队员命中后通过短时 GATT 读取。
7. 如果蓝牙不可用，房间仍保持可用，队员可扫二维码加入。

## 4. 队员加入流程

### 4.1 扫码加入

1. 扫描二维码并验证版本、有效期和字段完整性。
2. 检查 Wi-Fi/P2P 前置条件。
3. 调用 `startDiscoverDevices()` 扫描附近 P2P 设备。
4. 对候选设备原样使用系统返回的随机地址和地址类型，配合邀请内的 `groupName/passphrase` 尝试 P2P 连接。
5. 收到 `p2pConnectionChange: CONNECTED` 后读取当前组，核对组名并取得 `goIpAddress`。
6. 连接 `goIpAddress:9527`，发送 `roomId + authToken + protocolVersion + nonce`。
7. 队长校验成功后才允许后续消息、状态快照和时钟同步。

二维码可精确提供房间配置，但不会绕过 HarmonyOS 的 P2P 发现/连接过程。如果系统 P2P 被其他应用占用或设备不支持，扫码也不能强制建立连接。

### 4.2 六位码加入

1. 检查 Wi-Fi 和蓝牙，并请求 `ACCESS_BLUETOOTH`。
2. 同时开始 P2P 设备发现和 BLE 房间扫描。
3. BLE 使用「协议版本 + code」精确匹配队长广播，再通过 GATT 读取完整邀请。
4. 获得邀请后，按扫码流程完成 P2P + TCP 连接。

六位 code 只是附近房间的匹配键，不包含可直接连接的地址。如果 BLE 没有发现队长，code 无法凭空找到远程设备，页面会提示「附近未找到该房间」。

## 5. 邀请数据与认证

二维码和 BLE GATT 使用同一份邀请：

```json
{
  "v": 3,
  "role": "join",
  "roomId": "...",
  "code": "123456",
  "groupName": "DIRECT-...",
  "passphrase": "...",
  "authToken": "...",
  "protocolVersion": 1,
  "expiresAt": 0,
  "port": 9527
}
```

- 不包含真实 MAC、P2P 随机 MAC 或 `goIpAddress`。
- `passphrase` 用于 P2P 组连接，`authToken` 用于 TCP 应用层认证。
- `nonce` 每次连接随机生成，队长拒绝重复 nonce，降低会话重放风险。
- 未认证 TCP 连接不允许发送其他协议消息。

## 6. 生命周期与异常

- 队长正常退出房间：停止节拍、关闭 TCP、停止 BLE 广播，然后对本应用创建的组调用 `removeGroup()`。
- 队员退出：单向发送 `CLIENT_LEAVE` 后立即关闭 TCP 并退出 P2P 组，不等待队长确认。队长收到后立即移除该成员，同时向其余队员广播新的队伍快照。
- 队长返回大厅或系统恢复页面：先检查当前组；如果本应用持有的旧组不可用，先移除再重建。
- 发现未知 P2P 组：不主动删除，提示用户结束投屏、互传或附近共享。
- 锁屏、长时间切后台、来电、Wi-Fi 关闭或系统回收都可能中断 BLE/P2P/TCP。当前版本不将「后台永不掉线」作为承诺；恢复前台后需检查大厅状态，断线时重新加入。
- 关闭 Wi-Fi 后会丢失 P2P 组。重新开启 Wi-Fi 不会自动恢复原组，队长需重建房间，队员需重新加入。

## 7. 页面文案原则

- 不再显示「请连接同一 Wi-Fi」或「请连接队长热点」。
- 扫码加入：强调需要开启 Wi-Fi，蓝牙不是必需条件。
- 加入码：强调需要同时开启 Wi-Fi 和蓝牙，蓝牙只用于查找附近房间。
- 「蓝牙（用于加入码找房间）」与「蓝牙耳机音频延迟」是两个独立概念，页面文案必须分开表达。
- 关键失败状态包括：「请先打开 Wi-Fi」、「请先打开蓝牙」、「附近未找到该房间」、「设备正在使用其他 P2P 连接」、「连接队长超时」和「房间邀请已过期」。

## 8. 真机测试步骤

最少准备两台安装同版本 OneBeat 的 HarmonyOS 真机。P2P 和 BLE 行为不能用单机模拟器代替验证。

### A. 基本扫码加入

1. 两台设备打开 Wi-Fi，可以不连接任何路由器。
2. 队长创建多人房间，确认大厅显示 P2P 已就绪。
3. 队员关闭蓝牙后扫描二维码。
4. 确认仍能完成 P2P 连接、令牌认证并进入大厅。
5. 更改 BPM/节拍/场景，检查队员状态一致。

### B. 六位码 + BLE

1. 两台设备打开 Wi-Fi 和蓝牙。
2. 队员输入队长大厅显示的 6 位 code。
3. 确认页面先显示查找附近房间，再显示 P2P/TCP 连接成功。
4. 输入错误 code，确认最终提示「附近未找到该房间」。
5. 关闭队员蓝牙再输入 code，确认明确提示打开蓝牙，不进行无效重试。

### C. 前置条件与占用

1. 关闭任一端 Wi-Fi，确认提示可点击前往系统无线设置。
2. 用系统投屏/互传建立其他 P2P 连接，再进入 OneBeat 多人页。
3. 确认 OneBeat 提示连接被占用，且不会删除其他应用的组。
4. 结束其他 P2P 任务后重试，确认可正常创建/加入。

### D. 认证与边界

1. 使用过期二维码，确认在 P2P 连接前拒绝。
2. 使用不同协议版本的应用，确认提示版本不兼容。
3. 修改二维码中的 `authToken`，确认 TCP 连接不能进入大厅。
4. 队长退出房间后立即重建，确认没有「已存在 P2P 组」残留错误。

### E. 中断与恢复

1. 分别测试队长/队员锁屏、切后台 30 秒、来电或音频打断后回前台。
2. 记录不同机型是否保持 P2P/TCP，掉线时确认界面可返回大厅或重新加入。
3. 连接中关闭再开启 Wi-Fi，确认原会话不被误判为仍可用，可通过重建/重新加入恢复。
4. 至少测试 2、4、8 台设备，记录加入耗时、掉线率、音画差与长时间漂移。

## 9. 当前已验证与待验证

- 已通过 ArkTS 编译、资源打包和 HAP 签名。
- 待 HarmonyOS 目标版本双真机验证：随机设备地址映射、扫码后 P2P 候选匹配、BLE 广播/GATT 可达性、`goIpAddress` 可连通性、多队员容量和系统后台策略。

HarmonyOS 官方流程同样是先完成 P2P 连接，再从 `WifiP2pGroupInfo.goIpAddress` 取得 Socket 通信地址：[HarmonyOS P2P 开发指南](https://developer.huawei.com/consumer/en/doc/harmonyos-guides/p2p-development-guide)。
