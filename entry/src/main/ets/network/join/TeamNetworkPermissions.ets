import { abilityAccessCtrl, common, Permissions } from '@kit.AbilityKit';
import { access, wifiManager } from '@kit.ConnectivityKit';

/** 普通应用建立与发现 P2P 设备只使用 GET_WIFI_INFO，不申请系统级 MAC/连接管理权限。 */
const TEAM_NETWORK_USER_PERMISSIONS: Permissions[] = [
  'ohos.permission.GET_WIFI_INFO'
];

const CAMERA_PERMISSION: Permissions = 'ohos.permission.CAMERA';
const BLUETOOTH_PERMISSION: Permissions = 'ohos.permission.ACCESS_BLUETOOTH';
const MICROPHONE_PERMISSION: Permissions = 'ohos.permission.MICROPHONE';

function isGranted(status: number): boolean {
  return status === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED;
}

async function collectMissingPermissions(
  atManager: abilityAccessCtrl.AtManager,
  tokenId: number,
  permissions: Permissions[]
): Promise<Permissions[]> {
  const missing: Permissions[] = [];
  for (let i = 0; i < permissions.length; i++) {
    const perm = permissions[i];
    try {
      const status = await atManager.checkAccessToken(tokenId, perm);
      if (!isGranted(status)) {
        missing.push(perm);
      }
    } catch (_e) {
      missing.push(perm);
    }
  }
  return missing;
}

async function requestPermissions(
  context: common.UIAbilityContext,
  permissions: Permissions[]
): Promise<boolean> {
  if (permissions.length === 0) {
    return true;
  }
  const atManager = abilityAccessCtrl.createAtManager();
  const result = await atManager.requestPermissionsFromUser(context, permissions);
  for (let i = 0; i < result.authResults.length; i++) {
    if (!isGranted(result.authResults[i])) {
      return false;
    }
  }
  return true;
}

/** 创建 / 加入队伍前调用，会弹出系统授权框（若尚未授权） */
export async function ensureTeamNetworkPermissions(context: common.UIAbilityContext): Promise<boolean> {
  const atManager = abilityAccessCtrl.createAtManager();
  const tokenId = context.applicationInfo.accessTokenId;
  const missing = await collectMissingPermissions(atManager, tokenId, TEAM_NETWORK_USER_PERMISSIONS);
  return await requestPermissions(context, missing);
}

export async function ensureBluetoothDiscoveryPermission(context: common.UIAbilityContext): Promise<boolean> {
  const atManager = abilityAccessCtrl.createAtManager();
  const tokenId = context.applicationInfo.accessTokenId;
  const missing = await collectMissingPermissions(atManager, tokenId, [BLUETOOTH_PERMISSION]);
  return await requestPermissions(context, missing);
}

/** 权限允许后仍需确认系统能力和 Wi-Fi 开关；应用不会自行开启 Wi-Fi。 */
export async function verifyTeamNetworkAccess(): Promise<boolean> {
  return canIUse('SystemCapability.Communication.WiFi.P2P') && wifiManager.isWifiActive();
}

export function isTeamWifiActive(): boolean {
  try {
    return wifiManager.isWifiActive();
  } catch (_e) {
    return false;
  }
}

export function teamNetworkAccessUnavailableHint(): string {
  if (!canIUse('SystemCapability.Communication.WiFi.P2P')) {
    return '当前设备不支持 Wi-Fi P2P，无法使用多人练习。';
  }
  return '请先打开 Wi-Fi，点此可前往系统设置；不需要连接同一路由器。';
}

export function isBluetoothDiscoveryAvailable(): boolean {
  try {
    return canIUse('SystemCapability.Communication.Bluetooth.Core') &&
      access.getState() === access.BluetoothState.STATE_ON;
  } catch (_e) {
    return false;
  }
}

export async function openWirelessSettings(context: common.UIAbilityContext): Promise<void> {
  await context.startAbility({ action: 'ohos.settings.wireless' });
}

export async function ensureCameraPermission(context: common.UIAbilityContext): Promise<boolean> {
  const atManager = abilityAccessCtrl.createAtManager();
  const tokenId = context.applicationInfo.accessTokenId;
  const missing = await collectMissingPermissions(atManager, tokenId, [CAMERA_PERMISSION]);
  return await requestPermissions(context, missing);
}

export function teamNetworkPermissionDeniedHint(): string {
  return '需要允许 Wi-Fi 附近设备权限才能组队。请在系统弹窗中点允许，或到 设置 → OneBeat → 权限 中开启。';
}

export function bluetoothPermissionDeniedHint(): string {
  return '手输加入码需要蓝牙附近发现权限，请允许后重试；也可以直接扫码加入。';
}

export function cameraPermissionDeniedHint(): string {
  return '扫码加入需要「相机」权限，请在系统弹窗中允许或到应用设置中开启。';
}

export async function ensureMicrophonePermission(context: common.UIAbilityContext): Promise<boolean> {
  const atManager = abilityAccessCtrl.createAtManager();
  const tokenId = context.applicationInfo.accessTokenId;
  const missing = await collectMissingPermissions(atManager, tokenId, [MICROPHONE_PERMISSION]);
  return await requestPermissions(context, missing);
}

export function microphonePermissionDeniedHint(): string {
  return '麦克风回环测时需要「麦克风」权限，请在系统弹窗中允许或到应用设置中开启。';
}
