import { socket } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { LineCodec } from '../../protocol/codec';
import { WireMessage } from '../../protocol/messages';

export type ClientMessageHandler = (message: WireMessage) => void;

export class SessionClient {
  private tcp: socket.TCPSocket | undefined = undefined;
  private readonly codec: LineCodec = new LineCodec();
  private handler: ClientMessageHandler = () => {
  };
  private connected: boolean = false;

  setHandler(handler: ClientMessageHandler): void {
    this.handler = handler;
  }

  isConnected(): boolean {
    return this.connected;
  }

  async connect(host: string, port: number, timeoutMs: number = 3000): Promise<void> {
    await this.disconnect();
    const tcp = socket.constructTCPSocketInstance();
    this.tcp = tcp;
    tcp.on('message', (info: socket.SocketMessageInfo) => {
      const messages = this.codec.feed(info.message);
      for (let i = 0; i < messages.length; i++) {
        this.handler(messages[i]);
      }
    });
    tcp.on('close', () => {
      this.connected = false;
    });
    const address: socket.NetAddress = {
      address: host,
      port: port,
      family: 1
    };
    await new Promise<void>((resolve, reject) => {
      let settled = false;
      const timer = setTimeout(() => {
        if (settled) {
          return;
        }
        settled = true;
        void tcp.close();
        reject(new Error(`连接队长超时（${host}:${port}）`));
      }, timeoutMs);
      void (async () => {
        try {
          await tcp.connect({ address: address });
          if (settled) {
            return;
          }
          settled = true;
          clearTimeout(timer);
          resolve();
        } catch (err) {
          if (settled) {
            return;
          }
          settled = true;
          clearTimeout(timer);
          reject(err as Error);
        }
      })();
    });
    this.connected = true;
  }

  async send(message: WireMessage): Promise<void> {
    if (this.tcp === undefined || !this.connected) {
      return;
    }
    await this.tcp.send({ data: LineCodec.encode(message) });
  }

  async disconnect(): Promise<void> {
    this.connected = false;
    if (this.tcp === undefined) {
      return;
    }
    try {
      await this.tcp.close();
    } catch (err) {
      const e = err as BusinessError;
      console.warn(`SessionClient disconnect: ${e.message}`);
    }
    this.tcp = undefined;
  }
}
