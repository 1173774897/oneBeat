import { StoreBootstrap } from './StoreModels';
import { MonotonicClock } from '../common/MonotonicClock';
import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';

const ENTITLEMENT_CACHE_SCHEMA: number = 5;
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

function setMonthlyPassKnown(known: boolean): void {
  monthlyPassKnown = known;
  AppStorage.setOrCreate('monthlyPassRewardStateKnown', known);
}

function projectRestoredMonthlyPass(summary: MonthlyPassSummary): void {
  AppStorage.setOrCreate('storePassActive', summary.active);
  AppStorage.setOrCreate('storePassExpiresAt', summary.expiresAt);
  AppStorage.setOrCreate('storeEntitlementEpoch', (AppStorage.get<number>('storeEntitlementEpoch') ?? 0) + 1);
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
    projectRestoredMonthlyPass(restored);
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
  return monthlyPassKnown;
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

function normalizeCharacterKey(key: string): string {
  // Legacy matchman was a free default and must not silently grant the new paid lamp.
  return key === 'matchman' ? '' : key;
}

interface LimitedFreeCharacterAccess {
  key: string;
  endsAt: string;
}

function parseStringArray(raw: string, fallback: string[]): string[] {
  if (raw.length === 0) {
    return fallback.slice();
  }
  try {
    return JSON.parse(raw) as string[];
  } catch (_e) {
    return fallback.slice();
  }
}

function writeSnapshot(characters: string[], scenes: string[], passActive: boolean, proActive: boolean): void {
  AppStorage.setOrCreate('storeOwnedCharacters', JSON.stringify(characters));
  AppStorage.setOrCreate('storeOwnedScenes', JSON.stringify(scenes));
  AppStorage.setOrCreate('storePassActive', passActive);
  AppStorage.setOrCreate('storeProDrumMachine', proActive);
  const epoch = AppStorage.get<number>('storeEntitlementEpoch') ?? 0;
  AppStorage.setOrCreate('storeEntitlementEpoch', epoch + 1);
}

function activeLimitedFreeCharacters(): LimitedFreeCharacterAccess[] {
  const raw = AppStorage.get<string>('storeLimitedFreeCharacterAccess') ?? '';
  if (raw.length === 0) {
    return [];
  }
  try {
    const entries = JSON.parse(raw) as LimitedFreeCharacterAccess[];
    const now = Date.now();
    // Bootstrap data is cached for offline startup, so enforce validUntil again
    // locally instead of letting yesterday's promotion remain unlocked forever.
    return entries.filter((entry: LimitedFreeCharacterAccess) => {
      const expiresAt = Date.parse(entry.endsAt);
      return Number.isFinite(expiresAt) && expiresAt > now;
    });
  } catch (_e) {
    return [];
  }
}

export function initializeEntitlementCache(): void {
  const schema = AppStorage.get<number>('storeEntitlementCacheSchema') ?? 0;
  if (schema >= ENTITLEMENT_CACHE_SCHEMA) {
    return;
  }
  if (schema < ENTITLEMENT_CACHE_SCHEMA) {
    const rawChars = AppStorage.get<string>('storeOwnedCharacters') ?? '';
    if (rawChars.length > 0) {
      try {
        const parsed = JSON.parse(rawChars) as string[];
        let changed = false;
        const migrated: string[] = [];
        for (let i = 0; i < parsed.length; i++) {
          const key = parsed[i] === 'matchman' ? 'lamp' : parsed[i];
          if (key !== parsed[i]) {
            changed = true;
          }
          // Schema 4 granted lamp to everyone as the old default. Schema 5 makes
          // it a paid exclusive; a fresh server bootstrap can grant it back when
          // the account owns the product or an active pass.
          if (schema < 5 && key === 'lamp') {
            changed = true;
            continue;
          }
          if (migrated.indexOf(key) < 0) {
            migrated.push(key);
          }
        }
        if (changed) {
          AppStorage.setOrCreate('storeOwnedCharacters', JSON.stringify(migrated));
        }
      } catch (_e) {
      }
    }
  }
  if (schema < 1) {
    // Old builds stored simulated purchases locally. They are not valid receipts.
    writeSnapshot(DEFAULT_CHARACTERS, DEFAULT_SCENES, false, false);
    AppStorage.setOrCreate('storePassStatus', '');
    AppStorage.setOrCreate('storePassExpiresAt', '');
    AppStorage.setOrCreate('storePassAutoRenewing', false);
  }
  AppStorage.setOrCreate('storePassSource', '');
  AppStorage.setOrCreate('storePassIapPurchaseAllowed', true);
  AppStorage.setOrCreate('storeRedemptionAvailable', false);
  AppStorage.setOrCreate('storeLimitedFreeCharacters', '[]');
  AppStorage.setOrCreate('storeLimitedFreeCharacterAccess', '[]');
  AppStorage.setOrCreate('storeEntitlementCacheSchema', ENTITLEMENT_CACHE_SCHEMA);
}

export function applyStoreBootstrap(bootstrap: StoreBootstrap): void {
  if (!acceptMonthlyPassSummary(bootstrap)) {
    return;
  }
  const characters: string[] = [];
  const scenes: string[] = [];
  let proActive = false;
  const limitedFreeCharacters: string[] = [];
  const limitedFreeAccess: LimitedFreeCharacterAccess[] = [];
  for (let i = 0; i < bootstrap.items.length; i++) {
    const item = bootstrap.items[i];
    if (!item.access.allowed) {
      continue;
    }
    if (item.itemKey.startsWith('character.')) {
      const characterKey = normalizeCharacterKey(item.itemKey.substring('character.'.length));
      if (characterKey.length === 0) {
        continue;
      }
      if (characters.indexOf(characterKey) < 0) {
        characters.push(characterKey);
      }
      if (item.access.reason === 'LIMITED_FREE') {
        limitedFreeCharacters.push(characterKey);
        const endsAt = item.access.validUntil ?? item.freeWindow?.endsAt ?? '';
        limitedFreeAccess.push({ key: characterKey, endsAt: endsAt });
      }
    } else if (item.itemKey.startsWith('scene.')) {
      scenes.push(item.itemKey.substring('scene.'.length));
    } else if (item.itemKey === 'feature.pro_drum_machine') {
      proActive = true;
    }
  }
  if (scenes.indexOf('sunset_coast') < 0) {
    scenes.push('sunset_coast');
  }
  writeSnapshot(characters, scenes, bootstrap.pass.active, proActive || bootstrap.pass.active);
  AppStorage.setOrCreate('storePassStatus', bootstrap.pass.status ?? '');
  AppStorage.setOrCreate('storePassExpiresAt', bootstrap.pass.expiresAt ?? '');
  AppStorage.setOrCreate('storePassAutoRenewing', bootstrap.pass.autoRenewing);
  AppStorage.setOrCreate('storePassSource', bootstrap.pass.source ?? '');
  AppStorage.setOrCreate('storePassIapPurchaseAllowed', bootstrap.pass.iapPurchaseAllowed);
  AppStorage.setOrCreate('storeRedemptionAvailable', bootstrap.redemption.available);
  AppStorage.setOrCreate('storeLimitedFreeCharacters', JSON.stringify(limitedFreeCharacters));
  AppStorage.setOrCreate('storeLimitedFreeCharacterAccess', JSON.stringify(limitedFreeAccess));
  AppStorage.setOrCreate('storeBootstrapCache', JSON.stringify(bootstrap));
  AppStorage.setOrCreate('storeEntitlementCacheSchema', ENTITLEMENT_CACHE_SCHEMA);

  const selectedScene = AppStorage.get<string>('selectedSceneKey') ?? 'sunset_coast';
  if (scenes.indexOf(selectedScene) < 0) {
    AppStorage.setOrCreate('selectedSceneKey', 'sunset_coast');
  }
}

export function ownedCharacterKeys(): string[] {
  initializeEntitlementCache();
  const characters = parseStringArray(AppStorage.get<string>('storeOwnedCharacters') ?? '', DEFAULT_CHARACTERS);
  const cachedLimited = parseStringArray(AppStorage.get<string>('storeLimitedFreeCharacters') ?? '', []);
  const activeLimited = activeLimitedFreeCharacters().map((entry: LimitedFreeCharacterAccess) => entry.key);
  // Remove only expired promotional entries; permanent purchases and pass access
  // in the same cached snapshot remain untouched.
  return characters.filter((key: string) => cachedLimited.indexOf(key) < 0 || activeLimited.indexOf(key) >= 0);
}

export function ownedSceneKeys(): string[] {
  initializeEntitlementCache();
  return parseStringArray(AppStorage.get<string>('storeOwnedScenes') ?? '', DEFAULT_SCENES);
}

export function limitedFreeCharacterKeys(): string[] {
  initializeEntitlementCache();
  return activeLimitedFreeCharacters().map((entry: LimitedFreeCharacterAccess) => entry.key);
}

export function storeItemAccessReason(itemKey: string): string {
  initializeEntitlementCache();
  const raw = AppStorage.get<string>('storeBootstrapCache') ?? '';
  if (raw.length === 0) {
    return 'LOCKED';
  }
  try {
    const bootstrap = JSON.parse(raw) as StoreBootstrap;
    for (let i = 0; i < bootstrap.items.length; i++) {
      const item = bootstrap.items[i];
      if (item.itemKey !== itemKey) {
        continue;
      }
      const validUntil = item.access.validUntil ?? '';
      if (validUntil.length > 0) {
        const expiresAt = Date.parse(validUntil);
        if (Number.isFinite(expiresAt) && expiresAt <= Date.now()) {
          return 'LOCKED';
        }
      }
      return item.access.reason;
    }
  } catch (_e) {
  }
  return 'LOCKED';
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
  initializeEntitlementCache();
  if (AppStorage.get<boolean>('storePassActive') !== true) {
    return false;
  }
  const expiresAt = Date.parse(AppStorage.get<string>('storePassExpiresAt') ?? '');
  return Number.isFinite(expiresAt) && expiresAt > now;
}

export function resolveDrumAccess(now?: number): DrumAccess {
  initializeEntitlementCache();
  // The campaign's rollback floor only restricts its own trial. An anomalous
  // local check-in clock must not revoke otherwise valid paid membership.
  const formalNow = now ?? Date.now();
  const trialNow = now ?? currentDrumAccessTime();
  if (isMonthlyPassActive(formalNow)) {
    return { allowed: true, source: 'monthly',
      expiresAt: Date.parse(AppStorage.get<string>('storePassExpiresAt') ?? '') };
  }
  const raw = AppStorage.get<string>('storeBootstrapCache') ?? '';
  if (raw.length > 0) {
    try {
      const bootstrap = JSON.parse(raw) as StoreBootstrap;
      const feature = bootstrap.items.find((item) => item.itemKey === 'feature.pro_drum_machine');
      if (feature !== undefined && feature.access.allowed) {
        const expiry = feature.access.validUntil ?? '';
        const expiresAt = expiry.length > 0 ? Date.parse(expiry) : 0;
        const reason = feature.access.reason.toUpperCase();
        // A pass-derived cached feature cannot outlive the pass. Independent
        // purchased/promotional access may still have its own valid deadline.
        const passDerived = reason.indexOf('PASS') >= 0 || reason.indexOf('SUBSCRIPTION') >= 0;
        if (!passDerived && (expiresAt > formalNow || (expiresAt === 0 && !bootstrap.pass.active))) {
          return { allowed: true, source: 'owned', expiresAt };
        }
      }
    } catch (_e) {
    }
  } else if (AppStorage.get<boolean>('storeProDrumMachine') === true &&
    AppStorage.get<boolean>('storePassActive') !== true) {
    return { allowed: true, source: 'owned', expiresAt: 0 };
  }
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
