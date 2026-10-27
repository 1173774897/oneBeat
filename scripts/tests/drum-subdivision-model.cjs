// Run with Node and a typescript/lib/typescript.js path, matching the sync gate.
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require(process.argv[2]);
const { fixture } = require('./metronome-start-timing.cjs');
const sourceRoot = path.resolve(__dirname, '../../entry/src/main/ets');
const cache = new Map();
function load(relative) {
  const file = path.resolve(sourceRoot, relative);
  if (cache.has(file)) return cache.get(file);
  const exports = {};
  cache.set(file, exports);
  const compiled = ts.transpileModule(fs.readFileSync(file, 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 },
    reportDiagnostics: true
  });
  assert.equal((compiled.diagnostics ?? []).filter(d => d.category === ts.DiagnosticCategory.Error).length, 0);
  vm.runInNewContext(compiled.outputText, {
    exports,
    require(name) {
      if (name === '@kit.CryptoArchitectureKit') return { cryptoFramework: {} };
      return load(path.relative(sourceRoot, path.resolve(path.dirname(file), `${name}.ets`)));
    }
  }, { filename: file });
  return exports;
}
const meter = load('common/MeterModel.ets');
const timeline = load('audio/RhythmTimeline.ets');
const catalog = load('audio/DrumMachineCatalog.ets');
const plain = value => JSON.parse(JSON.stringify(value));
const event = (tick, sampleKey = 'snare', velocity = 0.37) => ({ tick, sampleKey, velocity });

function testLegacyRowsAndExpandedKit() {
  const oldKeys = ['kick', 'snare', 'hat_closed', 'hat_open', 'clap', 'tom_low', 'tom_high', 'perc'];
  assert.deepEqual(plain(catalog.DRUM_TRACKS.map(t => t.key)),
    ['kick', 'snare', 'hat_closed', 'hat_open', 'ride', 'clap', 'tom_low', 'tom_high', 'perc', 'shaker']);
  const legacyHash = crypto.createHash('sha256');
  for (const beats of meter.METER_NUMERATORS) for (const unit of meter.METER_DENOMINATORS) {
    const count = beats * meter.stepsPerBeatForUnit(unit);
    const rows = oldKeys.map((_, track) =>
      Array.from({ length: count }, (_, step) => (step + track) % 7 === 0 ? '1' : '0').join(''));
    const main = catalog.buildDrumPattern('rock', 0, beats, unit, -1, rows);
    legacyHash.update(JSON.stringify([beats, unit, main.ticksPerBeat, main.beatsPerBar, main.events]));
    const program = { styleKey: 'rock', beatsPerBar: beats, beatUnit: unit, sections: [{
      id: 'A', patternIndex: 0, repeats: 2, fillIndex: 2, fillEvery: 2, customRows: rows, customFillRows: rows
    }] };
    const decoded = catalog.parseDrumProgram(catalog.serializeDrumProgram(program));
    const sequence = catalog.buildProgramSequence(decoded);
    assert.deepEqual(plain(sequence[0].events), plain(main.events), 'Legacy main rows retain the old eight voice assignments');
    assert.deepEqual(plain(sequence[1].events), plain(main.events), 'Legacy custom fills retain full-bar timing, voices and dynamics');
    assert.ok(sequence.every(p => p.events.every(e => oldKeys.includes(e.sampleKey))),
      'Old rows must never become ride or shaker notes after a track insertion');
  }
  // Captured from production immediately before inserting ride/shaker. This
  // protects all original instrument keys, beat-unit timing and generated velocities.
  assert.equal(legacyHash.digest('hex'), '254bc571258e70e00ef06f969123c672b210719da0a418bd0b2ecf673235765f');
  const voiceRows = oldKeys.map((_, track) => '0'.repeat(track) + '1' + '0'.repeat(15 - track));
  const voices = catalog.buildDrumPattern('rock', 0, 4, 4, -1, voiceRows).events;
  assert.deepEqual(plain(voices.map(e => e.sampleKey)), oldKeys, 'The fifth old row remains clap, followed by both toms and percussion');
  assert.deepEqual(plain(voices.map(e => e.tick)), oldKeys.map((_, i) => i * 120));

  const newRows = catalog.emptyCustomRows(4, 4);
  assert.equal(newRows.length, 10);
  for (let track = 0; track < 10; track++) newRows[track] = '0'.repeat(track) + '1' + '0'.repeat(15 - track);
  const expanded = catalog.buildDrumPattern('rock', 0, 4, 4, -1, newRows);
  assert.deepEqual(plain(expanded.events.map(e => e.sampleKey)), plain(catalog.DRUM_TRACKS.map(t => t.key)));
  assert.deepEqual(plain(catalog.patternToRows(expanded, 4, 4)), plain(newRows),
    'Ten-row helpers must round-trip ride and shaker in their new positions');
}

