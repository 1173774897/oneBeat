// On-device Huawei purchase handling (2026-11-03): JWS trust, subscription
// mapping, deliver-before-finish ordering, full-query replacement, and how
// paid items merge with the server snapshot in EntitlementStore.
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const ts = require(process.argv[2] || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
const {
  loadLocalIap, run, keyPair, signJws, nodeCrypto, trustedChain, order, subscription, envelope
} = require('./iap-local-mocks.cjs');

const DAY = 24 * 60 * 60 * 1000;
const NOW = Date.parse('2026-11-03T12:00:00+08:00');
const CONTEXT = {};

async function rejects(promise, pattern) {
  await assert.rejects(promise, error => pattern.test(error.message));
}

async function testJwsTrust() {
  const { verifier } = loadLocalIap(ts);
  const trust = trustedChain();
  const log = [];
  const nodeTrust = nodeCrypto(log);
  const normal = { allowSandbox: false, rootCertificatesDer: trust.roots };
  const payload = order('onebeat.character.cloud');

  const good = signJws(payload, trust.leaf, trust.chain);
  const verified = await verifier.verifyHuaweiJws(good, nodeTrust, normal);
  assert.equal(verified.environment, 'NORMAL');
  assert.deepEqual(JSON.parse(verified.payloadJson), payload);
  assert.deepEqual(log, ['verify', 'chain'], 'NORMAL purchases check signature and chain');

  const [head, , sig] = good.split('.');
  const tampered = `${head}.${Buffer.from(JSON.stringify({ ...payload, productId: 'onebeat.scene.neon_street' })).toString('base64url')}.${sig}`;
  await rejects(verifier.verifyHuaweiJws(tampered, nodeTrust, normal), /signature/);

  const stranger = keyPair();
  await rejects(verifier.verifyHuaweiJws(signJws(payload, stranger, trust.chain), nodeTrust, normal), /signature/);
  await rejects(verifier.verifyHuaweiJws(signJws(payload, trust.leaf, trust.chain, { alg: 'HS256' }), nodeTrust, normal),
    /unsupported/);
  await rejects(verifier.verifyHuaweiJws(signJws(payload, trust.leaf, []), nodeTrust, normal), /unsupported/);
  await rejects(verifier.verifyHuaweiJws('a.b', nodeTrust, normal), /format/);

  // A self-made chain, or no embedded root at all, fails closed for NORMAL.
  const fake = trustedChain();
  await rejects(verifier.verifyHuaweiJws(signJws(payload, fake.leaf, fake.chain), nodeTrust, normal), /not trusted/);
  await rejects(verifier.verifyHuaweiJws(good, nodeTrust, { allowSandbox: true, rootCertificatesDer: [] }),
    /not trusted/);

  // SANDBOX: leaf signature only, and only when the build allows it.
  const sandbox = signJws(order('onebeat.character.cloud', { environment: 'SANDBOX' }), stranger, [stranger.der]);
  log.length = 0;
  assert.equal((await verifier.verifyHuaweiJws(sandbox, nodeTrust, { allowSandbox: true, rootCertificatesDer: [] }))
    .environment, 'SANDBOX');
  assert.deepEqual(log, ['verify'], 'Sandbox skips the chain, like the removed backend');
  await rejects(verifier.verifyHuaweiJws(sandbox, nodeTrust, normal), /sandbox/);
  await rejects(verifier.verifyHuaweiJws(signJws(order('x', { environment: 'TEST' }), trust.leaf, trust.chain),
    nodeTrust, normal), /environment/);

  // Debug chain logging sees the public chain before any trust decision.
  const seen = [];
  await rejects(verifier.verifyHuaweiJws(signJws(payload, fake.leaf, fake.chain), nodeTrust,
    { ...normal, observeChain: chain => seen.push(chain.length) }), /not trusted/);
  assert.deepEqual(seen, [2]);
}

function testDerConversion() {
  const { verifier } = loadLocalIap(ts);
  const key = keyPair();
  // Random signatures cover leading zero bytes and high-bit padding in R and S.
  for (let i = 0; i < 300; i++) {
    const data = crypto.randomBytes(32);
    const raw = crypto.sign('sha256', data, { key: key.privateKey, dsaEncoding: 'ieee-p1363' });
    const der = verifier.es256RawSignatureToDer(new Uint8Array(raw));
    assert.ok(crypto.verify('sha256', data, { key: key.publicKey, dsaEncoding: 'der' }, Buffer.from(der)), `sig ${i}`);
  }
  const edge = new Uint8Array(64);
  edge[31] = 1; edge[32] = 0x80;
  assert.deepEqual(Array.from(verifier.es256RawSignatureToDer(edge)),
    [0x30, 0x26, 0x02, 0x01, 0x01, 0x02, 0x21, 0x00, 0x80, ...new Array(31).fill(0)]);
  assert.throws(() => verifier.es256RawSignatureToDer(new Uint8Array(63)), /length/);
  const text = '畅游月卡 ✓ abc';
  assert.equal(verifier.utf8Decode(verifier.decodeBase64(Buffer.from(text).toString('base64url'))), text);
  assert.equal(verifier.encodeBase64(new Uint8Array([1, 2, 3, 4])), Buffer.from([1, 2, 3, 4]).toString('base64'));
  assert.throws(() => verifier.decodeBase64('ab$c'), /character/);
}

async function testPayloadDecoding() {
  const { verifier } = loadLocalIap(ts);
  const trust = trustedChain();
  const policy = { allowSandbox: false, rootCertificatesDer: trust.roots };
  const trustCrypto = nodeCrypto();
  const decode = data => verifier.verifyPurchaseData(data, trustCrypto, policy);

  const owned = await decode(envelope({ jwsPurchaseOrder: signJws(order('onebeat.character.cloud'), trust.leaf, trust.chain) }));
  assert.equal(owned.purchase.productId, 'onebeat.character.cloud');
  assert.equal(owned.revoked, false);
  const refunded = await decode(signJws(order('onebeat.character.cloud', { purchaseOrderRevocationReasonCode: 0 }),
    trust.leaf, trust.chain));
  assert.equal(refunded.revoked, true, 'A revocation code of 0 is still present');
  assert.equal(refunded.purchase, undefined);
  await rejects(decode(signJws(order('onebeat.character.cloud', { applicationId: '1' }), trust.leaf, trust.chain)),
    /another application/);
  await rejects(decode(signJws(order('onebeat.character.cloud', { packageName: 'com.other' }), trust.leaf, trust.chain)),
    /another application/);
  await rejects(decode(signJws(order('onebeat.character.cloud', { purchaseToken: '' }), trust.leaf, trust.chain)),
    /identity/);
  await rejects(decode('{}'), /no JWS/);

  // Status mapping mirrors the removed backend subscriptionStatus().
  const cases = [[1, 1, 'ACTIVE', true], [1, 0, 'CANCELED_ACTIVE', false], [2, 1, 'EXPIRED', false],
    [3, 0, 'EXPIRED', false], [5, 1, 'REVOKED', false], [9, 1, 'EXPIRED', false]];
  for (const [status, renew, expected, autoRenewing] of cases) {
    assert.equal(verifier.huaweiSubscriptionStatus(status, renew), expected);
    const record = await decode(envelope({
      jwsPurchaseOrder: signJws(order('onebeat.character.cloud'), trust.leaf, trust.chain),
      jwsSubscriptionStatus: signJws(subscription(`${status}`, `${renew}`, `${NOW + DAY}`), trust.leaf, trust.chain)
    }));
    assert.equal(record.pass.status, expected, `status ${status}/${renew}`);
    assert.equal(record.pass.autoRenewing, autoRenewing);
    assert.equal(record.pass.expiresAt, NOW + DAY, 'Millisecond strings are accepted');
  }
  const revokedPass = await decode(envelope({ jwsSubscriptionStatus: signJws(
    subscription(1, 1, NOW + DAY, {}, { revocationTime: NOW }), trust.leaf, trust.chain) }));
  assert.equal(revokedPass.pass.status, 'REVOKED');
  await rejects(decode(envelope({ jwsSubscriptionStatus: signJws(
    subscription(1, 1, NOW + DAY, { renewalInfo: { productId: 'other', autoRenewStatusCode: 1 } }), trust.leaf, trust.chain) })),
    /does not match/);
}

function purchaseData(trust, productId, extra = {}) {
  return envelope({ jwsPurchaseOrder: signJws(order(productId, extra), trust.leaf, trust.chain) });
}

function passData(trust, status, autoRenew, expires) {
  return envelope({ jwsSubscriptionStatus: signJws(subscription(status, autoRenew, expires), trust.leaf, trust.chain) });
}

async function testRefreshDeliverFinishOrder() {
  const trust = trustedChain();
  const env = loadLocalIap(ts, { roots: trust.roots, now: NOW });
  const { entitlements, huawei, events } = env;
  entitlements.initializeLocalIapEntitlements(CONTEXT);
  huawei.owned[1] = [purchaseData(trust, 'onebeat.character.cloud')];
  huawei.unfinished[1] = [purchaseData(trust, 'onebeat.scene.neon_street')];
  huawei.owned[2] = [passData(trust, 1, 1, NOW + 10 * DAY)];
  let notified = 0;
  entitlements.setLocalIapChangeListener(() => notified++);
  const result = await entitlements.refreshLocalIapEntitlements(CONTEXT);
  assert.deepEqual({ ...result }, { ownedItemCount: 2, passActive: true, finishedCount: 1, rejectedCount: 0 });
  const flushAt = events.indexOf('flush');
  const finishAt = events.indexOf('finish:order-onebeat.scene.neon_street');
  assert.ok(flushAt >= 0 && finishAt > flushAt, `Deliver (persist) before finishPurchase: ${events}`);
  assert.equal(events.filter(e => e.startsWith('finish:')).length, 1, 'Only UNFINISHED orders are confirmed');
  assert.ok(notified >= 1);
  const stored = env.prefsStore.get('onebeat_iap_entitlements/state_v1');
  assert.ok(!stored.includes('token-'), 'Purchase tokens never reach local storage');
  assert.deepEqual(Array.from(entitlements.localIapOwnedItemKeys(entitlements.currentLocalIapState())),
    ['character.cloud', 'scene.neon_street']);

  // A refund drops out on the next full query.
  huawei.owned[1] = [purchaseData(trust, 'onebeat.character.cloud', { purchaseOrderRevocationReasonCode: 1 })];
  huawei.unfinished[1] = [];
  await entitlements.refreshLocalIapEntitlements(CONTEXT);
  assert.deepEqual(Array.from(entitlements.localIapOwnedItemKeys(entitlements.currentLocalIapState())), []);

  // A failed query keeps the last summary instead of erasing it.
  huawei.owned[1] = [purchaseData(trust, 'onebeat.character.wave')];
  await entitlements.refreshLocalIapEntitlements(CONTEXT);
  huawei.failQuery = true;
  await assert.rejects(entitlements.refreshLocalIapEntitlements(CONTEXT));
  assert.deepEqual(Array.from(entitlements.localIapOwnedItemKeys(entitlements.currentLocalIapState())), ['character.wave']);
  huawei.failQuery = false;

  // Persistence failure: nothing is confirmed, Huawei keeps the order unfinished.
  events.length = 0;
  huawei.unfinished[1] = [purchaseData(trust, 'onebeat.character.teapot')];
  huawei.failFlush = true;
  await assert.rejects(entitlements.refreshLocalIapEntitlements(CONTEXT), /flush/);
  assert.equal(events.filter(e => e.startsWith('finish:')).length, 0, 'No finishPurchase without a saved delivery');
  huawei.failFlush = false;

  // finishPurchase failure is retried by a later refresh, delivery is kept.
  huawei.failFinish = true;
  const retried = await entitlements.refreshLocalIapEntitlements(CONTEXT);
  assert.equal(retried.finishedCount, 0);
  assert.ok(entitlements.localIapOwnedItemKeys(entitlements.currentLocalIapState()).includes('character.teapot'));
  huawei.failFinish = false;

  // Forged data is rejected and counted, the rest still delivers.
  const fake = trustedChain();
  huawei.owned[1] = [purchaseData(trust, 'onebeat.character.wave'), purchaseData(fake, 'onebeat.character.lamp')];
  huawei.unfinished[1] = [];
  const mixed = await entitlements.refreshLocalIapEntitlements(CONTEXT);
  assert.equal(mixed.rejectedCount, 1);
  assert.deepEqual(Array.from(entitlements.localIapOwnedItemKeys(entitlements.currentLocalIapState())), ['character.wave']);

}

async function testNewPurchaseAndRestore() {
  const trust = trustedChain();
  const env = loadLocalIap(ts, { roots: trust.roots, now: NOW });
  const { entitlements, huawei, events } = env;
  const service = run(ts, 'store/IapPurchaseService.ets', {
    '@kit.IAPKit': { iap: env.iap }, './IapEntitlements': entitlements, './IapJwsVerifier': env.verifier
  }, {});
  huawei.createResult = purchaseData(trust, 'onebeat.character.lamp');
  await service.purchaseStoreProduct(CONTEXT, 'onebeat.character.lamp', service.productTypeForStoreItem(false));
  assert.deepEqual(events.filter(e => !e.startsWith('query')),
    ['create:onebeat.character.lamp', 'put', 'flush', 'finish:order-onebeat.character.lamp']);
  huawei.createResult = purchaseData(trust, 'onebeat.character.cloud');
  await rejects(service.purchaseStoreProduct(CONTEXT, 'onebeat.character.lamp', 1), /不一致/);
  huawei.createResult = passData(trust, 1, 1, NOW + 30 * DAY);
  await service.purchaseStoreProduct(CONTEXT, 'onebeat.pass.monthly', service.productTypeForStoreItem(true));
  assert.ok(entitlements.localIapPassExpiry(entitlements.currentLocalIapState(), NOW) > 0);

  // Restart: the summary restores synchronously; sandbox entries need a debug build.
  const restarted = loadLocalIap(ts, { roots: trust.roots, now: NOW, durable: env.prefsStore });
  restarted.entitlements.initializeLocalIapEntitlements(CONTEXT);
  assert.deepEqual(Array.from(restarted.entitlements.localIapOwnedItemKeys(restarted.entitlements.currentLocalIapState())),
    ['character.cloud', 'character.lamp']);
  const raw = env.prefsStore.get('onebeat_iap_entitlements/state_v1').replace(/"NORMAL"/g, '"SANDBOX"');
  const release = restarted.entitlements.restoreLocalIapState(raw, false);
  assert.equal(release.purchases.length, 0);
  assert.equal(release.pass, null);
  assert.equal(restarted.entitlements.restoreLocalIapState(raw, true).purchases.length, 2);
  assert.equal(restarted.entitlements.restoreLocalIapState('{bad', true).purchases.length, 0);
}

// ---- EntitlementStore merge -----------------------------------------------------

function storeHarness(trust) {
  const env = loadLocalIap(ts, { roots: trust.roots, now: NOW });
  const app = new Map();
  const durable = new Map();
  const snapshotCache = run(ts, 'store/EntitlementSnapshotCache.ets', {}, { Date: env.ClockDate });
  const store = run(ts, 'store/EntitlementStore.ets', {
    './EntitlementSnapshotCache': snapshotCache,
    './IapEntitlements': env.entitlements,
    '../common/AtomicTextFile': { readOptionalSync: f => durable.get(f) ?? '', writeAtomicSync: (f, v) => durable.set(f, v) },
    '../common/MonotonicClock': { MonotonicClock: { nowMs: () => 0 } },
    '@kit.ArkData': { preferences: {} }
  }, { Date: env.ClockDate, AppStorage: { get: k => app.get(k), setOrCreate: (k, v) => app.set(k, v) } });
  store.initializeStoredEntitlementCache({ filesDir: '/app/files' });
  return { env, app, store };
}

function serverItem(itemKey, reason, validUntil, extra = {}) {
  return { itemKey, displayName: itemKey, kind: 'X', defaultFree: reason === 'DEFAULT_FREE', includedInPass: true,
    access: { allowed: reason !== 'LOCKED', reason, validUntil: validUntil ?? null }, ...extra };
}

function serverBootstrap(at, items, pass = { active: false, expiresAt: null, autoRenewing: false, iapPurchaseAllowed: true }) {
  return { serverTime: new Date(at).toISOString(), configVersion: 'v', pass, items, redemption: { available: true } };
}

async function testStoreMerge() {
  const trust = trustedChain();
  const { env, app, store } = storeHarness(trust);
  const epoch = () => app.get('storeEntitlementEpoch');

  // No server snapshot at all: a paid item still unlocks from the device summary.
  env.huawei.owned[1] = [purchaseData(trust, 'onebeat.character.cloud'), purchaseData(trust, 'onebeat.scene.neon_street')];
  const before = epoch();
  await env.entitlements.refreshLocalIapEntitlements(CONTEXT);
  assert.ok(epoch() > before, 'A Huawei change re-projects the UI');
  assert.deepEqual(Array.from(store.ownedCharacterKeys()), ['cloud']);
  assert.deepEqual(Array.from(store.ownedSceneKeys()), ['sunset_coast', 'neon_street']);
  assert.equal(store.storeItemAccessReason('character.cloud'), 'IAP_PURCHASE');
  assert.equal(app.get('storeOwnedCharacters'), '["cloud"]');

  // Purchase beats limited free; a gift pass covers the rest.
  const giftEnd = NOW + 5 * DAY;
  store.applyStoreBootstrap(serverBootstrap(NOW, [
    serverItem('character.cloud', 'LIMITED_FREE', new Date(NOW + DAY).toISOString(),
      { freeWindow: { startsAt: new Date(NOW - DAY).toISOString(), endsAt: new Date(NOW + DAY).toISOString() } }),
    serverItem('character.wave', 'PASS_REDEMPTION', new Date(giftEnd).toISOString()),
    serverItem('scene.sunset_coast', 'DEFAULT_FREE')
  ], { active: true, source: 'PASS_REDEMPTION', status: 'ACTIVE', expiresAt: new Date(giftEnd).toISOString(),
    autoRenewing: false, iapPurchaseAllowed: false }));
  assert.equal(store.storeItemAccessReason('character.cloud'), 'IAP_PURCHASE');
  assert.deepEqual(Array.from(store.limitedFreeCharacterKeys()), []);
  assert.equal(store.storeItemAccessReason('character.wave'), 'PASS_REDEMPTION');
  assert.equal(store.storeItemAccessReason('scene.sunset_coast'), 'DEFAULT_FREE');
  assert.equal(app.get('storePassSource'), 'PASS_REDEMPTION');
  assert.equal(app.get('storePassIapPurchaseAllowed'), false, 'A gift pass blocks buying the Huawei pass');
  assert.equal(store.isHuaweiPassActive(), false);

  // Huawei pass wins over the gift pass and blocks redemption.
  const huaweiEnd = NOW + 20 * DAY;
  env.huawei.owned[2] = [passData(trust, 1, 0, huaweiEnd)];
  await env.entitlements.refreshLocalIapEntitlements(CONTEXT);
  assert.equal(store.storeItemAccessReason('character.wave'), 'PASS_IAP');
  assert.equal(store.storeItemAccessReason('character.cloud'), 'IAP_PURCHASE', 'Owned stays owned under a pass');
  assert.equal(app.get('storePassSource'), 'PASS_IAP');
  assert.equal(app.get('storePassStatus'), 'CANCELED_ACTIVE');
  assert.equal(app.get('storePassExpiresAt'), new Date(huaweiEnd).toISOString());
  assert.equal(app.get('storePassAutoRenewing'), false);
  assert.equal(app.get('storePassIapPurchaseAllowed'), false);
  assert.equal(store.isHuaweiPassActive(), true);
  assert.equal(store.isMonthlyPassRewardStateKnown(), true, 'A verified Huawei pass is known membership');
  assert.deepEqual({ ...store.resolveDrumAccess(NOW) }, { allowed: true, source: 'monthly', expiresAt: huaweiEnd });

  // Past the server snapshot's 30-day lease: gift-derived rights end, paid ones do not.
  env.at(NOW + 31 * DAY);
  assert.equal(store.isHuaweiPassActive(), false, 'Huawei pass ended at its own expiry');
  assert.equal(store.storeItemAccessReason('character.cloud'), 'IAP_PURCHASE');
  assert.equal(store.storeItemAccessReason('character.wave'), 'LOCKED');
  assert.ok(store.isSceneAccessible('neon_street'));
  store.isMonthlyPassActive();
  assert.equal(app.get('storePassActive'), false);
  assert.equal(app.get('storePassIapPurchaseAllowed'), true);

  // Huawei pass alone, no server snapshot covering the item: static catalog applies.
  env.at(NOW);
  env.huawei.owned[2] = [passData(trust, 1, 1, NOW + DAY)];
  await env.entitlements.refreshLocalIapEntitlements(CONTEXT);
  assert.equal(store.storeItemAccessReason('character.lilroll'), 'PASS_IAP');
  assert.equal(store.storeItemAccessReason('feature.pro_drum_machine'), 'PASS_IAP');
  assert.equal(app.get('storePassAutoRenewing'), true);
}

// The platform adapter cannot run in Node, so its one fatal pitfall is pinned
// in source: a certificate-framework key passed to the crypto framework's
// Verify.init aborts the app natively (Pura X sandbox purchase, 2026-11-04).
function testPlatformKeyBoundary() {
  const source = require('node:fs').readFileSync(
    require('node:path').join(__dirname, '../../entry/src/main/ets/store/IapJwsPlatformCrypto.ets'), 'utf8')
    .replace(/\/\/.*$/gm, '');
  assert.equal(/\.getPublicKey\s*\(/.test(source), false,
    'Never hand a cert.X509Cert key object to cryptoFramework');
  assert.match(source, /CERT_ITEM_TYPE_PUBLIC_KEY/);
  assert.match(source, /createAsyKeyGenerator\('ECC256'\)[\s\S]*?\.convertKey\(/);
  assert.match(source, /verifier\.init\(keyPair\.pubKey\)/);
}

// Huawei sandbox hides finished non-consumables from every query, so sandbox
// one-time orders are delivered but never finished; NORMAL ones still are.
async function testSandboxNonConsumablesStayUnfinished() {
  const sandboxTrust = { leaf: keyPair(), chain: null };
  sandboxTrust.chain = [sandboxTrust.leaf.der];
  const env = loadLocalIap(ts, { roots: [], now: NOW, allowSandbox: true });
  const { entitlements, huawei, events } = env;
  const service = run(ts, 'store/IapPurchaseService.ets', {
    '@kit.IAPKit': { iap: env.iap }, './IapEntitlements': entitlements, './IapJwsVerifier': env.verifier
  }, {});
  const teapot = purchaseData(sandboxTrust, 'onebeat.character.teapot', { environment: 'SANDBOX' });
  huawei.createResult = teapot;
  await service.purchaseStoreProduct(CONTEXT, 'onebeat.character.teapot', service.productTypeForStoreItem(false));
  assert.deepEqual(events.filter(e => e.startsWith('finish:')), [], 'A sandbox purchase is delivered but not finished');
  assert.deepEqual(Array.from(entitlements.localIapOwnedItemKeys(entitlements.currentLocalIapState())),
    ['character.teapot']);
  // Still unfinished, so Huawei keeps listing it and a full refresh keeps it.
  huawei.unfinished[1] = [teapot];
  const refreshed = await entitlements.refreshLocalIapEntitlements(CONTEXT);
  assert.equal(refreshed.finishedCount, 0);
  assert.deepEqual(Array.from(entitlements.localIapOwnedItemKeys(entitlements.currentLocalIapState())),
    ['character.teapot']);
  // A sandbox refund shows up on the unfinished order and removes the item.
  huawei.unfinished[1] = [purchaseData(sandboxTrust, 'onebeat.character.teapot',
    { environment: 'SANDBOX', purchaseOrderRevocationReasonCode: 1 })];
  await entitlements.refreshLocalIapEntitlements(CONTEXT);
  assert.deepEqual(Array.from(entitlements.localIapOwnedItemKeys(entitlements.currentLocalIapState())), []);
  assert.deepEqual(events.filter(e => e.startsWith('finish:')), []);
}

(async () => {
  testPlatformKeyBoundary();
  await testSandboxNonConsumablesStayUnfinished();
  await testJwsTrust();
  testDerConversion();
  await testPayloadDecoding();
  await testRefreshDeliverFinishOrder();
  await testNewPurchaseAndRestore();
  await testStoreMerge();
  console.log('PASS store-iap-local: JWS trust, delivery ordering, Huawei/server merge, platform key passed as DER only, sandbox one-time orders stay unfinished');
})().catch(error => { console.error(error); process.exit(1); });
