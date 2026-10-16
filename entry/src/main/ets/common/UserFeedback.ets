import { promptAction } from '@kit.ArkUI';
import { MonotonicClock } from './MonotonicClock';

const NOTICE_REPEAT_WINDOW_MS: number = 2000;
const NOTICE_HISTORY_LIMIT: number = 32;

interface FeedbackError {
  code?: number;
  message?: string;
}

interface ShownNotice {
  scope: string;
  message: string;
  shownAtMs: number;
}

let shownNotices: ShownNotice[] = [];

// These are explicit business messages produced by the app, rather than an
// arbitrary server/native error string that could contain payloads or credentials.
const PRODUCT_ERROR_MESSAGES: string[] = [
  '双方版本不一致，请更新 OneBeat 后重试',
  '邀请已过期，请让队长重新创建队伍',
  '订单与当前华为账号不匹配，请确认登录账号后重试',
  '购买验证失败，请尝试恢复购买',
  '活动尚未开始',
  '口令不正确或活动已结束',
  '这个账号已经领取过本次活动月卡',
  '本次活动名额已领完',
  '华为自动续费月卡仍在生效，暂时不能领取赠送月卡',
  '兑换请求已变化，请重新输入后再试',
  '尝试次数过多，请稍后再试',
  '暂时无法核对华为订阅状态，请稍后再试',
  '赠送月卡生效期间不能购买自动续费月卡',
  '畅游月卡已生效',
  '华为账号已拥有该商品，请稍后点击「恢复购买」同步权益',
  '上次队伍连接尚未释放，请稍后重试',
  '请输入 6 位加入码',
  '队长已拒绝本次加入请求，请和队长确认后再试一次',
  '需要允许 Wi-Fi 附近设备权限才能组队。请在系统弹窗中点允许，或到 设置 → OneBeat → 权限 中开启。',
  '手输加入码需要蓝牙附近发现权限，请允许后重试；也可以直接扫码加入。',
  '扫码需要相机权限，请在设置中允许；也可以输入加入码。',
  '当前设备不支持多人组队，可使用单人练习'
];

function feedbackErrorCode(error: Object): number {
  const code = (error as FeedbackError).code;
  return typeof code === 'number' && Number.isFinite(code) ? code : 0;
}

/** Only explicit SDK cancellation codes count as cancellation; error prose does not. */
export function isUserCancelled(error: Object): boolean {
  const code = feedbackErrorCode(error);
  // ScanKit SCAN_SERVICE_CANCELED, IAP USER_CANCELED, AccountKit USER_CANCELED.
  return code === 1000500002 || code === 1001860000 || code === 1001502012;
}

/** Map known business failures to actionable copy; unknown details stay out of the UI. */
export function userErrorMessage(error: Object, fallback: string): string {
  const detail = (error as FeedbackError).message;
  const message = typeof detail === 'string' ? detail : '';
  const text = message.trim();
  if (PRODUCT_ERROR_MESSAGES.indexOf(text) >= 0) {
    return text;
  }
  if (text.indexOf('双方版本不一致') >= 0 || text.indexOf('不是当前版本的 OneBeat 邀请') >= 0) {
    return '双方版本不一致，请更新 OneBeat 后重试';
  }
  if (text.indexOf('邀请缺少') >= 0 || text.indexOf('邀请认证信息不完整') >= 0 ||
    text.indexOf('邀请端口无效') >= 0) {
    return '邀请信息不完整，请重新扫描队长二维码';
  }
  if (text.indexOf('当前设备不支持 Wi-Fi') >= 0) {
    return '当前设备不支持多人组队，可使用单人练习';
  }
  if (text.indexOf('请先打开 Wi-Fi') >= 0) {
    return '请先打开 Wi-Fi，再重试';
  }
  if (text.indexOf('其他 P2P 连接') >= 0) {
    return '设备正在使用其他直连连接，请先结束投屏或互传后重试';
  }
  if (text.indexOf('附近未找到该房间') >= 0) {
    return '附近未找到队伍，请确认队长仍在大厅，或改用扫码加入';
  }
  if (text.indexOf('手输加入码需要打开蓝牙') >= 0 || text.indexOf('蓝牙未开启') >= 0) {
    return '加入码需要打开蓝牙，也可以改用扫码加入';
  }
  if (text.indexOf('不支持蓝牙附近发现') >= 0) {
    return '当前设备无法通过加入码查找队伍，请改用扫码加入';
  }
  if (text.indexOf('队员时钟准备未完成') >= 0) {
    return '队伍同步尚未完成，请稍后重试';
  }
  if (text === '队长版本不支持即时连接结果回执') {
    return '双方版本不一致，请更新 OneBeat 后重试';
  }
  if (text === '队长未提供 OneBeat 房间邀请') {
    return '邀请信息不完整，请重新扫描队长二维码';
  }
  if (text.indexOf('上次 P2P 连接释放超时') >= 0 || text.indexOf('系统尚未返回上次 P2P 组信息') >= 0) {
    return '上次队伍连接尚未释放，请稍后重试';
  }
  if (text === '蓝牙连接超时' || text === 'BLE join feedback operation timeout') {
    return '连接超时，请靠近队长后重试，或改用扫码加入';
  }
  if (text.indexOf('发现附近设备，但连接队长失败') >= 0 || text === '连接队长失败') {
    return '未能连接队长，请确认队长仍在大厅后重试';
  }
  if (text.indexOf('华为账号登录') >= 0 || feedbackErrorCode(error) === 1001502001 ||
    feedbackErrorCode(error) === 1001860050) {
    return '请先登录华为账号，再重试';
  }
  return fallback.trim().length > 0 ? fallback : '操作未完成，请重试';
}

/** Diagnostics retain the native code, never arbitrary error payloads or redemption input. */
export function logUserFailure(scope: string, error: Object): void {
  console.warn(`[UserFeedback] scope=${scope} code=${feedbackErrorCode(error)}`);
}

/** Suppress repeated identical feedback for one operation, without hiding other failures. */
export function showUserNotice(message: string, scope: string = 'general'): void {
  if (message.trim().length === 0) {
    return;
  }
  const now = MonotonicClock.nowMs();
  shownNotices = shownNotices.filter((notice: ShownNotice) =>
    now >= notice.shownAtMs && now - notice.shownAtMs < NOTICE_REPEAT_WINDOW_MS);
  if (shownNotices.some((notice: ShownNotice) => notice.scope === scope && notice.message === message)) {
    return;
  }
  shownNotices.push({ scope, message, shownAtMs: now });
  if (shownNotices.length > NOTICE_HISTORY_LIMIT) {
    shownNotices.shift();
  }
  promptAction.showToast({ message });
}
