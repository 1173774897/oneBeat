// Configuration PCM rendered off the JS thread (TaskPool in production).
// Device evidence 2026-11-03: rendering a 40 BPM bar on the JS thread stalled
// writeData 114-310ms, underflowed, broke the frame map and skipped beats on
// every live BPM change. structuredClone stands in for the thread boundary: it
// copies Map/ArrayBuffer/typed arrays and drops class prototypes, as TaskPool does.
// Like TaskPool it also TRANSFERS (detaches) every ArrayBuffer not on the clone
// list; device 2026-11-03 the click tones were detached after the first job.
const assert = require('node:assert/strict');
const ts = require(process.argv[2]);
const { fixture } = require('./metronome-start-timing.cjs');
const { pcmRenderMocks } = require('./pcm-render-mocks.cjs');

const deterministicMath = Object.assign(Object.create(Math), { random: () => 0.5 });
const { renderPcmJob, pcmJobArrayBuffers } = pcmRenderMocks(ts, {}, deterministicMath)['./PcmRender'];

function allArrayBuffers(value, found = new Set()) {
  if (value instanceof ArrayBuffer) { found.add(value); return found; }
  if (ArrayBuffer.isView(value)) { found.add(value.buffer); return found; }
  if (value instanceof Map) { value.forEach(item => allArrayBuffers(item, found)); return found; }
  if (value !== null && typeof value === 'object') Object.values(value).forEach(item => allArrayBuffers(item, found));
  return found;
}
const plain = value => JSON.parse(JSON.stringify(value));
async function flush() { for (let i = 0; i < 20; i++) await Promise.resolve(); }
const barFrames = (bpm, beats) => Math.round(44100 * 60 / bpm * beats);

function harness() {
  const jobs = [];
  let runner;
  const h = fixture({ queueMs: 150, moduleMocks: {
    './PcmRenderOffload': { PcmRenderOffload: { get: () => runner } }
  } });
  runner = job => new Promise((resolve, reject) => {
    const cloned = new Set(pcmJobArrayBuffers(job));
    const transfer = [...allArrayBuffers(job)].filter(buffer => !cloned.has(buffer));
    const copied = structuredClone(job, { transfer });
    jobs.push({
      job,
      finish() { resolve(structuredClone(renderPcmJob(copied))); },
      fail(message) { reject(new Error(message)); }
    });
  });
  let syncRenders = 0;
  const mixBar = h.engine.mixBar.bind(h.engine);
  h.engine.mixBar = (...args) => { syncRenders++; return mixBar(...args); };
  return { h, e: h.engine, jobs, syncRenders: () => syncRenders };
}

