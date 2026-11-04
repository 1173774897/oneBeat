// Paid Huawei entitlements, resolved entirely on the device (2026-11-03).
//
// Purchase data never goes to the store server, so this module is the only
// authority for paid items: it asks Huawei IAP what the account owns, verifies
// every JWS locally, keeps a small private summary for offline launches, and
// confirms delivery (finishPurchase) only after that summary is on disk.
//
// The summary is independent of the server snapshot's 30-day lease: a paid
// item stays usable offline until a later successful Huawei query says
// otherwise, and the pass ends at Huawei's own expiry time.

import { common } from '@kit.AbilityKit';
import { iap } from '@kit.IAPKit';
import { preferences } from '@kit.ArkData';
import {
  IAP_ENVIRONMENT_SANDBOX,
  IAP_PASS_ACTIVE,
  IAP_PASS_CANCELED_ACTIVE,
  IapJwsCrypto,
  IapJwsPolicy,
  verifyPurchaseData,
  VerifiedIapRecord
} from './IapJwsVerifier';
import { platformIapJwsCrypto, platformIapJwsPolicy } from './IapJwsPlatformCrypto';

const TAG: string = '[IapEntitlements]';
const PREFERENCES_NAME: string = 'onebeat_iap_entitlements';
const STATE_KEY: string = 'state_v1';
const STATE_VERSION: number = 1;

export const IAP_PASS_PRODUCT_ID: string = 'onebeat.pass.monthly';

// Mirrors the server catalog (oneBeatBackend internal/store/catalog). Kept on
// the device so paid items unlock even before any server snapshot exists.
const PRODUCT_ITEM_KEYS: Map<string, string> = new Map<string, string>([
  ['onebeat.character.lamp', 'character.lamp'],
  ['onebeat.character.cloud', 'character.cloud'],
  ['onebeat.character.teapot', 'character.teapot'],
  ['onebeat.character.wave', 'character.wave'],
  ['onebeat.character.mismatch', 'character.mismatch'],
  ['onebeat.character.scooter', 'character.scooter'],
  ['onebeat.character.lilroll', 'character.lilroll'],
  ['onebeat.scene.neon_street', 'scene.neon_street']
]);

/** Items the pass unlocks when no server catalog is available. */
export const PASS_INCLUDED_ITEM_KEYS: string[] = [
  'character.lamp', 'character.cloud', 'character.teapot', 'character.wave', 'character.mismatch',
  'character.scooter', 'character.lilroll', 'scene.neon_street', 'feature.pro_drum_machine'
];

export function itemKeyForProductId(productId: string): string {
  return PRODUCT_ITEM_KEYS.get(productId) ?? '';
}

// Tokens are deliberately absent: they are only needed for finishPurchase,
// which always uses the token from the live Huawei response.
export interface LocalIapPurchase {
  productId: string;
  purchaseOrderId: string;
  purchaseTime: number;
  environment: string;
}

export interface LocalIapPass {
  productId: string;
  purchaseOrderId: string;
  status: string;
  expiresAt: number;
  autoRenewing: boolean;
  environment: string;
}

export interface LocalIapState {
  version: number;
  /** Local time of the last full Huawei query (0 = never). */
  capturedAt: number;
  purchases: LocalIapPurchase[];
  pass: LocalIapPass | null;
}

export function emptyLocalIapState(): LocalIapState {
  return { version: STATE_VERSION, capturedAt: 0, purchases: [], pass: null };
}

function passRank(pass: LocalIapPass, now: number): number {
  return (pass.status === IAP_PASS_ACTIVE || pass.status === IAP_PASS_CANCELED_ACTIVE) && pass.expiresAt > now ? 1 : 0;
}

function betterPass(current: LocalIapPass | null, candidate: LocalIapPass, now: number): LocalIapPass {
  if (current === null) {
    return candidate;
  }
  const rankDelta = passRank(candidate, now) - passRank(current, now);
  if (rankDelta !== 0) {
    return rankDelta > 0 ? candidate : current;
  }
  return candidate.expiresAt >= current.expiresAt ? candidate : current;
}

