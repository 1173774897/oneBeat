import { PcmRenderJob, PcmRenderResult } from './PcmRender';

export type PcmRenderRunner = (job: PcmRenderJob) => Promise<PcmRenderResult>;

/**
 * Where the engine sends PCM generation off the JS thread. The engine's
 * writeData callback runs on that thread, so a long synchronous render starves
 * it (device 2026-11-03: 114-310ms per live BPM change at 40 BPM, an underflow,
 * a broken frame map and skipped beats). Only EntryAbility registers the
 * TaskPool runner; without one (unit tests, early startup) rendering stays
 * synchronous and behaves exactly as before.
 */
export class PcmRenderOffload {
  private static runner: PcmRenderRunner | undefined = undefined;

  static register(runner: PcmRenderRunner | undefined): void {
    PcmRenderOffload.runner = runner;
  }

  static get(): PcmRenderRunner | undefined {
    return PcmRenderOffload.runner;
  }
}
