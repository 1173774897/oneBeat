import { StoreBootstrap } from './StoreModels';
import { MonotonicClock } from '../common/MonotonicClock';
import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { readOptionalSync, writeAtomicSync } from '../common/AtomicTextFile';
import {
  EntitlementSnapshot,
  entitlementSnapshotFingerprint,
  isEntitlementSnapshotUsable,
  restoreEntitlementSnapshot,
  sanitizeEntitlementBootstrap,
  snapshotItemExpiry,
  snapshotPassExpiry,
  snapshotServerTime
} from './EntitlementSnapshotCache';
import {
  currentLocalIapState,
  itemKeyForProductId,
  localIapOwnedItemKeys,
  localIapPassExpiry,
  PASS_INCLUDED_ITEM_KEYS,
  setLocalIapChangeListener
} from './IapEntitlements';

const ENTITLEMENT_CACHE_SCHEMA: number = 7;
const DEFAULT_CHARACTERS: string[] = [];
const DEFAULT_SCENES: string[] = ['sunset_coast'];
const MONTHLY_PASS_PREFERENCES: string = 'onebeat_monthly_pass_summary';
const MONTHLY_PASS_KEY: string = 'summary_v1';

interface MonthlyPassSummary {
  active: boolean;
  expiresAt: string;
  capturedAt: number;
}

let monthlyPassPref: preferences.Preferences | undefined = undefined;
let monthlyPassSummary: MonthlyPassSummary | undefined = undefined;
let monthlyPassInitialization: Promise<void> | undefined = undefined;
let monthlyPassWrites: Promise<void> = Promise.resolve();
let monthlyPassRevision: number = 0;
let monthlyPassKnown: boolean = false;
let entitlementSnapshot: EntitlementSnapshot | undefined = undefined;
let entitlementFilePath: string = '';
let entitlementRevision: number = 0;
let projectedEntitlementFingerprint: string = '';

function setMonthlyPassKnown(known: boolean): void {
  monthlyPassKnown = known;
  AppStorage.setOrCreate('monthlyPassRewardStateKnown', known);
}

function validMonthlyPassSummary(summary: MonthlyPassSummary): boolean {
  return typeof summary.active === 'boolean' && typeof summary.expiresAt === 'string' &&
    Number.isFinite(summary.capturedAt) && summary.capturedAt >= 0 &&
    (!summary.active || Number.isFinite(Date.parse(summary.expiresAt)));
}

function persistMonthlyPassSummary(summary: MonthlyPassSummary, revision: number): Promise<void> {
  const operation = monthlyPassWrites.then(async (): Promise<void> => {
    const pref = monthlyPassPref;
    if (pref === undefined || revision !== monthlyPassRevision) {
      return;
    }
    try {
      if (!validMonthlyPassSummary(summary)) {
        throw new Error('月卡状态暂时无法核对，请稍后重试');
      }
      // Persist only membership facts, never the rest of the bootstrap.
      await pref.put(MONTHLY_PASS_KEY, JSON.stringify(summary));
      await pref.flush();
      if (revision === monthlyPassRevision) {
        setMonthlyPassKnown(true);
      }
    } catch (_error) {
      if (revision === monthlyPassRevision) {
        setMonthlyPassKnown(false);
      }
      throw new Error('月卡状态暂时无法核对，请稍后重试');
    }
  });
  monthlyPassWrites = operation.catch(() => {});
  return operation;
}

function acceptMonthlyPassSummary(bootstrap: StoreBootstrap): boolean {
  const parsedTime = Date.parse(bootstrap.serverTime);
  const capturedAt = Number.isFinite(parsedTime) ? parsedTime : Date.now();
  if (monthlyPassSummary !== undefined && capturedAt < monthlyPassSummary.capturedAt) {
    // Concurrent catalog/purchase requests can resolve out of order. A response
    // older than our last accepted server snapshot cannot revoke newer access.
    return false;
  }
  const summary: MonthlyPassSummary = {
    active: bootstrap.pass.active, expiresAt: bootstrap.pass.expiresAt ?? '', capturedAt
  };
  monthlyPassSummary = summary;
  const revision = ++monthlyPassRevision;
  setMonthlyPassKnown(false);
  if (monthlyPassPref !== undefined) {
    void persistMonthlyPassSummary(summary, revision).catch(() => {
      console.warn('[MonthlyPassCache] persistence failed');
    });
  }
  return true;
}

