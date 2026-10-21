const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const ts = require(process.argv[2] || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
const source = fs.readFileSync('entry/src/main/ets/audio/RecordingPlaybackObserver.ets', 'utf8');
let interval;
const logs = [];
const context = { exports: {}, console: { info: text => logs.push(text), warn: text => logs.push(text) },
  setInterval: (callback, ms) => { assert.equal(ms, 250); interval = callback; return 1; },
  clearInterval: () => { interval = undefined; } };
vm.runInNewContext(ts.transpileModule(source, {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 }
}).outputText, context);
const Observer = context.exports.RecordingPlaybackObserver;
const base = () => ({ sampledAtMonoMs: 1000, rendererEpoch: 1, streamId: 42, physicalStartCount: 1,
  running: true, started: true, state: 2, interruptCount: 0, underflowCount: 0,
  lastWriteProgressMs: 999, outputDevices: '8:1', audioScene: 0, latencyHardwareMs: 100,
  latencySoftwareMs: 20, latencyAllMs: 120, rawFrame: 44100, timestampMonoMs: 1000 });
function fixture({ snapshot = base(), transport = 'playing' } = {}) {
  const calls = [];
  const failures = [];
  const current = { snapshot, transport };
  const observer = new Observer(details => {
    calls.push(details);
    if (!current.snapshot) return undefined;
    return details ? { ...current.snapshot } : { ...current.snapshot, outputDevices: '', audioScene: -1,
      latencyHardwareMs: -1, latencySoftwareMs: -1, latencyAllMs: -1 };
  }, () => current.transport, reason => failures.push(reason));
  assert.equal(observer.start(), '');
  return { observer, current, calls, failures };
}
for (const transport of ['playing', 'countdown']) {
  const f = fixture({ transport });
  f.current.snapshot.sampledAtMonoMs = 1250;
  f.current.snapshot.lastWriteProgressMs = 1249;
  f.current.snapshot.rawFrame += 11025;
  f.current.snapshot.timestampMonoMs += 250;
  interval();
  assert.deepEqual(f.calls, [true, false], 'Polling never queries platform latency or route');
  f.current.snapshot.latencySoftwareMs = 200;
  f.current.snapshot.latencyAllMs = 300;
  assert.equal(f.observer.checkpoint('native-started'), '', 'Software queue changes only log');
  f.current.transport = 'playing';
  assert.equal(f.observer.checkpoint('countdown-finished'), '');
  assert.deepEqual(f.failures, []);
  f.observer.dispose();
  assert.equal(interval, undefined);
}
for (const [change, match] of [
  [{ outputDevices: '2:3' }, /输出设备/], [{ audioScene: 3 }, /场景/],
  [{ interruptCount: 1 }, /焦点/], [{ latencyHardwareMs: 110 }, /硬件输出延迟/],
  [{ rendererEpoch: 2 }, /播放实例/], [{ streamId: 44 }, /播放实例/],
  [{ physicalStartCount: 2 }, /物理起点/], [{ running: false }, /中断/],
  [{ started: false }, /中断/], [{ state: 3 }, /中断/],
  [{ underflowCount: 1 }, /缓冲不足/], [{ sampledAtMonoMs: 2600 }, /未持续推进/],
  [{ rawFrame: 0 }, /时钟/], [{ timestampMonoMs: 1200 }, /时钟/]
]) {
  const f = fixture();
  Object.assign(f.current.snapshot, change);
  assert.match(f.observer.checkpoint('native-started'), match, JSON.stringify(change));
  assert.equal(f.failures.length, 1);
  assert.equal(interval, undefined);
  f.observer.checkpoint('after-native-stop');
  assert.equal(f.failures.length, 1, 'Unsafe callback fires once');
  f.observer.dispose();
}
{
  const f = fixture();
  f.current.snapshot.latencyHardwareMs = 106;
  assert.equal(f.observer.checkpoint('intermediate'), '');
  f.current.snapshot.latencyHardwareMs = 111;
  assert.match(f.observer.checkpoint('later'), /硬件输出延迟/, 'Compare cumulative displacement to initial baseline');
  f.observer.dispose();
}
for (const initial of ['idle', 'paused', 'countdown']) {
  const f = fixture({ transport: initial, snapshot: { ...base(), running: false, started: false,
    streamId: -1, state: -1, rawFrame: -1, timestampMonoMs: -1 } });
  f.current.transport = 'countdown';
  f.current.snapshot = { ...base(), rendererEpoch: 2, streamId: 43, physicalStartCount: 1 };
  assert.equal(f.observer.checkpoint('natural-start'), '', 'Initial rendering is allowed');
  f.current.transport = 'playing';
  assert.equal(f.observer.checkpoint('countdown-end'), '');
  f.current.transport = 'paused';
  f.current.snapshot.running = false;
  f.current.snapshot.started = false;
  f.current.snapshot.state = 3;
  assert.equal(f.observer.checkpoint('leader-pause'), '', 'Natural pauses stay available during capture');
  f.current.transport = 'playing';
  f.current.snapshot = { ...base(), rendererEpoch: 3, streamId: 44 };
  assert.equal(f.observer.checkpoint('leader-resume'), '', 'Natural resumed stream is reacquired');
  assert.equal(f.failures.length, 0);
  f.current.snapshot.physicalStartCount++;
  assert.match(f.observer.checkpoint('unexpected-restart'), /物理起点/);
  f.observer.dispose();
}
{
  let count = 0;
  const observer = new Observer(() => undefined, () => 'idle', () => count++);
  assert.equal(observer.start(), '');
  interval();
  assert.equal(observer.checkpoint('native-started'), '');
  assert.equal(count, 0, 'No session is explicitly unobserved, not declared synchronized');
  observer.dispose();
}
{
  const f = fixture({ snapshot: { ...base(), outputDevices: '8:1,2:3' } });
  f.current.snapshot.outputDevices = '2:3,8:1';
  assert.equal(f.observer.checkpoint('reordered'), '', 'Descriptor order is not a physical route change');
  f.current.snapshot.outputDevices = 'unavailable';
  assert.equal(f.observer.checkpoint('unsupported'), '', 'Unavailable route queries are explicitly unknown');
  f.current.snapshot.outputDevices = '8:1,2:3';
  assert.equal(f.observer.checkpoint('recovered-query'), '');
  f.observer.dispose();
}
{
  const f = fixture({ snapshot: { ...base(), underflowCount: -1 } });
  f.current.snapshot.underflowCount = 2;
  assert.equal(f.observer.checkpoint('first-known-counter'), '');
  f.current.snapshot.underflowCount = 3;
  assert.match(f.observer.checkpoint('later-underflow'), /缓冲不足/);
  f.observer.dispose();
}
{
  const f = fixture();
  f.current.snapshot = undefined;
  assert.match(f.observer.checkpoint('native-started'), /会话已结束/);
  f.observer.dispose();
}
{
  const f = fixture({ snapshot: { ...base(), latencyHardwareMs: -1, audioScene: -1, underflowCount: -1 } });
  f.current.snapshot.latencyHardwareMs = 70;
  f.current.snapshot.audioScene = 0;
  f.current.snapshot.underflowCount = 2;
  assert.equal(f.observer.checkpoint('known-later'), '', 'Unsupported queries never become zero latency');
  f.current.snapshot.latencyHardwareMs = 80;
  assert.match(f.observer.checkpoint('changed-later'), /硬件输出延迟/);
  f.observer.dispose();
}
assert.ok(logs.some(text => /hardwareMs=.*softwareMs=.*allMs=/.test(text)), 'Boundary diagnostics retain hardware and queue estimates separately');
assert.doesNotMatch(source, /AppStorage|AudioOutputMonitor|\.pause\(|\.recoverAudio\(|\.reschedule|\.refreshOutputCalibration\(/,
  'Recording observer cannot mutate team playback, calibration or global route listeners');
console.log('PASS recording playback observer: leader/member transport boundaries, output/focus/hardware latency, diagnostics and read-only ownership');
