// Run with DevEco's bundled Node; pass its typescript/lib/typescript.js path.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const ts = require(process.argv[2]);

const source = fs.readFileSync('entry/src/main/ets/pages/TimeCardCalibrationPage.ets', 'utf8');
function numericConstant(name) {
  const match = source.match(new RegExp(`const ${name}: number = (-?[\\d.]+);`));
  assert.ok(match, `Expected a numeric page layout constant ${name}`);
  return Number(match[1]);
}
const resultTextBottom = numericConstant('RESULT_TEXT_Y') + numericConstant('RESULT_TITLE_HEIGHT') +
  numericConstant('RESULT_VALUE_HEIGHT') + numericConstant('RESULT_JITTER_HEIGHT') +
  2 * numericConstant('RESULT_TEXT_GAP');
const holeGridTop = 1020 - 7 * 82 - 26 / 2;
assert.ok(resultTextBottom + 20 <= holeGridTop,
  'The result text line boxes must leave a clear gap above the highest punched row');
const builderStart = source.indexOf('  @Builder');
assert.ok(builderStart > 0, 'The page must expose business methods before ArkUI builders');
// Execute the page's actual timing and lifecycle methods. Only ArkUI syntax is
// stripped; the device-free harness must not replace calibration arithmetic.
const businessSource = source.slice(0, builderStart)
  .replace(/@(?:Entry|Component)\b\s*/g, '')
  .replace(/@State\s+/g, '')
  .replace(/@(?:StorageLink|Watch)\([^)]*\)\s*/g, '')
  .replace('struct TimeCardCalibrationPage', 'export class TimeCardCalibrationPage') + '\n}\n';
const compiled = ts.transpileModule(businessSource, {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 },
  reportDiagnostics: true
});
assert.equal((compiled.diagnostics ?? []).filter(d => d.category === ts.DiagnosticCategory.Error).length, 0,
  'The actual page business methods must transpile');

function deferred() {
  let resolve;
  let reject;
  const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}

function harness(options = {}) {
  const pixelRatio = options.pixelRatio ?? 2;
  let now = 100000;
  let nextTimer = 1;
  let persistedMs = options.previousMs ?? 72;
  let sessionAvailable = !options.noSession;
  const timers = new Map();
  const nativeAnimations = new Map();
  const archived = new Map();
  const trace = [];
  const writes = [];
  const toasts = [];
  const feedback = [];
  let page;
  function addTimer(callback, delay = 0, interval = 0) {
    const id = nextTimer++;
    const entry = { id, callback, at: now + Math.max(0, delay), interval };
    timers.set(id, entry);
    archived.set(id, entry);
    return id;
  }
  function cancelTimer(id) { timers.delete(id); }
  function advanceTo(target) {
    assert.ok(target >= now, 'The monotonic clock must move forward');
    let callbacks = 0;
    while (true) {
      const due = [...timers.values(), ...nativeAnimations.values()].filter(timer => timer.at <= target)
        .sort((a, b) => a.at - b.at || a.id - b.id)[0];
      if (due === undefined) break;
      assert.ok(++callbacks < 10000, 'Timers must settle instead of spinning forever');
      now = Math.max(now, due.at);
      if (due.interval > 0) due.at += due.interval;
      else {
        timers.delete(due.id);
        nativeAnimations.delete(due.id);
      }
      due.callback();
    }
    now = target;
  }
  const session = {
    controller: { async setBluetoothCalibrationActive(active) { trace.push(`active:${active}`); } },
    metronome: { refreshOutputCalibration() { trace.push('refresh'); } },
    async scheduleLatencyTapMeasurement(startAt, countIn) {
      trace.push(`measure:${startAt}:${countIn}`);
      if (options.measurement !== undefined) await options.measurement.promise;
    },
    async scheduleLatencyPreview(startAt, compensation) {
      trace.push(`preview:${startAt}:${compensation}`);
      if (options.preview !== undefined) await options.preview.promise;
    },
    pauseLatencyCalibration() { trace.push('pause'); },
    async stopLatencyCalibration() { trace.push('stop'); },
    keepLatencyCalibrationRendererAlive() { trace.push('keep-alive'); },
    markLatencyCalibrationRoute(wireless) { trace.push(`mark-route:${wireless}`); }
  };
  const mocks = {
    '@kit.ArkUI': {
      router: { back() { trace.push('back'); } },
      promptAction: { showToast(args) { toasts.push(args.message); } }
    },
    '../app/AppSession': { AppSession: { get: () => sessionAvailable ? session : undefined } },
    '../common/MonotonicClock': { MonotonicClock: { nowMs: () => now } },
    '../store/AudioLatencyPersistence': {
      getCalibrationMs: () => persistedMs,
      async saveCalibrationMs(value) {
        writes.push(value);
        if (options.save !== undefined) await options.save.promise;
        persistedMs = value;
      },
      async clearCalibrationMs() { persistedMs = -1; },
      getInputLatencyMs: () => -1
    },
    '../components/ComicKit': {
      BLUE: '#A9D4ED', CORAL: '#F88565', INK: '#171B1F', LILAC: '#CBB3ED',
      PAPER: '#F7EFDF', TEAL: '#69B9B0', WHITE: '#FFFFFF',
      CARD_SHADOW: {}, CONTROL_SHADOW: {}
    }
  };
  const context = {
    exports: {},
    require(name) {
      assert.ok(Object.hasOwn(mocks, name), `Unexpected page dependency ${name}`);
      return mocks[name];
    },
    console: { info() {}, warn() {}, error() {} },
    TouchType: { Down: 0, Up: 1, Move: 2, Cancel: 3 },
    SourceType: { Unknown: 0, Mouse: 1, TouchScreen: 2, TouchPad: 3, Joystick: 4, Keyboard: 5 },
    Scroller: class { scrollEdge() {} },
    Edge: { Top: 0 },
    vp2px: value => value * pixelRatio,
    Curve: { EaseInOut: 0, EaseOut: 1, EaseIn: 2, Linear: 3 },
    animateTo(animation, action) {
      const beforeRam = page?.ramDrop ?? 0;
      action();
      if (page !== undefined && beforeRam === 0 && page.ramDrop > 0) {
        assert.ok(page.tapOffsetsMs.length > page.visualTapCount,
          'The touch sample must commit before its lever and punch head move');
        feedback.push(page.visualTapCount + 1);
      }
      // ArkUI commits animated state immediately but finishes later. Result
      // reading must start after the card's lift, not when its pose is set.
      if (typeof animation.onFinish === 'function') {
        const id = nextTimer++;
        nativeAnimations.set(id, { id, callback: animation.onFinish,
          at: now + (animation.delay ?? 0) + (animation.duration ?? 0), interval: 0 });
      }
    },
    setTimeout: (callback, delay) => addTimer(callback, delay),
    clearTimeout: cancelTimer,
    setInterval: (callback, delay) => addTimer(callback, delay, Math.max(1, delay)),
    clearInterval: cancelTimer
  };
  vm.runInNewContext(compiled.outputText, context);
  page = new context.exports.TimeCardCalibrationPage();
  page.aboutToAppear();
  page.btAudioActive = true;
  assert.equal(typeof page.enqueuePunchFeedback, 'function');
  function touch(at, callbackDelay = 0, type = 0) {
    advanceTo(Math.max(now, at + callbackDelay));
    const event = { type, timestamp: at * 1000000 };
    page.onTapTouch(event);
    page.onPageTouch(event);
  }
  function pageTouch(type, at = now) {
    page.onPageTouch({ type, timestamp: at * 1000000 });
  }
  function resultTouch(action, type, at = now) {
    const event = { type, timestamp: at * 1000000 };
    // Child touch handlers run before the event bubbles to the page. A touch
    // held across unlock must not acquire permission merely because it lifts.
    page.onResultActionTouch(event, action);
    page.onPageTouch(event);
  }
  async function resultClick(action = 'save', source = 2) {
    const accepted = page.consumeResultActionClick(action, { source, timestamp: now * 1000000 });
    if (accepted) {
      if (action === 'save') await page.finishAndSave();
      else page.retryMeasurement();
    }
    return accepted;
  }
  function staleTimerCallbacks() {
    return [...archived.values(), ...nativeAnimations.values()].map(timer => () => {
      // Manually delivering a queued callback consumes that queue entry just
      // as the event loop does; a guard may then install a different deadline.
      timers.delete(timer.id);
      nativeAnimations.delete(timer.id);
      timer.callback();
    });
  }
  return { page, session, trace, writes, toasts, feedback, timers, touch, pageTouch, resultTouch, resultClick, advanceTo,
    advanceBy: delay => advanceTo(now + delay),
    now: () => now, setNow: value => { now = value; }, pixelRatio,
    setSessionAvailable: available => { sessionAvailable = available; },
    staleTimerCallbacks, persistedMs: () => persistedMs };
}

