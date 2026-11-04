// On-device verification of Huawei IAP JWS purchase data (2026-11-03).
//
// Paid purchases no longer reach the Hong Kong store server (cross-border
// transfer of transaction records is avoided entirely), so the device is now the
// only place that checks them. This file is pure logic: platform crypto is
// injected through IapJwsCrypto so the same code runs under Node tests.
//
// Trust model, ported from the removed backend verifier:
// - every JWS must carry an ES256 signature that verifies with its x5c leaf;
// - NORMAL (production) purchases must also chain to an embedded Huawei root;
// - SANDBOX purchases verify the leaf only and are accepted only in debug builds.
// A modified client can still fake ownership; the signature only stops forged
// purchase data from being accepted by an unmodified app.

export const HUAWEI_IAP_APPLICATION_ID: string = '6917617181108973504';
export const HUAWEI_IAP_PACKAGE_NAME: string = 'com.onebeat.app';

export const IAP_ENVIRONMENT_NORMAL: string = 'NORMAL';
export const IAP_ENVIRONMENT_SANDBOX: string = 'SANDBOX';

export const IAP_PRODUCT_TYPE_NONCONSUMABLE: number = 1;
export const IAP_PRODUCT_TYPE_AUTORENEWABLE: number = 2;

export const IAP_PASS_ACTIVE: string = 'ACTIVE';
export const IAP_PASS_CANCELED_ACTIVE: string = 'CANCELED_ACTIVE';
export const IAP_PASS_EXPIRED: string = 'EXPIRED';
export const IAP_PASS_REVOKED: string = 'REVOKED';

/** Platform crypto. Both calls must resolve false (not throw) on a failed check. */
export interface IapJwsCrypto {
  verifyEs256(leafCertificateDer: Uint8Array, signingInput: Uint8Array, derSignature: Uint8Array): Promise<boolean>;
  /** chainDer is in x5c order (leaf first). */
  validateChain(chainDer: Uint8Array[], rootCertificatesDer: Uint8Array[]): Promise<boolean>;
}

export interface IapJwsPolicy {
  /** Debug builds only. Release builds must never accept sandbox purchases. */
  allowSandbox: boolean;
  /** Embedded Huawei IAP root(s) for NORMAL purchases. Empty fails closed. */
  rootCertificatesDer: Uint8Array[];
  /** Debug diagnostics: sees the public x5c chain before any trust decision. */
  observeChain?: (chainDer: Uint8Array[]) => void;
}

export class IapJwsError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'IapJwsError';
  }
}

interface JwsHeader {
  alg?: string;
  typ?: string;
  x5c?: string[];
}

export interface VerifiedJws {
  payloadJson: string;
  environment: string;
  chainDer: Uint8Array[];
}

const BASE64_ALPHABET: string = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';

/** Strict base64 / base64url decoding; throws on any character outside the alphabet. */
export function decodeBase64(input: string): Uint8Array {
  let text = input.trim().replace(/-/g, '+').replace(/_/g, '/');
  while (text.endsWith('=')) {
    text = text.substring(0, text.length - 1);
  }
  if (text.length % 4 === 1) {
    throw new IapJwsError('invalid base64 length');
  }
  const out: number[] = [];
  let buffer = 0;
  let bits = 0;
  for (let i = 0; i < text.length; i++) {
    const value = BASE64_ALPHABET.indexOf(text.charAt(i));
    if (value < 0) {
      throw new IapJwsError('invalid base64 character');
    }
    buffer = ((buffer << 6) | value) & 0xffffff;
    bits += 6;
    if (bits >= 8) {
      bits -= 8;
      out.push((buffer >> bits) & 0xff);
    }
  }
  return new Uint8Array(out);
}

export function encodeBase64(bytes: Uint8Array): string {
  let out = '';
  for (let i = 0; i < bytes.length; i += 3) {
    const a = bytes[i];
    const b = i + 1 < bytes.length ? bytes[i + 1] : 0;
    const c = i + 2 < bytes.length ? bytes[i + 2] : 0;
    const triple = (a << 16) | (b << 8) | c;
    out += BASE64_ALPHABET.charAt((triple >> 18) & 63) + BASE64_ALPHABET.charAt((triple >> 12) & 63);
    out += i + 1 < bytes.length ? BASE64_ALPHABET.charAt((triple >> 6) & 63) : '=';
    out += i + 2 < bytes.length ? BASE64_ALPHABET.charAt(triple & 63) : '=';
  }
  return out;
}

