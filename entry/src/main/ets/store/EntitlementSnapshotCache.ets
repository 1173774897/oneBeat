import { StoreBootstrap, StoreItemSnapshot, StorePassSnapshot } from './StoreModels';

export const ENTITLEMENT_SNAPSHOT_MAX_AGE_MS: number = 30 * 24 * 60 * 60 * 1000;

/** updatedAt is the successful fetch time, never the restore/read time. */
export interface EntitlementSnapshot {
  version: number;
  updatedAt: number;
  bootstrap: StoreBootstrap;
}

function text(value: string | null | undefined): string {
  return typeof value === 'string' ? value.trim() : '';
}

function dateText(value: string | null | undefined): string {
  const raw = text(value);
  const parsed = Date.parse(raw);
  // Invalid nonempty deadlines must remain invalid, rather than becoming a
  // missing deadline that could accidentally turn a grant into a permanent one.
  return Number.isFinite(parsed) ? new Date(parsed).toISOString() : raw;
}

function sanitizePass(pass: StorePassSnapshot): StorePassSnapshot {
  return {
    active: pass.active,
    source: text(pass.source),
    status: text(pass.status),
    expiresAt: dateText(pass.expiresAt),
    autoRenewing: pass.autoRenewing === true,
    iapPurchaseAllowed: pass.iapPurchaseAllowed !== false,
    iapPurchaseBlockedReason: text(pass.iapPurchaseBlockedReason)
  };
}

function sanitizeItem(item: StoreItemSnapshot): StoreItemSnapshot {
  return {
    itemKey: item.itemKey.trim(),
    displayName: text(item.displayName),
    kind: text(item.kind),
    huaweiProductId: text(item.huaweiProductId),
    iapProductType: text(item.iapProductType),
    defaultFree: item.defaultFree === true,
    includedInPass: item.includedInPass === true,
    repeatableChoice: item.repeatableChoice === true,
    access: {
      allowed: item.access.allowed,
      reason: text(item.access.reason).toUpperCase(),
      validUntil: dateText(item.access.validUntil)
    },
    freeWindow: item.freeWindow === undefined || item.freeWindow === null ? null : {
      startsAt: dateText(item.freeWindow.startsAt), endsAt: dateText(item.freeWindow.endsAt)
    }
  };
}

/** Whitelist public catalog/access facts; account binding and receipt data never reach disk. */
export function sanitizeEntitlementBootstrap(raw: StoreBootstrap): StoreBootstrap | undefined {
  if (raw === null || typeof raw !== 'object' || Array.isArray(raw) ||
    raw.pass === null || typeof raw.pass !== 'object' || Array.isArray(raw.pass) ||
    typeof raw.pass.active !== 'boolean' || !Array.isArray(raw.items) ||
    (raw.pass.expiresAt !== undefined && raw.pass.expiresAt !== null && typeof raw.pass.expiresAt !== 'string') ||
    raw.redemption === null || typeof raw.redemption !== 'object' || Array.isArray(raw.redemption) ||
    typeof raw.redemption.available !== 'boolean') {
    return undefined;
  }
  const items: StoreItemSnapshot[] = [];
  const keys: Set<string> = new Set<string>();
  for (let i = 0; i < raw.items.length; i++) {
    const item = raw.items[i];
    if (item === null || typeof item !== 'object' || Array.isArray(item) ||
      typeof item.itemKey !== 'string' || item.itemKey.trim().length === 0 ||
      item.access === null || typeof item.access !== 'object' || Array.isArray(item.access) ||
      typeof item.access.allowed !== 'boolean' || typeof item.access.reason !== 'string' ||
      (item.access.validUntil !== undefined && item.access.validUntil !== null &&
        typeof item.access.validUntil !== 'string') ||
      (item.freeWindow !== undefined && item.freeWindow !== null &&
        (typeof item.freeWindow !== 'object' || Array.isArray(item.freeWindow) ||
          typeof item.freeWindow.startsAt !== 'string' || typeof item.freeWindow.endsAt !== 'string'))) {
      return undefined;
    }
    const sanitized = sanitizeItem(item);
    // Duplicate keys are ambiguous authority, so do not pick a grant according
    // to server array order. A malformed response must not refresh the TTL.
    if (keys.has(sanitized.itemKey)) { return undefined; }
    keys.add(sanitized.itemKey);
    items.push(sanitized);
  }
  items.sort((left: StoreItemSnapshot, right: StoreItemSnapshot) =>
    left.itemKey < right.itemKey ? -1 : left.itemKey > right.itemKey ? 1 : 0);
  return {
    serverTime: dateText(raw.serverTime),
    configVersion: text(raw.configVersion),
    pass: sanitizePass(raw.pass),
    items,
    redemption: { available: raw.redemption.available }
  };
}

