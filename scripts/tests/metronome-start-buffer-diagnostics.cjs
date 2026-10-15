// Real Engine callbacks: only timing evidence changes, never PCM or native audio calls.
const assert = require('node:assert/strict');
const { fixture, diagnostic, RATE } = require('./metronome-start-timing.cjs');

const stageLines = (h, stage) => h.logs.filter(line =>
  line.startsWith('[StartTimingDiag]') && line.includes(`stage=${stage} `));
const fields = line => Object.fromEntries([...line.matchAll(/(\w+)=([^\s]+)/g)]
  .map(match => [match[1], match[2]]));
function near(actual, expected, label, tolerance = 0.011) {
  assert.ok(Number.isFinite(Number(actual)), `${label}: ${actual}`);
  assert.ok(Math.abs(Number(actual) - expected) <= tolerance,
    `${label}: expected ${expected}, got ${actual}`);
}

async function schedule(h, framesAhead) {
  await h.engine.scheduleFromLeaderStart(h.now + h.compensationMs + framesAhead * 1000 / RATE, 0, 0);
  await h.fireDueTimers();
  assert.ok(h.engine.pendingAudioTransition);
  return h.engine.pendingAudioTransition;
}

async function renderCase(bufferFrames, offsetFrames, { previousFuture = false,
  rollbackAtCompletion = false, boundary = false } = {}) {
  const h = fixture({ queueMs: 0 });
  const e = h.engine;
  const framesAhead = bufferFrames + offsetFrames;
  const transition = await schedule(h, framesAhead);
  const before = e.audioSubmittedFrames;
  assert.equal(transition.targetFrame, before + framesAhead);
  const onset = e.pendingSequence[0].samples.findIndex(sample => sample !== 0);
  assert.ok(onset >= 0 && onset + offsetFrames < bufferFrames);
  const calls = h.audioCalls.slice();
  e.lastUnderflowCount = 7;
  const first = new ArrayBuffer(bufferFrames * 2);
  e.handleWriteData(first);
  assert.ok(new Int16Array(first).every(sample => sample === 0));
  assert.equal(stageLines(h, 'applied').length, 0,
    'A target at or after this buffer end belongs to a later callback');
  assert.equal(stageLines(h, 'write-complete').length, 0);
  if (boundary) assert.equal(offsetFrames, 0);
  if (previousFuture) e.previousWriteCallbackEntryMonoMs = h.now + 1;
  if (rollbackAtCompletion) {
    const complete = e.logStartWriteCompletion.bind(e);
    e.logStartWriteCompletion = (context, completed) => complete(context, completed - 1);
  }
  const final = new ArrayBuffer(bufferFrames * 2);
  assert.equal(e.handleWriteData(final), 0);
  const output = new Int16Array(final);
  assert.equal(output.findIndex(sample => sample !== 0), offsetFrames + onset,
    'The actual synthesized click must start at the logged buffer offset');
  assert.equal(e.audioSubmittedFrames, before + bufferFrames * 2);
  const applied = diagnostic(h, 'applied');
  const completed = diagnostic(h, 'write-complete');
  for (const line of [applied, completed]) {
    assert.equal(line.token, String(transition.token));
    near(line.callbackEntryMonoMs, h.now, 'callback entry');
    near(line.bufferStartFrame, before + bufferFrames, 'actual callback buffer origin', 0);
    near(line.bufferFrames, bufferFrames, 'actual callback length', 0);
    near(line.targetOffsetFrames, offsetFrames, 'actual target offset', 0);
    near(line.targetOffsetMs, offsetFrames * 1000 / RATE, 'offset duration');
    assert.equal(line.previousCallbackGapMs, previousFuture ? 'unknown' : '0.0');
    assert.equal(line.cachedUnderflowCount, '7');
  }
  assert.equal(applied.bufferContextKnown, 'true');
  near(applied.appliedMonoMs, h.now, 'existing application time');
  assert.equal(completed.fillCompletedBeforeReturn, 'true');
  assert.equal(completed.callbackDurationMs, rollbackAtCompletion ? 'unknown' : '0.0');
  near(completed.fillCompletedMonoMs, h.now - (rollbackAtCompletion ? 1 : 0), 'fill completion');
  assert.equal(stageLines(h, 'applied').length, 1);
  assert.equal(stageLines(h, 'write-complete').length, 1);
  assert.equal(e.startWriteBufferContext, undefined);
  e.handleWriteData(new ArrayBuffer(bufferFrames * 2));
  assert.equal(stageLines(h, 'write-complete').length, 1, 'Later buffers cannot repeat the start evidence');
  assert.deepEqual(h.audioCalls, calls, 'Callback evidence adds no native audio API calls');
}

