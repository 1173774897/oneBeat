// Run with Node and the DevEco typescript/lib/typescript.js path.
const assert = require('node:assert/strict');
const { harness, catalog, flush } = require('./drum-preview-session-ownership.cjs');
const plain = value => JSON.parse(JSON.stringify(value));
const BAR = 88200;
const marker = { rock: 6000, jazz: 12000, funk: 18000, trap: 24000 };
const section = (id, styleKey, extra = {}) => ({ id, styleKey, patternIndex: 0,
  repeats: 1, fillIndex: 0, fillEvery: 0,
  customPattern: { subdivision: 6, events: [{ tick: 0, sampleKey: 'kick', velocity: 1 }] }, ...extra });
const program = sections => ({ styleKey: 'rock', beatsPerBar: 4, beatUnit: 4, sections });
const raw = sections => catalog.serializeDrumProgram(program(sections));
const bank = (style, ride) => new Map([
  ['kick', new Int16Array([marker[style]]).buffer],
  ...(ride ? [['ride', new Int16Array(ride).buffer]] : [])
]);

function testModel() {
  const exact = { subdivision: 6, events: [
    { tick: 17.5, sampleKey: 'ride', velocity: 0.37 },
    { tick: 560, sampleKey: 'snare', velocity: 0.71 }
  ] };
  const mixed = program([
    section('A', 'jazz', { customPattern: exact }), section('B', 'rock'),
    section('C', 'jazz'), section('D', 'funk', { customFill: exact })
  ]);
  const decoded = catalog.parseDrumProgram(catalog.serializeDrumProgram(mixed));
  assert.deepEqual(plain(decoded), mixed, 'Persistence preserves each style, fractional ticks, ordering and dynamics');
  assert.deepEqual(plain(catalog.drumProgramStyleKeys(decoded)), ['jazz', 'rock', 'funk']);
  assert.equal(catalog.drumProgramStyleSummary(decoded), '爵士 · 摇滚 · …');
  assert.equal(catalog.drumProgramStyleSummary(decoded, 3), '爵士 · 摇滚 · 放克');
  assert.equal(catalog.drumProgramStyleSummary(program([section('A', 'rock'), section('B', 'jazz')])), '摇滚 · 爵士');
  assert.equal(catalog.drumSectionStyleKey({ ...mixed, styleKey: 'funk' }, { id: 'old' }), 'funk');
  assert.equal(catalog.drumSectionStyleKey({ ...mixed, styleKey: 'jazz' }, { styleKey: 'unknown' }), 'jazz');
  const withoutGlobal = catalog.parseDrumProgram(JSON.stringify({ beatsPerBar: 4, beatUnit: 4,
    sections: [section('A', 'jazz'), section('B', 'funk')] }));
  assert.equal(withoutGlobal.styleKey, 'jazz');
  assert.deepEqual(plain(catalog.drumProgramStyleKeys(withoutGlobal)), ['jazz', 'funk']);
  assert.deepEqual(plain(catalog.buildSectionPattern(decoded, decoded.sections[0], false).events), exact.events);

  for (const [beatsPerBar, beatUnit] of [[4, 4], [3, 8], [7, 16], [5, 2]]) {
    const sections = catalog.DRUM_STYLES.map((style, index) => ({ id: String.fromCharCode(65 + index),
      styleKey: style.key, patternIndex: index % 3, repeats: 2, fillIndex: index % 3, fillEvery: 2 }));
    const song = { styleKey: 'rock', beatsPerBar, beatUnit, sections };
    const sequence = catalog.buildProgramSequence(song);
    assert.equal(sequence.length, sections.length * 2);
    for (let i = 0; i < sections.length; i++) {
      const current = sections[i];
      for (const fill of [false, true]) {
        const expected = catalog.buildDrumPattern(current.styleKey, current.patternIndex,
          beatsPerBar, beatUnit, fill ? current.fillIndex : -1);
        assert.deepEqual(plain(sequence[i * 2 + Number(fill)]), plain(expected),
          'Every section resolves its own preset, fill and unchanged beat duration');
      }
      assert.equal(catalog.sectionFillStartBeat(song, current),
        catalog.presetFillStartBeat(current.styleKey, current.fillIndex, beatsPerBar));
    }
  }
  const fills = program([section('A', 'rock', { fillIndex: 1 }), section('B', 'jazz', { fillIndex: 1 })]);
  assert.equal(catalog.sectionFillStartBeat(fills, fills.sections[0]), 2);
  assert.equal(catalog.sectionFillStartBeat(fills, fills.sections[1]), 3,
    'Jazz and rock fill replacement windows must not inherit each other');
}