async function restoreMonthlyPassCache(context: common.Context): Promise<void> {
  const restoreRevision = monthlyPassRevision;
  const pref = await preferences.getPreferences(context, MONTHLY_PASS_PREFERENCES);
  monthlyPassPref = pref;
  const raw = await pref.get(MONTHLY_PASS_KEY, '') as string;
  if (monthlyPassRevision !== restoreRevision || monthlyPassSummary !== undefined) {
    const latest = monthlyPassSummary;
    if (latest !== undefined) {
      await persistMonthlyPassSummary(latest, monthlyPassRevision);
    }
    return;
  }
  if (raw.length > 0) {
    const restored = JSON.parse(raw) as MonthlyPassSummary;
    if (!validMonthlyPassSummary(restored)) {
      throw new Error('月卡状态暂时无法核对，请稍后重试');
    }
    monthlyPassSummary = restored;
    setMonthlyPassKnown(true);
    return;
  }
  const sessionPref = await preferences.getPreferences(context, 'onebeat_store_session');
  const diskToken = await sessionPref.get('storeAccessToken', '') as string;
  if (monthlyPassRevision !== restoreRevision) {
    const latest = monthlyPassSummary;
    if (latest !== undefined) {
      await persistMonthlyPassSummary(latest, monthlyPassRevision);
    }
    return;
  }
  if (diskToken.length > 0 || (AppStorage.get<string>('storeAccessToken') ?? '').length > 0) {
    // An existing account without a summary is unknown until bootstrap arrives;
    // treating it as a new install could grant a member an unintended trial.
    setMonthlyPassKnown(false);
    return;
  }
  const fresh: MonthlyPassSummary = { active: false, expiresAt: '', capturedAt: 0 };
  monthlyPassSummary = fresh;
  await persistMonthlyPassSummary(fresh, ++monthlyPassRevision);
}

/** Restore membership before local reward decisions, including offline launches. */
export async function initializeMonthlyPassCache(context: common.Context): Promise<void> {
  if (monthlyPassInitialization === undefined) {
    monthlyPassInitialization = restoreMonthlyPassCache(context).catch((error: Error) => {
      monthlyPassInitialization = undefined;
      throw error;
    });
  }
  await monthlyPassInitialization;
}

export function isMonthlyPassRewardStateKnown(): boolean {
  // A separately persisted reward summary is not authority for unlocking paid
  // content. A possibly active member without a current full snapshot must wait
  // for refresh before a local check-in can grant a trial.
  // A verified Huawei pass is itself a known, active membership.
  if (isHuaweiPassActive()) { return true; }
  const summary = monthlyPassSummary;
  if (!monthlyPassKnown || summary === undefined) { return false; }
  const snapshot = entitlementSnapshot;
  if (isEntitlementSnapshotUsable(snapshot, Date.now()) && snapshot !== undefined) {
    // The two independent files can commit differently after a disk failure.
    // A newer membership summary must not be paired with an older inactive
    // catalog to issue a trial to somebody whose membership is already active.
    return snapshotServerTime(snapshot) >= summary.capturedAt &&
      snapshot.bootstrap.pass.active === summary.active &&
      ((snapshot.bootstrap.pass.expiresAt ?? '') === summary.expiresAt ||
        Date.parse(snapshot.bootstrap.pass.expiresAt ?? '') === Date.parse(summary.expiresAt));
  }
  return !(summary.active && Date.parse(summary.expiresAt) > Date.now());
}

/** Wait only for local restore/writes; unknown network state leaves a share pending. */
export async function waitForMonthlyPassCache(): Promise<void> {
  if (monthlyPassInitialization !== undefined) {
    await monthlyPassInitialization.catch(() => {});
  }
  let previous: Promise<void>;
  do {
    previous = monthlyPassWrites;
    await previous;
  } while (previous !== monthlyPassWrites);
}

