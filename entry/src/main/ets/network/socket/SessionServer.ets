import { socket } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { SESSION_TCP_PORT } from '../../common/Constants';
import { WireMessage } from '../../protocol/messages';
import { SessionConnection } from './SessionConnection';

export type ClientConnectedHandler = (connection: SessionConnection) => void;
export type ClientClosedHandler = (connectionId: string) => void;
export type ClientMessageHandler = (connection: SessionConnection, message: WireMessage) => void;

export class SessionServer {
  private server: socket.TCPSocketServer | undefined = undefined;
  private readonly connections: Map<string, SessionConnection> = new Map();
  private nextId: number = 1;
  private onClientMessage: ClientMessageHandler = () => {
  };
  private onClientConnected: ClientConnectedHandler = () => {
  };
  private onClientClosed: ClientClosedHandler = () => {
  };

  setHandlers(
    onMessage: ClientMessageHandler,
    onConnected: ClientConnectedHandler,
    onClosed: ClientClosedHandler
  ): void {
    this.onClientMessage = onMessage;
    this.onClientConnected = onConnected;
    this.onClientClosed = onClosed;
  }

  async start(port: number = SESSION_TCP_PORT): Promise<number> {
    if (this.server !== undefined) {
      return port;
    }
    this.server = socket.constructTCPSocketServerInstance();
    this.server.on('connect', (client: socket.TCPSocketConnection) => {
      const id = `c-${this.nextId++}`;
      const connection = new SessionConnection(id, (message) => {
        this.onClientMessage(connection, message);
      }, () => {
        this.removeConnection(id);
      });
      connection.bind(client);
      this.connections.set(id, connection);
      this.onClientConnected(connection);
    });
    const address: socket.NetAddress = {
      address: '0.0.0.0',
      port: port,
      family: 1
    };
    await this.server.listen(address);
    return port;
  }

  async broadcast(messageHandler: (conn: SessionConnection) => Promise<void>): Promise<void> {
    const list = Array.from(this.connections.values());
    for (let i = 0; i < list.length; i++) {
      await messageHandler(list[i]);
    }
  }

  async sendToAll(message: WireMessage): Promise<void> {
    const list = Array.from(this.connections.values());
    for (let i = 0; i < list.length; i++) {
      await list[i].send(message);
    }
  }

  getConnections(): SessionConnection[] {
    return Array.from(this.connections.values());
  }

  removeConnection(id: string): void {
    if (!this.connections.has(id)) {
      return;
    }
    this.connections.delete(id);
    this.onClientClosed(id);
  }

  async stop(): Promise<void> {
    const list = Array.from(this.connections.values());
    for (let i = 0; i < list.length; i++) {
      await list[i].close();
    }
    this.connections.clear();
    if (this.server !== undefined) {
      try {
        await this.server.close();
      } catch (err) {
        const e = err as BusinessError;
        console.warn(`SessionServer stop: ${e.message}`);
      }
      this.server = undefined;
    }
  }
}