(async () => {
  {
    // The JS thread only captures the job; PCM arrives later and is identical.
    const { h, e, jobs, syncRenders } = harness();
    const before = e.pendingSequence;
    const renders = syncRenders();
    e.setBpm(40, 6);
    assert.equal(jobs.length, 1, 'A live BPM change dispatches one worker job');
    assert.equal(syncRenders(), renders, 'No PCM is mixed on the JS thread');
    assert.equal(e.pendingSequence, before, 'The current sequence stays in place until the result arrives');
    let ready = false;
    const waiting = e.waitForPcmReady().then(() => { ready = true; });
    await flush();
    assert.equal(ready, false, 'Readiness waits for the worker');
    jobs[0].finish();
    await waiting;
    assert.equal(e.pendingSequence[0].frameCount, barFrames(40, 6));
    const expected = e.renderSequence([e.pattern], true, e.sampleBank, undefined)[0].samples;
    assert.deepEqual(Array.from(e.pendingSequence[0].samples), Array.from(expected),
      'Worker PCM equals the synchronous render sample for sample');
    assert.ok(e.preparedCountInBars.has(6), 'The worker also prepares the count-in bar');
    assert.equal(e.preparedCountInRevision, e.pendingRevision);
    assert.ok(h.logs.some(line => line.includes('[PcmRenderDiag] stage=offload')));
  }
  {
    // A newer change supersedes an older result that arrives late.
    const { e, jobs } = harness();
    e.setBpm(50, 4);
    e.setBpm(60, 4);
    jobs[1].finish();
    await flush();
    jobs[0].finish();
    await flush();
    assert.equal(e.pendingSequence[0].frameCount, barFrames(60, 4), 'The stale 50 BPM result is discarded');
  }
  {
    // A start never uses the old configuration's PCM: it renders the job itself.
    const { h, e, jobs } = harness();
    e.setBpm(70, 4);
    await e.scheduleFromLeaderStart(h.now + 650, 0, 0);
    assert.equal(e.pendingSequence[0].frameCount, barFrames(70, 4));
    assert.ok(h.logs.some(line => line.includes('stage=sync-fallback reason=playback-start')));
    const applied = e.pendingSequence;
    jobs[0].finish();
    await flush();
    assert.equal(e.pendingSequence, applied, 'The late worker result does not replace the started PCM');
  }
  {
    // A worker failure (e.g. a serialization limit) falls back on this thread.
    const { h, e, jobs } = harness();
    e.setBpm(80, 4);
    jobs[0].fail('serialize failed');
    await flush();
    assert.equal(e.pendingSequence[0].frameCount, barFrames(80, 4));
    assert.ok(h.logs.some(line => line.includes('stage=offload-failed') && line.includes('serialize failed')));
    assert.ok(h.logs.some(line => line.includes('stage=sync-fallback reason=offload-failed')));
  }
  {
    // Every buffer is cloned, so the engine's click tones and kit samples
    // survive repeated jobs and later synchronous renders still work.
    const { e, jobs } = harness();
    e.sampleBank = new Map([['kick', new ArrayBuffer(64)], ['snare', new ArrayBuffer(64)]]);
    e.setBpm(90, 4);
    const first = jobs[0].job;
    assert.deepEqual([...allArrayBuffers(first)].filter(buffer => !pcmJobArrayBuffers(first).includes(buffer)), [],
      'The clone list covers every ArrayBuffer in the job');
    jobs[0].finish();
    await flush();
    e.setBpm(100, 4);
    jobs[1].finish();
    await flush();
    assert.equal(e.pendingSequence[0].frameCount, barFrames(100, 4), 'A second job still succeeds');
    assert.ok(e.accentBuffer.byteLength > 0 && e.weakBuffer.byteLength > 0, 'Click tones stay attached');
    assert.equal(e.sampleBank.get('kick').byteLength, 64, 'Kit samples stay attached');
    e.configureRouteProbeClickPair();
    assert.ok(e.pendingSequence[0].frameCount > 0, 'The route probe still renders its clicks');
  }
  {
    // Head-first split: 16 bars at 120 BPM with a limiter-engaging kick and a
    // ride longer than a bar (tails cross bars and wrap the loop into bar 0).
    const { h, e, jobs } = harness();
    const kick = new Int16Array(2000).fill(30000);
    const ride = new Int16Array(100000);
    for (let i = 0; i < ride.length; i++) ride[i] = i % 2 === 0 ? 9000 : -9000;
    e.sampleBank = new Map([['kick', kick.buffer], ['ride', ride.buffer]]);
    const patterns = Array.from({ length: 16 }, (_unused, bar) => ({ ticksPerBeat: 480, beatsPerBar: 4, events: [
      { tick: 0, sampleKey: 'kick', velocity: 1 },
      { tick: 0, sampleKey: 'kick', velocity: 1 },
      { tick: bar === 15 ? 1440 : 960, sampleKey: 'ride', velocity: 1 }
    ] }));
    const expected = e.renderSequence(patterns, true, e.sampleBank, undefined);
    const same = (bar, sequence = e.pendingSequence) =>
      Array.from(sequence[bar].samples).join() === Array.from(expected[bar].samples).join();
    const isPlaceholder = (bar, sequence = e.pendingSequence) => sequence[bar].samples.every(v => Math.abs(v) <= 4);
    async function finishChain(js) {
      for (let i = 0; i < 20 && js.some(j => !j.done); i++) {
        const next = js.find(j => !j.done);
        next.done = true;
        next.finish();
        await flush();
      }
    }
    e.rebuildPendingSequence(patterns, true, true);
    assert.equal(jobs.length, 1, 'Only the head is dispatched first');
    assert.deepEqual(plain(jobs[0].job.chunk), { startBar: 0, endBar: 2 });
    let ready = false;
    const waiting = e.waitForPcmReady().then(() => { ready = true; });
    jobs[0].done = true;
    jobs[0].finish();
    await waiting;
    assert.equal(ready, true, 'The head alone makes the configuration ready');
    assert.equal(e.pendingSequence.length, 16);
    assert.ok(same(0) && same(1), 'Head bars equal the whole render, including wrapped ride tails and limiting');
    for (let bar = 2; bar < 16; bar++) {
      assert.equal(e.pendingSequence[bar].frameCount, expected[bar].frameCount, 'Placeholders keep the beat grid');
      assert.ok(isPlaceholder(bar), 'Placeholders are dither only');
    }
    assert.equal(jobs.length, 2, 'The next chunk follows the head');
    assert.equal(jobs[1].job.chunk.startBar, 2);
    assert.equal(jobs[1].job.chunk.endBar, 4);
    assert.ok(jobs[1].job.chunk.limiterState.nextInput > 0, 'A chunk continues the carried limiter state');
    // Playback with a count-in copies the sequence and may be inside a placeholder.
    e.prepareAudioCursor(0, 4);
    const playing = e.activeSequence[3];
    assert.equal(playing, e.pendingSequence[2]);
    e.activeBar = playing;
    jobs[1].done = true;
    jobs[1].finish();
    await flush();
    assert.ok(same(2) && same(3), 'A chunk is replaced as soon as it arrives');
    assert.ok(isPlaceholder(4), 'Later bars stay placeholders until their chunk');
    assert.equal(e.activeSequence[3], e.pendingSequence[2], 'The copied active sequence is filled too');
    assert.equal(e.activeBar, e.pendingSequence[2], 'A playing placeholder is swapped in place');
    // One failure is retried on the worker.
    jobs[2].done = true;
    jobs[2].fail('busy');
    await flush();
    assert.ok(h.logs.some(line => line.includes('stage=tail-retry') && line.includes('bars=4-6/16')));
    assert.equal(jobs[3].job.chunk.startBar, 4, 'The retry repeats the same chunk');
    await finishChain(jobs);
    for (let bar = 0; bar < 16; bar++) assert.ok(same(bar), `Bar ${bar} equals the whole render after chunking`);
    assert.ok(h.logs.some(line => line.includes('stage=offload-head') && line.includes('bars=2/16')));
    assert.ok(h.logs.some(line => line.includes('stage=offload-tail') && line.includes('bars=14-16/16')));
    assert.equal(e.pcmTail, undefined, 'The chain ends after the last chunk');

    // Two failures: placeholders stay on the grid until the next preparation renders the rest.
    const { h: hf, e: ef, jobs: jf } = harness();
    ef.sampleBank = e.sampleBank;
    ef.rebuildPendingSequence(patterns, true, true);
    jf[0].finish(); await flush();
    jf[1].finish(); await flush();
    jf[2].fail('one'); await flush();
    jf[3].fail('two'); await flush();
    assert.ok(hf.logs.some(line => line.includes('stage=offload-failed part=tail') && line.includes('bars=4-6/16')));
    assert.equal(jf.length, 4, 'No further worker chunks after the retry failed');
    assert.ok(isPlaceholder(4, ef.pendingSequence));
    await ef.waitForPcmReady();
    assert.ok(hf.logs.some(line => line.includes('stage=sync-tail reason=tail-failed') && line.includes('bars=4-16/16')));
    for (let bar = 0; bar < 16; bar++) assert.ok(same(bar, ef.pendingSequence), `Recovered bar ${bar} equals the whole render`);

    // A newer configuration discards the older chain.
    const { e: es, jobs: js } = harness();
    es.sampleBank = e.sampleBank;
    es.rebuildPendingSequence(patterns, true, true);
    js[0].finish(); await flush();
    es.rebuildPendingSequence(patterns.slice(0, 8), true, true);
    js[1].finish(); await flush();
    assert.equal(es.pendingSequence.length, 16, 'Still the previous head until the new one arrives');
    assert.ok(isPlaceholder(2, es.pendingSequence), 'A stale chunk does not fill the new configuration');
    js[2].finish(); await flush();
    assert.equal(es.pendingSequence.length, 8);

    // A start before the head returns renders only the head here.
    const { h: h2, e: e2, jobs: jobs2 } = harness();
    e2.sampleBank = e.sampleBank;
    e2.rebuildPendingSequence(patterns, true, true);
    await e2.scheduleFromLeaderStart(h2.now + 650, 0, 0);
    assert.ok(h2.logs.some(line => line.includes('stage=sync-fallback') && line.includes('headBars=2')));
    assert.equal(e2.pendingSequence.length, 16);
    jobs2[0].done = true;
    jobs2[0].finish(); await flush();
    assert.equal(jobs2[1].job.chunk.startBar, 2, 'The chain continues on the worker after a head fallback');
    await finishChain(jobs2);
    for (let bar = 0; bar < 16; bar++) assert.ok(same(bar, e2.pendingSequence), `Fallback bar ${bar} equals the whole render`);
  }
  console.log('PASS PCM render offload: worker job leaves the JS thread free, identical PCM and count-in, ' +
    'readiness waits for it, stale results discarded, a start renders a pending job itself, worker failure falls back, ' +
    'head-first chunked tail identical to the whole render with in-place fill, retry, deferred recovery and stale-chain discard');
})().catch(error => { console.error(error); process.exitCode = 1; });
