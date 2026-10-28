// Run with DevEco's bundled Node; pass its typescript/lib/typescript.js path.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const ts = require(process.argv[2]);

function compile(file) {
  const result = ts.transpileModule(fs.readFileSync(file, 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 },
    reportDiagnostics: true
  });
  assert.equal((result.diagnostics ?? []).filter(d => d.category === ts.DiagnosticCategory.Error).length, 0);
  return result.outputText;
}
const compiled = compile('entry/src/main/ets/sync/ClockSync.ets');
const controllerCompiled = compile('entry/src/main/ets/session/SessionController.ets');

function harness() {
  const clock = { now: 37000000 };
  const logs = [];
  const exports = {};
  vm.runInNewContext(compiled, {
    exports,
    require: name => {
      if (name === '../common/MonotonicClock') return { MonotonicClock: { nowMs: () => clock.now } };
      if (name === '../common/Constants') return { PING_SAMPLES: 11 };
      if (name === '../protocol/messages') return {};
      throw new Error(`Unmocked dependency ${name}`);
    },
    console: { info: line => logs.push(line), warn: line => logs.push(line) },
    setTimeout: (callback, ms) => { clock.now += ms; Promise.resolve().then(callback); return 0; },
    Math, Number, Promise
  });
  return { estimator: new exports.ClockSyncEstimator(), Estimator: exports.ClockSyncEstimator,
    MeasurementError: exports.ClockSyncMeasurementError, clock, logs };
}

function memberController(h) {
  const exports = {};
  const mocks = {
    '../common/Constants': { PING_SAMPLES: 11 },
    '../common/MonotonicClock': { MonotonicClock: { nowMs: () => h.clock.now } },
    BuildProfile: { DEBUG: false },
    '../protocol/messages': { createMessage: (type, payload) => ({ type, payload }) },
    '../network/socket/SessionServer': { SessionServer: class {} },
    '../network/socket/SessionClient': { SessionClient: class {} },
    '../sync/ClockSync': { ClockSyncEstimator: h.Estimator, ClockSyncMeasurementError: h.MeasurementError },
    '../network/p2p/P2pInvitation': {},
    '../assets/AssetCatalog': {},
    '../common/MeterModel': { defaultBeatPointStates: () => [] },
    '../audio/DrumMachineCatalog': {},
    '../assets/CharacterCatalog': { defaultSessionAvatar: () => 'test-avatar' }
  };
  vm.runInNewContext(controllerCompiled, {
    exports,
    require: name => {
      assert.ok(mocks[name], `Unmocked controller dependency ${name}`);
      return mocks[name];
    },
    AppStorage: { get: () => undefined },
    Map, Set, Promise
  });
  const controller = new exports.SessionController('test-session', false, 'test');
  controller.clockSync = h.estimator;
  return controller;
}

const TRUE_OFFSET = 87230308;