function write(h, frames, advance = true) {
  const output = new Int16Array(frames);
  for (let offset = 0; offset < frames; offset += 4096) {
    const count = Math.min(4096, frames - offset);
    const data = new ArrayBuffer(count * 2);
    h.inWrite = true;
    try { assert.equal(h.engine.handleWriteData(data), 0); }
    finally { h.inWrite = false; }
    output.set(new Int16Array(data), offset);
    if (advance) h.advanceClock(count * 1000 / 44100);
  }
  return output;
}

async function testPreparedAudioAndLiveEdit() {
  const loads = [];
  const h = harness({ engineOptions: { compensationMs: 0, physicalLatencyMs: 0 },
    sampleBankClass: { async loadStyle(style) { loads.push(style); return bank(style); } } });
  h.session.keepRendererAliveForSession = true;
  const original = h.engine.renderBar.bind(h.engine);
  h.engine.renderBar = (...args) => {
    assert.notEqual(h.inWrite, true, 'Style loading/rendering stays outside the realtime callback');
    return original(...args);
  };
  const first = [section('A', 'rock'), section('B', 'jazz')];
  await h.session.previewDrumProgram(raw(first), true, 120, 4, 0, ['a', 'b']);
  assert.deepEqual(loads, ['rock', 'jazz']);
  assert.deepEqual(plain(h.engine.pendingSequence.map(bar => bar.samples[0])), [6000, 12000]);
  assert.ok(h.engine.pendingSequence.every(bar => bar.frameCount === BAR));
  await h.fireDueTimers();
  const e = h.engine;
  const transition = e.pendingAudioTransition;
  write(h, transition.targetFrame - e.audioSubmittedFrames);
  assert.equal(write(h, 1)[0], 6000);
  const before = { token: e.runToken, revision: e.transportRevision, renderer: e.renderer,
    starts: e.rendererPhysicalStartCount, origin: e.transportStartLocalMs, active: e.activeBar };
  assert.equal(await h.session.updateDrumPreviewProgram(raw([section('A', 'rock'), section('B', 'funk')]), ['a', 'b']), true);
  assert.equal(e.activeBar, before.active, 'Loading a new kit cannot replace the sounding bar');
  write(h, BAR - e.audioFrameCursor);
  assert.equal(write(h, 1)[0], 18000, 'The next section must use the newly prepared funk kit, not jazz or global rock');
  write(h, BAR - e.audioFrameCursor);
  assert.equal(write(h, 1)[0], 6000, 'Looping restores the first section kit');
  assert.equal(e.runToken, before.token);
  assert.equal(e.transportRevision, before.revision);
  assert.equal(e.renderer, before.renderer);
  assert.equal(e.rendererPhysicalStartCount, before.starts);
  assert.equal(e.transportStartLocalMs, before.origin);
  assert.equal(h.starts.length, 1, 'Per-section live style edits retain one playback origin');
}

async function testAsyncOwnership() {
  const h = harness();
  const stale = h.engine.configureProgram(raw([section('A', 'rock'), section('B', 'jazz')]));
  assert.equal(h.loads.length, 2, 'Both distinct kits load before any mixed sequence is committed');
  h.loads[0].resolve(bank('rock'));
  await flush();
  assert.equal(h.engine.customProgram, undefined, 'One resolved kit cannot expose a partly prepared arrangement');
  const freshRaw = raw([section('C', 'funk')]);
  const fresh = h.engine.configureProgram(freshRaw);
  h.loads[2].resolve(bank('funk'));
  assert.equal(await fresh, true);
  h.loads[1].resolve(bank('jazz'));
  assert.equal(await stale, false);
  assert.equal(h.engine.customProgramRaw, freshRaw);
  assert.equal(h.engine.pendingSequence[0].samples[0], 18000);

  const failure = h.engine.configureProgram(raw([section('D', 'rock'), section('E', 'trap')]));
  const rejected = assert.rejects(failure, /missing kit/);
  h.loads[3].reject(new Error('missing kit'));
  await rejected;
  assert.equal(h.engine.customProgramRaw, freshRaw, 'A missing secondary kit preserves the last complete configuration');
  assert.equal(h.engine.pendingSequence[0].samples[0], 18000);
}

