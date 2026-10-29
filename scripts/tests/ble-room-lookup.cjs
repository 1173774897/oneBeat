// Join-code lookup reads GATT only from leaders whose scan response carries the
// typed code (or no readable tag). A stronger room with another code must not
// consume a GATT connection, which can cost seconds each and exhaust the lookup.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const ts = require(process.argv[2]);
const encoder = new TextEncoder();
const decoder = new TextDecoder();
const SERVICE = '4f6e6542-6561-7452-6f6f-6d0000000001';
const INVITE = '4f6e6542-6561-7449-6e76-697465000001';
const FEEDBACK = '4f6e6542-6561-744a-6f69-6e0000000001';

const load = (file, mocks, extra = {}) => {
  const context = { exports: {}, Uint8Array, parseInt, ...extra,
    require: name => { assert.ok(Object.hasOwn(mocks, name), `Unexpected dependency ${name}`); return mocks[name]; } };
  vm.runInNewContext(ts.transpileModule(fs.readFileSync(file, 'utf8'), { compilerOptions: {
    module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 } }).outputText, context);
  return context.exports;
};
const tag = load('entry/src/main/ets/network/p2p/BleAdvertisingTag.ets', {});

function scanResult(deviceId, rssi, code) {
  const uuid = [...tag.uuidToLittleEndianBytes(SERVICE)];
  const payload = code === undefined ? [] :
    [1 + 16 + 7, 0x21, ...uuid, 6, ...[...code].map(c => c.charCodeAt(0))];
  return { deviceId, rssi, data: Uint8Array.from([17, 0x07, ...uuid, ...payload]).buffer };
}

async function lookup(results, code, { prefetch = false, lookupResults = results } = {}) {
  const reads = [];
  const logs = [];
  const scanningAtConnect = [];
  const order = [];
  const writes = [];
  const closes = [];
  let scanning = false;
  let onFind;
  const invitations = { far: '123456', near: '654321', notag: '123456' };
  const mocks = {
    './BleAdvertisingTag': tag,
    '@kit.ConnectivityKit': {
      access: { getState: () => 2, BluetoothState: { STATE_ON: 2 } },
      constant: { ProfileConnectionState: { STATE_CONNECTED: 2, STATE_DISCONNECTED: 0 } },
      ble: {
        ScanDuty: { SCAN_MODE_LOW_LATENCY: 2 }, MatchMode: { MATCH_MODE_AGGRESSIVE: 1 },
        GattWriteType: { WRITE: 1 },
        on: (event, callback) => { onFind = callback; }, off() {},
        startBLEScan() { scanning = true; }, stopBLEScan() { scanning = false; },
        createGattClientDevice: deviceId => {
          const handlers = new Map();
          return {
            on: (event, cb) => handlers.set(event, cb), off() {},
            setBLEMtuSize() { order.push(`mtu:${deviceId}`); handlers.get('BLEMtuChange')?.(128); },
            connect() { reads.push(deviceId); scanningAtConnect.push(scanning); handlers.get('BLEConnectionStateChange')?.({ deviceId, state: 2 }); },
            getServices: async () => { order.push(`services:${deviceId}`); return [{ serviceUuid: SERVICE, characteristics: [
              { serviceUuid: SERVICE, characteristicUuid: INVITE, descriptors: [] },
              { serviceUuid: SERVICE, characteristicUuid: FEEDBACK, descriptors: [] }] }]; },
            writeCharacteristicValue: async characteristic => {
              writes.push(`${deviceId}:${decoder.decode(characteristic.characteristicValue)}`);
            },
            readCharacteristicValue: async () => ({ characteristicValue: encoder.encode(JSON.stringify({
              code: invitations[deviceId], roomId: deviceId, protocolVersion: 6 })).buffer }),
            disconnect() {}, close() { closes.push(deviceId); }
          };
        }
      }
    },
    '@kit.ArkTS': { util: {
      TextEncoder: class { encodeInto(value) { return encoder.encode(value); } },
      TextDecoder: { create: () => ({ decodeToString: bytes => decoder.decode(bytes) }) }
    } },
    '@kit.BasicServicesKit': { commonEventManager: {} },
    './P2pInvitation': { parseP2pRoomInvitation: JSON.parse, validateP2pRoomInvitation() {},
      randomAuthNonce: () => '0'.repeat(32) }
  };
  const { BleRoomDiscovery, BleMemberJoinFeedbackAttempt } = load('entry/src/main/ets/network/p2p/BleRoomDiscovery.ets', mocks, {
    console: { info: line => logs.push(line), warn: line => logs.push(line) },
    canIUse: () => true, Date, Set, Map, Array,
    setTimeout: () => 0, clearTimeout() {}
  });
  const discovery = new BleRoomDiscovery();
  let invitation;
  if (prefetch) {
    // The page opens: invitations are read while the member types the code.
    discovery.startInvitationPrefetch(6);
    onFind(results);
    for (let i = 0; i < 20; i++) await Promise.resolve();
    const pending = discovery.resolveInvitationByCode(code, 6);
    for (let i = 0; i < 20; i++) await Promise.resolve();
    if (lookupResults !== results) onFind(lookupResults);
    invitation = await pending;
  } else {
    const pending = discovery.resolveInvitationByCode(code, 6);
    // The lookup first checks prefetched invitations (async), then scans.
    for (let i = 0; i < 20; i++) await Promise.resolve();
    onFind(results);
    invitation = await pending;
  }
  const closedAfterLookup = [...closes];
  const channel = await discovery.startMemberJoinFeedback(invitation, new BleMemberJoinFeedbackAttempt());
  return { invitation, reads, logs, scanningAtConnect, scanningAfter: scanning, channel, writes, closedAfterLookup, order };
}

