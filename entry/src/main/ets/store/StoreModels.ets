export interface StoreAccess {
  allowed: boolean;
  reason: string;
  validUntil?: string | null;
}

export interface StoreFreeWindow {
  startsAt: string;
  endsAt: string;
}

export interface StoreItemSnapshot {
  itemKey: string;
  displayName: string;
  kind: string;
  huaweiProductId?: string;
  iapProductType?: string;
  defaultFree: boolean;
  includedInPass: boolean;
  repeatableChoice?: boolean;
  access: StoreAccess;
  freeWindow?: StoreFreeWindow | null;
}

export interface StorePassSnapshot {
  active: boolean;
  source?: string;
  status?: string;
  expiresAt?: string | null;
  autoRenewing: boolean;
  iapPurchaseAllowed: boolean;
  iapPurchaseBlockedReason?: string;
}

export interface StoreRedemptionSnapshot {
  available: boolean;
}

export interface StoreBootstrap {
  serverTime: string;
  configVersion: string;
  developerPayload?: string;
  pass: StorePassSnapshot;
  items: StoreItemSnapshot[];
  redemption: StoreRedemptionSnapshot;
}

export interface StoreBootstrapEnvelope {
  code: number;
  message: string;
  data: StoreBootstrap;
}

export interface StoreSessionUser {
  id: string;
}

export interface StoreSession {
  accessToken: string;
  expiresAt: string;
  user: StoreSessionUser;
}

export interface StoreSessionEnvelope {
  code: number;
  message: string;
  data: StoreSession;
}

export interface StorePurchaseSubmission {
  idempotencyKey: string;
  productId: string;
  purchaseData: string;
}

export interface StoreRedemptionRequest {
  idempotencyKey: string;
  code: string;
}

export interface StoreRedemptionResult {
  campaignKey: string;
  redeemedAt: string;
  grantStartsAt: string;
  grantEndsAt: string;
  pass: StorePassSnapshot;
}

export interface StoreRedemptionEnvelope {
  code: number;
  message: string;
  data: StoreRedemptionResult;
}
