// Run with DevEco's bundled Node; pass typescript/lib/typescript.js as argv[2].
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const ts = require(process.argv[2]);

function compile(path) {
  const result = ts.transpileModule(fs.readFileSync(path, 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 },
    reportDiagnostics: true
  });
  assert.equal((result.diagnostics ?? []).filter(d => d.category === ts.DiagnosticCategory.Error).length, 0);
  return result.outputText;
}
const probeCode = compile('entry/src/main/ets/audio/TeamAcousticProbe.ets');
const observerCode = compile('entry/src/main/ets/audio/RecordingPlaybackObserver.ets');

function harness() {
  const events = [];
  const intervals = new Map();
  const recording = { state: 'idle', captureActive: false };
  const output = {
    sampledAtMonoMs: 1000, rendererEpoch: 1, streamId: 9, physicalStartCount: 1,
    running: true, started: true, state: 2, outputDevices: '8:1', audioScene: 0,
    latencyHardwareMs: 200, latencySoftwareMs: 40, latencyAllMs: 240,
    interruptCount: 0, underflowCount: 0, rawFrame: 44100, timestampMonoMs: 1000,
    lastWriteProgressMs: 1000, productionFrame: 44100, productionClockQueryMonoMs: 1000,
    transportStartLocalMs: 500, transportStartBeatIndex: 0, transportBpm: 120,
    transportOutputCompensationMs: 240, sharedClockOffsetMs: 0
  };
  let permission = 0;
  let gate;
  const session = { controller: { state: 'playing' }, metronome: {
    readMicExperimentPlaybackSnapshot(details) {
      events.push(['snapshot', details]);
      return { ...output, ...(details ? {} : {
        outputDevices: '', audioScene: -1, latencyHardwareMs: -1,
        latencySoftwareMs: -1, latencyAllMs: -1
      }) };
    }
  } };
  let currentSession = session;
  class MockExperiment {
    async run(filesDir, source, observer, duration) {
      events.push(['run', filesDir, source, duration]);
      observer.snapshot();
      if (gate) await gate;
      observer.snapshot();
      return { totalFrames: 480000, sampleRate: 48000, channels: 1, peak: .2,
        wavPath: `${filesDir}/mic-capture-experiment/mic.wav`,
        reportPath: `${filesDir}/mic-capture-experiment/mic.json` };
    }
    cancel() { events.push(['cancel']); }
  }
  let timerId = 0;
  const shared = {
    console: { info: message => events.push(['log', message]), warn: message => events.push(['log', message]) },
    setInterval(callback) { const id = ++timerId; intervals.set(id, callback); return id; },
    clearInterval(id) { intervals.delete(id); }
  };
  const observerContext = { ...shared, exports: {} };
  vm.runInNewContext(observerCode, observerContext);
  const mocks = {
    '@kit.AbilityKit': { abilityAccessCtrl: {
      createAtManager: () => ({ checkAccessTokenSync: () => permission }),
      GrantStatus: { PERMISSION_GRANTED: 0 }
    } },
    'libonebeat_recording.so': { chmod: (...args) => { events.push(['chmod', ...args]); return true; } },
    '../app/AppSession': { AppSession: { get: () => { events.push(['session']); return currentSession; } } },
    '../recording/RecordingCoordinator': { RecordingCoordinator: { getSnapshot: () => ({ ...recording }) } },
    '../recording/RecordingRepository': { RecordingRepository: {
      async exportLatestTracksForDebug() { events.push(['export']); return ['/private/files/recordings/debug-export-mic.pcm']; }
    } },
    './MicCaptureExperiment': { MicCaptureExperiment: MockExperiment },
    './RecordingPlaybackObserver': observerContext.exports
  };
  const context = { ...shared, exports: {}, require(name) {
    assert.ok(Object.hasOwn(mocks, name), `Unexpected dependency ${name}`);
    return mocks[name];
  } };
  vm.runInNewContext(probeCode, context);
  const api = context.exports.TeamAcousticProbe;
  const ability = { applicationInfo: { debug: true, accessTokenId: 123 }, filesDir: '/private/files' };
  return { events, output, recording, session, api, ability, intervals,
    command: (command, other = {}) => api.handleWant(ability, { parameters: { onebeatProbe: command, ...other } }),
    setPermission: value => { permission = value; },
    setGate: value => { gate = value; },
    changeSession: () => { currentSession = { ...session }; }
  };
}

(async () => {
  const release = harness();
  release.ability.applicationInfo.debug = false;
  await release.command('mic');
  await release.command('snapshot');
  await release.command('export');
  assert.equal(release.events.length, 0, 'Release builds must not read session, capture, or export');

  const unknown = harness();
  await unknown.command('volume-on');
  assert.equal(unknown.events.length, 0, 'Only the fixed passive whitelist is callable');

  const successful = harness();
  const before = JSON.stringify(successful.output);
  await successful.command('mic', { path: '/caller/path', durationMs: 1000000 });
  assert.deepEqual(successful.events.find(event => event[0] === 'run'), ['run', '/private/files', 'mic', 10000]);
  assert.equal(successful.events.filter(event => event[0] === 'chmod').length, 2);
  assert.ok(successful.events.filter(event => event[0] === 'chmod').every(event => event[2] === 0o644));
  assert.equal(JSON.stringify(successful.output), before, 'No renderer/transport/calibration state may be changed');
  assert.equal(successful.intervals.size, 0, 'All observation timers are disposed');

  for (const state of ['preparing', 'recording', 'stopping']) {
    const busy = harness(); busy.recording.state = state;
    await busy.command('mic');
    assert.ok(!busy.events.some(event => event[0] === 'run'));
  }
  const active = harness(); active.recording.captureActive = true;
  await active.command('mic');
  assert.ok(!active.events.some(event => event[0] === 'run'));

  const denied = harness(); denied.setPermission(-1);
  await denied.command('mic');
  assert.ok(!denied.events.some(event => event[0] === 'run'), 'Permission failure never opens a prompt or capturer');

  const paused = harness(); paused.session.controller.state = 'paused';
  await paused.command('mic');
  assert.ok(!paused.events.some(event => event[0] === 'run'));
  await paused.command('snapshot');
  assert.ok(paused.events.some(event => event[0] === 'log' && event[1].includes('stage=snapshot')));

  for (const mutate of [
    h => h.api.cancel(),
    h => h.changeSession(),
    h => { h.session.controller.state = 'paused'; },
    h => { h.recording.state = 'preparing'; },
    h => { h.output.latencyHardwareMs += 10; },
    h => { h.output.streamId += 1; },
    h => { h.output.interruptCount += 1; },
    h => { h.output.underflowCount += 1; }
  ]) {
    const changed = harness();
    let resume; changed.setGate(new Promise(resolve => { resume = resolve; }));
    const operation = changed.command('mic');
    mutate(changed); resume(); await operation;
    assert.ok(!changed.events.some(event => event[0] === 'chmod'), 'Changed session/output cannot publish a valid diagnostic');
    assert.equal(changed.intervals.size, 0);
  }

  const serial = harness();
  let resume; serial.setGate(new Promise(resolve => { resume = resolve; }));
  const operation = serial.command('mic');
  await serial.command('export');
  assert.ok(!serial.events.some(event => event[0] === 'export'));
  resume(); await operation;
  await serial.command('export');
  assert.equal(serial.events.filter(event => event[0] === 'export').length, 1);
  console.log('PASS debug acoustic probe: release/permission/busy guards, fixed passive capture, cancellation, output/session validation, exports');
})().catch(error => { console.error(error); process.exitCode = 1; });