async function begin(h) {
  await h.page.startMeasurement();
  assert.equal(h.page.phase, 'listening');
  assert.ok(h.page.measurementStartAtMs > h.now());
  assert.equal(h.page.paperDepthScale, numericConstant('PAPER_DEPTH_SCALE'),
    'A fresh card must use the configured feed-plane depth');
  assert.equal(h.page.paperPerspective, numericConstant('PAPER_PERSPECTIVE'),
    'A fresh card must use the configured perspective over the upright texture');
  assert.ok(h.page.paperDepthScale > 0 && h.page.paperDepthScale < 1 && h.page.paperPerspective > 0,
    'The active feed plane must have a finite perspective camera and an upright result transition');
  assertPaperVisible(h);
  for (let row = 0; row < 8; row++) {
    h.page.updatePaperFeed(row * 4);
    for (let col = 0; col < 4; col++) {
      const [x, y] = projectPaper(h, 420 + col * 150, 1020 - row * 82);
      assert.ok(Math.abs(170 + x * 0.68 - (455.6 + col * 102)) < 0.001,
        `Paper row ${row + 1} must fill the same four inlet positions`);
      assert.ok(Math.abs(h.page.cardY + y * 0.68 - 686) < 0.001,
        `Paper row ${row + 1} must meet the die plane after feeding`);
    }
    for (const sourceY of [0, 1254]) {
      assert.ok(h.page.paperDivisor(sourceY) > 0, 'No paper corner may cross the perspective horizon');
    }
    assertPaperVisible(h, row);
  }
  h.page.updatePaperFeed(0);
  const topWidth = projectPaper(h, 1018, 54)[0] - projectPaper(h, 238, 54)[0];
  const bottomWidth = projectPaper(h, 1018, 1208)[0] - projectPaper(h, 238, 1208)[0];
  assert.ok(bottomWidth > topWidth, 'The active upright texture must project to a narrower far edge');
}

// Evaluate the options passed to native scale/rotate through Rosen's camera:
// scale precedes rotation, the Skia paper Y axis points up, and camera Z uses
// inches. This catches a wrong camera sign, density or pivot at the API boundary.
function projectPaper(h, x, y) {
  const scale = h.page.paperScale();
  const rotation = h.page.paperRotation();
  const unit = h.page.cardScale * h.page.sceneWidth / 1254 * h.pixelRatio;
  assert.equal(scale.centerX, rotation.centerX, 'Rotation and feed scale must share the same paper center');
  assert.equal(scale.centerY, rotation.centerY, 'Rotation and feed scale must share the same paper anchor');
  assert.ok(Number.isFinite(rotation.perspective) && rotation.perspective < 0,
    'The camera must stay on a finite negative Z coordinate, including the upright result');
  const cx = rotation.centerX * h.pixelRatio, cy = rotation.centerY * h.pixelRatio;
  const px = (x * unit - cx) * scale.x, py = (y * unit - cy) * scale.y;
  const angle = rotation.angle * Math.PI / 180;
  const cameraZ = rotation.perspective * 72;
  const paperZ = -Math.sin(angle) * py;
  const w = (paperZ - cameraZ) / -cameraZ;
  assert.ok(w > 0, 'Projected artwork must remain in front of the perspective horizon');
  return [(cx + px / w) / unit, (cy + Math.cos(angle) * py / w) / unit];
}

