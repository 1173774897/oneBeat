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

const ENTITLEMENT_CACHE_SCHEMA: number = 6;
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
      // Persist only membership facts. Bootstrap also carries purchase binding
      // data, which must never be copied into this independent local cache.
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

function projectEntitlementSnapshot(now: number): void {
  const snapshot = entitlementSnapshot;
  const bootstrap = snapshot?.bootstrap;
  const usable = isEntitlementSnapshotUsable(snapshot, now);
  const characters: string[] = [];
  const scenes: string[] = DEFAULT_SCENES.slice();
  const limited: string[] = [];
  const limitedAccess: string[] = [];
  let proActive = false;
  if (bootstrap !== undefined) {
    for (let i = 0; i < bootstrap.items.length; i++) {
      const item = bootstrap.items[i];
      const expiry = snapshotItemExpiry(snapshot, item, now);
      if (expiry <= 0) { continue; }
      if (item.itemKey.startsWith('character.')) {
        const key = item.itemKey.substring('character.'.length);
        // The obsolete free matchman identity must not unlock the paid lamp.
        if (key.length === 0 || key === 'matchman') { continue; }
        characters.push(key);
        if (item.access.reason === 'LIMITED_FREE') {
          limited.push(key);
          limitedAccess.push(JSON.stringify({ key, endsAt: new Date(expiry).toISOString() }));
        }
      } else if (item.itemKey.startsWith('scene.')) {
        const key = item.itemKey.substring('scene.'.length);
        if (key.length > 0 && scenes.indexOf(key) < 0) { scenes.push(key); }
      } else if (item.itemKey === 'feature.pro_drum_machine') {
        proActive = true;
      }
    }
  }
  const monthly = snapshotPassExpiry(snapshot, now) > 0;
  const charactersJson = JSON.stringify(characters);
  const scenesJson = JSON.stringify(scenes);
  const limitedJson = JSON.stringify(limited);
  const limitedAccessJson = `[${limitedAccess.join(',')}]`;
  const pass = bootstrap?.pass;
  const fingerprint = JSON.stringify({
    catalog: bootstrap === undefined ? '' : entitlementSnapshotFingerprint(bootstrap),
    usable,
    characters: charactersJson,
    scenes: scenesJson,
    limited: limitedJson,
    // TTL renewal is metadata, not a visible change. Include which grants are
    // active, while leaving their lease timestamps out of UI comparison.
    monthly,
    proActive
  });
  const changed = fingerprint !== projectedEntitlementFingerprint;
  // Observers can synchronously call getters. Commit the comparison state before
  // publishing any revision, and publish only after every projected field is set.
  projectedEntitlementFingerprint = fingerprint;
  setString('storeOwnedCharacters', charactersJson);
  setString('storeOwnedScenes', scenesJson);
  setBoolean('storePassActive', monthly);
  setBoolean('storeProDrumMachine', proActive || monthly);
  setString('storePassStatus', pass?.status ?? '');
  setString('storePassExpiresAt', pass?.expiresAt ?? '');
  setBoolean('storePassAutoRenewing', pass?.autoRenewing === true);
  setString('storePassSource', pass?.source ?? '');
  setBoolean('storePassIapPurchaseAllowed', pass?.iapPurchaseAllowed !== false);
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
  const snapshot = entitlementSnapshot;
  const bootstrap = snapshot?.bootstrap;
  if (bootstrap === undefined) { return DEFAULT_CHARACTERS.slice(); }
  const now = Date.now();
  return bootstrap.items.filter((item) => item.itemKey.startsWith('character.') &&
    item.itemKey.length > 'character.'.length && item.itemKey !== 'character.matchman' &&
    snapshotItemExpiry(snapshot, item, now) > 0)
    .map((item) => item.itemKey.substring('character.'.length));
}

export function ownedSceneKeys(): string[] {
  initializeEntitlementCache();
  const snapshot = entitlementSnapshot;
  const bootstrap = snapshot?.bootstrap;
  const scenes = DEFAULT_SCENES.slice();
  if (bootstrap !== undefined) {
    const now = Date.now();
    for (let i = 0; i < bootstrap.items.length; i++) {
      const item = bootstrap.items[i];
      const key = item.itemKey.substring('scene.'.length);
      if (item.itemKey.startsWith('scene.') && key.length > 0 && scenes.indexOf(key) < 0 &&
        snapshotItemExpiry(snapshot, item, now) > 0) { scenes.push(key); }
    }
  }
  return scenes;
}

export function limitedFreeCharacterKeys(): string[] {
  initializeEntitlementCache();
  const snapshot = entitlementSnapshot;
  const now = Date.now();
  return (snapshot?.bootstrap.items ?? []).filter((item) => item.itemKey.startsWith('character.') &&
    item.itemKey.length > 'character.'.length && item.itemKey !== 'character.matchman' &&
    item.access.reason === 'LIMITED_FREE' && snapshotItemExpiry(snapshot, item, now) > 0)
    .map((item) => item.itemKey.substring('character.'.length));
}

export function storeItemAccessReason(itemKey: string): string {
  initializeEntitlementCache();
  const snapshot = entitlementSnapshot;
  const item = snapshot?.bootstrap.items.find((entry) => entry.itemKey === itemKey);
  return item !== undefined && snapshotItemExpiry(snapshot, item, Date.now()) > 0 ? item.access.reason : 'LOCKED';
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
  return snapshotPassExpiry(entitlementSnapshot, now) > 0;
}

export function resolveDrumAccess(now?: number): DrumAccess {
  // The campaign's rollback floor only restricts its own trial. An anomalous
  // local check-in clock must not revoke otherwise valid paid membership.
  const formalNow = now ?? Date.now();
  const trialNow = now ?? currentDrumAccessTime();
  projectEntitlementSnapshot(formalNow);
  const passExpiry = snapshotPassExpiry(entitlementSnapshot, formalNow);
  if (passExpiry > 0) {
    return { allowed: true, source: 'monthly', expiresAt: passExpiry };
  }
  const snapshot = entitlementSnapshot;
  const feature = snapshot?.bootstrap.items.find((item) => item.itemKey === 'feature.pro_drum_machine');
  if (feature !== undefined) {
    const expiry = snapshotItemExpiry(snapshot, feature, formalNow);
    if (expiry > 0) { return { allowed: true, source: 'owned', expiresAt: expiry }; }
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
