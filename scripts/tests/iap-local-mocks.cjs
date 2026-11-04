// Loads the real on-device IAP modules (IapJwsVerifier + IapEntitlements) with
// Huawei IAP, preferences and platform crypto replaced by Node fakes.
//
// Test "certificates" are SPKI DER public keys: the verifier only hands
// certificate bytes to the injected crypto, so real X.509 parsing is the
// platform adapter's job and is checked on device. Signatures are real ES256.
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const ROOT = path.resolve(__dirname, '../../entry/src/main/ets');
const APP_ID = '6917617181108973504';
const PACKAGE = 'com.onebeat.app';

function transpile(ts, file) {
  const result = ts.transpileModule(fs.readFileSync(path.join(ROOT, file), 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 }, reportDiagnostics: true
  });
  assert.deepEqual((result.diagnostics || []).filter(d => d.category === ts.DiagnosticCategory.Error), []);
  return result.outputText;
}

function run(ts, file, mocks, globals) {
  const context = { exports: {}, require(name) {
    assert.ok(Object.hasOwn(mocks, name), `Unexpected dependency ${name} in ${file}`);
    return mocks[name];
  }, Uint8Array, console: { warn() {}, info() {} }, ...globals };
  vm.runInNewContext(transpile(ts, file), context);
  return context.exports;
}

function keyPair() {
  const pair = crypto.generateKeyPairSync('ec', { namedCurve: 'P-256' });
  return { ...pair, der: new Uint8Array(pair.publicKey.export({ format: 'der', type: 'spki' })) };
}

const b64url = value => Buffer.from(value).toString('base64url');

/** Signs a compact JWS; chain is x5c (leaf first) as DER bytes. */
function signJws(payload, signer, chain, header = {}) {
  const head = b64url(JSON.stringify({ alg: 'ES256', typ: 'JWT',
    x5c: chain.map(der => Buffer.from(der).toString('base64')), ...header }));
  const body = b64url(typeof payload === 'string' ? payload : JSON.stringify(payload));
  const signature = crypto.sign('sha256', Buffer.from(`${head}.${body}`), { key: signer.privateKey, dsaEncoding: 'ieee-p1363' });
  return `${head}.${body}.${b64url(signature)}`;
}

const sameBytes = (a, b) => a.length === b.length && Buffer.from(a).equals(Buffer.from(b));

/** Node implementation of IapJwsCrypto. validateChain: the top of x5c must be an embedded root. */
function nodeCrypto(log = []) {
  return {
    async verifyEs256(leaf, input, derSignature) {
      log.push('verify');
      try {
        const key = crypto.createPublicKey({ key: Buffer.from(leaf), format: 'der', type: 'spki' });
        return crypto.verify('sha256', Buffer.from(input), { key, dsaEncoding: 'der' }, Buffer.from(derSignature));
      } catch (_error) { return false; }
    },
    async validateChain(chain, roots) {
      log.push('chain');
      return chain.length >= 2 && roots.some(root => sameBytes(root, chain[chain.length - 1]));
    }
  };
}

function order(productId, extra = {}) {
  return { applicationId: APP_ID, packageName: PACKAGE, productId, productType: 1,
    purchaseToken: `token-${productId}`, purchaseOrderId: `order-${productId}`, purchaseTime: 1000,
    environment: 'NORMAL', ...extra };
}

function subscription(status, autoRenew, expiresTime, extra = {}, orderExtra = {}) {
  return { environment: 'NORMAL', subGroupId: 'group', lastSubscriptionStatus: {
    status, expiresTime, purchaseToken: 'token-pass',
    lastPurchaseOrder: order('onebeat.pass.monthly', { productType: 2, purchaseToken: 'token-pass',
      purchaseOrderId: 'order-pass', ...orderExtra }),
    renewalInfo: { productId: 'onebeat.pass.monthly', autoRenewStatusCode: autoRenew }, ...extra } };
}

/**
 * Builds a fake Huawei account. `owned`/`unfinished` map productType (1 or 2)
 * to purchaseData strings. Events record put/flush/finish order.
 */
function loadLocalIap(ts, options = {}) {
  let now = options.now ?? Date.parse('2026-11-03T12:00:00+08:00');
  const ClockDate = class extends Date { static now() { return now; } };
  const events = [];
  const durable = options.durable ?? new Map();
  const huawei = { owned: { 1: [], 2: [] }, unfinished: { 1: [], 2: [] }, failQuery: false, failFlush: false,
    failFinish: false, createResult: '' };
  const prefsStore = new Map(durable);
  const preferences = {
    getPreferencesSync(_context, { name }) {
      return {
        getSync(key, fallback) { return prefsStore.get(`${name}/${key}`) ?? fallback; },
        async put(key, value) { events.push('put'); this.pending = [key, value]; },
        async flush() {
          if (huawei.failFlush) throw new Error('synthetic flush failure');
          events.push('flush');
          prefsStore.set(`${name}/${this.pending[0]}`, this.pending[1]);
        }
      };
    }
  };
  const iap = {
    ProductType: { CONSUMABLE: 0, NONCONSUMABLE: 1, AUTORENEWABLE: 2 },
    PurchaseQueryType: { CURRENT_ENTITLEMENT: 'CURRENT_ENTITLEMENT', UNFINISHED: 'UNFINISHED' },
    async queryPurchases(_context, { productType, queryType }) {
      events.push(`query:${productType}:${queryType}`);
      if (huawei.failQuery) throw Object.assign(new Error('synthetic IAP failure'), { code: 1001860050 });
      const source = queryType === 'UNFINISHED' ? huawei.unfinished : huawei.owned;
      return { purchaseDataList: source[productType].slice() };
    },
    async finishPurchase(_context, parameter) {
      events.push(`finish:${parameter.purchaseOrderId}`);
      if (huawei.failFinish) throw new Error('synthetic finish failure');
    },
    async createPurchase(_context, parameter) {
      events.push(`create:${parameter.productId}`);
      assert.equal(parameter.developerPayload, undefined, 'No server binding is sent to Huawei');
      return { purchaseData: huawei.createResult };
    }
  };
  const chainLog = [];
  const policy = { allowSandbox: options.allowSandbox ?? false, rootCertificatesDer: options.roots ?? [] };
  const verifier = run(ts, 'store/IapJwsVerifier.ets', {}, { Date: ClockDate });
  const entitlements = run(ts, 'store/IapEntitlements.ets', {
    '@kit.IAPKit': { iap },
    '@kit.ArkData': { preferences },
    './IapJwsVerifier': verifier,
    './IapJwsPlatformCrypto': {
      platformIapJwsCrypto: () => options.crypto ?? nodeCrypto(chainLog),
      platformIapJwsPolicy: () => policy
    }
  }, { Date: ClockDate });
  return { verifier, entitlements, iap, huawei, events, prefsStore, policy, chainLog,
    at(value) { now = value; }, now: () => now, ClockDate };
}

/** A complete NORMAL trust setup: root key + leaf key, chain [leaf, root]. */
function trustedChain() {
  const root = keyPair();
  const leaf = keyPair();
  return { root, leaf, chain: [leaf.der, root.der], roots: [root.der] };
}

function envelope(fields) {
  return JSON.stringify(fields);
}

module.exports = { loadLocalIap, run, transpile, keyPair, signJws, nodeCrypto, trustedChain, order, subscription,
  envelope, APP_ID, PACKAGE };
