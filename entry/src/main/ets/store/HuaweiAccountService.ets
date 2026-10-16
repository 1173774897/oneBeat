import { common } from '@kit.AbilityKit';
import { authentication } from '@kit.AccountKit';
import { util } from '@kit.ArkTS';
import { authenticateHuawei } from './StoreApi';
import { invalidateStoreBootstrapRefresh } from './StoreBootstrapRefresh';
import {
  erasePersistedStoreSessionFromDisk,
  getStoreSessionPersistenceContext,
  persistStoreSessionToDisk
} from './StoreSessionPersistence';
import { StoreSession } from './StoreModels';

const SESSION_TOKEN_KEY: string = 'storeAccessToken';
const SESSION_EXPIRY_KEY: string = 'storeAccessTokenExpiresAt';

function cachedSessionToken(): string {
  const token = AppStorage.get<string>(SESSION_TOKEN_KEY) ?? '';
  const expiresAt = AppStorage.get<string>(SESSION_EXPIRY_KEY) ?? '';
  if (token.length === 0 || expiresAt.length === 0) {
    return '';
  }
  const expiryMs = Date.parse(expiresAt);
  if (!Number.isFinite(expiryMs) || expiryMs <= Date.now() + 60000) {
    clearStoreSession();
    return '';
  }
  return token;
}

export function currentStoreSessionToken(): string {
  return cachedSessionToken();
}

export function clearStoreSession(): void {
  AppStorage.setOrCreate(SESSION_TOKEN_KEY, '');
  AppStorage.setOrCreate(SESSION_EXPIRY_KEY, '');
  invalidateStoreBootstrapRefresh();
  void erasePersistedStoreSessionFromDisk();
}

function saveStoreSession(session: StoreSession): void {
  AppStorage.setOrCreate(SESSION_TOKEN_KEY, session.accessToken);
  AppStorage.setOrCreate(SESSION_EXPIRY_KEY, session.expiresAt);
  invalidateStoreBootstrapRefresh();
  void persistStoreSessionToDisk(session.accessToken, session.expiresAt);
}

/** Uses Huawei Account Kit silent login (forceLogin=false) to mint a new backend JWT. */
export async function trySilentStoreSessionRenewal(): Promise<string> {
  const existing = cachedSessionToken();
  if (existing.length > 0) {
    return existing;
  }
  const context = getStoreSessionPersistenceContext();
  if (context === undefined) {
    return '';
  }
  try {
    return await ensureStoreSession(context, false);
  } catch (_err) {
    return '';
  }
}

export async function ensureStoreSession(
  context: common.Context,
  interactive: boolean
): Promise<string> {
  const existing = cachedSessionToken();
  if (existing.length > 0) {
    return existing;
  }

  const state = util.generateRandomUUID(false);
  const request = new authentication.HuaweiIDProvider().createLoginWithHuaweiIDRequest();
  request.forceLogin = interactive;
  request.state = state;

  const controller = new authentication.AuthenticationController(context);
  // Preserve the native code so callers can distinguish explicit cancellation
  // from an account failure without interpreting the SDK's localized message.
  const response = await controller.executeRequest(request) as authentication.LoginWithHuaweiIDResponse;

  if (response.state !== state || response.data === undefined) {
    throw new Error('华为账号登录结果无效，请重试');
  }
  const authorizationCode = response.data.authorizationCode ?? '';
  const idToken = response.data.idToken ?? '';
  if (authorizationCode.length === 0 || idToken.length === 0) {
    throw new Error('华为账号未返回授权凭证，请确认已登录华为账号并重试');
  }

  const session: StoreSession = await authenticateHuawei(idToken, authorizationCode);
  saveStoreSession(session);
  return session.accessToken;
}