async function main() {
  for (const offset of [19, 931, 1372, 3538]) await renderCase(4096, offset);
  await renderCase(1024, 1000);
  await renderCase(8192, 5500);
  await renderCase(4096, 0, { boundary: true });
  await renderCase(4096, 931, { previousFuture: true, rollbackAtCompletion: true });

  {
    const h = fixture({ queueMs: 0, frameBiasFrames: 5000 });
    const e = h.engine;
    const original = h.renderer.getAudioTimestampInfoSync.bind(h.renderer);
    let reads = 0;
    h.renderer.getAudioTimestampInfoSync = () => {
      const sample = original();
      return { ...sample, framePos: sample.framePos + (reads++ === 0 ? 0 : 882) };
    };
    await schedule(h, 10000);
    const target = diagnostic(h, 'target');
    assert.equal(reads, 2, 'The original target read and production diagnostic read remain the only queries');
    assert.equal(target.estimateFrameMapKnown, 'true');
    near(target.estimateRawFrame, h.physicalFrame, 'first target raw frame', 0);
    near(target.estimateRawTimestampMs, h.now, 'first raw timestamp');
    near(target.estimateBaseFrame, -5000, 'base', 0);
    near(target.uncappedMappedFrame, h.physicalFrame + 5000, 'uncapped first mapping');
    near(target.submittedCapFrames, 5000, 'first mapping cap', 0);
    near(target.submittedCapMs, 5000 * 1000 / RATE, 'cap duration');
    near(target.estimateLegacyAgeMs, 0, 'legacy age');
    assert.equal(e.productionClockSample.rawFrame, h.physicalFrame + 882,
      'The later read really replaced the production sample');
    assert.equal(e.startTargetEstimate.frameMapping.rawFrame, h.physicalFrame,
      'The target cache must retain the first read, not the later sample');

    const captured = e.productionClockSample;
    const targetFrame = e.pendingAudioTransition.targetFrame;
    for (const kind of ['stale-query', 'stale-request', 'exact', 'fallback', 'cold-wall']) {
      e.productionClockSample = { ...captured, queryMonoMs: h.now - (kind === 'stale-query' ? 1 : 0) };
      e.lastAudioFrameMapExact = kind === 'exact';
      const requestToken = e.startTimingRequest.token;
      if (kind === 'stale-request') e.startTimingRequest.token -= 1;
      const mode = kind === 'fallback' || kind === 'cold-wall' ? kind : 'timestamp';
      e.cacheStartTargetEstimate(mode, h.now, h.now + 100, e.productionClockSample.renderedFrame,
        targetFrame, targetFrame);
      assert.equal(e.startTargetEstimate.frameMapping, undefined, `${kind} must have no legacy evidence`);
      e.startTimingRequest.token = requestToken;
      e.logStartTimingTarget('test', e.pendingAudioTransition, h.now + 400, 300);
      const unknown = fields(stageLines(h, 'target').at(-1));
      assert.equal(unknown.estimateFrameMapKnown, 'false');
      for (const key of ['estimateRawFrame', 'estimateRawTimestampMs', 'estimateBaseFrame',
        'uncappedMappedFrame', 'submittedCapFrames', 'submittedCapMs', 'estimateLegacyAgeMs']) {
        assert.equal(unknown[key], 'unknown', `${kind}: ${key}`);
      }
    }
  }

  {
    const h = fixture({ queueMs: 0 });
    await schedule(h, 10000);
    assert.ok(h.engine.startTargetEstimate.frameMapping);
    h.renderer.getAudioTimestampInfoSync = () => {
      h.audioCalls.push('timestamp');
      throw new Error('timestamp unavailable after an earlier successful start');
    };
    const priorLogs = h.logs.length;
    await schedule(h, 10000);
    const target = diagnostic({ logs: h.logs.slice(priorLogs) }, 'target');
    assert.equal(target.mode, 'fallback');
    assert.equal(target.estimateFrameMapKnown, 'false');
    assert.equal(h.engine.productionClockSample, undefined);
    assert.equal(h.engine.startTargetEstimate.frameMapping, undefined,
      'A failed first query cannot retain an earlier legacy sample');
  }

  for (const direct of ['fillAudioData', 'applyAudioTransition']) {
    const h = fixture({ queueMs: 0 });
    const e = h.engine;
    // A previous real callback must not leave context for either direct entry.
    e.handleWriteData(new ArrayBuffer(100 * 2));
    const transition = await schedule(h, 10000);
    if (direct === 'fillAudioData') e.fillAudioData(new ArrayBuffer(11000 * 2));
    else e.applyAudioTransition(transition);
    const applied = diagnostic(h, 'applied');
    assert.equal(applied.bufferContextKnown, 'false', direct);
    for (const key of ['callbackEntryMonoMs', 'bufferStartFrame', 'bufferFrames',
      'targetOffsetFrames', 'targetOffsetMs', 'previousCallbackGapMs']) assert.equal(applied[key], 'unknown');
    assert.equal(stageLines(h, 'write-complete').length, 0);
    e.handleWriteData(new ArrayBuffer(100 * 2));
    assert.equal(stageLines(h, 'write-complete').length, 0);
  }

  {
    const h = fixture({ queueMs: 0 });
    const e = h.engine;
    const transition = await schedule(h, 10000);
    const oldSidecar = e.startTimingTransition;
    e.pause();
    assert.equal(e.startWriteBufferContext, undefined);
    e.pendingAudioTransition = transition;
    e.startTimingTransition = oldSidecar;
    const calls = h.audioCalls.slice();
    e.handleWriteData(new ArrayBuffer(11000 * 2));
    assert.equal(stageLines(h, 'applied').length, 0, 'An old token cannot produce application evidence');
    assert.equal(stageLines(h, 'write-complete').length, 0);
    assert.deepEqual(h.audioCalls, calls);
  }

  {
    const h = fixture({ queueMs: 0 });
    const e = h.engine;
    await schedule(h, 10000);
    const original = e.fillAudioData.bind(e);
    e.fillAudioData = data => { original(data); e.pause(); };
    e.handleWriteData(new ArrayBuffer(11000 * 2));
    assert.equal(stageLines(h, 'applied').length, 1);
    assert.equal(stageLines(h, 'write-complete').length, 0,
      'Cancellation after applying but before completion must not publish stale completion evidence');
    assert.equal(e.startWriteBufferContext, undefined);
  }
  console.log('PASS start buffer diagnostics: actual PCM offsets and lengths, exact tail boundary, first-query mapping cache, unknown contexts, clock rollback, cancellation and stale-token isolation; no added native audio calls');
}

main().catch(error => { console.error(error); process.exitCode = 1; });
