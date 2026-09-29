import { socket } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { LineCodec } from '../../protocol/codec';
import { WireMessage } from '../../protocol/messages';
import { SessionPeerConnection } from '../transport/SessionPeerConnection';

export type MessageHandler = (message: WireMessage) => void;

export class SessionConnection implements SessionPeerConnection {
  readonly id: string;
  readonly isRoomAuthenticated: boolean = false;
  private readonly codec: LineCodec = new LineCodec();
  private readonly onMessage: MessageHandler;
  private readonly onClosed: () => void;
  private socketRef: socket.TCPSocketConnection | undefined = undefined;

  constructor(id: string, onMessage: MessageHandler, onClosed: () => void = () => {
  }) {
    this.id = id;
    this.onMessage = onMessage;
    this.onClosed = onClosed;
  }

  bind(connection: socket.TCPSocketConnection): void {
    this.socketRef = connection;
    connection.on('message', (info: socket.SocketMessageInfo) => {
      const messages = this.codec.feed(info.message);
      for (let i = 0; i < messages.length; i++) {
        this.onMessage(messages[i]);
      }
    });
    connection.on('close', () => {
      this.socketRef = undefined;
      this.onClosed();
    });
  }

  async send(message: WireMessage): Promise<void> {
    if (this.socketRef === undefined) {
      return;
    }
    const data = LineCodec.encode(message);
    await this.socketRef.send({ data: data });
  }

  async close(): Promise<void> {
    if (this.socketRef === undefined) {
      return;
    }
    try {
      await this.socketRef.close();
    } catch (err) {
      const e = err as BusinessError;
      console.warn(`SessionConnection close: ${e.message}`);
    }
    this.socketRef = undefined;
  }
}
