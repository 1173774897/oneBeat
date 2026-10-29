// The member skips rooms whose scan response carries another code before any
// GATT connection. A report without a readable tag must stay a GATT candidate.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const ts = require(process.argv[2]);

const source = fs.readFileSync('entry/src/main/ets/network/p2p/BleAdvertisingTag.ets', 'utf8');
const compiled = ts.transpileModule(source, { compilerOptions: {
  module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 } });
const context = { exports: {}, Uint8Array, parseInt };
vm.runInNewContext(compiled.outputText, context);
const { serviceDataFromAdvertising, sameTag, uuidToLittleEndianBytes } = context.exports;

const ROOM = '4f6e6542-6561-7452-6f6f-6d0000000001';
const tagFor = (code, version = 3) => Uint8Array.from([version, ...[...code].map(c => c.charCodeAt(0))]);
function ad(type, payload) { return [payload.length + 1, type, ...payload]; }
function advertising(serviceUuid, tag) {
  const uuid = [...uuidToLittleEndianBytes(serviceUuid)];
  return Uint8Array.from([
    ...ad(0x01, [0x06]),                 // flags
    ...ad(0x07, uuid),                   // complete 128-bit service UUIDs
    ...ad(0x21, [...uuid, ...tag])       // scan response: service data
  ]).buffer;
}

const found = serviceDataFromAdvertising(advertising(ROOM, tagFor('482913')), ROOM);
assert.ok(found && sameTag(found, tagFor('482913')), 'The room tag is read from 128-bit service data');
assert.equal(sameTag(found, tagFor('482914')), false, 'A different code is a different tag');
assert.equal(sameTag(found, tagFor('482913', 2)), false, 'A different protocol version is a different tag');
assert.equal(serviceDataFromAdvertising(advertising('4f6e6542-6561-7452-6f6f-6d0000000002', tagFor('482913')), ROOM),
  undefined, 'Service data of another UUID is not a room tag');
const withoutScanResponse = Uint8Array.from([...ad(0x01, [0x06]), ...ad(0x07, [...uuidToLittleEndianBytes(ROOM)])]).buffer;
assert.equal(serviceDataFromAdvertising(withoutScanResponse, ROOM), undefined,
  'A report without the scan response has no tag and stays a GATT candidate');
assert.equal(serviceDataFromAdvertising(Uint8Array.from([0x1f, 0x21, 0x01]).buffer, ROOM), undefined,
  'A truncated structure is ignored rather than misread');
const padded = new Uint8Array(62);
padded.set(new Uint8Array(advertising(ROOM, tagFor('000001'))));
assert.ok(sameTag(serviceDataFromAdvertising(padded.buffer, ROOM), tagFor('000001')),
  'Zero padding after the structures (fixed-size report buffers) is tolerated');
console.log('PASS BLE advertising tag: room code read from scan-response service data, other codes/UUIDs rejected, missing or truncated data left for GATT');