function testStyleArrangements() {
  const trackKeys = new Set(catalog.DRUM_TRACKS.map(t => t.key));
  const identities = new Set();
  let cases = 0;
  for (const style of catalog.DRUM_STYLES) {
    const names = catalog.drumPatternNames(style.key);
    const fills = catalog.drumFillNames(style.key);
    assert.equal(names.length, 3);
    assert.equal(fills.length, 3);
    assert.equal(new Set(names).size, 3, `${style.key} patterns need distinct descriptive names`);
    assert.equal(new Set(fills).size, 3, `${style.key} fills need distinct descriptive names`);
    assert.notDeepEqual(plain(names), ['基础律动', '推进律动', '强力律动']);
    const variants = [0, 1, 2].map(v => JSON.stringify(catalog.buildDrumPattern(style.key, v, 4, 4).events));
    assert.equal(new Set(variants).size, 3, `${style.key} needs three distinct arrangements`);
    assert.equal(new Set([0, 1, 2].map(fill => JSON.stringify(catalog.buildDrumPattern(style.key, 0, 4, 4, fill).events))).size, 3,
      `${style.key} needs three distinct fill phrases`);
    identities.add(variants[0]);
    for (const beats of meter.METER_NUMERATORS) for (const unit of meter.METER_DENOMINATORS) {
      for (let variant = 0; variant < 3; variant++) for (let fill = -1; fill < 3; fill++) {
        const p = catalog.buildDrumPattern(style.key, variant, beats, unit, fill);
        assert.equal(p.ticksPerBeat, 480);
        assert.equal(p.beatsPerBar, beats);
        assert.ok(p.events.length > 0, `${style.key} cannot accidentally produce an empty built-in bar`);
        const hits = new Set();
        for (const e of p.events) {
          assert.ok(trackKeys.has(e.sampleKey), `${style.key} may use only available kit voices`);
          assert.ok(Number.isFinite(e.tick) && e.tick >= 0 && e.tick < beats * 480, 'Built-ins must stay in the selected bar');
          assert.ok(Number.isFinite(e.velocity) && e.velocity > 0 && e.velocity <= 1);
          const identity = `${e.sampleKey}/${e.tick}`;
          assert.ok(!hits.has(identity), 'A single instrument cannot double-trigger at the same position');
          hits.add(identity);
        }
        cases++;
      }
    }
  }
  assert.equal(cases, 11520);
  assert.equal(identities.size, 12, 'Every style needs its own audible rhythm rather than a renamed shared preset');
  const notes = (style, variant, key) => plain(catalog.buildDrumPattern(style, variant, 4, 4).events.filter(e => e.sampleKey === key));
  const ticks = (style, variant, key) => notes(style, variant, key).map(e => e.tick);
  assert.deepEqual(ticks('rock', 0, 'snare'), [480, 1440], 'Rock retains the second/fourth-beat snare backbeat');
  assert.ok(notes('rock', 2, 'ride').length > 0);
  assert.ok(notes('psychedelic', 0, 'ride').length > 0);
  assert.ok(catalog.buildDrumPattern('psychedelic', 0, 4, 4).events.length < catalog.buildDrumPattern('rock', 0, 4, 4).events.length,
    'Psychedelic base phrasing must leave room for its sustained cymbal texture');
  assert.ok(notes('funk', 1, 'snare').some(e => e.tick % 480 !== 0 && e.velocity < 0.4), 'Funk needs syncopated ghost notes');
  assert.ok(notes('funk', 0, 'kick').some(e => e.tick % 480 !== 0), 'Funk needs a syncopated kick');
  for (const style of ['disco', 'house', 'techno']) {
    assert.deepEqual(ticks(style, 0, 'kick'), [0, 480, 960, 1440], `${style} keeps four-on-the-floor kicks`);
    assert.deepEqual(ticks(style, 0, 'hat_open'), [240, 720, 1200, 1680], `${style} keeps the offbeat open hat`);
  }
  assert.deepEqual(ticks('hiphop', 0, 'snare'), [492, 1452], 'Hip-hop layback belongs to event ticks, leaving transport beats intact');
  assert.deepEqual(ticks('trap', 0, 'snare'), [960], 'Trap keeps a half-time backbeat');
  const trapRoll = ticks('trap', 1, 'hat_closed').filter(t => t >= 480 && t < 960);
  assert.deepEqual(trapRoll, [480, 560, 640, 720, 800, 880], 'Trap includes a six-way hi-hat roll');
  assert.deepEqual(ticks('trap', 1, 'hat_open'), [400], 'The triplet preset keeps its open-hat pickup on the last sixth');
  assert.deepEqual(ticks('trap', 1, 'kick'), [0, 1200, 1840], 'The triplet preset keeps its late kick on the last sixth');
  for (const beats of meter.METER_NUMERATORS) for (const unit of meter.METER_DENOMINATORS) {
    const triplet = catalog.buildDrumPattern('trap', 1, beats, unit);
    assert.ok(triplet.events.every(e => e.tick % 80 === 0),
      'Every voice in the triplet-roll preset must fit six subdivisions, including pickups and compound meters');
  }
  assert.deepEqual(ticks('trap', 0, 'kick'), [0, 1800], 'The straight trap preset keeps its existing kick positions');
  assert.deepEqual(ticks('trap', 2, 'kick'), [0, 1200, 1800], 'The dense trap preset keeps its existing kick positions');
  assert.deepEqual(ticks('trap', 2, 'hat_open'), [360], 'Only the triplet preset moves its open-hat pickup');
  assert.deepEqual(ticks('dnb', 0, 'kick'), [0, 1200], 'Drum and bass uses a broken kick phrase');
  assert.deepEqual(ticks('dnb', 0, 'snare'), [480, 1440]);
  assert.deepEqual(ticks('latin', 1, 'perc'), [0, 720, 1440], 'Latin accents follow the named 3+3+2 eighth-note pattern');
  assert.ok(notes('latin', 0, 'shaker').length >= 8);
  assert.deepEqual(ticks('reggae', 0, 'kick'), [960], 'One Drop leaves the first beat empty on kick');
  assert.deepEqual(ticks('reggae', 2, 'kick'), [0, 480, 960, 1440], 'Steppers restores a kick on every beat');
  for (const style of ['disco', 'hiphop', 'house']) assert.ok(notes(style, 1, 'shaker').length > 0);
  for (const style of ['funk', 'hiphop', 'house', 'techno', 'dnb']) assert.ok(notes(style, 2, 'ride').length > 0);
}