async function testRideCrossesStyleBoundary() {
  const h = harness({ sampleBankClass: { async loadStyle(style) {
    return bank(style, style === 'rock' ? [1000, 2000, 3000, 4000, 5000] : [9000, 8000, 7000, 6000, 5000]);
  } } });
  const frames = 22050;
  const song = { styleKey: 'rock', beatsPerBar: 1, beatUnit: 4, sections: [
    section('A', 'rock', { customPattern: { subdivision: 4, events: [
      { tick: 480 * (frames - 2) / frames, sampleKey: 'ride', velocity: 1 }
    ] } }), section('B', 'jazz', { customPattern: { subdivision: 4, events: [] } })
  ] };
  await h.engine.configureProgram(catalog.serializeDrumProgram(song), false);
  assert.deepEqual(Array.from(h.engine.pendingSequence[0].samples.subarray(-2)), [1000, 2000]);
  assert.deepEqual(Array.from(h.engine.pendingSequence[1].samples.subarray(0, 4)), [3000, 4000, 5000, 0],
    'The old section cymbal tail keeps its source kit across a style boundary');
  assert.ok(h.engine.pendingSequence.every(bar => bar.frameCount === frames));
}

async function testProductionReadyBarrier() {
  const h = harness({ engineOptions: { compensationMs: 0, physicalLatencyMs: 0 } });
  h.session.keepRendererAliveForSession = true;
  const c = h.session.controller;
  const target = raw([section('A', 'rock'), section('B', 'jazz')]);
  c.rhythm = 3; c.drumProgram = target;
  c.emit();
  let settled = false;
  const preparation = c.prepareAudio().then(ready => { settled = true; return ready; });
  for (let i = 0; i < 4; i++) c.emit();
  await flush();
  assert.equal(h.loads.length, 2, 'Repeated production snapshots share one pending mixed-kit preparation');
  assert.equal(settled, false);
  assert.equal(h.starts.length, 0);
  h.loads[0].resolve(bank('rock'));
  await flush();
  assert.equal(settled, false, 'A clock ACK cannot become audio-ready after only the first kit');
  h.advanceKeepAlive(1800);
  h.loads[1].resolve(bank('jazz'));
  assert.equal(await preparation, true);
  assert.equal(h.starts.length, 0, 'Preparing PCM must not publish or schedule a local deadline');
  const deadline = h.now + 650;
  c.state = 'playing';
  h.storage.set('lastTransportMessage', JSON.stringify({ type: 'TRANSPORT', payload: {
    startAtLeaderMonoMs: deadline, beatIndex: 0, countInBeats: 0
  } }));
  c.emit();
  await flush();
  await h.fireDueTimers();
  const transition = h.engine.pendingAudioTransition;
  assert.ok(transition, 'The ordinary production transport schedules after readiness');
  assert.equal(h.engine.transportStartLocalMs, deadline);
  write(h, transition.targetFrame - h.engine.audioSubmittedFrames);
  assert.equal(write(h, 1)[0], 6000);
  write(h, BAR - h.engine.audioFrameCursor);
  assert.equal(write(h, 1)[0], 12000,
    'A cold production start must contain the secondary section kit rather than old click PCM');

  const superseded = harness();
  const owner = superseded.session.controller;
  owner.rhythm = 3; owner.drumProgram = target; owner.emit();
  const older = owner.prepareAudio();
  superseded.loads[0].resolve(bank('rock'));
  await flush();
  const newerRaw = raw([section('A', 'rock'), section('B', 'funk')]);
  owner.drumProgram = newerRaw; owner.emit();
  const newer = owner.prepareAudio();
  superseded.loads[2].resolve(bank('funk'));
  assert.equal(await newer, true);
  superseded.loads[1].resolve(bank('jazz'));
  assert.equal(await older, false, 'A superseded audio configuration cannot authorize its old preparation ACK');
  assert.equal(superseded.engine.customProgramRaw, newerRaw);

  const failed = harness();
  const bad = failed.session.controller;
  bad.rhythm = 3; bad.drumProgram = target; bad.emit();
  const rejected = bad.prepareAudio();
  failed.loads[0].resolve(bank('rock'));
  failed.loads[1].reject(new Error('missing second kit'));
  assert.equal(await rejected, false, 'Production configuration failures report not-ready without unhandled rejections');
  assert.equal(failed.starts.length, 0);
}

async function main() {
  testModel();
  await testPreparedAudioAndLiveEdit();
  await testAsyncOwnership();
  await testRideCrossesStyleBoundary();
  await testProductionReadyBarrier();
  console.log('PASS multi-style drums: exact persistence, 12 styles across four meters, source-style fill windows, actual per-section PCM, unchanged shared clock/renderer during edits, complete-bank readiness/latest-wins/failure, cross-style cymbal tails, production cold-load readiness and superseded ACK rejection');
}
main().catch(error => { console.error(error); process.exitCode = 1; });
