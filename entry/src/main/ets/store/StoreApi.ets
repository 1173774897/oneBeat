import { http } from '@kit.NetworkKit';
import { isStoreApiConfigured, storeApiBaseUrl } from './StoreApiConfig';
import {
  StoreBootstrap,
  StoreBootstrapEnvelope,
  StorePurchaseSubmission,
  StoreRedemptionEnvelope,
  StoreRedemptionRequest,
  StoreRedemptionResult,
  StoreSession,
  StoreSessionEnvelope
} from './StoreModels';

const STORE_REQUEST_TIMEOUT_MS: number = 10000;

interface StoreRestoreRequest {
  purchases: StorePurchaseSubmission[];
}

function requestHeaders(accessToken?: string): Record<string, string> {
  const headers: Record<string, string> = {
    'Content-Type': 'application/json;charset=UTF-8',
    'Accept': 'application/json'
  };
  if (accessToken !== undefined && accessToken.length > 0) {
    headers['Authorization'] = `Bearer ${accessToken}`;
  }
  return headers;
}

function parseBootstrap(result: string, statusCode: number): StoreBootstrap {
  const envelope = JSON.parse(result) as StoreBootstrapEnvelope;
  if (statusCode !== 200 || envelope.code !== 0 || envelope.data === undefined) {
    const detail = envelope.message.length > 0 ? envelope.message : `store request failed with HTTP ${statusCode}`;
    if (statusCode === 422 && envelope.code === 42232) {
      throw new Error('订单与当前华为账号不匹配，请确认登录账号后重试');
    }
    if (statusCode === 422 && envelope.code === 42231) {
      throw new Error('购买验证失败，请尝试恢复购买');
    }
    throw new Error(detail);
  }
  return envelope.data;
}

export async function fetchStoreBootstrap(accessToken?: string): Promise<StoreBootstrap | null> {
  if (!isStoreApiConfigured()) {
    return null;
  }

  const client = http.createHttp();
  try {
    const response = await client.request(`${storeApiBaseUrl()}/api/v1/store/bootstrap`, {
      method: http.RequestMethod.GET,
      header: requestHeaders(accessToken),
      connectTimeout: STORE_REQUEST_TIMEOUT_MS,
      readTimeout: STORE_REQUEST_TIMEOUT_MS,
      expectDataType: http.HttpDataType.STRING
    });
    if (typeof response.result !== 'string') {
      throw new Error(`store bootstrap failed with HTTP ${response.responseCode}`);
    }
    return parseBootstrap(response.result, response.responseCode);
  } finally {
    client.destroy();
  }
}

export async function authenticateHuawei(idToken: string, authorizationCode: string): Promise<StoreSession> {
  const client = http.createHttp();
  try {
    const response = await client.request(`${storeApiBaseUrl()}/api/v1/auth/huawei`, {
      method: http.RequestMethod.POST,
      header: requestHeaders(),
      extraData: JSON.stringify({
        idToken: idToken,
        authorizationCode: authorizationCode
      }),
      connectTimeout: STORE_REQUEST_TIMEOUT_MS,
      readTimeout: STORE_REQUEST_TIMEOUT_MS,
      expectDataType: http.HttpDataType.STRING
    });
    if (typeof response.result !== 'string') {
      throw new Error(`Huawei login failed with HTTP ${response.responseCode}`);
    }
    const envelope = JSON.parse(response.result) as StoreSessionEnvelope;
    if (response.responseCode !== 200 || envelope.code !== 0 || envelope.data === undefined) {
      throw new Error(envelope.message.length > 0 ? envelope.message : 'Huawei login failed');
    }
    return envelope.data;
  } finally {
    client.destroy();
  }
}

export async function verifyStorePurchase(
  accessToken: string,
  purchase: StorePurchaseSubmission
): Promise<StoreBootstrap> {
  return postBootstrap('/api/v1/iap/purchases/verify', accessToken, purchase);
}

export async function restoreStorePurchases(
  accessToken: string,
  purchases: StorePurchaseSubmission[]
): Promise<StoreBootstrap> {
  const body: StoreRestoreRequest = { purchases: purchases };
  return postBootstrap('/api/v1/iap/purchases/restore', accessToken, body);
}

export async function redeemStoreCode(
  accessToken: string,
  request: StoreRedemptionRequest
): Promise<StoreRedemptionResult> {
  const client = http.createHttp();
  try {
    const response = await client.request(`${storeApiBaseUrl()}/api/v1/store/redemptions`, {
      method: http.RequestMethod.POST,
      header: requestHeaders(accessToken),
      extraData: JSON.stringify(request),
      connectTimeout: STORE_REQUEST_TIMEOUT_MS,
      readTimeout: STORE_REQUEST_TIMEOUT_MS,
      expectDataType: http.HttpDataType.STRING
    });
    if (typeof response.result !== 'string') {
      throw new Error(`store redemption failed with HTTP ${response.responseCode}`);
    }
    const envelope = JSON.parse(response.result) as StoreRedemptionEnvelope;
    if (response.responseCode === 200 && envelope.code === 0 && envelope.data !== undefined) {
      return envelope.data;
    }
    // Keep stable backend business codes out of page components so all callers
    // present the same actionable Chinese message.
    switch (envelope.code) {
      case 40921:
        throw new Error('活动尚未开始');
      case 40922:
        throw new Error('口令不正确或活动已结束');
      case 40923:
        throw new Error('这个账号已经领取过本次活动月卡');
      case 40924:
        throw new Error('本次活动名额已领完');
      case 40925:
        throw new Error('华为自动续费月卡仍在生效，暂时不能领取赠送月卡');
      case 40926:
        throw new Error('兑换请求已变化，请重新输入后再试');
      case 42901:
        throw new Error('尝试次数过多，请稍后再试');
      case 50321:
        throw new Error('暂时无法核对华为订阅状态，请稍后再试');
      default:
        throw new Error(envelope.message.length > 0 ? envelope.message : '口令兑换失败');
    }
  } finally {
    client.destroy();
  }
}

async function postBootstrap(path: string, accessToken: string, body: Object): Promise<StoreBootstrap> {
  const client = http.createHttp();
  try {
    const response = await client.request(`${storeApiBaseUrl()}${path}`, {
      method: http.RequestMethod.POST,
      header: requestHeaders(accessToken),
      extraData: JSON.stringify(body),
      connectTimeout: STORE_REQUEST_TIMEOUT_MS,
      readTimeout: STORE_REQUEST_TIMEOUT_MS,
      expectDataType: http.HttpDataType.STRING
    });
    if (typeof response.result !== 'string') {
      throw new Error(`store request failed with HTTP ${response.responseCode}`);
    }
    return parseBootstrap(response.result, response.responseCode);
  } finally {
    client.destroy();
  }
}
