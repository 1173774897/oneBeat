// Run with DevEco's bundled Node; pass typescript/lib/typescript.js as argv[2].
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const ts = require(process.argv[2]);

function deferred() {
  let resolve;
  let reject;
  const promise = new Promise((done, fail) => { resolve = done; reject = fail; });
  return { promise, resolve, reject };
}

const source = fs.readFileSync('entry/src/main/ets/session/SessionController.ets', 'utf8');
const compiled = ts.transpileModule(source, {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 },
  reportDiagnostics: true
});
assert.equal((compiled.diagnostics ?? []).filter(d => d.category === ts.DiagnosticCategory.Error).length, 0);

function harness(leader = false) {
  let now = 10000;
  let nextTimer = 1;
  const timers = new Map();
  const logs = [];
  const sent = [];
  const measurements = [];
  const connections = [];
  const storage = new Map();
  const measurement = deferred();
  class ClockSyncEstimator {
    offset = 7;
    getOffsetMs() { return this.offset; }
    getRttMs() { return 2; }
    recordSample() {}
    applySample(sample) { this.offset = sample.offsetMs + 0.25; }
    static measureWithSender(_sender, count) {
      measurements.push(count);
      return measurement.promise;
    }
  }
  const mocks = {
    '../common/Constants': {
      PING_SAMPLES: 11, TRANSPORT_PREPARE_TIMEOUT_MS: 900, TRANSPORT_START_PREPARE_TIMEOUT_MS: 4000,
      TRANSPORT_PREROLL_MS: 650, TRANSPORT_PAUSE_PREROLL_MS: 650,
      COUNT_IN_BARS: 1, SESSION_TCP_PORT: 9527
    },
    BuildProfile: { DEBUG: false },
    '../common/MonotonicClock': { MonotonicClock: { nowMs: () => now } },
    '../protocol/messages': { createMessage: (type, payload) => ({ type, payload }) },
    '../network/socket/SessionServer': { SessionServer: class {
      getConnections() { return connections; }
      async stop() {}
    } },
    '../network/socket/SessionClient': { SessionClient: class {} },
    '../sync/ClockSync': { ClockSyncEstimator },
    '../network/p2p/P2pInvitation': {},
    '../assets/AssetCatalog': {},
    '../common/MeterModel': { defaultBeatPointStates: () => [] },
    '../audio/DrumMachineCatalog': {},
    '../assets/CharacterCatalog': { defaultSessionAvatar: () => 'test-avatar' }
  };
  const exports = {};
  vm.runInNewContext(compiled.outputText, {
    exports,
    require: name => {
      assert.ok(mocks[name], `Unmocked dependency ${name}`);
      return mocks[name];
    },
    console: { info: line => logs.push(line), warn: line => logs.push(line) },
    AppStorage: { get: key => storage.get(key), setOrCreate: (key, value) => storage.set(key, value) },
    setTimeout(callback, delay) {
      const id = nextTimer++;
      timers.set(id, { callback, at: now + delay });
      return id;
    },
    clearTimeout: id => timers.delete(id),
    Map, Set, Promise
  }, { filename: 'SessionController.ets' });
  // The member constructor avoids unrelated avatar identity setup.
  const controller = new exports.SessionController('test-session', false, 'test');
  controller.isLeader = leader;
  controller.scheduleRandomAvatarReveals = () => {};
  controller.notifyUi = () => {};
  controller.isMemberTransportConnected = () => true;
  controller.sendToLeader = async message => { sent.push(message); };
  controller.sendToAll = async message => { sent.push(message); };
  return {
    controller, logs, sent, measurements, measurement, storage,
    now: () => now,
    addPeer(id) {
      const peer = { id, async send(message) { sent.push(message); }, async close() {} };
      connections.push(peer);
      controller.authenticatedConnections.add(id);
      return peer;
    },
    async advance(ms) {
      now += ms;
      for (const [id, timer] of [...timers]) {
        if (timer.at <= now) {
          timers.delete(id);
          timer.callback();
        }
      }
      await Promise.resolve();
      await Promise.resolve();
      await Promise.resolve();
    }
  };
}

