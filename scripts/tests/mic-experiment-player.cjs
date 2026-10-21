const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const ts = require(process.argv[2] || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');

const source = fs.readFileSync('entry/src/main/ets/audio/MicExperimentPlayer.ets', 'utf8')
  .replace(/^import[^\n]*\n/gm, '');
const compiled = ts.transpileModule(source, {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 }, reportDiagnostics: true
});
assert.equal(compiled.diagnostics.filter(item => item.category === ts.DiagnosticCategory.Error).length, 0);

function deferred() {
  let resolve, reject;
  const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}

async function flush() { for (let index = 0; index < 30; index++) await Promise.resolve(); }
function outcome(promise) { return promise.then(() => undefined, error => error); }

function harness() {
  const trace = [], players = [], timers = new Map(), configurations = [];
  let fd = 40, timerId = 0;
  class Player {
    constructor(options = {}) {
      this.options = options;
      this.id = players.length + 1;
      this.handlers = new Map();
      this.prepareGate = deferred();
      this.playGate = options.playGate;
      this.releaseGate = options.releaseGate;
      players.push(this);
    }
    on(event, callback) { this.handlers.set(event, callback); }
    off(event) { this.handlers.delete(event); }
    emit(event, value) { this.handlers.get(event)?.(value); }
    set fdSrc(value) {
      this.source = value;
      trace.push(`source:${this.id}:${value.fd}`);
      this.emit('stateChange', 'initialized');
    }
    set audioRendererInfo(value) { this.rendererInfo = value; }
    set audioEffectMode(value) { this.effectMode = value; }
    prepare() {
      trace.push(`prepare:${this.id}`);
      if (this.options.prepareError) return Promise.reject(new Error('prepare failed'));
      return this.prepareGate.promise;
    }
    ready() { this.prepareGate.resolve(); this.emit('stateChange', 'prepared'); }
    play() {
      trace.push(`play:${this.id}`);
      if (this.options.playError) return Promise.reject(new Error('play failed'));
      return this.playGate?.promise ?? Promise.resolve();
    }
    async release() {
      trace.push(`release:${this.id}`);
      if (this.releaseGate) await this.releaseGate.promise;
      trace.push(`released:${this.id}`);
      if (this.options.releaseError) throw new Error('release failed');
    }
  }
  const context = {
    exports: {},
    audio: { StreamUsage: { STREAM_USAGE_GAME: 99 }, AudioEffectMode: { EFFECT_NONE: 0 } },
    fs: {
      OpenMode: { READ_ONLY: 0 },
      async open(path) { const file = { fd: ++fd }; trace.push(`open:${path}:${file.fd}`); return file; },
      async stat(sourceFd) { trace.push(`stat:${sourceFd}`); return { size: 2048, isFile: () => true }; },
      async close(file) { trace.push(`close:${file.fd}`); }
    },
    media: {
      async createAVPlayer() {
        const options = configurations.shift() ?? {};
        trace.push('create');
        if (options.creationGate) await options.creationGate.promise;
        if (options.creationError) throw new Error('create failed');
        return new Player(options);
      }
    },
    setTimeout(callback, delay) { const id = ++timerId; timers.set(id, { callback, delay }); return id; },
    clearTimeout(id) { timers.delete(id); }
  };
  vm.runInNewContext(compiled.outputText, context);
  return {
    player: new context.exports.MicExperimentPlayer(), trace, players, timers, configurations, context,
    Player, fireTimeout() {
      const [id, timer] = [...timers.entries()][0];
      timers.delete(id); timer.callback();
    }
  };
}