function testEventPersistence() {
  const pattern = { subdivision: 6, events: [event(320, 'ride', 0.42), event(17.5, 'snare', 0), event(560, 'shaker', 0.83)] };
  const fill = { subdivision: 3, events: [event(1760, 'tom_high', 0.66)] };
  const section = { id: 'A', patternIndex: 0, repeats: 2, fillIndex: 1, fillEvery: 2,
    customPattern: pattern, customFill: fill };
  const program = { styleKey: 'jazz', beatsPerBar: 4, beatUnit: 4, sections: [section] };
  const encoded = catalog.serializeDrumProgram(program);
  const decoded = catalog.parseDrumProgram(encoded);
  assert.deepEqual(plain(decoded), program, 'Save and restore must preserve exact event tick, track, velocity and event order');
  assert.equal(catalog.serializeDrumProgram(decoded), encoded);
  const copy = catalog.cloneDrumCustomPattern(pattern);
  assert.deepEqual(plain(copy), pattern);
  copy.events[0].velocity = 1;
  copy.events.push(event(100));
  assert.equal(pattern.events[0].velocity, 0.42, 'Drafts must never alias saved event objects');
  assert.equal(pattern.events.length, 3);
  assert.equal(catalog.cloneDrumCustomPattern(undefined), undefined);
  const sequence = catalog.buildProgramSequence(decoded);
  assert.deepEqual(plain(sequence[0].events), pattern.events, 'Rendering the custom pattern must retain dynamics and off-grid timing');
  assert.deepEqual(plain(sequence[1].events), fill.events, 'A saved custom fill replaces the entire fill bar');
  assert.deepEqual(plain(catalog.buildSectionPattern(decoded, decoded.sections[0], false).events), pattern.events);
  assert.deepEqual(plain(catalog.buildSectionPattern(decoded, decoded.sections[0], true).events), fill.events);

  for (const field of ['customPattern', 'customFill']) {
    const emptySection = { id: 'A', patternIndex: 2, repeats: 1, fillIndex: 2, fillEvery: field === 'customFill' ? 1 : 0,
      customRows: Array(8).fill('1111111111111111'), customFillRows: Array(8).fill('1111111111111111'),
      [field]: { subdivision: 3, events: [] } };
    const empty = catalog.parseDrumProgram(catalog.serializeDrumProgram({ ...program, sections: [emptySection] }));
    assert.deepEqual(plain(catalog.buildProgramSequence(empty)[0].events), [],
      'An explicitly empty event pattern means silence and must override legacy rows and presets');
  }
  const nextPattern = { subdivision: 3, events: [event(160), event(1920), event(2000)] };
  const cropped = catalog.buildSectionPattern(program, { ...section, customPattern: nextPattern }, false);
  assert.deepEqual(plain(cropped.events), [event(160)], 'Render only events inside the current bar');
  assert.equal(nextPattern.events.length, 3, 'A temporary meter change must not erase stored out-of-bar notes');
}

