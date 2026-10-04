import { StoreBootstrap } from './StoreModels';

const ENTITLEMENT_CACHE_SCHEMA: number = 5;
const DEFAULT_CHARACTERS: string[] = [];
const DEFAULT_SCENES: string[] = ['sunset_coast'];

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
  initializeEntitlementCache();
  return AppStorage.get<boolean>('storeProDrumMachine') === true;
}