async function main() {
  {
    // A slow measurement inside the window must not drag a fast-link fit by its rtt/2.
    const h = harness();
    for (let i = 0; i < 10; i++) {
      h.estimator.applySample({ offsetMs: TRUE_OFFSET + (i % 2 === 0 ? 1 : -1), rttMs: 12 });
      h.clock.now += 5000;
    }
    h.estimator.applySample({ offsetMs: TRUE_OFFSET - 150, rttMs: 380 });
    assert.ok(Math.abs(h.estimator.getOffsetMs() - TRUE_OFFSET) < 3,
      `slow sample must be down-weighted, got ${h.estimator.getOffsetMs()}`);
  }
  {
    // 12:52 replay: the window is already biased ~150ms low. A fresh low-rtt median proves
    // that history wrong, so the used offset must equal the new median instead of a blend.
    const h = harness();
    for (let i = 0; i < 6; i++) {
      h.estimator.applySample({ offsetMs: TRUE_OFFSET - 150, rttMs: 14 });
      h.clock.now += 5000;
    }
    h.estimator.applySample({ offsetMs: TRUE_OFFSET - 1, rttMs: 22 });
    assert.equal(h.estimator.getOffsetMs(), TRUE_OFFSET - 1);
    assert.ok(h.logs.some(line => line.startsWith('[ClockFitDiag] action=reset') &&
      line.includes('droppedSamples=6')));
    h.clock.now += 5000;
    h.estimator.applySample({ offsetMs: TRUE_OFFSET + 0.5, rttMs: 17 });
    assert.ok(Math.abs(h.estimator.getOffsetMs() - TRUE_OFFSET) < 2);
  }
  {
    // Ordinary jitter inside the NTP interval keeps the history and does not reset.
    const h = harness();
    for (let i = 0; i < 8; i++) {
      h.estimator.applySample({ offsetMs: TRUE_OFFSET + (i % 3) * 3, rttMs: 14 });
      h.clock.now += 5000;
    }
    assert.equal(h.logs.length, 0, 'in-bound jitter must not reset the fit');
  }
  {
    // A sample inside the NTP interval does not trigger the reset above. After
    // 60 s, however, expired skew history must not project into a fresh start.
    const h = harness();
    for (let i = 0; i < 6; i++) {
      h.estimator.applySample({ offsetMs: TRUE_OFFSET, rttMs: 14 });
      h.clock.now += 5000;
    }
    h.clock.now += 65000;
    h.estimator.applySample({ offsetMs: TRUE_OFFSET + 8, rttMs: 14 });
    assert.equal(h.logs.length, 0, 'This case must exercise expiry rather than an NTP reset');
    assert.equal(h.estimator.getOffsetMs(), TRUE_OFFSET + 8,
      'A fresh result must replace expired history without a residual blend');
    assert.equal(h.estimator.getOffsetAt(h.clock.now + 20000), TRUE_OFFSET + 8,
      'One fresh sample must not inherit drift from expired history');
  }
  {
    // Exercise the real SessionController caller as well as ClockSync. A static
    // measurement and an unrelated estimator would stay independent even when
    // the old per-ping fit callback was accidentally restored in the caller.
    const h = harness();
    for (let i = 0; i < 6; i++) {
      h.estimator.applySample({ offsetMs: TRUE_OFFSET, rttMs: 12 });
      h.clock.now += 5000;
    }
    const controller = memberController(h);
    const rtts = [600, 12, 450, 14, 13, 520, 15, 700, 16, 480, 20];
    let i = 0;
    controller.sendPing = async (_id, t0) => {
      assert.ok(Math.abs(h.estimator.getOffsetMs() - TRUE_OFFSET) < 0.01,
        'Unfiltered packets must not alter the live clock fit while a batch is measuring');
      const rtt = rtts[i++];
      h.clock.now = t0 + rtt;
      const bias = rtt > 100 ? -rtt / 2 : 0;
      const serverMono = t0 + TRUE_OFFSET + rtt / 2 + bias;
      return { serverMono, leaderMono: serverMono };
    };
    const result = await controller.measureClockSync(rtts.length);
    assert.equal(i, rtts.length, 'The real caller must measure the whole batch');
    assert.ok(Math.abs(h.estimator.getOffsetMs() - TRUE_OFFSET) < 0.01,
      'The live fit must remain unchanged until the caller accepts the filtered result');
    assert.ok(Math.abs(result.offsetMs - TRUE_OFFSET) < 1, `median ${result.offsetMs}`);
    assert.equal(result.rttMs, 12);
    h.estimator.applySample(result);
    assert.ok(Math.abs(h.estimator.getOffsetAt(h.clock.now + 20000) - TRUE_OFFSET) < 0.1,
      'A wake-up batch containing slow asymmetric packets must not bias a later shared start');
  }
  console.log('PASS clock sync fit: rtt weighting, NTP-bound reset, expired-history recovery, real SessionController raw-ping isolation');
}

module.exports = { harness, memberController };
if (require.main === module) main().catch(error => { console.error(error); process.exitCode = 1; });