export function utf8Decode(bytes: Uint8Array): string {
  let out = '';
  let i = 0;
  while (i < bytes.length) {
    const first = bytes[i];
    let code = 0xfffd;
    let size = 1;
    if (first < 0x80) {
      code = first;
    } else if (first >= 0xc2 && first < 0xe0 && i + 1 < bytes.length) {
      code = ((first & 0x1f) << 6) | (bytes[i + 1] & 0x3f);
      size = 2;
    } else if (first >= 0xe0 && first < 0xf0 && i + 2 < bytes.length) {
      code = ((first & 0x0f) << 12) | ((bytes[i + 1] & 0x3f) << 6) | (bytes[i + 2] & 0x3f);
      size = 3;
    } else if (first >= 0xf0 && first < 0xf5 && i + 3 < bytes.length) {
      code = ((first & 0x07) << 18) | ((bytes[i + 1] & 0x3f) << 12) |
        ((bytes[i + 2] & 0x3f) << 6) | (bytes[i + 3] & 0x3f);
      size = 4;
    }
    out += String.fromCodePoint(code);
    i += size;
  }
  return out;
}

export function asciiBytes(text: string): Uint8Array {
  const out = new Uint8Array(text.length);
  for (let i = 0; i < text.length; i++) {
    out[i] = text.charCodeAt(i) & 0xff;
  }
  return out;
}

function derInteger(raw: Uint8Array): number[] {
  let start = 0;
  while (start < raw.length - 1 && raw[start] === 0) {
    start++;
  }
  const body: number[] = [];
  // A set high bit would make the DER INTEGER negative.
  if ((raw[start] & 0x80) !== 0) {
    body.push(0);
  }
  for (let i = start; i < raw.length; i++) {
    body.push(raw[i]);
  }
  const out: number[] = [0x02, body.length];
  return out.concat(body);
}

/** JWS ES256 signatures are raw R||S (64 bytes); the platform verifier expects DER. */
export function es256RawSignatureToDer(raw: Uint8Array): Uint8Array {
  if (raw.length !== 64) {
    throw new IapJwsError('invalid ES256 signature length');
  }
  const r = derInteger(raw.subarray(0, 32));
  const s = derInteger(raw.subarray(32, 64));
  const sequence: number[] = [0x30, r.length + s.length];
  return new Uint8Array(sequence.concat(r).concat(s));
}

function payloadEnvironment(payloadJson: string): string {
  const payload = JSON.parse(payloadJson) as IapEnvironmentProbe;
  const direct = typeof payload.environment === 'string' ? payload.environment : '';
  const nested = payload.lastSubscriptionStatus?.lastPurchaseOrder?.environment;
  const value = direct.length > 0 ? direct : (typeof nested === 'string' ? nested : '');
  return value.trim().toUpperCase();
}

interface IapEnvironmentOrderProbe {
  environment?: string;
}

interface IapEnvironmentStatusProbe {
  lastPurchaseOrder?: IapEnvironmentOrderProbe;
}

interface IapEnvironmentProbe {
  environment?: string;
  lastSubscriptionStatus?: IapEnvironmentStatusProbe;
}