function setString(key: string, value: string): void {
  if (AppStorage.get<string>(key) !== value) { AppStorage.setOrCreate(key, value); }
}

function setBoolean(key: string, value: boolean): void {
  if (AppStorage.get<boolean>(key) !== value) { AppStorage.setOrCreate(key, value); }
}

function persistEntitlementSnapshot(): void {
  if (entitlementFilePath.length === 0 || entitlementSnapshot === undefined) { return; }
  try {
    writeAtomicSync(entitlementFilePath, JSON.stringify(entitlementSnapshot));
  } catch (_error) {
    // A successful response remains usable in this process. Atomic replacement
    // leaves the old disk snapshot and its original age intact on write failure.
    console.warn('[EntitlementCache] persistence failed');
  }
}

/** Restore the private full snapshot before pages mount; a restore never renews its thirty-day lease. */
export function initializeStoredEntitlementCache(context: common.Context): void {
  const path = `${context.filesDir}/entitlement-snapshot-v1.json`;
  if (entitlementFilePath === path) {
    projectEntitlementSnapshot(Date.now());
    return;
  }
  entitlementFilePath = path;
  const revision = entitlementRevision;
  try {
    const raw = readOptionalSync(path);
    const restored = raw.length > 0 ? restoreEntitlementSnapshot(raw) : undefined;
    // Ability recreation or a response arriving before local initialization must
    // not replace newer in-memory authority with an older on-disk response.
    if (revision === entitlementRevision && entitlementSnapshot === undefined && restored !== undefined) {
      entitlementSnapshot = restored;
      entitlementRevision++;
    } else if (entitlementSnapshot !== undefined) {
      persistEntitlementSnapshot();
    }
  } catch (_error) {
    console.warn('[EntitlementCache] restore failed');
  }
  initializeEntitlementCache();
}

/** Valid cache avoids a network readiness wait; per-item deadlines still apply independently. */
export function hasUsableEntitlementCache(now: number = Date.now()): boolean {
  return isEntitlementSnapshotUsable(entitlementSnapshot, now);
}

export const ACCESS_IAP_PURCHASE: string = 'IAP_PURCHASE';
export const ACCESS_PASS_IAP: string = 'PASS_IAP';
const PERMANENT_EXPIRY: number = Number.MAX_SAFE_INTEGER;

interface ItemAccess {
  reason: string;
  /** 0 = locked. */
  expiry: number;
}

/**
 * One precedence for every reader, mirroring the server catalog's order:
 * default free > paid purchase > pass > limited free. Paid purchases and the
 * Huawei pass come from the device (IapEntitlements) and ignore the server
 * snapshot lease; when both passes are live the Huawei one wins.
 */
function resolveItemAccess(itemKey: string, now: number): ItemAccess {
  const snapshot = entitlementSnapshot;
  const serverItem = snapshot?.bootstrap.items.find((entry) => entry.itemKey === itemKey);
  const serverExpiry = serverItem !== undefined ? snapshotItemExpiry(snapshot, serverItem, now) : 0;
  const serverReason = serverItem !== undefined ? serverItem.access.reason : 'LOCKED';
  if (serverExpiry > 0 && serverReason === 'DEFAULT_FREE') {
    return { reason: serverReason, expiry: serverExpiry };
  }
  const local = currentLocalIapState();
  if (localIapOwnedItemKeys(local).indexOf(itemKey) >= 0) {
    return { reason: ACCESS_IAP_PURCHASE, expiry: PERMANENT_EXPIRY };
  }
  // Catalog membership is configuration, not a grant, so an expired snapshot
  // still says which items the pass covers.
  const includedInPass = serverItem !== undefined ? serverItem.includedInPass
    : PASS_INCLUDED_ITEM_KEYS.indexOf(itemKey) >= 0;
  const huaweiPass = localIapPassExpiry(local, now);
  if (includedInPass && huaweiPass > 0) {
    return { reason: ACCESS_PASS_IAP, expiry: huaweiPass };
  }
  if (serverExpiry > 0) {
    return { reason: serverReason, expiry: serverExpiry };
  }
  return { reason: 'LOCKED', expiry: 0 };
}