function assertPaperVisible(h, row = Math.min(7, Math.floor(h.page.visualTapCount / 4))) {
  // A broad paper band must remain above the cover's first opaque edge at
  // y=718.08, rather than only a sliver leaking out at the cover's right side.
  const sourceY = h.page.phase === 'intro' ? 700 : 1020 - row * 82;
  const left = projectPaper(h, 238, sourceY), right = projectPaper(h, 1018, sourceY);
  const sceneLeft = h.page.cardX + left[0] * h.page.cardScale;
  const sceneRight = h.page.cardX + right[0] * h.page.cardScale;
  const sceneY = h.page.cardY + left[1] * h.page.cardScale;
  assert.ok(sceneLeft > 0 && sceneRight < 1254 && sceneRight - sceneLeft > 400,
    'A complete paper band must remain centered inside the scene');
  assert.ok(sceneY > h.page.paperClipTop && sceneY < 718.08 && sceneY < 785,
    'The paper band must be inside the feed window and above the front cover');
}

async function collectCompleteRun(h) {
  await begin(h);
  const firstAt = h.page.measurementStartAtMs;
  // Unequal offsets distinguish event-time sampling from callback-time sampling.
  const offsets = Array.from({ length: 32 }, (_, i) => 120 + (i % 2 === 0 ? -10 : 10));
  offsets.forEach((offset, i) => h.touch(firstAt + i * 500 + offset, 37));
  h.pageTouch(1);
  assert.equal(h.page.tapCount, 32);
  assert.deepEqual(Array.from(h.page.tapOffsetsMs), offsets,
    'Every sample must retain the touch hardware timestamp despite delayed JS delivery');
  h.advanceBy(1500);
  assert.equal(h.page.phase, 'result');
  assert.equal(h.page.resultMs, 120);
  assert.equal(h.page.jitterMs, 10);
  assert.equal(h.page.paperDepthScale, 1, 'The completed card and its holes must turn upright for result reading');
  assert.equal(h.page.paperPerspective, 0);
  assert.equal(h.page.paperWidthScale, 1);
  for (let row = 0; row < 8; row++) {
    for (let col = 0; col < 4; col++) {
      const sourceX = 420 + col * 150, sourceY = 1020 - row * 82;
      const [x, y] = projectPaper(h, sourceX, sourceY);
      assert.ok(Math.abs(x - sourceX) < 0.001 && Math.abs(y - sourceY) < 0.001,
        'All 32 result holes must return to the unprojected rectangular grid');
    }
  }
}

async function saveWithFreshResultTouch(h) {
  h.pageTouch(1);
  h.advanceBy(numericConstant('RESULT_REVIEW_MS') + numericConstant('RESULT_TOUCH_QUIET_MS'));
  assert.equal(h.page.resultActionsReady, true, 'An upright result must become actionable after reading and release');
  h.resultTouch('save', 0);
  h.resultTouch('save', 1);
  assert.equal(await h.resultClick(), true, 'A fresh completed save gesture must be accepted');
}

