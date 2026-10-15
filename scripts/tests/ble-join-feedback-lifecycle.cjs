// Run with DevEco's bundled Node; pass its typescript/lib/typescript.js path.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const ts = require(process.argv[2]);
const encoder = new TextEncoder();
const decoder = new TextDecoder();
const SERVICE = '4f6e6542-6561-7452-6f6f-6d0000000001';
const FEEDBACK = '4f6e6542-6561-744a-6f69-6e0000000001';
const invitation = { code: '123456', roomId: 'room', protocolVersion: 4, expiresAt: 60000 };
const target = { serviceUuid: SERVICE, characteristicUuid: FEEDBACK,
  characteristicValue: new ArrayBuffer(0), descriptors: [] };
const services = [{ serviceUuid: SERVICE, characteristics: [target] }];
const compiled = ts.transpileModule(fs.readFileSync(
  'entry/src/main/ets/network/p2p/BleRoomDiscovery.ets', 'utf8'), {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 },
  reportDiagnostics: true
});
assert.equal((compiled.diagnostics ?? []).filter(d => d.category === ts.DiagnosticCategory.Error).length, 0);

function deferred() {
  let resolve;
  let reject;
  const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}

async function flush() {
  for (let i = 0; i < 24; i++) await Promise.resolve();
}

function harness(specs = [{}]) {
  let now = 1000;
  let timerId = 0;
  let nonce = 0;
  const timers = new Map();
  const clients = [];
  const serverHandlers = new Map();
  const logs = [];
  const server = {
    on: (event, callback) => serverHandlers.set(event, callback),
    addService() {}, sendResponse() {}, close() {}
  };
  function makeClient(spec = {}) {
    const handlers = new Map();
    const client = {
      writes: [], reads: 0, serviceQueries: 0, connects: 0, disconnects: 0, closes: 0,
      on: (event, callback) => handlers.set(event, callback),
      off: (event, callback) => { if (handlers.get(event) === callback) handlers.delete(event); },
      emit: state => handlers.get('BLEConnectionStateChange')?.({ deviceId: 'device', state }),
      connect() {
        this.connects++;
        if (spec.connect === 'fail') this.emit(0);
        else if (spec.connect !== 'hold') this.emit(2);
      },
      setBLEMtuSize() {},
      getServices() {
        this.serviceQueries++;
        return spec.services?.promise ?? Promise.resolve(services);
      },
      writeCharacteristicValue(characteristic) {
        const command = decoder.decode(characteristic.characteristicValue);
        this.writes.push(command);
        spec.onWrite?.(command);
        return (command.startsWith('C:') ? spec.cancelWrite?.promise : spec.registerWrite?.promise)
          ?? Promise.resolve();
      },
      readCharacteristicValue() {
        this.reads++;
        return spec.read?.promise ?? Promise.resolve({
          characteristicValue: encoder.encode(spec.readValue?.(this) ?? 'N').buffer
        });
      },
      disconnect() { this.disconnects++; },
      close() { this.closes++; }
    };
    clients.push(client);
    return client;
  }
  const mocks = {
    '@kit.ConnectivityKit': {
      access: { getState: () => 2, BluetoothState: { STATE_ON: 2 } },
      constant: { ProfileConnectionState: { STATE_CONNECTED: 2, STATE_DISCONNECTED: 0 } },
      ble: { GattWriteType: { WRITE: 1 }, createGattClientDevice: () => makeClient(specs.shift()),
        createGattServer: () => server, startAdvertising: async () => 1, stopAdvertising: async () => {} }
    },
    '@kit.ArkTS': { util: {
      TextEncoder: class { encodeInto(value) { return encoder.encode(value); } },
      TextDecoder: { create: () => ({ decodeToString: bytes => decoder.decode(bytes) }) }
    } },
    '@kit.BasicServicesKit': { commonEventManager: {
      createSubscriber: async () => ({}), subscribe() {}, unsubscribe: async () => {}
    } },
    './P2pInvitation': { parseP2pRoomInvitation: JSON.parse, validateP2pRoomInvitation() {},
      randomAuthNonce: () => (++nonce).toString(16).padStart(32, '0').slice(-16).repeat(2) }
  };
  const context = {
    exports: {}, require: name => {
      assert.ok(Object.hasOwn(mocks, name), `Unexpected dependency ${name}`);
      return mocks[name];
    },
    console: { info: line => logs.push(line), warn: line => logs.push(line) },
    canIUse: () => true, Date: class extends Date { static now() { return now; } },
    setTimeout(callback, delay) {
      const id = ++timerId;
      timers.set(id, { callback, at: now + delay });
      return id;
    },
    clearTimeout: id => timers.delete(id)
  };
  vm.runInNewContext(compiled.outputText, context);
  const discovery = new context.exports.BleRoomDiscovery();
  discovery.lastResolvedDeviceId = 'device';
  discovery.lastResolvedRoomId = 'room';
  const attempt = new context.exports.BleMemberJoinFeedbackAttempt();
  return { discovery, attempt, clients, timers, logs, context,
    start: () => discovery.startMemberJoinFeedback(invitation, attempt),
    async advance(ms) {
      const end = now + ms;
      while (true) {
        const next = [...timers.entries()].filter(([, timer]) => timer.at <= end)
          .sort((a, b) => a[1].at - b[1].at || a[0] - b[0])[0];
        if (!next) break;
        now = next[1].at;
        timers.delete(next[0]);
        next[1].callback();
        await flush();
      }
      now = end;
      await flush();
    },
    deliverLeaderWrite(command) {
      serverHandlers.get('characteristicWrite')({ deviceId: 'device', serviceUuid: SERVICE,
        characteristicUuid: FEEDBACK, value: encoder.encode(command).buffer,
        needRsp: false, offset: 0 });
    }
  };
}