function testJazzPhrasing() {
  assert.deepEqual(plain(catalog.drumPatternNames('jazz')), ['经典 Swing', 'Jazz Shuffle', '推进 Swing']);
  assert.deepEqual(plain(catalog.drumFillNames('jazz')), ['三连应答', '六连滚奏', 'Swing 过鼓']);
  const swing = catalog.buildDrumPattern('jazz', 0, 4, 4);
  const closed = swing.events.filter(e => e.sampleKey === 'ride');
  assert.deepEqual(plain(closed.map(e => e.tick)), [0, 480, 800, 960, 1440, 1760],
    'Classic swing must have the quarter-note ride phrase with 2:1 skip notes on beats two and four');
  const shuffle = catalog.buildDrumPattern('jazz', 1, 4, 4);
  const shuffleHat = shuffle.events.filter(e => e.sampleKey === 'ride');
  assert.deepEqual(plain(shuffleHat.map(e => e.tick)), [0, 320, 480, 800, 960, 1280, 1440, 1760],
    'Shuffle must use the first and third triplet positions rather than the old 3:1 sixteenth pairing');
  assert.ok(shuffleHat[0].velocity > shuffleHat[1].velocity, 'Shuffle pairs must retain their long/short accent contrast');
  const roll = catalog.buildDrumPattern('jazz', 0, 4, 4, 1).events.filter(e => e.tick >= 1440);
  const rolls = roll.filter(e => ['snare', 'tom_high', 'tom_low'].includes(e.sampleKey));
  assert.deepEqual(plain(rolls.map(e => e.tick)), [1440, 1520, 1600, 1680, 1760, 1840]);
  assert.ok(new Set(rolls.map(e => e.velocity)).size >= 3, 'Six-note rolls need accented and ghost-note dynamics');
  for (const beats of meter.METER_NUMERATORS) for (const unit of meter.METER_DENOMINATORS) {
    for (let variant = 0; variant < 3; variant++) for (let fill = -1; fill < 3; fill++) {
      const p = catalog.buildDrumPattern('jazz', variant, beats, unit, fill);
      assert.equal(p.ticksPerBeat, 480);
      assert.equal(p.beatsPerBar, beats);
      const hits = new Set();
      for (const e of p.events) {
        assert.ok(Number.isFinite(e.tick) && e.tick >= 0 && e.tick < beats * 480, 'Jazz notes must stay in the selected bar');
        assert.ok(Number.isFinite(e.velocity) && e.velocity > 0 && e.velocity <= 1);
        const identity = `${e.sampleKey}/${e.tick}`;
        assert.ok(!hits.has(identity), 'Each instrument may trigger only once at the same time');
        hits.add(identity);
      }
    }
  }
}