function candidateItemKeys(): string[] {
  const keys: string[] = PASS_INCLUDED_ITEM_KEYS.slice();
  const items = entitlementSnapshot?.bootstrap.items ?? [];
  for (let i = 0; i < items.length; i++) {
    if (keys.indexOf(items[i].itemKey) < 0) { keys.push(items[i].itemKey); }
  }
  const purchases = currentLocalIapState().purchases;
  for (let i = 0; i < purchases.length; i++) {
    const key = itemKeyForProductId(purchases[i].productId);
    if (key.length > 0 && keys.indexOf(key) < 0) { keys.push(key); }
  }
  return keys;
}

function characterKeyOf(itemKey: string): string {
  if (!itemKey.startsWith('character.')) { return ''; }
  const key = itemKey.substring('character.'.length);
  // The obsolete free matchman identity must not unlock the paid lamp.
  return key === 'matchman' ? '' : key;
}

/** Effective pass end across the Huawei pass and a server gift pass. */
function effectivePassExpiry(now: number): number {
  return Math.max(localIapPassExpiry(currentLocalIapState(), now), snapshotPassExpiry(entitlementSnapshot, now));
}

interface EffectivePass {
  status: string;
  expiresAt: string;
  autoRenewing: boolean;
  source: string;
  iapPurchaseAllowed: boolean;
}

function effectivePass(now: number): EffectivePass {
  const localPass = currentLocalIapState().pass;
  const huaweiExpiry = localIapPassExpiry(currentLocalIapState(), now);
  if (localPass !== null && huaweiExpiry > 0) {
    return {
      status: localPass.status, expiresAt: new Date(huaweiExpiry).toISOString(),
      autoRenewing: localPass.autoRenewing, source: ACCESS_PASS_IAP, iapPurchaseAllowed: false
    };
  }
  const pass = entitlementSnapshot?.bootstrap.pass;
  const giftActive = snapshotPassExpiry(entitlementSnapshot, now) > 0;
  return {
    status: pass?.status ?? '',
    expiresAt: pass?.expiresAt ?? '',
    autoRenewing: pass?.autoRenewing === true,
    source: pass?.source ?? '',
    // Any live pass blocks buying a second one in the normal flow; the server
    // can also block it explicitly, but only while its snapshot is still valid.
    iapPurchaseAllowed: !giftActive &&
      !(isEntitlementSnapshotUsable(entitlementSnapshot, now) && pass?.iapPurchaseAllowed === false)
  };
}

/** A live Huawei auto-renew pass blocks redeeming a gift pass (client-only rule since 2026-11-03). */
export function isHuaweiPassActive(now: number = Date.now()): boolean {
  return localIapPassExpiry(currentLocalIapState(), now) > 0;
}

