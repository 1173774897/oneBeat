/**
 * Reads the OneBeat room tag (protocol version + 6-digit code) that a leader
 * puts in its scan response as 128-bit-UUID service data. Lets a member skip
 * rooms with another code before spending a GATT connection on them; a result
 * without a readable tag returns undefined and must still be checked over GATT,
 * because some stacks do not merge the scan response into every report.
 */

const AD_TYPE_SERVICE_DATA_128: number = 0x21;

/** 128-bit UUID in the little-endian byte order used inside advertising data. */
export function uuidToLittleEndianBytes(uuid: string): Uint8Array {
  const hex = uuid.replace(/-/g, '');
  const bytes = new Uint8Array(16);
  for (let i = 0; i < 16; i++) {
    bytes[15 - i] = parseInt(hex.substring(i * 2, i * 2 + 2), 16);
  }
  return bytes;
}

/** Service data for `uuid` from raw advertising + scan response bytes, if present. */
export function serviceDataFromAdvertising(data: ArrayBuffer, uuid: string): Uint8Array | undefined {
  const bytes = new Uint8Array(data);
  const uuidBytes = uuidToLittleEndianBytes(uuid);
  let offset = 0;
  while (offset < bytes.length) {
    const length = bytes[offset];
    if (length === 0 || offset + 1 + length > bytes.length) {
      return undefined;
    }
    const type = bytes[offset + 1];
    if (type === AD_TYPE_SERVICE_DATA_128 && length - 1 >= 16) {
      let same = true;
      for (let i = 0; i < 16; i++) {
        if (bytes[offset + 2 + i] !== uuidBytes[i]) {
          same = false;
          break;
        }
      }
      if (same) {
        return bytes.slice(offset + 2 + 16, offset + 1 + length);
      }
    }
    offset += 1 + length;
  }
  return undefined;
}

export function sameTag(left: Uint8Array, right: Uint8Array): boolean {
  if (left.length !== right.length) {
    return false;
  }
  for (let i = 0; i < left.length; i++) {
    if (left[i] !== right[i]) {
      return false;
    }
  }
  return true;
}
