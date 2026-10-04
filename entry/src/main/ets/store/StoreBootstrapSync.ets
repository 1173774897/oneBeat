import { applyStoreBootstrap, isSceneAccessible } from './EntitlementStore';
import { fetchStoreBootstrap } from './StoreApi';
import { isStoreApiConfigured } from './StoreApiConfig';
import {
  clearStoreSession,
  currentStoreSessionToken,
  trySilentStoreSessionRenewal
} from './HuaweiAccountService';
import { restoreStoreSessionFromDisk } from './StoreSessionPersistence';
import {
  getStoreBootstrapRefreshPromise,
  setStoreBootstrapRefreshPromise
} from './StoreBootstrapRefresh';

export { invalidateStoreBootstrapRefresh } from './StoreBootstrapRefresh';

let coldStartBootstrapPromise: Promise<void> | undefined = undefined;
let launchSessionHydrated: boolean = false;

/** Fetches store bootstrap once per app session (deduped). Safe to call from EntryAbility, Index, and lobby. */
export function refreshStoreEntitlements(): Promise<void> {
  if (!isStoreApiConfigured()) {
    return Promise.resolve();
  }
  const existing = getStoreBootstrapRefreshPromise();
  if (existing !== undefined) {
    return existing;
  }
  const pending = runStoreBootstrapSync();
  setStoreBootstrapRefreshPromise(pending);
  return pending;
}

/** App open: resolve session then bootstrap. Deduped for the whole process launch. */
export function startStoreColdStartBootstrap(): Promise<void> {
  if (coldStartBootstrapPromise !== undefined) {
    return coldStartBootstrapPromise;
  }
  coldStartBootstrapPromise = refreshStoreEntitlements();
  return coldStartBootstrapPromise;
}

export async function ensureStoreBootstrapReady(): Promise<void> {
  await startStoreColdStartBootstrap();
}

/** Refreshes the catalog after cold start so newly released pass content becomes usable without restarting the app. */
export async function refreshStoreEntitlementsNow(): Promise<void> {
  await startStoreColdStartBootstrap();
  setStoreBootstrapRefreshPromise(undefined);
  await refreshStoreEntitlements();
}

/**
 * Launch session policy (runs at app open via EntryAbility / Index / lobby):
 * 1. Restore JWT from Preferences once per process.
 * 2. Valid credential in session → use it and skip Huawei UI.
 * 3. No valid credential → silent Huawei re-login to mint a new JWT.
 * 4. Bootstrap with that token; empty token uses anonymous snapshot.
 */
async function resolveStoreSessionForBootstrap(): Promise<string> {
  if (!launchSessionHydrated) {
    await restoreStoreSessionFromDisk();
    launchSessionHydrated = true;
  }
  const existing = currentStoreSessionToken();
  if (existing.length > 0) {
    return existing;
  }
  return trySilentStoreSessionRenewal();
}

async function runStoreBootstrapSync(): Promise<void> {
  try {
    const accessToken = await resolveStoreSessionForBootstrap();
    await syncBootstrapWithSession(accessToken);
    reconcileSelectedSceneAfterBootstrap();
  } catch (_error) {
    // Keep last cached entitlement snapshot; lobby still works offline with defaults.
  }
}

async function syncBootstrapWithSession(accessToken: string): Promise<void> {
  let result = await fetchAndApplyBootstrap(accessToken);
  if (result !== 'unauthorized') {
    return;
  }
  clearStoreSession();
  const renewed = await trySilentStoreSessionRenewal();
  if (renewed.length > 0) {
    result = await fetchAndApplyBootstrap(renewed);
  }
  if (result !== 'ok') {
    await fetchAndApplyBootstrap('');
  }
}

function reconcileSelectedSceneAfterBootstrap(): void {
  const selectedScene = AppStorage.get<string>('selectedSceneKey') ?? 'sunset_coast';
  if (!isSceneAccessible(selectedScene)) {
    AppStorage.setOrCreate('selectedSceneKey', 'sunset_coast');
  }
}

type BootstrapFetchResult = 'ok' | 'unauthorized' | 'failed';

function isUnauthorizedBootstrapError(err: Object): boolean {
  const message = (err as Error).message ?? '';
  return message.includes('HTTP 401') || message.includes('invalid OneBeat session');
}

async function fetchAndApplyBootstrap(accessToken: string): Promise<BootstrapFetchResult> {
  try {
    const bootstrap = await fetchStoreBootstrap(accessToken);
    if (bootstrap !== null) {
      applyStoreBootstrap(bootstrap);
    }
    return 'ok';
  } catch (err) {
    if (accessToken.length > 0 && isUnauthorizedBootstrapError(err)) {
      return 'unauthorized';
    }
    return 'failed';
  }
}