function projectEntitlementSnapshot(now: number): void {
  const snapshot = entitlementSnapshot;
  const bootstrap = snapshot?.bootstrap;
  const usable = isEntitlementSnapshotUsable(snapshot, now);
  const characters: string[] = [];
  const scenes: string[] = DEFAULT_SCENES.slice();
  const limited: string[] = [];
  const limitedAccess: string[] = [];
  let proActive = false;
  const keys = candidateItemKeys();
  for (let i = 0; i < keys.length; i++) {
    const access = resolveItemAccess(keys[i], now);
    if (access.expiry <= 0) { continue; }
    const characterKey = characterKeyOf(keys[i]);
    if (characterKey.length > 0) {
      characters.push(characterKey);
      if (access.reason === 'LIMITED_FREE') {
        limited.push(characterKey);
        limitedAccess.push(JSON.stringify({ key: characterKey, endsAt: new Date(access.expiry).toISOString() }));
      }
    } else if (keys[i].startsWith('scene.')) {
      const key = keys[i].substring('scene.'.length);
      if (key.length > 0 && scenes.indexOf(key) < 0) { scenes.push(key); }
    } else if (keys[i] === 'feature.pro_drum_machine') {
      proActive = true;
    }
  }
  characters.sort();
  const monthly = effectivePassExpiry(now) > 0;
  const pass = effectivePass(now);
  const charactersJson = JSON.stringify(characters);
  const scenesJson = JSON.stringify(scenes);
  const limitedJson = JSON.stringify(limited);
  const limitedAccessJson = `[${limitedAccess.join(',')}]`;
  const fingerprint = JSON.stringify({
    catalog: bootstrap === undefined ? '' : entitlementSnapshotFingerprint(bootstrap),
    usable,
    characters: charactersJson,
    scenes: scenesJson,
    limited: limitedJson,
    // TTL renewal is metadata, not a visible change. Include which grants are
    // active, while leaving their lease timestamps out of UI comparison.
    monthly,
    proActive,
    // Pass status/source changes (e.g. auto-renew cancelled) are visible too.
    pass: JSON.stringify(pass)
  });
  const changed = fingerprint !== projectedEntitlementFingerprint;
  // Observers can synchronously call getters. Commit the comparison state before
  // publishing any revision, and publish only after every projected field is set.
  projectedEntitlementFingerprint = fingerprint;
  setString('storeOwnedCharacters', charactersJson);
  setString('storeOwnedScenes', scenesJson);
  setBoolean('storePassActive', monthly);
  setBoolean('storeProDrumMachine', proActive || monthly);
  setString('storePassStatus', pass.status);
  setString('storePassExpiresAt', pass.expiresAt);
  setBoolean('storePassAutoRenewing', pass.autoRenewing);
  setString('storePassSource', pass.source);
  setBoolean('storePassIapPurchaseAllowed', pass.iapPurchaseAllowed);
  setBoolean('storeRedemptionAvailable', bootstrap?.redemption.available === true);
  setString('storeLimitedFreeCharacters', limitedJson);
  setString('storeLimitedFreeCharacterAccess', limitedAccessJson);
  setString('storeBootstrapCache', bootstrap === undefined ? '' : JSON.stringify(bootstrap));
  const updatedAt = snapshot?.updatedAt ?? 0;
  if (AppStorage.get<number>('storeEntitlementUpdatedAt') !== updatedAt) {
    AppStorage.setOrCreate('storeEntitlementUpdatedAt', updatedAt);
  }
  AppStorage.setOrCreate('storeEntitlementCacheSchema', ENTITLEMENT_CACHE_SCHEMA);
  if (changed) {
    AppStorage.setOrCreate('storeEntitlementEpoch', (AppStorage.get<number>('storeEntitlementEpoch') ?? 0) + 1);
  }
}

/** Unverified AppStorage flags and legacy simulated purchases are never entitlement authority. */
export function initializeEntitlementCache(): void {
  setLocalIapChangeListener(() => projectEntitlementSnapshot(Date.now()));
  projectEntitlementSnapshot(Date.now());
}

export function applyStoreBootstrap(bootstrap: StoreBootstrap): void {
  const sanitized = sanitizeEntitlementBootstrap(bootstrap);
  if (sanitized === undefined) { return; }
  const serverTime = Date.parse(sanitized.serverTime);
  if (!Number.isFinite(serverTime) ||
    (entitlementSnapshot !== undefined && serverTime < snapshotServerTime(entitlementSnapshot)) ||
    (monthlyPassSummary !== undefined && serverTime < monthlyPassSummary.capturedAt)) { return; }
  if (!acceptMonthlyPassSummary(sanitized)) { return; }
  entitlementSnapshot = { version: 1, updatedAt: Date.now(), bootstrap: sanitized };
  entitlementRevision++;
  persistEntitlementSnapshot();
  projectEntitlementSnapshot(Date.now());
}

export function ownedCharacterKeys(): string[] {
  initializeEntitlementCache();
  const now = Date.now();
  const keys = candidateItemKeys();
  const owned: string[] = [];
  for (let i = 0; i < keys.length; i++) {
    const key = characterKeyOf(keys[i]);
    if (key.length > 0 && resolveItemAccess(keys[i], now).expiry > 0) { owned.push(key); }
  }
  return owned.sort();
}