function testRenderedTimeline() {
  let checked = 0;
  for (const bpm of [60, 90, 120, 137]) for (const beats of [3, 4, 6, 7]) {
    const h = fixture({ queueMs: 0 });
    h.engine.bpm = bpm;
    h.engine.beatPointStates = Array(beats).fill('normal');
    h.engine.sampleBank = new Map([['kick', new Int16Array([10000]).buffer]]);
    const expectedFrames = Math.round(44100 * 60 / bpm * beats);
    for (const subdivision of [4, 3, 6]) {
      const events = Array.from({ length: beats * subdivision }, (_, step) =>
        event(step * 480 / subdivision, 'kick', step % 2 === 0 ? 0.8 : 0.3));
      const rendered = h.engine.renderBar(new timeline.SequencerPattern(480, beats, events));
      assert.equal(rendered.frameCount, expectedFrames, 'Subdivision must never change the bar duration or its beat clock');
      assert.equal(rendered.samplesPerBeat, 44100 * 60 / bpm);
      const onsets = [...rendered.samples].flatMap((sample, frame) => sample !== 0 ? [[frame, sample]] : []);
      assert.deepEqual(onsets, events.map(e => [Math.round(e.tick * rendered.samplesPerBeat / 480), Math.round(10000 * e.velocity)]),
        'The actual audio renderer must place all three subdivisions and their dynamics on the original beat timeline');
      checked++;
    }
  }
  assert.equal(checked, 48);
}

function testProtocolCompatibility() {
  const constants = load('common/Constants.ets');
  const invitations = load('network/p2p/P2pInvitation.ets');
  assert.ok(constants.PROTOCOL_VERSION > 6, 'Per-section styles cannot be shared with peers that silently discard them');
  const valid = { v: invitations.P2P_INVITATION_FORMAT_VERSION, role: 'join', code: '123456',
    roomId: 'test-room-identifier', authToken: 'a'.repeat(32), groupName: 'DIRECT-test', passphrase: 'test-password',
    protocolVersion: constants.PROTOCOL_VERSION, expiresAt: Date.now() + 100000, port: 9527 };
  assert.doesNotThrow(() => invitations.parseP2pRoomInvitation(JSON.stringify(valid)));
  for (const oldVersion of [4, 5, 6]) {
    assert.throws(() => invitations.parseP2pRoomInvitation(JSON.stringify({ ...valid, protocolVersion: oldVersion })), /双方版本不一致/,
      'Old peers must be rejected visibly instead of silently playing missing voices or a different rhythm');
  }
}

