import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';

const PREFERENCES_NAME: string = 'onebeat_store_session';
const KEY_ACCESS_TOKEN: string = 'storeAccessToken';
const KEY_EXPIRES_AT: string = 'storeAccessTokenExpiresAt';

let appContext: common.Context | undefined = undefined;

export function bindStoreSessionPersistenceContext(context: common.Context): void {
  appContext = context;
}

export function getStoreSessionPersistenceContext(): common.Context | undefined {
  return appContext;
}

function sessionExpiryMs(expiresAt: string): number {
  return Date.parse(expiresAt);
}

function isSessionStillValid(token: string, expiresAt: string): boolean {
  if (token.length === 0 || expiresAt.length === 0) {
    return false;
  }
  const expiryMs = sessionExpiryMs(expiresAt);
  return Number.isFinite(expiryMs) && expiryMs > Date.now() + 60000;
}

async function openPreferences(): Promise<preferences.Preferences | undefined> {
  if (appContext === undefined) {
    return undefined;
  }
  return preferences.getPreferences(appContext, PREFERENCES_NAME);
}

export async function restoreStoreSessionFromDisk(): Promise<void> {
  const pref = await openPreferences();
  if (pref === undefined) {
    return;
  }
  const token = (await pref.get(KEY_ACCESS_TOKEN, '')) as string;
  const expiresAt = (await pref.get(KEY_EXPIRES_AT, '')) as string;
  if (!isSessionStillValid(token, expiresAt)) {
    if (token.length > 0 || expiresAt.length > 0) {
      await clearPersistedStoreSession(pref);
    }
    AppStorage.setOrCreate(KEY_ACCESS_TOKEN, '');
    AppStorage.setOrCreate(KEY_EXPIRES_AT, '');
    return;
  }
  AppStorage.setOrCreate(KEY_ACCESS_TOKEN, token);
  AppStorage.setOrCreate(KEY_EXPIRES_AT, expiresAt);
}

export async function persistStoreSessionToDisk(token: string, expiresAt: string): Promise<void> {
  const pref = await openPreferences();
  if (pref === undefined) {
    return;
  }
  if (token.length === 0 || expiresAt.length === 0) {
    await clearPersistedStoreSession(pref);
    return;
  }
  await pref.put(KEY_ACCESS_TOKEN, token);
  await pref.put(KEY_EXPIRES_AT, expiresAt);
  await pref.flush();
}

async function clearPersistedStoreSession(pref: preferences.Preferences): Promise<void> {
  await pref.delete(KEY_ACCESS_TOKEN);
  await pref.delete(KEY_EXPIRES_AT);
  await pref.flush();
}

export async function erasePersistedStoreSessionFromDisk(): Promise<void> {
  const pref = await openPreferences();
  if (pref === undefined) {
    return;
  }
  await clearPersistedStoreSession(pref);
}