/** Parses one compact JWS and returns the payload only after every trust check passed. */
export async function verifyHuaweiJws(compact: string, crypto: IapJwsCrypto,
  policy: IapJwsPolicy): Promise<VerifiedJws> {
  const parts = compact.trim().split('.');
  if (parts.length !== 3 || parts[0].length === 0 || parts[1].length === 0 || parts[2].length === 0) {
    throw new IapJwsError('invalid compact JWS format');
  }
  let header: JwsHeader;
  try {
    header = JSON.parse(utf8Decode(decodeBase64(parts[0]))) as JwsHeader;
  } catch (_error) {
    throw new IapJwsError('invalid JWS header');
  }
  const chain = header.x5c;
  if (header === null || typeof header !== 'object' || header.alg !== 'ES256' ||
    (header.typ !== undefined && header.typ !== '' && header.typ !== 'JWT') ||
    !Array.isArray(chain) || chain.length === 0) {
    throw new IapJwsError('unsupported Huawei JWS header');
  }
  const chainDer: Uint8Array[] = [];
  for (let i = 0; i < chain.length; i++) {
    if (typeof chain[i] !== 'string') {
      throw new IapJwsError('invalid x5c certificate encoding');
    }
    chainDer.push(decodeBase64(chain[i]));
  }
  if (policy.observeChain !== undefined) {
    policy.observeChain(chainDer);
  }
  const signature = es256RawSignatureToDer(decodeBase64(parts[2]));
  const signed = await crypto.verifyEs256(chainDer[0], asciiBytes(`${parts[0]}.${parts[1]}`), signature);
  if (!signed) {
    throw new IapJwsError('Huawei JWS signature verification failed');
  }
  let payloadJson: string;
  let environment: string;
  try {
    payloadJson = utf8Decode(decodeBase64(parts[1]));
    environment = payloadEnvironment(payloadJson);
  } catch (_error) {
    throw new IapJwsError('invalid JWS payload');
  }
  // The environment is read from the signed payload, so a self-signed JWS can
  // only claim SANDBOX, which release builds refuse below.
  if (environment === IAP_ENVIRONMENT_SANDBOX) {
    if (!policy.allowSandbox) {
      throw new IapJwsError('sandbox purchase in a release build');
    }
  } else if (environment === IAP_ENVIRONMENT_NORMAL || environment === 'PRODUCTION') {
    if (policy.rootCertificatesDer.length === 0 ||
      !(await crypto.validateChain(chainDer, policy.rootCertificatesDer))) {
      throw new IapJwsError('Huawei JWS certificate chain is not trusted');
    }
    environment = IAP_ENVIRONMENT_NORMAL;
  } else {
    throw new IapJwsError('unknown purchase environment');
  }
  return { payloadJson, environment, chainDer };
}

// ---- Purchase payload decoding -------------------------------------------------

interface PurchaseOrderPayload {
  applicationId?: string;
  packageName?: string;
  productId?: string;
  productType?: number | string;
  purchaseToken?: string;
  purchaseOrderId?: string;
  purchaseTime?: number | string;
  purchaseOrderRevocationReasonCode?: number | string | null;
  revocationTime?: number | string;
}

interface RenewalInfoPayload {
  productId?: string;
  autoRenewStatusCode?: number | string;
}

interface SubscriptionStatusPayload {
  status?: number | string;
  expiresTime?: number | string;
  purchaseToken?: string;
  lastPurchaseOrder?: PurchaseOrderPayload;
  renewalInfo?: RenewalInfoPayload;
}

interface SubGroupStatusPayload {
  lastSubscriptionStatus?: SubscriptionStatusPayload;
}

/** A verified one-time purchase. Revoked/refunded orders never become one. */
export interface VerifiedIapPurchase {
  productId: string;
  purchaseOrderId: string;
  purchaseToken: string;
  purchaseTime: number;
}

/** A verified subscription snapshot, mapped like the removed backend did. */
export interface VerifiedIapPass {
  productId: string;
  purchaseOrderId: string;
  purchaseToken: string;
  status: string;
  expiresAt: number;
  autoRenewing: boolean;
}

export interface VerifiedIapRecord {
  environment: string;
  purchase?: VerifiedIapPurchase;
  pass?: VerifiedIapPass;
  /** True when Huawei reported an order that was refunded or revoked. */
  revoked: boolean;
}

function numberValue(value: number | string | null | undefined): number {
  if (typeof value === 'number') {
    return Number.isFinite(value) ? value : 0;
  }
  if (typeof value === 'string' && value.trim().length > 0) {
    const parsed = Number(value.trim());
    return Number.isFinite(parsed) ? parsed : 0;
  }
  return 0;
}

function textValue(value: string | undefined): string {
  return typeof value === 'string' ? value.trim() : '';
}

/** Mirrors the removed backend subscriptionStatus(): 1 = in period, 5 = revoked. */
export function huaweiSubscriptionStatus(status: number, autoRenewStatusCode: number): string {
  if (status === 1) {
    return autoRenewStatusCode === 1 ? IAP_PASS_ACTIVE : IAP_PASS_CANCELED_ACTIVE;
  }
  if (status === 5) {
    return IAP_PASS_REVOKED;
  }
  return IAP_PASS_EXPIRED;
}

function checkOrderOwner(order: PurchaseOrderPayload): void {
  const packageName = textValue(order.packageName);
  if (textValue(order.applicationId) !== HUAWEI_IAP_APPLICATION_ID ||
    (packageName.length > 0 && packageName !== HUAWEI_IAP_PACKAGE_NAME)) {
    throw new IapJwsError('purchase belongs to another application');
  }
}

function orderRevoked(order: PurchaseOrderPayload): boolean {
  const code = order.purchaseOrderRevocationReasonCode;
  const hasCode = code !== undefined && code !== null && `${code}`.trim().length > 0;
  return hasCode || numberValue(order.revocationTime) > 0;
}