/** Adds one verified record; used for a fresh purchase and while building a full query. */
export function mergeLocalIapRecord(state: LocalIapState, record: VerifiedIapRecord, now: number): LocalIapState {
  const next: LocalIapState = {
    version: STATE_VERSION, capturedAt: state.capturedAt, purchases: state.purchases.slice(), pass: state.pass
  };
  const purchase = record.purchase;
  if (purchase !== undefined && itemKeyForProductId(purchase.productId).length > 0 &&
    next.purchases.findIndex((entry) => entry.productId === purchase.productId) < 0) {
    next.purchases.push({
      productId: purchase.productId, purchaseOrderId: purchase.purchaseOrderId,
      purchaseTime: purchase.purchaseTime, environment: record.environment
    });
    next.purchases.sort((left, right) => left.productId < right.productId ? -1 : left.productId > right.productId ? 1 : 0);
  }
  const pass = record.pass;
  if (pass !== undefined && pass.productId === IAP_PASS_PRODUCT_ID) {
    next.pass = betterPass(next.pass, {
      productId: pass.productId, purchaseOrderId: pass.purchaseOrderId, status: pass.status,
      expiresAt: pass.expiresAt, autoRenewing: pass.autoRenewing, environment: record.environment
    }, now);
  }
  return next;
}

/** A full query replaces the previous summary, so refunds and revocations drop out. */
export function buildLocalIapState(records: VerifiedIapRecord[], now: number): LocalIapState {
  let state = emptyLocalIapState();
  for (let i = 0; i < records.length; i++) {
    state = mergeLocalIapRecord(state, records[i], now);
  }
  state.capturedAt = now;
  return state;
}

/** Strict restore. Sandbox entries are dropped when the build no longer accepts sandbox. */
export function restoreLocalIapState(raw: string, allowSandbox: boolean): LocalIapState {
  try {
    const value = JSON.parse(raw) as LocalIapState;
    if (value === null || typeof value !== 'object' || value.version !== STATE_VERSION ||
      !Number.isFinite(value.capturedAt) || !Array.isArray(value.purchases)) {
      return emptyLocalIapState();
    }
    const purchases: LocalIapPurchase[] = value.purchases.filter((entry) =>
      entry !== null && typeof entry === 'object' && typeof entry.productId === 'string' &&
      itemKeyForProductId(entry.productId).length > 0 &&
      (allowSandbox || entry.environment !== IAP_ENVIRONMENT_SANDBOX));
    const rawPass = value.pass;
    const pass = rawPass !== null && typeof rawPass === 'object' && rawPass.productId === IAP_PASS_PRODUCT_ID &&
      typeof rawPass.status === 'string' && Number.isFinite(rawPass.expiresAt) &&
      (allowSandbox || rawPass.environment !== IAP_ENVIRONMENT_SANDBOX) ? rawPass : null;
    return { version: STATE_VERSION, capturedAt: value.capturedAt, purchases, pass };
  } catch (_error) {
    return emptyLocalIapState();
  }
}

export function localIapOwnedItemKeys(state: LocalIapState): string[] {
  const keys: string[] = [];
  for (let i = 0; i < state.purchases.length; i++) {
    const key = itemKeyForProductId(state.purchases[i].productId);
    if (key.length > 0 && keys.indexOf(key) < 0) {
      keys.push(key);
    }
  }
  return keys;
}

/** Huawei's own period end; 0 when no paid pass is in effect. */
export function localIapPassExpiry(state: LocalIapState, now: number): number {
  const pass = state.pass;
  return pass !== null && passRank(pass, now) > 0 ? pass.expiresAt : 0;
}

// ---- Process state and Huawei calls --------------------------------------------

let localState: LocalIapState = emptyLocalIapState();
let statePref: preferences.Preferences | undefined = undefined;
let stateRevision: number = 0;
let refreshInFlight: Promise<LocalIapRefreshResult> | undefined = undefined;
// Refreshes and new purchases run one at a time, so a full query that was
// listed before a purchase completed can never overwrite that purchase.
let exclusiveTail: Promise<void> = Promise.resolve();
let changeListener: (() => void) | undefined = undefined;
let jwsCrypto: IapJwsCrypto | undefined = undefined;
let jwsPolicy: IapJwsPolicy | undefined = undefined;

function crypto(): IapJwsCrypto {
  if (jwsCrypto === undefined) {
    jwsCrypto = platformIapJwsCrypto();
  }
  return jwsCrypto;
}