async function testRideTailContinuation() {
  const frames = 22050; // One unchanged 120 BPM transport beat.
  const lastTick = 480 * (frames - 2) / frames;
  const empty = () => new timeline.SequencerPattern(480, 1, []);
  const hit = () => new timeline.SequencerPattern(480, 1, [event(lastTick, 'ride', 0.5)]);
  function harness(samples, state = 'normal', accentProgram = false) {
    const h = fixture({ queueMs: 0 });
    h.engine.bpm = 120;
    h.engine.beatsPerBar = 1;
    h.engine.beatPointStates = [state];
    h.engine.sampleBank = new Map([['ride', new Int16Array(samples).buffer]]);
    if (accentProgram) h.engine.customProgram = { styleKey: 'jazz', beatsPerBar: 1, beatUnit: 4, sections: [] };
    return h;
  }
  const pulse = [1000, 800, 600, 400, 200, 120];
  const internal = harness(pulse);
  internal.engine.rebuildPendingSequence([hit(), empty()], false);
  const [first, second] = internal.engine.pendingSequence;
  assert.equal(first.frameCount, frames);
  assert.equal(second.frameCount, frames);
  assert.deepEqual([...first.samples.slice(-2)], [500, 400]);
  assert.deepEqual([...second.samples.slice(0, 5)], [300, 200, 100, 60, 0],
    'A ride struck two frames before the boundary must continue naturally into the next bar');

  const finite = harness(pulse);
  finite.engine.rebuildPendingSequence([empty(), hit()], false);
  assert.ok(finite.engine.pendingSequence[0].samples.every(v => v === 0),
    'A finite arrangement must not wrap its last ride tail to the beginning');
  assert.deepEqual([...finite.engine.pendingSequence[1].samples.slice(-2)], [500, 400]);
  const looping = harness(pulse);
  looping.engine.rebuildPendingSequence([empty(), hit()], true);
  assert.deepEqual([...looping.engine.pendingSequence[0].samples.slice(0, 5)], [300, 200, 100, 60, 0],
    'Looping arrangements must retain the last bar ride tail across the loop seam');

  const longSample = new Int16Array(frames * 3 + 5);
  longSample.fill(2000, 0, frames);
  longSample.fill(1000, frames, frames * 2);
  longSample.fill(500, frames * 2, frames * 3);
  longSample.fill(250, frames * 3);
  const long = harness(longSample);
  long.engine.rebuildPendingSequence([hit()], true);
  const steady = long.engine.pendingSequence[0];
  assert.equal(steady.frameCount, frames, 'Long cymbal tails cannot extend the bar or move the transport boundary');
  assert.deepEqual([...steady.samples.slice(0, 5)], [1875, 1875, 1875, 1750, 1750],
    'A tail longer than a full loop must sum all preceding-cycle contributions');
  assert.equal(steady.samples[Math.floor(frames / 2)], 1750);
  assert.deepEqual([...steady.samples.slice(-2)], [1875, 1875]);

  const silent = harness(pulse, 'silent', true);
  silent.engine.rebuildPendingSequence([hit(), empty()], true);
  assert.ok(silent.engine.pendingSequence.every(bar => bar.samples.every(v => v === 0)),
    'A ride on a silent source beat must contribute neither its attack nor a later tail');
  const accent = harness(pulse, 'accent', true);
  accent.engine.rebuildPendingSequence([hit(), empty()], false);
  assert.deepEqual([...accent.engine.pendingSequence[0].samples.slice(-2)], [575, 460]);
  assert.deepEqual([...accent.engine.pendingSequence[1].samples.slice(0, 4)], [345, 230, 115, 69],
    'Ride continuation must retain the source hit velocity and accent gain across a normal boundary');

  const oldVoice = harness(pulse);
  oldVoice.engine.sampleBank.set('snare', new Int16Array(pulse).buffer);
  const oldPattern = new timeline.SequencerPattern(480, 1, [event(lastTick, 'snare', 0.5)]);
  const original = oldVoice.engine.renderBar(oldPattern);
  oldVoice.engine.rebuildPendingSequence([oldPattern], true);
  assert.deepEqual([...oldVoice.engine.pendingSequence[0].samples], [...original.samples],
    'The new continuation must leave existing non-ride PCM byte-for-byte unchanged');

  // Prepared PCM must contain all continuation work. Guard both preparation
  // entry points while exercising the actual native write callback path.
  long.engine.renderBar = () => { throw new Error('Cannot render a bar inside native playback'); };
  long.engine.mixRideTails = () => { throw new Error('Cannot mix ride tails inside native playback'); };
  await long.engine.scheduleFromLeaderStart(long.now + 650, 0, 0, undefined, 0);
  await long.fireDueTimers();
  const transition = long.engine.pendingAudioTransition;
  assert.ok(transition);
  const prefix = transition.targetFrame - long.engine.audioSubmittedFrames;
  assert.ok(prefix >= 0);
  const buffer = new ArrayBuffer((prefix + 64) * 2);
  assert.equal(long.engine.handleWriteData(buffer), 0);
  assert.deepEqual([...new Int16Array(buffer).subarray(prefix)], [...steady.samples.slice(0, 64)],
    'The native callback must only read the already-prepared ride continuation');
}

async function main() {
  testLegacyRowsAndExpandedKit();
  testStyleArrangements();
  testEventPersistence();
  testJazzPhrasing();
  testRenderedTimeline();
  testProtocolCompatibility();
  await testRideTailContinuation();
  console.log('PASS drum subdivisions/kit: 11520 built-ins, all80 legacy main/fill meters unchanged, 10-voice persistence, dynamics, jazz phrasing, 48 real-renderer timing cases, ride tail continuation/loop/finite/accent/silence/callback boundaries and old-peer rejection');
}
main().catch(error => { console.error(error); process.exitCode = 1; });