async function main() {
  const beforeStart = harness();
  beforeStart.attempt.cancel();
  assert.equal(await beforeStart.start(), undefined);
  assert.equal(beforeStart.clients.length, 0, 'A completed attempt never opens another GATT client');

  const connecting = harness([{ connect: 'hold' }]);
  const connectWork = connecting.start();
  connecting.attempt.cancel();
  assert.equal(connecting.clients[0].closes, 1, 'Cancellation releases an unresolved connection synchronously');
  connecting.clients[0].emit(2);
  assert.equal(await connectWork, undefined);
  await connecting.advance(10000);
  assert.equal(connecting.clients.length, 1);
  assert.equal(connecting.clients[0].serviceQueries, 0);
  assert.equal(connecting.timers.size, 0, 'Connection cancellation also removes its system listener/deadline');

  const serviceRead = deferred();
  const querying = harness([{ services: serviceRead }]);
  const queryWork = querying.start();
  await flush();
  assert.equal(querying.clients[0].serviceQueries, 1);
  querying.attempt.cancel();
  assert.equal(querying.clients[0].closes, 1);
  serviceRead.resolve(services);
  assert.equal(await queryWork, undefined);
  assert.deepEqual(querying.clients[0].writes, [], 'Late service completion must not register an old P: attempt');
  assert.equal(querying.timers.size, 0);

  const registration = deferred();
  const registering = harness([{ registerWrite: registration }]);
  const registrationWork = registering.start();
  await flush();
  assert.equal(registering.clients[0].writes.length, 1);
  registering.attempt.cancel();
  assert.equal(registering.clients[0].closes, 1);
  registration.resolve();
  assert.equal(await registrationWork, undefined);
  await registering.advance(10000);
  assert.equal(registering.clients.length, 1, 'A late registration cannot start another retry or channel');
  assert.equal(registering.clients[0].reads, 0);

  const retrying = harness([{ connect: 'fail' }, {}]);
  const retryWork = retrying.start();
  await flush();
  assert.equal(retrying.clients[0].closes, 1);
  retrying.attempt.cancel();
  assert.equal(await retryWork, undefined);
  await retrying.advance(10000);
  assert.equal(retrying.clients.length, 1, 'Cancelling during retry backoff prevents a second connect');
  assert.equal(retrying.timers.size, 0);

  for (const operation of ['services', 'registerWrite']) {
    const hanging = deferred();
    const timed = harness([{ [operation]: hanging }, {}]);
    const work = timed.start();
    await flush();
    await timed.advance(2999);
    assert.equal(timed.clients[0].closes, 0);
    await timed.advance(1);
    assert.equal(timed.clients[0].closes, 1, `${operation} has a bounded deadline`);
    await timed.advance(250);
    const channel = await work;
    assert.ok(channel, 'A live attempt can retry after an optional feedback timeout');
    assert.equal(timed.clients.length, 2);
    hanging.reject(new Error('late system rejection'));
    await flush();
    timed.attempt.cancel();
    await flush();
    assert.equal(timed.clients[1].closes, 1);
    assert.equal(timed.timers.size, 0);
  }

  const cancelWrite = deferred();
  const closeHanging = harness([{ cancelWrite }]);
  const channel = await closeHanging.start();
  const closing = channel.close();
  assert.equal(closeHanging.clients[0].closes, 0);
  await closeHanging.advance(249);
  assert.equal(closeHanging.clients[0].closes, 0);
  await closeHanging.advance(1);
  await closing;
  assert.equal(closeHanging.clients[0].closes, 1, 'A hanging C: write cannot retain the GATT handle beyond 250ms');
  await channel.close();
  assert.equal(closeHanging.clients[0].closes, 1, 'Closing/cancelling the same channel remains idempotent');
  cancelWrite.reject(new Error('late cancel write rejection'));
  await flush();

  const lateRead = deferred();
  const polling = harness([{ read: lateRead }]);
  const pollingChannel = await polling.start();
  let rejected = false;
  pollingChannel.rejection.then(() => { rejected = true; });
  await polling.advance(0);
  polling.attempt.cancel();
  lateRead.resolve({ characteristicValue: encoder.encode(
    polling.clients[0].writes[0].replace('P:', 'R:')).buffer });
  await flush();
  assert.equal(rejected, false, 'Late polling data cannot reject a join after feedback was cancelled');
  await polling.advance(10000);
  assert.equal(polling.clients[0].reads, 1, 'Cancellation never reschedules the 250ms poll');
  assert.equal(polling.clients[0].closes, 1);

  const rejection = harness([{ readValue: client => client.reads === 1 ? 'N' :
    client.writes[0].replace('P:', 'R:') }]);
  const rejectionChannel = await rejection.start();
  await rejection.advance(0);
  assert.equal(rejection.clients[0].reads, 1);
  await rejection.advance(249);
  assert.equal(rejection.clients[0].reads, 1);
  await rejection.advance(1);
  assert.match((await rejectionChannel.rejection).message, /队长已拒绝/);
  rejection.attempt.cancel();
  await flush();
  assert.equal(rejection.clients[0].closes, 1);

  const oldServices = deferred();
  const replacement = harness([{ services: oldServices }, {}]);
  await replacement.discovery.startLeaderAdvertising(invitation);
  const oldWork = replacement.start();
  await flush();
  replacement.attempt.cancel();
  const nextAttempt = new replacement.context.exports.BleMemberJoinFeedbackAttempt();
  const nextChannel = await replacement.discovery.startMemberJoinFeedback(invitation, nextAttempt);
  const nextCommand = replacement.clients[1].writes[0];
  replacement.deliverLeaderWrite(nextCommand);
  oldServices.resolve(services);
  assert.equal(await oldWork, undefined);
  assert.deepEqual(replacement.clients[0].writes, [], 'An old cancelled query cannot overwrite a new P: registration');
  replacement.deliverLeaderWrite('C:0000000000000000');
  assert.equal(replacement.discovery.leaderJoinAttempts.get('device').attemptId,
    nextCommand.slice(2), 'Leader cleanup remains scoped to the exact attemptId');
  await nextChannel.close();
  replacement.deliverLeaderWrite(nextCommand.replace('P:', 'C:'));
  assert.equal(replacement.discovery.leaderJoinAttempts.has('device'), false);

  console.log('PASS: actual BLE feedback lifecycle cancels connect, service, registration and retry work; closes bounded GATT handles; retains rejection polling and exact-attempt cleanup');
}

main().catch(error => { console.error(error); process.exitCode = 1; });
