// Actual SessionController methods with deterministic network and clock boundaries.
const assert = require('node:assert/strict');
const { harness, deferred } = require('./transport-start-diagnostics.cjs');

const transportMessages = h => h.sent.filter(message =>
  message.type === 'TRANSPORT' || message.type === 'TRANSPORT_RESUME');
const ack = (h, peer, id, clockReady = true) => h.controller.onLeaderMessage(peer, {
  type: 'TRANSPORT_READY', payload: { id, clockReady }
});

async function main() {
  {
    const leader = harness(true);
    const member = harness();
    const peer = leader.addPeer('member');
    let prepare;
    peer.send = async message => { leader.sent.push(message); prepare = message; };
    member.controller.sendToLeader = async message => {
      member.sent.push(message);
      leader.controller.onLeaderMessage(peer, message);
    };
    const start = leader.controller.startTransport();
    assert.equal(prepare.payload.requireClockReady, true);
    // Reproduce the attachment's delayed first PREPARE delivery and 935 ms sampling.
    await leader.advance(1300);
    await member.advance(1300);
    member.controller.onMemberMessage(prepare);
    assert.equal(transportMessages(leader).length, 0, '900 ms must no longer release an unready start');
    await leader.advance(935);
    await member.advance(935);
    assert.equal(transportMessages(leader).length, 0, 'no shared deadline before clock readiness');
    member.measurement.resolve({ offsetMs: 7, rttMs: 17 });
    const startAt = await start;
    assert.equal(startAt, leader.now() + 650, 'the full shared lead begins after READY');
    assert.equal(transportMessages(leader).length, 1);
    assert.equal(transportMessages(leader)[0].payload.startAtLeaderMonoMs, startAt);
    assert.equal(member.sent[0].payload.clockReady, true);
  }

  for (const method of ['startTransport', 'resumeTransport']) {
    for (const clockReady of [false, undefined]) {
      const h = harness(true);
      const peer = h.addPeer('member');
      h.controller.state = 'paused';
      h.controller.beatIndex = 7;
      h.storage.set('lastTransportMessage', 'previous');
      const failed = assert.rejects(h.controller[method](), /队员时钟准备未完成/);
      const id = h.sent[0].payload.id;
      // A legacy ACK cannot prove success for a new strict request.
      h.controller.onLeaderMessage(peer, { type: 'TRANSPORT_READY', payload: { id, clockReady } });
      await failed;
      assert.equal(transportMessages(h).length, 0);
      assert.equal(h.controller.state, 'paused');
      assert.equal(h.controller.beatIndex, 7);
      assert.equal(h.storage.get('lastTransportMessage'), 'previous');
    }
  }

  {
    const h = harness(true);
    const peer = h.addPeer('member');
    const nativeSend = deferred();
    peer.send = message => { h.sent.push(message); return nativeSend.promise; };
    h.controller.state = 'paused';
    h.controller.beatIndex = 9;
    const failed = assert.rejects(h.controller.startTransport(), /队员时钟准备未完成/);
    const id = h.sent[0].payload.id;
    await h.advance(3999);
    assert.ok(h.controller.transportPrepareWaiter);
    await h.advance(1);
    await failed;
    assert.equal(transportMessages(h).length, 0, 'an unresolved native send cannot bypass the total budget');
    assert.equal(h.controller.state, 'paused');
    assert.equal(h.controller.beatIndex, 9);
    ack(h, peer, id);
    nativeSend.reject(new Error('late native send failure'));
    await h.advance(0);
    assert.equal(transportMessages(h).length, 0, 'late ACK or send failure cannot revive the failed start');
  }

  {
    const h = harness(true);
    const peer = h.addPeer('member');
    peer.send = async () => { throw new Error('native send failure'); };
    await assert.rejects(h.controller.resumeTransport(), /队员时钟准备未完成/);
    assert.equal(transportMessages(h).length, 0);
  }

  for (const exit of ['returnToLobby', 'disconnect']) {
    for (const afterReady of [false, true]) {
      const h = harness(true);
      const peer = h.addPeer('member');
      h.controller.lobbyDeparted = true;
      h.controller.broadcastSessionDisbanded = async () => {};
      const start = h.controller.startTransport();
      const id = h.sent[0].payload.id;
      if (afterReady) ack(h, peer, id);
      // Also cover READY resolving immediately before an exit in the same task.
      await h.controller[exit]();
      assert.equal(await start, 0);
      ack(h, peer, id);
      await h.advance(4000);
      assert.equal(transportMessages(h).length, 0, `${exit} must cancel the old start`);
    }
  }

  for (const method of ['startTransport', 'resumeTransport']) {
    const h = harness(true);
    const peer = h.addPeer('member');
    const nativeTransportSend = deferred();
    h.controller.lobbyDeparted = true;
    h.controller.sendToAll = message => {
      h.sent.push(message);
      return message.type === 'TRANSPORT' || message.type === 'TRANSPORT_RESUME'
        ? nativeTransportSend.promise : Promise.resolve();
    };
    const start = h.controller[method]();
    ack(h, peer, h.sent[0].payload.id);
    await h.advance(0);
    assert.equal(transportMessages(h).length, 1, 'the native transport send is now pending');
    await h.controller.returnToLobby();
    nativeTransportSend.resolve();
    assert.equal(await start, 0);
    assert.equal(h.storage.get('lastTransportMessage'), '', 'a late native send must not revive exited playback locally');
    assert.equal(h.controller.state, 'idle');
  }

  {
    const h = harness(true);
    const peer = h.addPeer('member');
    const firstSend = deferred();
    let sends = 0;
    peer.send = message => {
      h.sent.push(message);
      return sends++ === 0 ? firstSend.promise : Promise.resolve();
    };
    const first = h.controller.startTransport();
    const firstId = h.sent[0].payload.id;
    const second = h.controller.resumeTransport();
    const secondId = h.sent[1].payload.id;
    assert.equal(await first, 0, 'a newer transport command owns publication');
    firstSend.reject(new Error('old native send failed'));
    ack(h, peer, firstId);
    await h.advance(0);
    assert.equal(h.controller.transportPrepareWaiter.id, secondId, 'old work must not finish the new waiter');
    assert.equal(transportMessages(h).length, 0);
    ack(h, peer, secondId);
    assert.equal(await second, h.now() + 650);
    assert.equal(transportMessages(h).length, 1);
    assert.equal(transportMessages(h)[0].type, 'TRANSPORT_RESUME');
  }

  {
    const h = harness(true);
    const peer = h.addPeer('member');
    h.addPeer('member-two');
    const start = h.controller.startTransport();
    h.controller.releaseTransportPreparationConnection(peer.id);
    assert.equal(await start, 0, 'a peer leaving during strict preparation cancels this attempt');
    assert.equal(transportMessages(h).length, 0);
  }

  {
    const h = harness(true);
    const first = h.addPeer('member-one');
    const second = h.addPeer('member-two');
    const start = h.controller.startTransport();
    const id = h.sent[0].payload.id;
    ack(h, first, id);
    await h.advance(25);
    assert.equal(transportMessages(h).length, 0, 'every connected member must explicitly report readiness');
    ack(h, first, id);
    await h.advance(25);
    assert.equal(transportMessages(h).length, 0, 'a duplicate ACK cannot stand in for a second member');
    ack(h, second, id);
    assert.equal(await start, h.now() + 650);
    assert.equal(transportMessages(h).length, 1);
  }

  {
    const h = harness(true);
    h.addPeer('member');
    const pause = h.controller.pauseTransport();
    assert.equal(h.sent[0].payload.requireClockReady, undefined);
    await h.advance(900);
    await pause;
    const wire = h.sent.find(message => message.type === 'TRANSPORT_PAUSE');
    assert.equal(wire.payload.pauseAtLeaderMonoMs, h.now() + 650, 'pause retains its bounded fallback');
  }

  for (const method of ['startTransport', 'resumeTransport']) {
    for (const soloTeam of [true, false]) {
      const h = harness(true);
      h.controller.soloTeam = soloTeam;
      const result = await h.controller[method]();
      assert.equal(result, h.now() + 650);
      assert.equal(h.sent.some(message => message.type === 'TRANSPORT_PREPARE'), false);
    }
  }
  console.log('PASS strict transport readiness: delayed first delivery, failure, bounded native send, cancellation, ownership, pause and solo');
}

main().catch(error => { console.error(error); process.exitCode = 1; });
