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
    await h.advance(0);
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
    // A newer change supersedes an older one before it publishes TRANSPORT.
    const h = harness(true);
    const peer = h.addPeer('peer-one');
    h.controller.state = 'playing';
    h.controller.bpm = 120;
    const first = h.controller.updateBpm(60);
    await h.advance(0);
    const second = h.controller.updateBpm(90);
    await h.advance(0);
    const prepares = h.sent.filter(message => message.type === 'TRANSPORT_PREPARE');
    h.controller.onLeaderMessage(peer, { type: 'TRANSPORT_READY', payload: { id: prepares.at(-1).payload.id } });
    await Promise.all([first, second]);
    const transports = h.sent.filter(message => message.type === 'TRANSPORT');
    assert.equal(transports.length, 1, 'only the newest configuration restarts');
    const snapshots = h.sent.filter(message => message.type === 'SESSION_SNAPSHOT');
    assert.equal(snapshots.at(-1).payload.bpm, 90);
  }
  console.log('PASS transport restart: configuration precedes preparation, newest change wins');
}

main().catch(error => { console.error(error); process.exitCode = 1; });