function policy(): IapJwsPolicy {
  if (jwsPolicy === undefined) {
    jwsPolicy = platformIapJwsPolicy();
  }
  return jwsPolicy;
}

export function currentLocalIapState(): LocalIapState {
  return localState;
}

/** EntitlementStore re-projects UI state whenever the paid summary changes. */
export function setLocalIapChangeListener(listener: (() => void) | undefined): void {
  changeListener = listener;
}

function publish(next: LocalIapState): void {
  localState = next;
  stateRevision++;
  if (changeListener !== undefined) {
    changeListener();
  }
}

async function persist(next: LocalIapState): Promise<void> {
  const pref = statePref;
  if (pref === undefined) {
    throw new Error('IAP entitlement storage is not ready');
  }
  await pref.put(STATE_KEY, JSON.stringify(next));
  await pref.flush();
}

/**
 * Restores the offline summary synchronously, so launch code that validates
 * the selected scene or character already sees paid items.
 */
export function initializeLocalIapEntitlements(context: common.Context): void {
  if (statePref !== undefined) {
    return;
  }
  try {
    const pref = preferences.getPreferencesSync(context, { name: PREFERENCES_NAME });
    statePref = pref;
    const raw = pref.getSync(STATE_KEY, '') as string;
    if (raw.length > 0) {
      publish(restoreLocalIapState(raw, policy().allowSandbox));
    }
  } catch (_error) {
    // Paid items reappear after the next successful Huawei query.
    console.warn(`${TAG} restore failed`);
  }
}

interface PendingFinish {
  productType: iap.ProductType;
  purchaseToken: string;
  purchaseOrderId: string;
}

function pendingFinish(record: VerifiedIapRecord, productType: iap.ProductType): PendingFinish | undefined {
  // Huawei sandbox never lists a finished (shipped) non-consumable again, so a
  // full refresh would erase it (Pura X 2026-11-04: teapot vanished minutes
  // after purchase). Sandbox one-time orders stay unfinished: they keep being
  // listed, refunds still appear with a revocation code, and Huawei does not
  // auto-refund them. Production (NORMAL) orders are always finished.
  // Subscriptions are still finished: unconfirmed renewals make queries fail.
  if (record.purchase !== undefined && record.environment === IAP_ENVIRONMENT_SANDBOX) {
    return undefined;
  }
  if (record.purchase !== undefined) {
    return {
      productType, purchaseToken: record.purchase.purchaseToken, purchaseOrderId: record.purchase.purchaseOrderId
    };
  }
  if (record.pass !== undefined && !record.revoked) {
    return { productType, purchaseToken: record.pass.purchaseToken, purchaseOrderId: record.pass.purchaseOrderId };
  }
  return undefined;
}

async function finishAll(context: common.UIAbilityContext, finishes: PendingFinish[]): Promise<number> {
  let finished = 0;
  for (let i = 0; i < finishes.length; i++) {
    try {
      await iap.finishPurchase(context, {
        productType: finishes[i].productType,
        purchaseToken: finishes[i].purchaseToken,
        purchaseOrderId: finishes[i].purchaseOrderId
      });
      finished++;
    } catch (_error) {
      // The order stays UNFINISHED at Huawei and is retried by the next refresh.
      console.warn(`${TAG} finishPurchase failed; will retry on next refresh`);
    }
  }
  return finished;
}

export interface LocalIapRefreshResult {
  ownedItemCount: number;
  passActive: boolean;
  finishedCount: number;
  /** Purchase data Huawei returned that failed local verification. */
  rejectedCount: number;
}

async function queryAll(context: common.UIAbilityContext, productType: iap.ProductType,
  queryType: iap.PurchaseQueryType): Promise<string[]> {
  const out: string[] = [];
  let continuationToken: string | undefined = undefined;
  do {
    const result: iap.QueryPurchaseResult = await iap.queryPurchases(context, {
      productType, queryType, continuationToken
    });
    const list: string[] = result.purchaseDataList ?? [];
    for (let i = 0; i < list.length; i++) {
      out.push(typeof list[i] === 'string' ? list[i] : JSON.stringify(list[i]));
    }
    continuationToken = result.continuationToken;
  } while (continuationToken !== undefined && continuationToken.length > 0 && out.length < 200);
  return out;
}

