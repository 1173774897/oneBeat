# 组队加入流程：问题定位、参考项目对比与取舍（2026-10-29）

## 1. 现在的流程（队员手输加入码）

| 阶段 | 代码 | 真机耗时（10-28～29 日志） | 日志 |
|---|---|---|---|
| 1. BLE 查找房间 | `BleRoomDiscovery.findRoomInvitation`：按服务 UUID 扫描，按信号强度逐个 GATT 连接、读取邀请，再比对加入码；超时 15s | 未记录；10-28 17:03 一次约 9.9s（P2P 预热注册 → `p2p-start`） | 本次新增 `ble-candidate`、`ble-read`、`ble-lookup-timeout` |
| 2. Wi-Fi P2P 连接 | `WifiP2pManager.connectToLeader`：P2P 发现，按邀请里的设备名找队长，然后 `p2pConnect`，由队长在系统弹窗确认；单个候选等 25s，发现等 30s | 1.7–4.4s（含队长点确认） | `p2p-start`→`p2p-ready`；本次新增 `p2p-peers`、`p2p-candidate(-failed)` |
| 3. TCP 握手 + 时钟同步 | `SessionController.connectMember`，11 个时钟样本 | 0.8–1.9s | `clock-ready` |
| 4. 渲染器、后台任务 | | 0.1–0.3s | `renderer-ready`、`background-ready` |

P2P 连接期间，BLE「拒绝反馈」通道同时在建立 GATT 连接。在已有日志里，它每次都要连续超时两次（3s+3s）才放弃。

## 2. 「加入码正确却找不到队伍」的实际失败

| 时间 | 卡住的阶段 | 用时 | 对应超时 |
|---|---|---|---|
| 10-29 12:47:19 | BLE 已找到房间，P2P 阶段失败 | 25.0s | `CONNECTION_TIMEOUT_MS`：已找到同名候选并发起连接，队长侧没有出现系统确认，也没有连接事件 |
| 10-29 14:25:52 | 同上 | 30.8s | `DISCOVERY_TIMEOUT_MS`：P2P 发现里一直没有可用的同名设备，提示「附近未找到该房间」 |

两次失败都发生在队长刚重建 P2P 组之后（应用刚安装或启动），紧接着重试就成功了（14:26:29）。

- 事实：失败不在 BLE 查找，而在按设备名匹配 P2P 设备并建立连接这一步。
- 推测（待验证）：系统 P2P 设备表里残留了队长上一个组的旧条目（旧随机地址或旧状态），或者队长刚建组时暂时没被发现。当时只抓了 JSAPP 日志，没有系统 Wi-Fi 日志，无法区分。本次已改为抓取完整日志，并加了候选设备摘要。

## 3. 参考项目