async function main() {
  {
    const h = harness();
    const light = h.controller.measureClockSync(5);
    const prepare = h.controller.handleTransportPreparation({ id: 'reuse-five' });
    assert.deepEqual(h.measurements, [5], 'preparation must reuse the active light resync');
    assert.equal(h.sent.length, 0, 'READY must still wait for the reused work');
    await h.advance(125);
    h.measurement.resolve({ offsetMs: 12, rttMs: 3 });
    await Promise.all([light, prepare]);
    assert.equal(h.sent[0].type, 'TRANSPORT_READY');
    assert.equal(h.sent[0].payload.id, 'reuse-five');
    assert.equal(h.controller.clockSyncWorkSampleCount, 0);
    const line = h.logs.find(line => line.includes('role=member'));
    for (const value of ['result=success', 'requestedSampleCount=11', 'actualSampleCount=5',
      'reused=true', 'elapsedMs=125.0', 'offsetBeforeMs=7.00', 'sampleOffsetMs=12.00',
      'usedOffsetMs=12.25', 'rttMs=3.00']) assert.ok(line.includes(value), value);
  }
  {
    const h = harness();
    const prepare = h.controller.handleTransportPreparation({ id: 'failed-clock' });
    h.measurement.reject(new Error('synthetic ping failure'));
    await prepare;
    assert.equal(h.sent[0].type, 'TRANSPORT_READY', 'clock failure must retain the existing ACK fallback');
    assert.equal(h.controller.getOffsetMs(), 7, 'failed measurement must retain the last valid offset');
    assert.equal(h.controller.clockSyncWorkSampleCount, 0);
    const line = h.logs.find(line => line.includes('role=member'));
    for (const value of ['result=failure', 'actualSampleCount=11', 'reused=false',
      'sampleOffsetMs=unavailable', 'usedOffsetMs=7.00', 'rttMs=unavailable']) {
      assert.ok(line.includes(value), value);
    }
  }
  {
    const h = harness();
    const prepare = h.controller.handleTransportPreparation({ id: 'strict-failed-clock', requireClockReady: true });
    h.measurement.reject(new Error('synthetic ping failure'));
    await prepare;
    assert.equal(h.sent[0].payload.clockReady, false, 'strict failure must be explicit in the ACK');
  }
  {
    const h = harness();
    const prepare = h.controller.handleTransportPreparation({ id: 'strict-ready', requireClockReady: true });
    h.measurement.resolve({ offsetMs: 12, rttMs: 3 });
    await prepare;
    assert.equal(h.sent[0].payload.clockReady, true);
  }
  {
    const h = harness(true);
    h.addPeer('peer-one');
    let finished = false;
    const prepare = h.controller.prepareConnectedMembersForTransport().then(() => { finished = true; });
    await h.advance(899);
    assert.equal(finished, false, 'diagnostics must not shorten the preparation timeout');
    await h.advance(1);
    await prepare;
    assert.equal(finished, true);
    assert.equal(h.sent.length, 1);
    assert.equal(h.sent[0].type, 'TRANSPORT_PREPARE');
    assert.ok(h.logs.some(line => line.includes('role=leader stage=begin') && line.includes('peers=1 pending=1')));
    assert.ok(h.logs.some(line => line.includes('reason=timeout') && line.includes('pending=1 elapsedMs=900.0')));
  }
  {
    const h = harness(true);
    const peer = h.addPeer('peer-one');
    const prepare = h.controller.prepareConnectedMembersForTransport();
    const id = h.sent[0].payload.id;
    h.controller.onLeaderMessage(peer, { type: 'TRANSPORT_READY', payload: { id: 'stale-request' } });
    assert.ok(h.controller.transportPrepareWaiter, 'a stale READY must not finish the current wait');
    await h.advance(30);
    h.controller.onLeaderMessage(peer, { type: 'TRANSPORT_READY', payload: { id } });
    await prepare;
    assert.ok(h.logs.some(line => line.includes('reason=ready') && line.includes('pending=0 elapsedMs=30.0')));
  }
  {
    const h = harness(true);
    h.addPeer('peer-one');
    const prepare = h.controller.prepareConnectedMembersForTransport();
    h.controller.finishTransportPreparation();
    await prepare;
    assert.ok(h.logs.some(line => line.includes('reason=cancelled')));
    const disconnected = h.controller.prepareConnectedMembersForTransport();
    h.controller.releaseTransportPreparationConnection('peer-one');
    await disconnected;
    assert.ok(h.logs.some(line => line.includes('reason=disconnected')));
  }
  console.log('PASS transport preparation diagnostics: reused sampling, failure ACK, timeout, ready, cancellation');
}

module.exports = { harness, deferred };
if (require.main === module) main().catch(error => { console.error(error); process.exitCode = 1; });
