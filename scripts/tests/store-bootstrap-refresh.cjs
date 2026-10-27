// Run with Node and the bundled typescript/lib/typescript.js path.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require(process.argv[2]);
const storeRoot = path.resolve(__dirname, '../../entry/src/main/ets/store');

function compile(file) {
  const result = ts.transpileModule(fs.readFileSync(path.join(storeRoot, file), 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 },
    reportDiagnostics: true
  });
  assert.equal((result.diagnostics ?? []).filter(d => d.category === ts.DiagnosticCategory.Error).length, 0);
  return result.outputText;
}
const refreshSource = compile('StoreBootstrapRefresh.ets');
const syncSource = compile('StoreBootstrapSync.ets');

function deferred() {
  let resolve, reject;
  const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}
async function flush() {
  for (let i = 0; i < 20; i++) await Promise.resolve();
}
function harness(options = {}) {
  const shared = { exports: {} };
  vm.runInNewContext(refreshSource, shared);
  const requests = [], applied = [], storage = new Map([['selectedSceneKey', 'custom-scene']]);
  let token = options.token ?? 'session-a';
  let restoreCount = 0, renewalCount = 0, clearCount = 0;
  const dependencies = {
    './StoreBootstrapRefresh': shared.exports,
    './StoreApiConfig': { isStoreApiConfigured: () => options.configured !== false },
    './StoreApi': {
      fetchStoreBootstrap(accessToken) {
        const task = deferred();
        requests.push({ token: accessToken, ...task });
        return task.promise;
      }
    },
    './EntitlementStore': {
      applyStoreBootstrap: bootstrap => applied.push(bootstrap),
      isSceneAccessible: scene => options.sceneAccessible !== false || scene === 'sunset_coast'
    },
    './HuaweiAccountService': {
      currentStoreSessionToken: () => token,
      clearStoreSession() {
        clearCount++;
        token = '';
        shared.exports.invalidateStoreBootstrapRefresh();
      },
      async trySilentStoreSessionRenewal() {
        renewalCount++;
        return options.renew ? options.renew(renewalCount) : '';
      }
    },
    './StoreSessionPersistence': {
      async restoreStoreSessionFromDisk() {
        restoreCount++;
        if (options.restore) await options.restore();
      }
    }
  };
  const module = { exports: {}, AppStorage: {
    get: key => storage.get(key), setOrCreate: (key, value) => storage.set(key, value)
  }, require(name) {
    assert.ok(Object.hasOwn(dependencies, name), 'Unexpected bootstrap dependency ' + name);
    return dependencies[name];
  }};
  vm.runInNewContext(syncSource, module);
  return {
    api: module.exports, requests, applied, storage,
    stats: () => ({ restoreCount, renewalCount, clearCount }),
    setToken(value) { token = value; }
  };
}

