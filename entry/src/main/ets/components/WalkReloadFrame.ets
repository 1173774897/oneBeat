import { FrameCallback } from '@kit.ArkUI';

/** Submit native loading animation before synchronous PCM work can occupy JS. */
export class WalkReloadFrame extends FrameCallback {
  private readonly ready: () => void;

  constructor(ready: () => void) {
    super();
    this.ready = ready;
  }

  onIdle(_timeLeftInNano: number): void {
    this.ready();
  }
}