/** Server time orders responses; local updatedAt bounds offline use. */
export function snapshotServerTime(snapshot: EntitlementSnapshot): number {
  return Date.parse(snapshot.bootstrap.serverTime);
}

export function restoreEntitlementSnapshot(raw: string): EntitlementSnapshot | undefined {
  try {
    const value = JSON.parse(raw) as EntitlementSnapshot;
    if (value === null || typeof value !== 'object' || Array.isArray(value) || value.version !== 1 ||
      !Number.isFinite(value.updatedAt) || value.updatedAt <= 0) { return undefined; }
    const bootstrap = sanitizeEntitlementBootstrap(value.bootstrap);
    if (bootstrap === undefined || !Number.isFinite(Date.parse(bootstrap.serverTime))) { return undefined; }
    return { version: 1, updatedAt: value.updatedAt, bootstrap };
  } catch (_error) {
    return undefined;
  }
}

export function isEntitlementSnapshotUsable(snapshot: EntitlementSnapshot | undefined, now: number): boolean {
  return snapshot !== undefined && Number.isFinite(now) && now >= snapshot.updatedAt &&
    now < snapshot.updatedAt + ENTITLEMENT_SNAPSHOT_MAX_AGE_MS;
}

export function entitlementSnapshotFingerprint(bootstrap: StoreBootstrap): string {
  // Publication follows user-visible catalog/access facts, not response time,
  // request ordering, purchase bindings, or an otherwise unchanged config tag.
  return JSON.stringify({ pass: bootstrap.pass, items: bootstrap.items, redemption: bootstrap.redemption });
}

export function snapshotPassExpiry(snapshot: EntitlementSnapshot | undefined, now: number): number {
  if (!isEntitlementSnapshotUsable(snapshot, now) || snapshot === undefined || !snapshot.bootstrap.pass.active) {
    return 0;
  }
  const expiry = Date.parse(snapshot.bootstrap.pass.expiresAt ?? '');
  return Number.isFinite(expiry) && expiry > now
    ? Math.min(expiry, snapshot.updatedAt + ENTITLEMENT_SNAPSHOT_MAX_AGE_MS) : 0;
}

export function snapshotItemExpiry(snapshot: EntitlementSnapshot | undefined,
  item: StoreItemSnapshot, now: number): number {
  if (!isEntitlementSnapshotUsable(snapshot, now) || snapshot === undefined || !item.access.allowed) { return 0; }
  let expiry = snapshot.updatedAt + ENTITLEMENT_SNAPSHOT_MAX_AGE_MS;
  const validUntil = item.access.validUntil ?? '';
  if (validUntil.length > 0) {
    const parsed = Date.parse(validUntil);
    if (!Number.isFinite(parsed)) { return 0; }
    expiry = Math.min(expiry, parsed);
  }
  const reason = item.access.reason;
  if (reason.indexOf('PASS') >= 0 || reason.indexOf('SUBSCRIPTION') >= 0) {
    const passExpiry = snapshotPassExpiry(snapshot, now);
    if (passExpiry <= 0) { return 0; }
    expiry = Math.min(expiry, passExpiry);
  }
  if (reason === 'LIMITED_FREE') {
    const end = item.freeWindow?.endsAt ?? '';
    if (end.length > 0) {
      const parsed = Date.parse(end);
      if (!Number.isFinite(parsed)) { return 0; }
      expiry = Math.min(expiry, parsed);
    } else if (validUntil.length === 0) {
      return 0;
    }
  }
  return expiry > now ? expiry : 0;
}