(async () => {
  const cold = harness({ sceneAccessible: false });
  const opening = cold.api.startStoreColdStartBootstrap();
  const enteringLobby = cold.api.refreshStoreEntitlementsNow();
  const anotherCaller = cold.api.refreshStoreEntitlementsNow();
  assert.equal(enteringLobby, opening, 'Entering the lobby shares an active launch request');
  assert.equal(anotherCaller, opening, 'Overlapping immediate refreshes share the same promise');
  await flush();
  assert.equal(cold.requests.length, 1, 'Cold start plus lobby must not issue serial duplicate requests');
  const initial = { revision: 'initial' };
  cold.requests[0].resolve(initial);
  await Promise.all([opening, enteringLobby, anotherCaller]);
  assert.deepEqual(cold.applied, [initial]);
  assert.equal(cold.storage.get('selectedSceneKey'), 'sunset_coast', 'Existing scene reconciliation is preserved');
  await cold.api.refreshStoreEntitlements();
  await cold.api.startStoreColdStartBootstrap();
  assert.equal(cold.requests.length, 1, 'Normal refresh remains cached after settlement');

  const next = cold.api.refreshStoreEntitlementsNow();
  assert.notEqual(next, opening, 'A deliberate refresh after settlement starts fresh');
  assert.equal(cold.api.refreshStoreEntitlementsNow(), next);
  assert.equal(cold.api.refreshStoreEntitlements(), next);
  await flush();
  assert.equal(cold.requests.length, 2);
  cold.requests[1].resolve({ revision: 'updated' });
  await next;
  assert.equal(cold.applied.at(-1).revision, 'updated');
  assert.equal(cold.stats().restoreCount, 1, 'Session disk hydration remains once per process');

  const firstImmediate = harness();
  const first = firstImmediate.api.refreshStoreEntitlementsNow();
  await flush();
  assert.equal(firstImmediate.requests.length, 1, 'An immediate refresh may itself initialize cold start');
  firstImmediate.requests[0].resolve(null);
  await first;
  assert.equal(firstImmediate.applied.length, 0, 'An empty response does not overwrite cached rights');

  const normal = harness();
  const regular = normal.api.refreshStoreEntitlements();
  assert.equal(normal.api.refreshStoreEntitlements(), regular);
  assert.equal(normal.api.startStoreColdStartBootstrap(), regular);
  await flush();
  assert.equal(normal.requests.length, 1);
  normal.requests[0].resolve({ revision: 'regular' });
  await regular;
  assert.equal(normal.api.refreshStoreEntitlements(), regular);

  const auth = harness();
  const oldAccount = auth.api.startStoreColdStartBootstrap();
  await flush();
  auth.setToken('session-b');
  auth.api.invalidateStoreBootstrapRefresh();
  const newAccount = auth.api.refreshStoreEntitlementsNow();
  assert.notEqual(newAccount, oldAccount, 'Explicit account invalidation bypasses an old active request');
  await flush();
  assert.deepEqual(auth.requests.map(request => request.token), ['session-a', 'session-b']);
  auth.requests[0].resolve(null);
  await oldAccount;
  assert.equal(auth.api.refreshStoreEntitlementsNow(), newAccount,
    'Finishing an older request must not clear the newer in-flight request');
  auth.requests[1].resolve({ revision: 'new-account' });
  await newAccount;
  auth.api.invalidateStoreBootstrapRefresh();
  const invalidated = auth.api.refreshStoreEntitlements();
  await flush();
  assert.equal(auth.requests.length, 3, 'Auth invalidation also bypasses a fulfilled cached request');
  auth.requests[2].resolve(null);
  await invalidated;

  const offline = harness();
  const unavailable = offline.api.refreshStoreEntitlementsNow();
  await flush();
  offline.requests[0].reject(new Error('offline'));
  await unavailable;
  assert.equal(offline.applied.length, 0, 'Network failure preserves the entitlement snapshot');
  await offline.api.refreshStoreEntitlements();
  assert.equal(offline.requests.length, 1, 'A failed normal refresh still keeps once-per-process semantics');
  const retry = offline.api.refreshStoreEntitlementsNow();
  assert.equal(offline.api.refreshStoreEntitlementsNow(), retry);
  await flush();
  assert.equal(offline.requests.length, 2, 'A later deliberate refresh retries after offline settlement');
  offline.requests[1].resolve({ revision: 'online' });
  await retry;
  assert.equal(offline.applied[0].revision, 'online');

  const renewal = harness({ renew: async () => 'renewed-session' });
  const renewed = renewal.api.refreshStoreEntitlementsNow();
  await flush();
  renewal.requests[0].reject(new Error('HTTP 401'));
  await flush();
  assert.equal(renewal.requests[1].token, 'renewed-session');
  renewal.requests[1].resolve({ revision: 'renewed' });
  await renewed;
  assert.equal(renewal.stats().clearCount, 1);
  assert.equal(renewal.stats().renewalCount, 1);

  const anonymous = harness({ renew: async () => '' });
  const fallback = anonymous.api.startStoreColdStartBootstrap();
  await flush();
  anonymous.requests[0].reject(new Error('invalid OneBeat session'));
  await flush();
  assert.equal(anonymous.requests[1].token, '', 'Failed session renewal retains the anonymous bootstrap fallback');
  anonymous.requests[1].resolve({ revision: 'anonymous' });
  await fallback;
  assert.equal(anonymous.applied[0].revision, 'anonymous');

  const noToken = harness({ token: '' });
  const guest = noToken.api.refreshStoreEntitlementsNow();
  await flush();
  assert.equal(noToken.requests[0].token, '');
  assert.equal(noToken.stats().renewalCount, 1);
  noToken.requests[0].resolve(null);
  await guest;

  const unconfigured = harness({ configured: false });
  await Promise.all([unconfigured.api.refreshStoreEntitlements(),
    unconfigured.api.startStoreColdStartBootstrap(), unconfigured.api.refreshStoreEntitlementsNow()]);
  assert.equal(unconfigured.requests.length, 0);
  assert.equal(unconfigured.stats().restoreCount, 0);
  console.log('PASS store bootstrap refresh: active request coalescing, fresh retry, auth invalidation and offline fallback');
})().catch(error => { console.error(error); process.exitCode = 1; });
