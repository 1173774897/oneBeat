// Run with DevEco's bundled Node; pass its typescript/lib/typescript.js path.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const ts = require(process.argv[2]);

const compiled = ts.transpileModule(fs.readFileSync('entry/src/main/ets/sync/ClockSync.ets', 'utf8'), {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 },
  reportDiagnostics: true
});
assert.equal((compiled.diagnostics ?? []).filter(d => d.category === ts.DiagnosticCategory.Error).length, 0);

function harness() {
  const clock = { now: 37000000 };
  const logs = [];
  const exports = {};
  vm.runInNewContext(compiled.outputText, {
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
  return { estimator: new exports.ClockSyncEstimator(), Estimator: exports.ClockSyncEstimator, clock, logs };
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
    // Raw pings never reach the estimator: only the filtered median is returned.
    const h = harness();
    const rtts = [600, 12, 450, 14, 13, 520, 15, 700, 16, 480, 20];
    let i = 0;
    const result = await h.Estimator.measureWithSender(async (_id, t0) => {
      const rtt = rtts[i++];
      h.clock.now = t0 + rtt;
      const bias = rtt > 100 ? -rtt / 2 : 0;
      const serverMono = t0 + TRUE_OFFSET + rtt / 2 + bias;
      return { serverMono, leaderMono: serverMono };
    }, rtts.length);
    assert.equal(h.estimator.getOffsetMs(), 0, 'measurement must not mutate the estimator');
    assert.ok(Math.abs(result.offsetMs - TRUE_OFFSET) < 1, `median ${result.offsetMs}`);
    assert.equal(result.rttMs, 12);
  }
  console.log('PASS clock sync fit: rtt weighting, NTP-bound reset, raw pings excluded');
}

main().catch(error => { console.error(error); process.exitCode = 1; });