/** Decodes a verified jwsPurchaseOrder payload (one-time product). */
export function decodePurchaseOrder(verified: VerifiedJws): VerifiedIapRecord {
  const order = JSON.parse(verified.payloadJson) as PurchaseOrderPayload;
  checkOrderOwner(order);
  const productId = textValue(order.productId);
  const purchaseOrderId = textValue(order.purchaseOrderId);
  const purchaseToken = textValue(order.purchaseToken);
  if (productId.length === 0 || purchaseOrderId.length === 0 || purchaseToken.length === 0) {
    throw new IapJwsError('purchase is missing order identity');
  }
  if (numberValue(order.productType) === IAP_PRODUCT_TYPE_AUTORENEWABLE) {
    throw new IapJwsError('subscription order must come with its subscription status');
  }
  const revoked = orderRevoked(order);
  return {
    environment: verified.environment,
    revoked,
    purchase: revoked ? undefined : {
      productId, purchaseOrderId, purchaseToken, purchaseTime: numberValue(order.purchaseTime)
    }
  };
}

/** Decodes a verified jwsSubscriptionStatus payload (auto-renew pass). */
export function decodeSubscriptionStatus(verified: VerifiedJws): VerifiedIapRecord {
  const group = JSON.parse(verified.payloadJson) as SubGroupStatusPayload;
  const status = group.lastSubscriptionStatus;
  const order = status?.lastPurchaseOrder;
  if (status === undefined || order === undefined) {
    throw new IapJwsError('subscription status is missing its order');
  }
  checkOrderOwner(order);
  const productId = textValue(order.productId);
  const renewalProductId = textValue(status.renewalInfo?.productId);
  const purchaseOrderId = textValue(order.purchaseOrderId);
  const purchaseToken = textValue(status.purchaseToken).length > 0
    ? textValue(status.purchaseToken) : textValue(order.purchaseToken);
  if (productId.length === 0 || purchaseOrderId.length === 0 || purchaseToken.length === 0) {
    throw new IapJwsError('subscription is missing order identity');
  }
  if (numberValue(order.productType) !== IAP_PRODUCT_TYPE_AUTORENEWABLE ||
    (renewalProductId.length > 0 && renewalProductId !== productId)) {
    throw new IapJwsError('subscription product does not match');
  }
  const revoked = orderRevoked(order);
  const mapped = huaweiSubscriptionStatus(numberValue(status.status),
    numberValue(status.renewalInfo?.autoRenewStatusCode));
  return {
    environment: verified.environment,
    revoked,
    pass: {
      productId,
      purchaseOrderId,
      purchaseToken,
      status: revoked ? IAP_PASS_REVOKED : mapped,
      expiresAt: numberValue(status.expiresTime),
      autoRenewing: !revoked && mapped === IAP_PASS_ACTIVE
    }
  };
}

interface PurchaseDataEnvelope {
  jwsPurchaseOrder?: string;
  jwsSubscriptionStatus?: string;
}

/**
 * purchaseData from createPurchase/queryPurchases is a JSON envelope (or, in
 * old SDKs, a bare compact JWS). A subscription envelope carries both JWS; its
 * status JWS is authoritative because it holds the period and renewal state.
 */
export async function verifyPurchaseData(raw: string, crypto: IapJwsCrypto,
  policy: IapJwsPolicy): Promise<VerifiedIapRecord> {
  const trimmed = raw.trim();
  let orderJws = '';
  let subscriptionJws = '';
  if (trimmed.startsWith('{')) {
    let envelope: PurchaseDataEnvelope;
    try {
      envelope = JSON.parse(trimmed) as PurchaseDataEnvelope;
    } catch (_error) {
      throw new IapJwsError('invalid purchase data');
    }
    orderJws = typeof envelope.jwsPurchaseOrder === 'string' ? envelope.jwsPurchaseOrder : '';
    subscriptionJws = typeof envelope.jwsSubscriptionStatus === 'string' ? envelope.jwsSubscriptionStatus : '';
  } else {
    orderJws = trimmed;
  }
  if (subscriptionJws.length > 0) {
    return decodeSubscriptionStatus(await verifyHuaweiJws(subscriptionJws, crypto, policy));
  }
  if (orderJws.length > 0) {
    return decodePurchaseOrder(await verifyHuaweiJws(orderJws, crypto, policy));
  }
  throw new IapJwsError('purchase data has no JWS');
}