(async () => {
  {
    // The other room is closer (stronger RSSI) and would have been read first.
    const r = await lookup([scanResult('near', -40, '654321'), scanResult('far', -70, '123456')], '123456');
    assert.equal(r.invitation.roomId, 'far');
    assert.deepEqual(r.reads, ['far'], 'A room advertising another code is never read over GATT');
    assert.ok(r.logs.some(line => line.includes('stage=ble-candidate') && line.includes('tag=other')));
    assert.deepEqual(r.scanningAtConnect, [false], 'Scanning is paused while the GATT connection is set up');
    assert.equal(r.scanningAfter, false, 'A resolved lookup leaves scanning stopped');
    assert.ok(!r.closedAfterLookup.includes('far'), 'The matched leader link stays open for the join feedback');
    assert.ok(r.channel, 'The feedback channel opens on the retained link');
    assert.deepEqual(r.reads, ['far'], 'Opening feedback does not make a second GATT connection');
    assert.ok(r.writes.length === 1 && r.writes[0].startsWith('far:P:'),
      'The join attempt is registered before P2P, so a rejection has an attempt to report to');
    assert.ok(r.logs.some(line => line.includes('link=lookup')));
    assert.ok(r.order.indexOf('services:far') >= 0 && r.order.indexOf('services:far') < r.order.indexOf('mtu:far'),
      'The MTU is raised only after service discovery (a raced request left getServices empty on device)');
  }
  {
    // A report without the scan response stays a GATT candidate.
    const r = await lookup([scanResult('notag', -50, undefined)], '123456');
    assert.equal(r.invitation.roomId, 'notag');
    assert.deepEqual(r.reads, ['notag'], 'Without a readable tag the leader is still checked over GATT');
  }
  {
    // Prefetch: the code resolves from the invitation read while typing, the
    // attempt is registered on the kept link, and feedback opens without BLE work.
    const r = await lookup([scanResult('far', -50, undefined)], '123456', { prefetch: true });
    assert.equal(r.invitation.roomId, 'far');
    assert.deepEqual(r.reads, ['far'], 'Submitting the code makes no new GATT connection');
    assert.ok(r.logs.some(line => line.includes('stage=prefetch-hit preRegistered=true')));
    assert.equal(r.writes.length, 1, 'One registration, written before P2P; opening feedback adds none');
    assert.ok(r.writes[0].startsWith('far:P:'));
    assert.ok(r.channel && r.logs.some(line => line.includes('link=lookup')));
  }
  {
    // A prefetched room with another code is not used; the normal lookup runs.
    const r = await lookup([scanResult('near', -40, undefined)], '123456',
      { prefetch: true, lookupResults: [scanResult('far', -60, undefined)] });
    assert.ok(r.logs.some(line => line.includes('stage=prefetch-read result=ok')));
    assert.ok(!r.logs.some(line => line.includes('stage=prefetch-hit')),
      'An invitation with another code never resolves the lookup');
    assert.equal(r.invitation.roomId, 'far', 'After a prefetch miss the normal lookup finds the room');
  }
  console.log('PASS BLE room lookup: other-code rooms skipped before GATT, untagged reports still read, scan paused during GATT reads, join attempt registered on the lookup link before P2P, invitations prefetched while typing, candidates logged');
})().catch(error => { console.error(error); process.exitCode = 1; });