| 参考 | 解决的场景 | 引入的依赖 | 与当前需求的差异 | 取舍 |
|---|---|---|---|---|
| [Android `ScanFilter`](https://developer.android.com/reference/android/bluetooth/le/ScanFilter.html)；[ble_proximity_signal_android](https://pub.dev/documentation/ble_proximity_signal_android/latest/)（从服务数据取令牌） | 在广播服务数据里放短令牌，扫描时直接过滤 | 仅系统 BLE | 我们的扫描响应里已经有加入码标签（`serviceTag`），只是没用 | **采用**：在应用层比对标签，不匹配就跳过 GATT。不用系统 `ScanFilter.serviceData`，因为标签在扫描响应里，硬件过滤是否覆盖扫描响应因设备而异，一旦漏掉就会永远找不到 |
| [OpenHarmony P2P 开发指南](https://gitcode.com/openharmony/docs/blob/master/en/application-dev/connectivity/wlan/p2p-development-guide.md) | netId=-2 持久组：组内设备重连时不需要 GO 协商和 WPS 密钥协商 | 系统 P2P | 我们用 netId=-1 临时组，每次加入都要完整协商。持久组会在系统里留下记录，可能影响用户的其他 P2P 使用（投屏、分享），而且多人、陌生设备场景下重连的意义有限 | **暂不采用**，单独实验：测 P2P 阶段能省多少，以及系统里会残留什么 |
| [Briar public-mesh-testbed](https://code.briarproject.org/briar/public-mesh-testbed/-/commit/253ff24304cc0b2c0c0ea8f86bf1d21ae3aec734.patch)；[Android `WifiP2pConfig.Builder`](https://developer.android.com/reference/android/net/wifi/p2p/WifiP2pConfig.Builder) | 已知网络名和密码时，Android 10+ 可以不经用户确认加入组 | Android API 29+ | 鸿蒙文档没有说明 `p2pConnect` 带 groupName/passphrase 能否免确认；我们的邀请里已经带了这两项，但队长侧仍会弹系统确认 | **待验证**：如果鸿蒙支持，能省掉队长点确认的时间 |
| [LocalSend 协议](https://github.com/localsend/protocol)；[Ableton Link](https://github.com/Ableton/link)（UDP 组播发现，加入即入会话） | 同一局域网内零配置发现 | 需要共同的 Wi-Fi AP 和组播 | 行进练习通常在户外，没有共同的 AP | **不采用**为主路径；只能作为「同一 Wi-Fi 下」的备选 |
| [OpenHarmony 软总线 dsoftbus](https://gitee.com/openharmony/communication_dsoftbus) | 系统内 BLE 发现后自动建 Wi-Fi 链路 | 系统设备信任/配对 | 队员是陌生设备、不同账号，需要先配对信任 | **不采用** |
| [Berty BLE 驱动](https://berty.tech/blog/bluetooth-low-energy/)；Briar 早期 [邮件讨论](https://moderncrypto.org/mail-archive/messaging/attachments/20140711/c01eca13/attachment.html) | 纯 BLE 传输；Briar 观察到蓝牙与 Wi-Fi 同时使用时，部分设备的发现成功率下降 | 自研 BLE 传输 | 我们只用 BLE 交换邀请，数据走 Wi-Fi | **借鉴**：P2P 连接期间减少并行的 BLE 活动（见 §4.3），需实测 |

## 4. 可选改动与取舍

1. **按标签过滤 BLE 候选（已做，本次验证）**：附近有其他 OneBeat 房间或别的广播设备时，不再逐个 GATT 连接（单个 GATT 连接最长 8s，整个查找 15s）。不改协议，旧版本队长的广播同样带标签。
2. **P2P 精确匹配队长（待第 2 节的日志确认根因后再做）**：在邀请里加上队长 P2P 设备地址（可选字段，兼容旧版），优先按地址匹配，找不到再按设备名。这样可以避开同名的旧条目。如果日志显示是队长刚建组后暂时发现不到，就改为发现阶段多刷新几次，不再单个候选死等 25s。
3. **P2P 期间推迟 BLE 反馈通道（待实测）**：它的作用只是把队长的「拒绝」尽快传回来，但每次都要超时 6s，而且和 Wi-Fi 争用射频。可以改成 P2P 连接完成或失败后再建，拒绝改由系统 P2P 的结果兜底。
4. **时钟同步提前就绪（待评估）**：11 个样本约 0.8–1.9s；可以在样本质量够好时提前结束。需要单独评估对起拍精度的影响。
5. **持久组 / 免确认加入（单独实验）**：见 §3。

## 5. 最小化验证（本次）

- 代码：
  - `BleAdvertisingTag.ets` 解析扫描响应中 128 位 UUID 的服务数据；
  - `BleRoomDiscovery` 跳过标签不匹配的设备，并记录候选和每次 GATT 读取的耗时；
  - `WifiP2pManager` 记录 P2P 设备表摘要（只记录名字是否匹配、状态、GO 位和地址后 5 位）及每个候选的结果。
- 测试：
  - `ble-advertising-tag.cjs`：解析、其他 UUID、截断、末尾补零；
  - `ble-room-lookup.cjs`：信号更强的其他房间不会被 GATT 读取，没有标签时仍走 GATT；
  - 门禁 71/71。
- 真机：抓取两台手机的完整日志（含系统 Wi-Fi）。重复加入 10 次左右，其中几次在队长刚建房间后立即加入。看三件事：
  - 每个阶段的耗时（`ble-candidate` 到 `ble-read result=match`）；
  - 候选设备的标签状态；
  - 一旦出现失败，看 `p2p-peers` 和系统 P2P 日志，确定 §2 的推测。

## 6. 真机验证第一轮（16:00–16:07，完整日志，含系统 Wi-Fi）

### 6.1 「首次加入失败、重试成功」：根因已确认

| 队员开始 P2P 搜索 | 队长 `CreateGroup` | 结果 |
|---|---|---|
| 16:00:33、16:00:53 | 16:00:31、16:00:52（搜索在建组**之后**开始） | 成功 |
| 16:02:45、16:04:21、16:05:41 | 16:02:47、16:04:23、16:05:43（搜索比建组**早约 2s**） | 全部失败：30s 内设备列表一直为空，提示「附近未找到该房间」 |
| 16:03:54、16:05:12、16:06:29（重试） | 组早已存在 | 全部成功 |

- 失败期间，队员的 wpa_supplicant 一直在正常循环 `p2p-scan`/`p2p-listen`，但队长侧一次 `P2P-DEVICE-FOUND` 都没有。
- 解释（与 P2P 搜索的行为一致）：一次搜索开始时会做一轮全信道扫描，之后只在 2.4GHz 的社交信道上监听。队长的组跟随它连接的 Wi-Fi 跑在 5GHz（5220MHz）。如果组是在那轮全信道扫描之后才建的，这次搜索就永远发现不了它。队员一进入加入页就会提前开始 P2P 搜索，所以更容易碰上这种情况。
- 排除：§2 推测的「匹配到同名的旧条目」不成立。这一轮每次的设备列表里都只有队长一个（`name/s3/go1`）。
- 修复：`WifiP2pManager.connectToLeader` 中，如果超过 `DISCOVERY_RESTART_MS`=3000ms 还没发现队长，就停止当前搜索并重新发起（日志 `p2p-rediscover`）。测试：`p2p-join-readiness.cjs` 新增用例。

### 6.2 队员卡在「正在退出队伍…」

- 过程：16:00:27 队长解散队伍。队员走远程解散流程时，清空了页面栈并替换成 `TeamPage`，此后栈里没有 `pages/Index`。16:01:10 队员点退出，退出流程本身跑完了，但 `router.back({ url: 'pages/Index' })` 在目标不在栈中时既不报错、也不跳转。页面停在大厅，`leavingLobby` 一直为 true，返回键全部被拦截，只能杀进程。
- 修复：`navigateToHome` 先用 `router.getStateByUrl` 检查首页是否在栈中，不在就 `clear` + `replaceUrl`。测试：`home-navigation.cjs`。

### 6.3 耗时分解（成功的几次）

| 阶段 | 耗时 | 说明 |
|---|---|---|
| BLE 查找 | 4.1–6.2s | 所有候选都是 `tag=none`：这台手机上报的扫描结果里不包含扫描响应，所以只有一个房间时，标签过滤帮不上忙。时间几乎都花在建立 GATT 连接上 |
| P2P | 3.1–4.1s | 包含队长点「同意」（约 1.8s），以及关联和获取 IP（约 2.3s） |
| 时钟同步 + 进入大厅 | 0.8s | |

- 试验：GATT 读取期间暂停扫描（没找到房间时再恢复），对比 `readMs` 是否缩短。测试：`ble-room-lookup.cjs`。
- 未做：P2P 期间 BLE 反馈通道仍会两次超时（每次 3s）；推迟建立反馈通道、持久组、免确认加入，都留到下一轮。

## 7. 真机验证第二轮（16:44–16:47）与修复

- 加入：每次都成功。几次「队长刚建组就加入」都触发了 `p2p-rediscover`，随后成功。
- BLE 查找：GATT 读取耗时 3.1–5.2s，上一轮是 4.1–6.2s，平均快了不到 1s。仍是「发出请求 → 队长弹窗」中最慢的一段。
- 重新搜索要等 3s（`p2p-rediscover elapsedMs≈3620`），有这一步的加入总耗时 9.5s，没有的约 5.8s。
- 拒绝反馈慢：16:47:01 队长拒绝，队长侧日志为 `rejected: no pending attempt`，因为队员的反馈通道两次 GATT 连接都超时（只给了 3s，而实测建连要 3–5s），没能登记加入尝试。队员一直等到自己 25s 的确认超时（`P2P-GROUP-FORMATION-FAILURE`），系统侧没有任何拒绝信号传到队员。
- 系统弹窗结果是有序事件。我们的订阅者处理完没有调用 `finishCommonEvent`，每次决定后系统都要等 5–20s（日志 `Ordered: Timeout`）。

修复：
1. 查找时，读到匹配的邀请后**保留这条 GATT 连接**（最长 15s，`RETAINED_LOOKUP_LINK_MS`）。反馈通道直接在这条连接上写入 `P:attemptId`，不再建第二条连接，日志 `link=lookup`。这样在队员发起 P2P、队长弹窗之前，加入尝试已经登记好，队长拒绝后队员下一次轮询（250ms）就能收到。保留的连接不可用时，改为新建连接，超时从 3s 放宽到 6s。
2. 是否重新搜索改为按「当前搜索已经进行了多久」判断（`discoveryStartedAtMs`）。队员进加入页时开始的预热搜索，到 P2P 这一步时通常已超过 3s，所以队长不在列表里时会立即重新搜索，不再先干等 3s。
3. 弹窗结果事件处理完后调用 `finishCommonEvent()`。
4. 测试：`ble-room-lookup.cjs` 验证反馈通道复用查找时的连接，不发生第二次 GATT 连接，并在 P2P 之前写入登记；门禁 74/74。

## 8. 真机验证第三轮（17:08–17:11）与修复

- 立即重新搜索已生效：`p2p-rediscover` 在 P2P 开始后 2–7ms 触发，0.9s 内找到队长，上一轮要 3.6s。
- BLE 查找仍为 3.0–4.7s，所以「发出请求 → 队长弹窗」没有明显变化。
- 拒绝仍要等 25s：反馈通道每次都在 P2P 开始后正好 3s 报 `operation timeout`。连接已经复用了，但读服务、写入这类操作正好和 P2P 协商同时进行，结果被挂起。
- 修复：
  1. **查找时就登记**：读到匹配的邀请后，在同一条连接上立即写入 `P:attemptId`，这时 P2P 还没开始。反馈通道直接用这次登记，不再做任何 BLE 写操作。P2P 期间只做轮询读取，没有用上的登记在释放时写入 `C:` 撤销。
  2. **输码时预读**：进入加入页时（已有蓝牙权限，不弹权限框）开始扫描，读取最强的至多 3 个房间的邀请（20s 内），并保留第一个房间的连接。提交加入码时，先等正在进行的读取完成，再在预读结果里找匹配；找到就在保留的连接上登记后直接进入 P2P，省掉查找阶段 3–5s 的 GATT 建连；找不到就照常查找。日志 `prefetch-start`、`prefetch-read`、`prefetch-hit`。
  3. 测试：`ble-room-lookup.cjs` 覆盖预读命中（不再建 GATT 连接，只写一次登记）和预读未命中时退回正常查找；门禁 74/74。

## 9. 最终结果（17:29–17:31）

用户反馈：速度明显变快，拒绝立即显示，加入仍然正常。日志确认如下。

| 指标 | 修复前（16:00–16:06） | 修复后 |
|---|---|---|
| 提交加入码 → 发起 P2P（队长弹窗） | 3.0–6.2s（BLE 查找） | 0–1ms（5 次全部 `prefetch-hit preRegistered=true`） |
| 提交加入码 → 进入大厅 | 约 9–11s | 3.8–5.6s（含队长点「同意」） |
| 队长拒绝 → 队员收到 | 等满 25s 超时，提示「加入失败」 | 即时：17:31:36 发起，17:31:38 收到 `feedback rejected`（含队长操作时间） |
| 队长刚建组就加入 | 必定失败（30s 后提示「未找到」） | 立即重新搜索，0.9s 内找到 |
| 队长解散后队员再退出 | 卡在「正在退出队伍…」 | 正常回到首页 |

预读在进入页面后 3.0–4.1s 内完成。输入加入码比这更慢时直接命中；输入更快时先等进行中的那次读取完成，再进入 P2P。

仍未做：持久组、免确认加入（§3），时钟同步提前结束（§4.4）。

## 10. 队长弹窗显示长代码 → 在队长 App 里提示申请人昵称

- 证据（17:40）：队员的 21 次请求都带了机型名（`P2P-PROV-DISC-PBC-REQ name='Pura 80 Pro'`）。显示长代码的几次（17:29:54、17:30:10、17:40:13）都是队员刚退出十几秒就重新加入，请求到达前队长侧没有新的 `P2P-DEVICE-FOUND`。系统弹窗用的是之前留下的旧记录，里面没有机型名，只能显示地址。弹窗是系统 Wi-Fi 的界面，应用改不了上面的文字，也清不掉系统缓存的旧记录。
- 方案（按用户要求，不兼容旧版本）：
  - 登记命令改为 `P:<attemptId>[:<昵称>]`。昵称最多 16 个字（与昵称输入框上限一致）；只有 id 后面的第一个冒号作为分隔符。
  - 队员连接后申请 MTU 128（`JOIN_REGISTRATION_MTU`），保证一次写入能放下完整命令。如果带昵称的写入被拒，改为写入不带昵称的命令，保证拒绝反馈仍然可用。
  - 队长收到登记后，`AppSession.showJoinRequest` 弹出提示「「昵称」正在申请加入，请在系统弹窗中确认」，并在大厅状态文字上方显示一条常驻提示（AppStorage `pendingJoinRequestName`）。队长做出决定、队员撤销登记、超过 30s（`JOIN_REQUEST_NOTICE_MS`）或会话结束时，这条提示会清除。
- 测试：`ble-join-feedback-lifecycle.cjs` 覆盖带昵称解析、昵称中含冒号、可省略昵称、拒收格式错误的命令、撤销登记和弹窗决定后清除提示，以及队员发出的命令带上昵称；门禁 74/74。
- 回归（18:24、18:32 复现「加入码正确但找不到队伍」）：连接建立后立即调用 `setBLEMtuSize`，与系统的服务发现撞在一起（日志 `bta_gattc_enqueue: already has a pending command`）。系统在约 1.9s 内完成了发现，但应用侧的 `getServices` 一直等到 10s 超时（`GattClient::GetServices timeout`），返回空列表，于是被判定为「队长未提供 OneBeat 房间邀请」，重试后仍然一样。
- 修复：MTU 改为服务发现完成之后、写入登记之前再申请，并等待 `BLEMtuChange`，最多 600ms（`negotiateRegistrationMtu`）。服务列表为空时再读一次（`discoverServices`，日志 `ble-services-empty`）。测试：`ble-room-lookup.cjs` 断言 MTU 申请发生在服务发现之后。