async function runRefresh(context: common.UIAbilityContext): Promise<LocalIapRefreshResult> {
  initializeLocalIapEntitlements(context);
  const records: VerifiedIapRecord[] = [];
  const finishes: PendingFinish[] = [];
  let rejectedCount = 0;
  const productTypes: iap.ProductType[] = [iap.ProductType.NONCONSUMABLE, iap.ProductType.AUTORENEWABLE];
  for (let t = 0; t < productTypes.length; t++) {
    // Any failed query aborts the refresh: a partial answer must not erase
    // items that simply were not listed this time.
    const owned = await queryAll(context, productTypes[t], iap.PurchaseQueryType.CURRENT_ENTITLEMENT);
    const unfinished = await queryAll(context, productTypes[t], iap.PurchaseQueryType.UNFINISHED);
    const all = owned.concat(unfinished);
    // Counts only: purchase payloads and tokens are never logged.
    console.info(`${TAG} query type=${productTypes[t]} owned=${owned.length} unfinished=${unfinished.length}`);
    for (let i = 0; i < all.length; i++) {
      try {
        const record = await verifyPurchaseData(all[i], crypto(), policy());
        records.push(record);
        const finish = i >= owned.length ? pendingFinish(record, productTypes[t]) : undefined;
        if (finish !== undefined) {
          finishes.push(finish);
        }
      } catch (error) {
        rejectedCount++;
        console.warn(`${TAG} purchase data rejected: ${(error as Error).message}`);
      }
    }
  }
  const now = Date.now();
  const next = buildLocalIapState(records, now);
  // Product ids are catalog constants, not personal data. This line shows what
  // Huawei listed when an item unexpectedly appears or disappears.
  console.info(`${TAG} refresh items=[${localIapOwnedItemKeys(next).join(',')}] ` +
    `pass=${localIapPassExpiry(next, now) > 0} rejected=${rejectedCount} finishing=${finishes.length}`);
  // Deliver first, confirm second: if the summary cannot be saved, Huawei
  // keeps the order unfinished and the next refresh delivers it again.
  await persist(next);
  publish(next);
  const finishedCount = await finishAll(context, finishes);
  return {
    ownedItemCount: localIapOwnedItemKeys(next).length,
    passActive: localIapPassExpiry(next, now) > 0,
    finishedCount,
    rejectedCount
  };
}

function exclusive<T>(task: () => Promise<T>): Promise<T> {
  const run = exclusiveTail.then(task);
  exclusiveTail = run.then(() => {}, () => {});
  return run;
}

/** Full re-query of Huawei (Store page, team lobby, 恢复购买). Shared while running. */
export function refreshLocalIapEntitlements(context: common.UIAbilityContext): Promise<LocalIapRefreshResult> {
  if (refreshInFlight === undefined) {
    const pending = exclusive(() => runRefresh(context));
    refreshInFlight = pending;
    const clear = (): void => {
      if (refreshInFlight === pending) {
        refreshInFlight = undefined;
      }
    };
    pending.then(clear, clear);
  }
  return refreshInFlight;
}

/**
 * Completes a createPurchase result: verify, save, then finishPurchase.
 * Throws when the data cannot be verified or saved; the order then stays
 * unfinished and a later refresh picks it up.
 */
export async function deliverNewPurchase(context: common.UIAbilityContext, purchaseData: string,
  productType: iap.ProductType): Promise<VerifiedIapRecord> {
  return exclusive(() => deliverNewPurchaseNow(context, purchaseData, productType));
}

async function deliverNewPurchaseNow(context: common.UIAbilityContext, purchaseData: string,
  productType: iap.ProductType): Promise<VerifiedIapRecord> {
  initializeLocalIapEntitlements(context);
  const record = await verifyPurchaseData(purchaseData, crypto(), policy());
  if (record.revoked) {
    throw new Error('该订单已退款或撤销');
  }
  const next = mergeLocalIapRecord(localState, record, Date.now());
  await persist(next);
  publish(next);
  const finish = pendingFinish(record, productType);
  if (finish !== undefined) {
    await finishAll(context, [finish]);
  }
  return record;
}

/** Test seam: replaces platform crypto/policy. Not used by production code. */
export function setIapJwsTrustForTesting(cryptoImpl: IapJwsCrypto, policyImpl: IapJwsPolicy): void {
  jwsCrypto = cryptoImpl;
  jwsPolicy = policyImpl;
}
