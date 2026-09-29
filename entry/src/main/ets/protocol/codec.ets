import { util } from '@kit.ArkTS';
import { WireMessage } from './messages';

const textEncoder = new util.TextEncoder();
const textDecoder = util.TextDecoder.create('utf-8');

export class LineCodec {
  private buffer: string = '';

  feed(chunk: ArrayBuffer): WireMessage[] {
    const part = textDecoder.decodeWithStream(new Uint8Array(chunk), { stream: true });
    this.buffer += part;
    const out: WireMessage[] = [];
    let idx = this.buffer.indexOf('\n');
    while (idx >= 0) {
      const line = this.buffer.substring(0, idx).trim();
      this.buffer = this.buffer.substring(idx + 1);
      if (line.length > 0) {
        try {
          out.push(JSON.parse(line) as WireMessage);
        } catch (_e) {
          // ignore malformed line
        }
      }
      idx = this.buffer.indexOf('\n');
    }
    return out;
  }

  static encode(message: WireMessage): ArrayBuffer {
    const line = `${JSON.stringify(message)}\n`;
    const bytes = textEncoder.encodeInto(line);
    return bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength);
  }
}