export function ownedSceneKeys(): string[] {
  initializeEntitlementCache();
  const now = Date.now();
  const scenes = DEFAULT_SCENES.slice();
  const keys = candidateItemKeys();
  for (let i = 0; i < keys.length; i++) {
    const key = keys[i].substring('scene.'.length);
    if (keys[i].startsWith('scene.') && key.length > 0 && scenes.indexOf(key) < 0 &&
      resolveItemAccess(keys[i], now).expiry > 0) { scenes.push(key); }
  }
  return scenes;
}

export function limitedFreeCharacterKeys(): string[] {
  initializeEntitlementCache();
  const now = Date.now();
  const keys = candidateItemKeys();
  const limited: string[] = [];
  for (let i = 0; i < keys.length; i++) {
    const key = characterKeyOf(keys[i]);
    const access = resolveItemAccess(keys[i], now);
    if (key.length > 0 && access.expiry > 0 && access.reason === 'LIMITED_FREE') { limited.push(key); }
  }
  return limited.sort();
}

export function storeItemAccessReason(itemKey: string): string {
  initializeEntitlementCache();
  const access = resolveItemAccess(itemKey, Date.now());
  return access.expiry > 0 ? access.reason : 'LOCKED';
}

export function isCharacterAccessible(key: string): boolean {
  return ownedCharacterKeys().indexOf(key) >= 0;
}

export function isSceneAccessible(key: string): boolean {
  return ownedSceneKeys().indexOf(key) >= 0;
}

export function isProDrumMachineAccessible(): boolean {
  return resolveDrumAccess().allowed;
}

export interface DrumAccess {
  allowed: boolean;
  source: string;
  expiresAt: number;
}

/** Calendar rewards never change the audio clock; this anchor only ages access. */
export function currentDrumAccessTime(): number {
  const wallAnchor = AppStorage.get<number>('shareTrialClockWallAnchor') ?? 0;
  const monoAnchor = AppStorage.get<number>('shareTrialClockMonoAnchor') ?? 0;
  const lastObserved = AppStorage.get<number>('shareLastObservedWallMs') ?? 0;
  const elapsed = wallAnchor > 0 ? Math.max(0, MonotonicClock.nowMs() - monoAnchor) : 0;
  return Math.max(Date.now(), lastObserved, wallAnchor + elapsed);
}

export function isMonthlyPassActive(now: number = Date.now()): boolean {
  projectEntitlementSnapshot(now);
  return effectivePassExpiry(now) > 0;
}

export function resolveDrumAccess(now?: number): DrumAccess {
  // The campaign's rollback floor only restricts its own trial. An anomalous
  // local check-in clock must not revoke otherwise valid paid membership.
  const formalNow = now ?? Date.now();
  const trialNow = now ?? currentDrumAccessTime();
  projectEntitlementSnapshot(formalNow);
  const passExpiry = effectivePassExpiry(formalNow);
  if (passExpiry > 0) {
    return { allowed: true, source: 'monthly', expiresAt: passExpiry };
  }
  const feature = resolveItemAccess('feature.pro_drum_machine', formalNow);
  if (feature.expiry > 0) {
    return { allowed: true, source: 'owned', expiresAt: feature.expiry };
  }
  // Local share rewards have their own durable ledger and clock. Expiring a
  // server snapshot cannot revoke or extend an independently granted trial.
  const trialExpiresAt = AppStorage.get<number>('shareTrialExpiresAt') ?? 0;
  if (trialExpiresAt > trialNow) {
    return { allowed: true, source: 'trial', expiresAt: trialExpiresAt };
  }
  return { allowed: false, source: 'locked', expiresAt: 0 };
}

/** All campaign dates and deadlines are shown in Beijing time on every device. */
export function formatTrialExpiry(ms: number): string {
  if (!Number.isFinite(ms) || ms <= 0) {
    return '';
  }
  const date = new Date(ms + 8 * 3600000);
  const month = `${date.getUTCMonth() + 1}`.padStart(2, '0');
  const day = `${date.getUTCDate()}`.padStart(2, '0');
  const hour = `${date.getUTCHours()}`.padStart(2, '0');
  const minute = `${date.getUTCMinutes()}`.padStart(2, '0');
  return `${month}/${day} ${hour}:${minute}`;
}