(async () => {
  const countdown = harness();
  await begin(countdown);
  const audioAt = countdown.page.audioStartAtMs;
  const firstMeasuredAt = countdown.page.measurementStartAtMs;
  const countdownToken = countdown.page.runToken;
  assert.equal(firstMeasuredAt - audioAt, 2000, 'Four count-in beats must not change the measurement clock');
  assert.equal(countdown.page.countdownNumber, 0, 'Renderer preparation must not display an extra 4');
  countdown.advanceTo(audioAt - 1);
  countdown.page.refreshCountdown(countdownToken);
  assert.equal(countdown.page.countdownNumber, 0, 'Countdown must stay hidden before the scheduled audio starts');
  for (let beat = 0; beat < 4; beat++) {
    countdown.advanceTo(audioAt + beat * 500);
    countdown.page.refreshCountdown(countdownToken);
    assert.equal(countdown.page.countdownNumber, 4 - beat, 'Each scheduled rehearsal beat must show 4, 3, 2, 1');
    assert.ok(Math.abs(countdown.page.countdownScale - 0.52) <= 0.01);
    assert.ok(Math.abs(countdown.page.countdownOpacity - 0.76) <= 0.01);
    countdown.advanceBy(250);
    countdown.page.refreshCountdown(countdownToken);
    assert.ok(Math.abs(countdown.page.countdownScale - 1.07) <= 0.01,
      'Count-in pulses must expand with the walking page animation');
    assert.ok(Math.abs(countdown.page.countdownOpacity - 0.57) <= 0.01);
  }
  countdown.advanceTo(firstMeasuredAt);
  assert.equal(countdown.page.countdownNumber, 0,
    'The scheduled end must hide the last number without waiting for the next 32 ms frame');
  countdown.page.refreshCountdown(countdownToken);
  assert.equal(countdown.page.countdownNumber, 0, 'Countdown must disappear at the first measured beat');
  assert.equal(countdown.page.countdownOpacity, 0);
  assert.equal(countdown.page.countdownTimer, -1, 'The visual interval must stop after its four beats');
  assert.equal(countdown.page.countdownStopTimer, -1, 'The exact scheduled end must release its timeout');
  assert.equal(countdown.page.tapCount, 0, 'Countdown cannot fabricate a tap or start measuring');
  assert.equal(countdown.page.phase, 'listening', 'A delayed first Bluetooth tap must retain its acceptance window');
  countdown.touch(firstMeasuredAt + 1130);
  assert.equal(countdown.page.tapOffsetsMs[0], 1130,
    'Count-in presentation cannot fold a Bluetooth delay into the click interval');

  const busyCountdown = harness();
  await begin(busyCountdown);
  const busyAudioAt = busyCountdown.page.audioStartAtMs;
  busyCountdown.setNow(busyAudioAt + 1200);
  busyCountdown.page.refreshCountdown(busyCountdown.page.runToken);
  assert.equal(busyCountdown.page.countdownNumber, 2, 'A stalled UI must resume at the scheduled number rather than replay missed numbers');
  assert.ok(Math.abs(busyCountdown.page.countdownScale - 0.96) <= 0.01);
  assert.ok(Math.abs(busyCountdown.page.countdownOpacity - 0.6384) <= 0.01);
  busyCountdown.setNow(busyCountdown.page.measurementStartAtMs + 20);
  busyCountdown.page.refreshCountdown(busyCountdown.page.runToken);
  assert.equal(busyCountdown.page.countdownNumber, 0, 'A missed visual frame cannot extend the count-in');
  assert.equal(busyCountdown.page.countdownTimer, -1);

  const delayedCountInStart = deferred();
  const delayedCountdown = harness({ measurement: delayedCountInStart });
  const delayedStarting = delayedCountdown.page.startMeasurement();
  const delayedAudioAt = delayedCountdown.page.audioStartAtMs;
  const delayedMeasuredAt = delayedCountdown.page.measurementStartAtMs;
  delayedCountdown.advanceTo(delayedAudioAt + 650);
  assert.equal(delayedCountdown.page.countdownNumber, 0, 'Pending audio startup must not start a visual rehearsal alone');
  delayedCountInStart.resolve();
  await delayedStarting;
  assert.equal(delayedCountdown.page.countdownNumber, 3, 'Delayed preparation must join the current scheduled beat');
  assert.equal(delayedCountdown.page.audioStartAtMs, delayedAudioAt);
  assert.equal(delayedCountdown.page.measurementStartAtMs, delayedMeasuredAt);

  const expiredCountInStart = deferred();
  const expiredCountdown = harness({ measurement: expiredCountInStart });
  const expiredStarting = expiredCountdown.page.startMeasurement();
  const expiredMeasuredAt = expiredCountdown.page.measurementStartAtMs;
  expiredCountdown.advanceTo(expiredMeasuredAt + 20);
  expiredCountInStart.resolve();
  await expiredStarting;
  assert.equal(expiredCountdown.page.countdownNumber, 0,
    'Audio preparation finishing after the rehearsal must not replay 4, 3, 2, 1');
  assert.equal(expiredCountdown.page.countdownTimer, -1);
  assert.equal(expiredCountdown.page.measurementStartAtMs, expiredMeasuredAt);
  expiredCountdown.touch(expiredMeasuredAt + 1130);
  assert.equal(expiredCountdown.page.tapCount, 1, 'Late startup keeps the same first-tap window');

  const earlyTap = harness();
  await begin(earlyTap);
  earlyTap.advanceTo(earlyTap.page.measurementStartAtMs - 70);
  earlyTap.page.refreshCountdown(earlyTap.page.runToken);
  assert.equal(earlyTap.page.countdownNumber, 1);
  earlyTap.touch(earlyTap.now());
  assert.equal(earlyTap.page.tapCount, 1, 'Countdown must preserve the existing first-tap early tolerance');
  assert.equal(earlyTap.page.countdownNumber, 0, 'The first accepted tap must hide a residual final countdown frame');
  assert.equal(earlyTap.page.countdownTimer, -1);

  for (const cancel of ['failure', 'page-exit', 'disconnect']) {
    const cancelledCountdown = harness();
    await begin(cancelledCountdown);
    cancelledCountdown.advanceTo(cancelledCountdown.page.audioStartAtMs + 10);
    cancelledCountdown.page.refreshCountdown(cancelledCountdown.page.runToken);
    assert.equal(cancelledCountdown.page.countdownNumber, 4);
    const staleCallbacks = cancelledCountdown.staleTimerCallbacks();
    if (cancel === 'failure') cancelledCountdown.page.failMeasurement('测试倒数停止');
    if (cancel === 'page-exit') cancelledCountdown.page.aboutToDisappear();
    if (cancel === 'disconnect') {
      cancelledCountdown.page.btAudioActive = false;
      cancelledCountdown.page.onBluetoothAudioRouteChanged();
    }
    for (const callback of staleCallbacks) callback();
    assert.equal(cancelledCountdown.page.countdownNumber, 0, `${cancel} must hide the rehearsal number`);
    assert.equal(cancelledCountdown.page.countdownTimer, -1, `${cancel} must release the visual interval`);
    assert.equal(cancelledCountdown.page.countdownStopTimer, -1, `${cancel} must release the scheduled visual end`);
  }

  const complete = harness();
  assert.ok(source.includes('.scale(this.paperScale()).rotate(this.paperRotation())'),
    'The tested native options must be applied to the whole paper and ink subtree');
  assert.ok(!source.includes('.transform('), 'Perspective paper must not enter the 2D matrix decomposition path');
  assertPaperVisible(complete);
  await collectCompleteRun(complete);
  const highDensity = harness({ pixelRatio: 3.5 });
  await collectCompleteRun(highDensity);
  const disconnectDuringLift = harness();
  await begin(disconnectDuringLift);
  const liftStart = disconnectDuringLift.page.measurementStartAtMs;
  for (let i = 0; i < 32; i++) disconnectDuringLift.touch(liftStart + i * 500 + 120);
  disconnectDuringLift.advanceBy(391);
  assert.equal(disconnectDuringLift.page.phase, 'result');
  assert.equal(disconnectDuringLift.page.paperReleased, false,
    'This disconnect case must interrupt the pending lift, before it turns upright');
  disconnectDuringLift.page.btAudioActive = false;
  disconnectDuringLift.page.onBluetoothAudioRouteChanged();
  disconnectDuringLift.advanceBy(1000);
  assert.equal(disconnectDuringLift.page.paperReleased, true);
  assert.equal(disconnectDuringLift.page.paperPerspective, 0);
  assert.equal(disconnectDuringLift.page.paperDepthScale, 1);
  assert.equal(disconnectDuringLift.page.paperWidthScale, 1);
  const disconnectedCorner = projectPaper(disconnectDuringLift, 238, 54);
  assert.ok(Math.abs(disconnectedCorner[0] - 238) < 0.001 && Math.abs(disconnectedCorner[1] - 54) < 0.001,
    'Disconnect must complete the upright result instead of leaving cancelled perspective work');
  await disconnectDuringLift.page.finishAndSave();
  assert.deepEqual(disconnectDuringLift.writes, [], 'A disconnected result remains readable without being saved');
  assert.deepEqual(complete.feedback, Array.from({ length: 32 }, (_, i) => i + 1),
    'Every valid sample must trigger exactly one punch, after its count is recorded');
  assert.deepEqual(complete.writes, [], 'Completing a card must wait for explicit saving');
  await saveWithFreshResultTouch(complete);
  assert.deepEqual(complete.writes, [120], 'The new art must preserve the existing tap calibration value');
  assert.equal(complete.persistedMs(), 120);
  for (const action of ['refresh', 'keep-alive', 'mark-route:true', 'back']) {
    assert.ok(complete.trace.includes(action), `A saved card must complete ${action}`);
  }
  assert.ok(complete.trace.indexOf('refresh') < complete.trace.indexOf('back'));

  const accidentalSave = harness();
  await begin(accidentalSave);
  const accidentalStart = accidentalSave.page.measurementStartAtMs;
  for (let i = 0; i < 32; i++) accidentalSave.touch(accidentalStart + i * 500 + 120);
  accidentalSave.pageTouch(1);
  accidentalSave.advanceBy(391);
  assert.equal(accidentalSave.page.phase, 'result');
  assert.equal(accidentalSave.page.paperReleased, false);
  assert.equal(accidentalSave.page.resultActionsReady, false,
    'Creating the result controls cannot authorize saving before the card has lifted');
  await accidentalSave.page.finishAndSave();
  accidentalSave.resultTouch('save', 0);
  accidentalSave.resultTouch('save', 1);
  assert.equal(await accidentalSave.resultClick(), false,
    'The 33rd habitual press must not activate the new result button');
  assert.deepEqual(accidentalSave.writes, []);
  assert.ok(!accidentalSave.trace.includes('back'));
  // Repeated taps remain at the measured tempo, including beyond the minimum
  // review interval. Quiet time must exceed a full beat rather than opening
  // an actionable gap between habitual taps.
  for (let extra = 0; extra < 6; extra++) {
    accidentalSave.advanceBy(500);
    accidentalSave.resultTouch('save', 0);
    accidentalSave.resultTouch('save', 1);
    assert.equal(await accidentalSave.resultClick(), false);
    assert.equal(accidentalSave.page.resultActionsReady, false,
      'The result must stay locked while a 500 ms punching rhythm continues');
  }
  assert.deepEqual(accidentalSave.writes, []);
  accidentalSave.advanceBy(numericConstant('RESULT_TOUCH_QUIET_MS') - 1);
  assert.equal(accidentalSave.page.resultActionsReady, false,
    'The quiet guard must include the release of the last accidental touch');
  accidentalSave.advanceBy(1);
  assert.equal(accidentalSave.page.resultActionsReady, true);
  assert.equal(await accidentalSave.resultClick(), false,
    'Unlocking alone cannot turn an earlier unqualified touch into saving');
  accidentalSave.resultTouch('save', 0);
  accidentalSave.resultTouch('save', 1);
  assert.equal(await accidentalSave.resultClick(), true);
  assert.deepEqual(accidentalSave.writes, [120]);
  assert.equal(accidentalSave.trace.filter(action => action === 'back').length, 1);
  assert.equal(await accidentalSave.resultClick(), false, 'A touch permission must be consumed by its first click');
  assert.deepEqual(accidentalSave.writes, [120]);

  const heldAcrossReview = harness();
  await collectCompleteRun(heldAcrossReview);
  heldAcrossReview.resultTouch('save', 0);
  heldAcrossReview.advanceBy(numericConstant('RESULT_REVIEW_MS') + numericConstant('RESULT_TOUCH_QUIET_MS'));
  assert.equal(heldAcrossReview.page.resultActionsReady, false,
    'A finger held through the reading deadline must keep result actions locked');
  heldAcrossReview.resultTouch('save', 1);
  heldAcrossReview.advanceBy(numericConstant('RESULT_TOUCH_QUIET_MS'));
  assert.equal(heldAcrossReview.page.resultActionsReady, true);
  assert.equal(await heldAcrossReview.resultClick(), false,
    'A Down inside the lock followed by an Up outside it cannot save');
  assert.deepEqual(heldAcrossReview.writes, []);
  await saveWithFreshResultTouch(heldAcrossReview);
  assert.deepEqual(heldAcrossReview.writes, [120]);

  const cancelledSave = harness();
  await collectCompleteRun(cancelledSave);
  cancelledSave.advanceBy(numericConstant('RESULT_REVIEW_MS') + numericConstant('RESULT_TOUCH_QUIET_MS'));
  assert.equal(cancelledSave.page.resultActionsReady, true);
  cancelledSave.resultTouch('save', 0);
  cancelledSave.resultTouch('save', 3);
  assert.equal(await cancelledSave.resultClick(), false, 'Cancelling a button touch must revoke its save permission');
  assert.deepEqual(cancelledSave.writes, []);
  cancelledSave.resultTouch('save', 0);
  cancelledSave.resultTouch('save', 1);
  assert.equal(await cancelledSave.resultClick('retry'), false,
    'A save gesture cannot authorize the adjacent retry action');
  assert.deepEqual(cancelledSave.writes, []);

  const queuedOldTouch = harness();
  await collectCompleteRun(queuedOldTouch);
  const lockedTouchAt = queuedOldTouch.now();
  queuedOldTouch.advanceBy(600);
  assert.equal(queuedOldTouch.page.resultActionsReady, true);
  queuedOldTouch.resultTouch('save', 0, lockedTouchAt);
  queuedOldTouch.resultTouch('save', 1);
  assert.equal(await queuedOldTouch.resultClick(), false,
    'A delayed Down stamped before enabling must not become a fresh save gesture');
  assert.deepEqual(queuedOldTouch.writes, []);

  const accessibleSave = harness();
  await collectCompleteRun(accessibleSave);
  assert.equal(await accessibleSave.resultClick('save', 5), false,
    'Keyboard or accessibility activation must respect the reading lock');
  accessibleSave.advanceBy(numericConstant('RESULT_REVIEW_MS') + numericConstant('RESULT_TOUCH_QUIET_MS'));
  assert.equal(await accessibleSave.resultClick('save', 5), true,
    'After review, keyboard or accessibility activation must not require touch events');
  assert.deepEqual(accessibleSave.writes, [120]);

  for (const cancel of ['page-exit', 'retry', 'disconnect']) {
    const cancelledReview = harness();
    await collectCompleteRun(cancelledReview);
    assert.equal(cancelledReview.page.resultActionsReady, false);
    const oldCallbacks = cancelledReview.staleTimerCallbacks();
    if (cancel === 'page-exit') cancelledReview.page.aboutToDisappear();
    if (cancel === 'retry') {
      // A direct new measurement models a transport restart. UI retry itself
      // must remain guarded, while stale callbacks must not unlock its new run.
      cancelledReview.page.retryMeasurement();
      assert.equal(cancelledReview.page.phase, 'result', 'A locked result cannot accidentally trigger retry');
      await begin(cancelledReview);
    }
    if (cancel === 'disconnect') {
      cancelledReview.page.btAudioActive = false;
      cancelledReview.page.onBluetoothAudioRouteChanged();
      cancelledReview.page.btAudioActive = true;
    }
    const currentToken = cancelledReview.page.runToken;
    for (const callback of oldCallbacks) callback();
    assert.equal(cancelledReview.page.runToken, currentToken);
    assert.equal(cancelledReview.page.resultActionsReady, false,
      `${cancel}: stale result timers cannot authorize the next run or renewed result`);
    await cancelledReview.page.finishAndSave();
    assert.deepEqual(cancelledReview.writes, [], `${cancel}: stale review work must never save`);
    assert.ok(!cancelledReview.trace.includes('back'));
  }

  for (const cancel of ['page-exit', 'retry', 'disconnect']) {
    const lifting = harness();
    await begin(lifting);
    const liftAt = lifting.page.measurementStartAtMs;
    for (let i = 0; i < 32; i++) lifting.touch(liftAt + i * 500 + 120);
    lifting.pageTouch(1);
    lifting.advanceBy(691);
    assert.equal(lifting.page.phase, 'result');
    assert.equal(lifting.page.resultActionsReady, false);
    const oldCallbacks = lifting.staleTimerCallbacks();
    if (cancel === 'page-exit') lifting.page.aboutToDisappear();
    if (cancel === 'retry') await begin(lifting);
    if (cancel === 'disconnect') {
      lifting.page.btAudioActive = false;
      lifting.page.onBluetoothAudioRouteChanged();
      lifting.page.btAudioActive = true;
    }
    const currentToken = lifting.page.runToken;
    for (const callback of oldCallbacks) callback();
    assert.equal(lifting.page.runToken, currentToken);
    assert.equal(lifting.page.resultActionsReady, false,
      `${cancel}: a stale native lift completion cannot start or bypass a new review`);
    await lifting.page.finishAndSave();
    assert.deepEqual(lifting.writes, []);
    assert.ok(!lifting.trace.includes('back'));
  }

  const longBluetooth = harness();
  await begin(longBluetooth);
  const longFirstAt = longBluetooth.page.measurementStartAtMs;
  for (let i = 0; i < 32; i++) longBluetooth.touch(longFirstAt + i * 500 + 1130);
  longBluetooth.advanceBy(1500);
  assert.equal(longBluetooth.page.resultMs, 1130,
    'A Bluetooth delay spanning several beats must not fold into the 500 ms click period');
  assert.equal(longBluetooth.page.jitterMs, 0);

  const delayedTail = harness();
  await begin(delayedTail);
  const tailStart = delayedTail.page.measurementStartAtMs + 120;
  for (let i = 0; i < 29; i++) delayedTail.touch(tailStart + i * 500);
  // JS blocks at touch 30 while the hardware continues stamping touch times.
  // Deliver those queued touches before the already-due deadline callback.
  delayedTail.advanceTo(tailStart + 29 * 500);
  delayedTail.setNow(delayedTail.now() + 1000);
  const tailPauses = delayedTail.trace.filter(action => action === 'pause').length;
  for (let i = 29; i < 32; i++) {
    delayedTail.page.onTapTouch({ type: 0, timestamp: (tailStart + i * 500) * 1000000 });
  }
  assert.equal(delayedTail.page.tapCount, 32, 'All queued physical touches must be accepted before animation');
  assert.deepEqual(Array.from(delayedTail.page.tapOffsetsMs), Array(32).fill(120));
  assert.equal(delayedTail.trace.filter(action => action === 'pause').length, tailPauses + 1,
    'The last touch must pause audio immediately while the lever queue drains');
  assert.equal(delayedTail.feedback.length, 30, 'The last three accepted samples initially queue behind one stroke');
  delayedTail.advanceBy(390);
  assert.equal(delayedTail.page.phase, 'measuring', 'The original finish deadline must not truncate pending strokes');
  assert.ok(delayedTail.page.visualTapCount < 32);
  delayedTail.advanceBy(1000);
  assert.equal(delayedTail.page.phase, 'result');
  assert.equal(delayedTail.page.visualTapCount, 32);
  assert.equal(delayedTail.page.punchAnimationActive, false);
  assert.deepEqual(delayedTail.feedback, Array.from({ length: 32 }, (_, i) => i + 1),
    'A delayed tail must still perform all 32 independent downward strokes before showing its result');
  assert.equal(delayedTail.page.resultMs, 120);
  assert.equal(delayedTail.page.jitterMs, 0);
  assert.deepEqual(delayedTail.writes, []);

  const touchClock = harness();
  await begin(touchClock);
  const firstAt = touchClock.page.measurementStartAtMs;
  touchClock.touch(firstAt - 100, 30);
  touchClock.touch(firstAt + 120, 30, 1);
  assert.equal(touchClock.page.tapCount, 0, 'Count-in and touch-up must never punch');
  touchClock.touch(firstAt + 120, 30);
  assert.equal(touchClock.page.tapOffsetsMs[0], 120);
  touchClock.setNow(firstAt + 620);
  touchClock.page.onTapTouch({ type: 0, timestamp: 1 });
  assert.equal(touchClock.page.tapOffsetsMs[1], 120,
    'An unsupported touch clock epoch must fall back to the monotonic callback time');

  // Simulate a busy UI thread leaving the first punch's animation timers queued.
  // The next hardware touch is still accepted before those callbacks run.
  const animationBusy = harness();
  await begin(animationBusy);
  const animationFirstAt = animationBusy.page.measurementStartAtMs + 120;
  animationBusy.touch(animationFirstAt);
  animationBusy.setNow(animationFirstAt + 500);
  animationBusy.page.onTapTouch({ type: 0, timestamp: (animationFirstAt + 500) * 1000000 });
  assert.equal(animationBusy.page.tapCount, 2);
  animationBusy.advanceBy(500);
  assert.deepEqual(animationBusy.feedback, [1, 2], 'Animation completion must not unlock sampling');

  for (const [label, secondGap] of [['duplicate', 280], ['skipped beat', 700]]) {
    const failed = harness();
    await begin(failed);
    const firstAt = failed.page.measurementStartAtMs + 120;
    failed.touch(firstAt);
    const token = failed.page.runToken;
    failed.touch(firstAt + secondGap);
    assert.equal(failed.page.phase, 'missed', label);
    assert.equal(failed.page.tapCount, 1, `${label} must not fabricate a missing punch`);
    assert.equal(failed.page.tapOffsetsMs.length, 1);
    assert.deepEqual(failed.feedback, [1]);
    assert.ok(failed.page.runToken > token, `${label} must invalidate asynchronous work`);
    await failed.page.finishAndSave();
    assert.deepEqual(failed.writes, [], `${label} must preserve the previous calibration`);
    assert.equal(failed.persistedMs(), 72);
  }

  const missedFirst = harness();
  await begin(missedFirst);
  missedFirst.advanceTo(missedFirst.page.measurementStartAtMs + 2001);
  assert.equal(missedFirst.page.phase, 'missed');
  assert.equal(missedFirst.page.tapCount, 0);
  assert.deepEqual(missedFirst.feedback, []);
  await missedFirst.page.finishAndSave();
  assert.deepEqual(missedFirst.writes, [], 'A blank failed card must not save zero over an earlier result');

  for (const cancel of ['failure', 'page-exit', 'disconnect']) {
    const measurement = deferred();
    const pending = harness({ measurement });
    const starting = pending.page.startMeasurement();
    assert.equal(pending.page.phase, 'arming');
    const token = pending.page.runToken;
    if (cancel === 'failure') pending.page.failMeasurement('测试断拍');
    if (cancel === 'page-exit') pending.page.aboutToDisappear();
    if (cancel === 'disconnect') {
      pending.page.btAudioActive = false;
      pending.page.onBluetoothAudioRouteChanged();
    }
    assert.ok(pending.page.runToken > token, `${cancel} must invalidate pending audio startup`);
    measurement.resolve();
    await starting;
    assert.notEqual(pending.page.phase, 'listening', `${cancel} cannot be revived by a completed startup`);
    assert.equal(pending.page.missTimer, -1, `${cancel} cannot re-arm a missed-beat deadline`);
  }

  const retry = harness();
  await begin(retry);
  retry.touch(retry.page.measurementStartAtMs + 120);
  const oldCallbacks = retry.staleTimerCallbacks();
  retry.page.failMeasurement('测试断拍');
  retry.advanceBy(1001);
  retry.page.retryMeasurement();
  assert.equal(retry.page.phase, 'missed', 'A held finger must not accidentally activate retry');
  retry.page.touchHeld = false;
  retry.page.retryMeasurement();
  assert.equal(retry.page.phase, 'changing');
  retry.advanceBy(239);
  assert.equal(retry.page.tapCount, 1, 'The outgoing paper must keep its original holes');
  retry.advanceBy(1);
  assert.equal(retry.page.tapCount, 0, 'Samples clear only when the fresh paper is installed');
  retry.advanceBy(260);
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(retry.page.phase, 'listening', 'The fresh paper starts a new full count-in');
  assert.ok(retry.page.measurementStartAtMs > retry.now());
  const retryToken = retry.page.runToken;
  const retryPhase = retry.page.phase;
  retry.advanceTo(retry.page.audioStartAtMs + 1);
  retry.page.refreshCountdown(retryToken);
  assert.equal(retry.page.countdownNumber, 4, 'A replacement paper must receive its own full count-in');
  for (const callback of oldCallbacks) callback();
  assert.equal(retry.page.runToken, retryToken);
  assert.equal(retry.page.phase, retryPhase, 'Cancelled callbacks must not fail a replacement card');
  assert.equal(retry.page.tapCount, 0);
  assert.equal(retry.page.countdownNumber, 4, 'Old visual callbacks cannot hide or replace the new card countdown');
  retry.touch(retry.page.measurementStartAtMs + 130);
  assert.equal(retry.page.tapCount, 1);

  const changingExit = harness();
  await begin(changingExit);
  changingExit.page.failMeasurement('测试退卡');
  changingExit.advanceBy(1001);
  changingExit.page.retryMeasurement();
  assert.equal(changingExit.page.phase, 'changing');
  const changingCallbacks = changingExit.staleTimerCallbacks();
  const measureCalls = changingExit.trace.filter(action => action.startsWith('measure:')).length;
  changingExit.page.aboutToDisappear();
  for (const callback of changingCallbacks) callback();
  changingExit.advanceBy(1000);
  assert.equal(changingExit.trace.filter(action => action.startsWith('measure:')).length, measureCalls,
    'Leaving during paper exchange cannot start audio for a new card');
  assert.equal(changingExit.timers.size, 0);

  for (const lostAt of ['before-retry', 'during-exchange']) {
    const lostSession = harness();
    await begin(lostSession);
    lostSession.touch(lostSession.page.measurementStartAtMs + 120);
    lostSession.page.failMeasurement('测试会话结束');
    lostSession.advanceBy(1001);
    lostSession.page.touchHeld = false;
    const measureCalls = lostSession.trace.filter(action => action.startsWith('measure:')).length;
    if (lostAt === 'before-retry') lostSession.setSessionAvailable(false);
    lostSession.page.retryMeasurement();
    if (lostAt === 'during-exchange') {
      assert.equal(lostSession.page.phase, 'changing');
      lostSession.advanceBy(240);
      lostSession.setSessionAvailable(false);
    }
    lostSession.advanceBy(2000);
    await new Promise(resolve => setImmediate(resolve));
    assert.equal(lostSession.page.phase, 'missed', `${lostAt}: lost session cannot leave the page changing forever`);
    assert.equal(lostSession.page.retryReady, true, `${lostAt}: recovery guidance must become available`);
    assert.equal(lostSession.trace.filter(action => action.startsWith('measure:')).length, measureCalls,
      `${lostAt}: no measurement may start without a live session`);
    assert.deepEqual(lostSession.writes, []);
    if (lostAt === 'before-retry') {
      assert.equal(lostSession.page.tapCount, 1, 'A failed retry request must preserve the outgoing card');
      assert.ok(lostSession.toasts.some(message => message.includes('会话已结束')));
    } else {
      assert.ok(lostSession.page.missReason.includes('会话已结束'), 'A lost mid-exchange session must explain how to recover');
    }
  }

  const failedStartup = deferred();
  const startupRetry = harness();
  let starts = 0;
  startupRetry.session.scheduleLatencyTapMeasurement = async () => {
    if (++starts === 1) await failedStartup.promise;
  };
  const oldStartup = startupRetry.page.startMeasurement();
  startupRetry.page.failMeasurement('换一张卡');
  await begin(startupRetry);
  failedStartup.reject(new Error('旧一轮启动失败'));
  await oldStartup;
  assert.equal(startupRetry.page.phase, 'listening', 'A rejected old audio start cannot fail the replacement card');
  assert.equal(startupRetry.page.tapCount, 0);

  const preview = harness();
  await collectCompleteRun(preview);
  await preview.page.startResultPreview(0, '校准前试听');
  const oldPreviewCallbacks = preview.staleTimerCallbacks();
  await preview.page.startResultPreview(120, '校准后试听');
  const latestPreview = preview.page.previewLabel;
  const pauses = preview.trace.filter(action => action === 'pause').length;
  for (const callback of oldPreviewCallbacks) callback();
  assert.equal(preview.page.previewLabel, latestPreview, 'The first preview cannot overwrite the second one');
  assert.equal(preview.trace.filter(action => action === 'pause').length, pauses,
    'A cancelled preview-stop callback cannot pause its replacement');
  const beforeExit = preview.staleTimerCallbacks();
  preview.page.aboutToDisappear();
  const exitPauses = preview.trace.filter(action => action === 'pause').length;
  for (const callback of beforeExit) callback();
  assert.equal(preview.trace.filter(action => action === 'pause').length, exitPauses,
    'Expired preview work cannot touch playback after leaving the page');
  assert.equal(preview.timers.size, 0);

  const asyncPreview = deferred();
  const leaving = harness({ preview: asyncPreview });
  await collectCompleteRun(leaving);
  const previewing = leaving.page.startResultPreview(0, '校准前试听');
  leaving.page.aboutToDisappear();
  asyncPreview.reject(new Error('迟到的试听失败'));
  await previewing;
  assert.deepEqual(leaving.toasts, [], 'A stale preview error must not show a toast on the next page');
  assert.equal(leaving.timers.size, 0);

  console.log('PASS: whole-card calibration preserves 32 timestamped punches, requires reviewed results and fresh save gestures, and rejects stale or off-page work');
})().catch(error => { console.error(error); process.exitCode = 1; });
