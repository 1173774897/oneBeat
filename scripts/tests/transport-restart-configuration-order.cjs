// Run with DevEco's bundled Node; pass typescript/lib/typescript.js as argv[2].
const assert = require('node:assert/strict');
const { harness } = require('./transport-start-diagnostics.cjs');

async function main() {
  {
    // A running BPM change must render the new configuration on every device
    // before the clock preparation round, never right before TRANSPORT.
    const h = harness(true);
    const peer = h.addPeer('peer-one');
    const events = [];
    h.controller.notifyUi = () => events.push(`ui:bpm=${h.controller.bpm}`);
    const originalPush = h.sent.push.bind(h.sent);
    h.sent.push = message => {
      events.push(`send:${message.type}${message.payload?.bpm !== undefined ? `:bpm=${message.payload.bpm}` : ''}`);
      return originalPush(message);
    };
    h.controller.state = 'playing';
    h.controller.bpm = 120;
    const restart = h.controller.updateBpm(60);
    await h.advance(349);
    assert.equal(h.sent.some(message => message.type === 'SESSION_SNAPSHOT'), false,
      'a live change waits for the 350ms coalescing window');
    await h.advance(1);
    const prepare = h.sent.find(message => message.type === 'TRANSPORT_PREPARE');
    assert.ok(prepare, 'preparation must have started');
    const configIndex = events.indexOf('send:SESSION_SNAPSHOT:bpm=60');
    const prepareIndex = events.indexOf('send:TRANSPORT_PREPARE');
    assert.ok(configIndex >= 0 && configIndex < prepareIndex,
      `configuration must reach members before preparation: ${events.join(' | ')}`);
    assert.ok(events.indexOf('ui:bpm=60') < prepareIndex, 'leader engine must apply the config before preparation');
    assert.equal(events.includes('send:TRANSPORT'), false, 'TRANSPORT waits for preparation');

    await h.advance(600);
    h.controller.onLeaderMessage(peer, { type: 'TRANSPORT_READY', payload: { id: prepare.payload.id } });
    await restart;
    const transportIndex = events.indexOf('send:TRANSPORT');
    assert.ok(transportIndex > prepareIndex, 'TRANSPORT follows preparation');
    const transport = h.sent.find(message => message.type === 'TRANSPORT');
    assert.equal(transport.payload.countInBeats, 0, 'a running restart has no count-in');
    assert.equal(h.controller.state, 'countdown');
  }
  {
    // Rapid changes coalesce: one snapshot (re-render) and one restart for the last value.
    const h = harness(true);
    const peer = h.addPeer('peer-one');
    h.controller.state = 'playing';
    h.controller.bpm = 120;
    const first = h.controller.updateBpm(60);
    await h.advance(200);
    const second = h.controller.updateBpm(90);
    await h.advance(200);
    const third = h.controller.updateBpm(95);
    assert.equal(h.controller.bpm, 95, 'the value is stored at once for display');
    await h.advance(350);
    const prepares = h.sent.filter(message => message.type === 'TRANSPORT_PREPARE');
    assert.equal(prepares.length, 1, 'rapid changes share one preparation round');
    assert.equal(h.sent.filter(message => message.type === 'SESSION_SNAPSHOT').length, 1,
      'rapid changes re-render once');
    h.controller.onLeaderMessage(peer, { type: 'TRANSPORT_READY', payload: { id: prepares.at(-1).payload.id } });
    await Promise.all([first, second, third]);
    const transports = h.sent.filter(message => message.type === 'TRANSPORT');
    assert.equal(transports.length, 1, 'only the newest configuration restarts');
    const snapshots = h.sent.filter(message => message.type === 'SESSION_SNAPSHOT');
    assert.equal(snapshots[0].payload.bpm, 95);
  }
  {
    // A pause requested while a change is coalescing is never overridden by a restart.
    const h = harness(true);
    h.addPeer('peer-one');
    h.controller.state = 'playing';
    const change = h.controller.updateBpm(70);
    await h.advance(100);
    const pause = h.controller.pauseTransport();
    await h.advance(900);
    await pause;
    await h.advance(350);
    await change;
    assert.equal(h.sent.some(message => message.type === 'TRANSPORT'), false, 'no restart after a pause');
    assert.ok(h.sent.some(message => message.type === 'SESSION_SNAPSHOT' && message.payload.bpm === 70),
      'the new value is still published');
  }
  console.log('PASS transport restart: configuration precedes preparation, rapid changes coalesce into one re-render and restart, pause is never overridden');
}

main().catch(error => { console.error(error); process.exitCode = 1; });
