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
let inFlightBootstrapPromise: Promise<void> | undefined = undefined;
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
  inFlightBootstrapPromise = pending;
  setStoreBootstrapRefreshPromise(pending);
  void pending.then(() => clearCompletedBootstrap(pending), () => clearCompletedBootstrap(pending));
  return pending;
}

function clearCompletedBootstrap(pending: Promise<void>): void {
  // Auth invalidation can start a newer request before this one completes.
  if (inFlightBootstrapPromise === pending) {
    inFlightBootstrapPromise = undefined;
  }
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

/** Shares an active refresh, or starts a fresh catalog request when the previous one has settled. */
export function refreshStoreEntitlementsNow(): Promise<void> {
  if (!isStoreApiConfigured()) {
    return Promise.resolve();
  }
  startStoreColdStartBootstrap();
  const pending = inFlightBootstrapPromise;
  // A cleared cache means the account changed; do not reuse an old account's request.
  if (pending !== undefined && getStoreBootstrapRefreshPromise() === pending) {
    return pending;
  }
  setStoreBootstrapRefreshPromise(undefined);
  return refreshStoreEntitlements();
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