(async () => {
  {
    const h = harness(), nativePlay = deferred();
    h.configurations.push({ playGate: nativePlay });
    let started = false, ended = 0;
    const start = h.player.play('/raw/mic.wav', () => ended++).then(() => { started = true; });
    await flush();
    assert.equal(started, false, 'Preparing a file cannot report audible playback');
    assert.equal(h.players[0].rendererInfo.usage, 99);
    assert.equal(h.players[0].rendererInfo.rendererFlags, 0);
    h.players[0].ready(); await flush();
    assert.equal(started, false, 'The start promise waits for native play success');
    assert.equal(h.players[0].effectMode, 0, 'Both original WAVs use effects disabled, without gain normalization');
    nativePlay.resolve(); await start;
    assert.equal(started, true);
    assert.equal(h.timers.size, 0, 'The startup timer does not end successful playback later');
    h.players[0].emit('stateChange', 'completed'); await flush();
    assert.equal(ended, 1);
    assert.ok(h.trace.indexOf('released:1') < h.trace.indexOf('close:41'), 'Release the decoder before closing its source fd');
    assert.equal(h.players[0].handlers.size, 0);
    await h.player.stop();
    assert.equal(h.trace.filter(value => value === 'close:41').length, 1);
  }
  {
    const h = harness(); let ended = 0;
    const start = outcome(h.player.play('/raw/a.wav', () => ended++));
    await flush();
    h.player.cancel();
    assert.match((await start).message, /取消/);
    await h.player.stop();
    h.players[0].ready(); await flush();
    assert.equal(h.trace.includes('play:1'), false, 'A late prepared callback after cancellation cannot play');
    assert.equal(ended, 0, 'Explicit navigation cancellation is not natural completion');
    assert.ok(h.trace.includes('close:41'));
  }
  {
    const h = harness(), release = deferred();
    h.configurations.push({ releaseGate: release });
    const oldStart = outcome(h.player.play('/raw/old.wav'));
    await flush();
    const replacement = h.player.play('/raw/new.wav');
    assert.match((await oldStart).message, /取消/);
    await flush();
    assert.equal(h.players.length, 1, 'Replacement waits for old player release before allocating playback');
    release.resolve(); await flush();
    assert.equal(h.players.length, 2);
    h.players[0].ready(); h.players[1].ready(); await replacement;
    assert.equal(h.trace.includes('play:1'), false);
    assert.equal(h.trace.filter(value => value === 'play:2').length, 1);
    await h.player.stop();
    assert.deepEqual(h.trace.filter(value => value.startsWith('close:')), ['close:41', 'close:42']);
  }
  {
    const h = harness(), release = deferred(); let oldEnded = 0, newEnded = 0;
    h.configurations.push({ releaseGate: release });
    const first = h.player.play('/raw/old.wav', () => oldEnded++);
    await flush(); h.players[0].ready(); await first;
    h.players[0].emit('stateChange', 'completed');
    const second = h.player.play('/raw/new.wav', () => newEnded++);
    release.resolve(); await flush(); h.players[1].ready(); await second;
    assert.equal(oldEnded, 0, 'An old completion pending cleanup cannot overwrite replacement UI');
    h.players[1].emit('stateChange', 'completed'); await flush();
    assert.equal(newEnded, 1);
  }
  {
    const h = harness(); let ended = 0;
    const start = h.player.play('/raw/error.wav', () => ended++);
    await flush(); h.players[0].ready(); await start;
    h.players[0].emit('error', new Error('native decode failure'));
    h.players[0].emit('stateChange', 'completed'); await flush();
    assert.equal(ended, 1, 'An error followed by completed only ends the current audition once');
    assert.ok(h.trace.includes('close:41'));
  }
  {
    const h = harness(); let ended = 0;
    const start = h.player.play('/raw/interrupted.wav', () => ended++);
    await flush(); h.players[0].ready(); await start;
    h.players[0].emit('audioInterrupt', { hintType: 'resume', forceType: 'share' }); await flush();
    assert.equal(ended, 1, 'Any interrupt ends the audition; resume cannot restart it later');
    assert.ok(h.trace.includes('close:41'));
    assert.equal(h.trace.filter(value => value === 'play:1').length, 1);
  }
  {
    const h = harness();
    h.configurations.push({ releaseError: true });
    const start = h.player.play('/raw/release-error.wav');
    await flush(); h.players[0].ready(); await start;
    await h.player.stop();
    assert.ok(h.trace.includes('close:41'), 'Native release rejection must still close its fd');
  }
  for (const options of [{ creationError: true }, { prepareError: true }, { playError: true }]) {
    const h = harness();
    h.configurations.push(options);
    const start = outcome(h.player.play('/raw/bad.wav'));
    await flush();
    if (options.playError) h.players[0].ready();
    assert.match((await start).message, /失败|无法打开/);
    await h.player.stop();
    assert.ok(h.trace.includes('close:41'), 'Native setup failure closes the opened fd');
    assert.equal(h.timers.size, 0);
  }
  {
    const h = harness(), creation = deferred();
    h.configurations.push({ creationGate: creation });
    const start = outcome(h.player.play('/raw/pending-create.wav'));
    await flush(); h.player.cancel();
    assert.match((await start).message, /取消/);
    assert.equal(h.trace.includes('close:41'), false, 'An fd stays alive while native creation is pending');
    creation.resolve(); await h.player.stop();
    assert.ok(h.trace.indexOf('released:1') < h.trace.indexOf('close:41'));
    assert.equal(h.trace.some(value => value.startsWith('source:')), false, 'Late player creation cannot attach a cancelled source');
  }
  {
    const h = harness();
    const start = outcome(h.player.play('/raw/timeout.wav'));
    await flush();
    assert.equal([...h.timers.values()][0].delay, 8000);
    h.fireTimeout(); assert.match((await start).message, /超时/);
    await h.player.stop();
    assert.ok(h.trace.includes('close:41'));
    h.players[0].ready(); await flush();
    assert.equal(h.trace.includes('play:1'), false);
  }
  console.log('PASS mic-experiment-player: cancellation, replacement, native failures, timeout and fd lifecycle');
})().catch(error => { console.error(error); process.exitCode = 1; });
