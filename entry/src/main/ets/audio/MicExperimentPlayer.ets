import { audio } from '@kit.AudioKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { media } from '@kit.MediaKit';

const MIC_PREVIEW_START_TIMEOUT_MS: number = 8000;

class MicExperimentPlayback {
  sequence: number = 0;
  player: media.AVPlayer | undefined = undefined;
  sourceFile: fs.File | undefined = undefined;
  initialization: Promise<void> = Promise.resolve();
  cleanup: Promise<void> | undefined = undefined;
  timer: number = -1;
  terminal: boolean = false;
  preparing: boolean = false;
  playRequested: boolean = false;
  started: boolean = false;
  startSettled: boolean = false;
  resolveStart: () => void = () => {};
  rejectStart: (error: Error) => void = () => {};
  onEnded: (() => void) | undefined = undefined;
}

/**
 * Auditions unchanged experiment WAVs after capture and test playback stop.
 * The owner must stop/cancel this player on navigation and app backgrounding.
 * No session engine, calibration, system volume, or per-file gain is changed.
 */
export class MicExperimentPlayer {
  private sequence: number = 0;
  private current: MicExperimentPlayback | undefined = undefined;
  private cleanupTail: Promise<void> = Promise.resolve();

  /** Resolves once this request's native play call succeeds, not when its audio ends. */
  play(path: string, onEnded?: () => void): Promise<void> {
    const sequence = ++this.sequence;
    const previous = this.current;
    if (previous !== undefined) {
      void this.finish(previous, new Error('试听已取消'));
    }
    const request = new MicExperimentPlayback();
    request.sequence = sequence;
    request.onEnded = onEnded;
    const started = new Promise<void>((resolve, reject) => {
      request.resolveStart = resolve;
      request.rejectStart = reject;
    });
    this.current = request;
    request.timer = setTimeout(() => {
      if (this.isCurrent(request)) {
        void this.finish(request, new Error('试听启动超时，请重试'));
      }
    }, MIC_PREVIEW_START_TIMEOUT_MS);
    // A replacement cannot overlap an old audible stream. Pending native
    // creation is allowed to finish only so its own resources can be released.
    request.initialization = this.initialize(request, path, this.cleanupTail);
    void request.initialization.catch((_error: Object) => {
      if (this.isCurrent(request)) {
        void this.finish(request, new Error('无法打开实验音轨，请重新实验'));
      }
    });
    return started;
  }

  /** Invalidates synchronously; resolves after every older player and fd are released. */
  stop(): Promise<void> {
    this.sequence++;
    const request = this.current;
    if (request !== undefined) {
      void this.finish(request, new Error('试听已取消'));
    }
    return this.cleanupTail;
  }

  /** Navigation-safe synchronous invalidation; native cleanup continues asynchronously. */
  cancel(): void {
    void this.stop();
  }

  private isCurrent(request: MicExperimentPlayback): boolean {
    return this.current === request && !request.terminal && request.sequence === this.sequence;
  }

  private async initialize(request: MicExperimentPlayback, path: string,
    previousCleanup: Promise<void>): Promise<void> {
    await previousCleanup;
    if (!this.isCurrent(request)) { return; }
    request.sourceFile = await fs.open(path, fs.OpenMode.READ_ONLY);
    if (!this.isCurrent(request)) { return; }
    const stat = await fs.stat(request.sourceFile.fd);
    if (!stat.isFile() || stat.size <= 44) { throw new Error('实验音轨为空'); }
    if (!this.isCurrent(request)) { return; }
    request.player = await media.createAVPlayer();
    if (!this.isCurrent(request)) { return; }
    const player = request.player;
    player.on('stateChange', (state: media.AVPlayerState) => {
      if (!this.isCurrent(request)) { return; }
      if (state === 'initialized') {
        void this.prepare(request);
      } else if (state === 'prepared') {
        void this.startPrepared(request);
      } else if (state === 'completed') {
        void this.finish(request, undefined, true);
      } else if (request.started && (state === 'paused' || state === 'stopped')) {
        void this.finish(request, new Error('试听已暂停'), true);
      }
    });
    player.on('error', (_error: Object) => {
      if (this.isCurrent(request)) {
        void this.finish(request, new Error('音轨试听失败，请重试'), request.started);
      }
    });
    player.on('audioInterrupt', (_event: audio.InterruptEvent) => {
      if (this.isCurrent(request)) {
        // Resume is also terminal: an interrupted A/B audition must never
        // restart later and compete with practice or a newer audition.
        void this.finish(request, new Error('试听被其他声音中断'), request.started);
      }
    });
    player.fdSrc = { fd: request.sourceFile.fd, offset: 0, length: stat.size };
  }

  private async prepare(request: MicExperimentPlayback): Promise<void> {
    const player = request.player;
    if (!this.isCurrent(request) || request.preparing || player === undefined) { return; }
    request.preparing = true;
    try {
      player.audioRendererInfo = { usage: audio.StreamUsage.STREAM_USAGE_GAME, rendererFlags: 0 };
      await player.prepare();
    } catch (_error) {
      if (this.isCurrent(request)) {
        void this.finish(request, new Error('实验音轨准备失败，请重试'));
      }
    }
  }

  private async startPrepared(request: MicExperimentPlayback): Promise<void> {
    const player = request.player;
    if (!this.isCurrent(request) || request.playRequested || player === undefined) { return; }
    request.playRequested = true;
    try {
      // Compare the two raw recordings with the same default gain and without
      // player effects; normalization would hide genuine suppression/loss.
      player.audioEffectMode = audio.AudioEffectMode.EFFECT_NONE;
      await player.play();
      if (!this.isCurrent(request)) { return; }
      request.started = true;
      request.startSettled = true;
      this.clearStartTimer(request);
      request.resolveStart();
    } catch (_error) {
      if (this.isCurrent(request)) {
        void this.finish(request, new Error('实验音轨播放失败，请重试'));
      }
    }
  }

  private clearStartTimer(request: MicExperimentPlayback): void {
    if (request.timer >= 0) {
      clearTimeout(request.timer);
      request.timer = -1;
    }
  }

  private finish(request: MicExperimentPlayback, error?: Error, notifyEnded: boolean = false): Promise<void> {
    if (request.terminal) { return request.cleanup ?? Promise.resolve(); }
    request.terminal = true;
    this.clearStartTimer(request);
    if (!request.startSettled) {
      request.startSettled = true;
      request.rejectStart(error ?? new Error('试听已结束'));
    }
    if (this.current === request) { this.current = undefined; }
    const cleanup = this.releaseResources(request);
    request.cleanup = cleanup;
    const previous = this.cleanupTail;
    this.cleanupTail = previous.then(() => cleanup);
    if (notifyEnded && request.started && request.onEnded !== undefined) {
      void cleanup.then(() => {
        // Completion from an older file cannot reset a replacement's UI.
        if (this.sequence === request.sequence) { request.onEnded?.(); }
      }).catch((_error: Object) => {});
    }
    return cleanup;
  }

  private async releaseResources(request: MicExperimentPlayback): Promise<void> {
    // Cancellation may arrive while open/createAVPlayer is unresolved. Wait
    // for those owned resources, then release the decoder before closing fd.
    try { await request.initialization; } catch (_error) {}
    const player = request.player;
    request.player = undefined;
    try {
      if (player !== undefined) {
        try { player.off('stateChange'); } catch (_error) {}
        try { player.off('error'); } catch (_error) {}
        try { player.off('audioInterrupt'); } catch (_error) {}
        await player.release();
      }
    } catch (_error) {
      // A native release failure must not leak the still-owned source fd.
    } finally {
      const sourceFile = request.sourceFile;
      request.sourceFile = undefined;
      if (sourceFile !== undefined) {
        try { await fs.close(sourceFile); } catch (_error) {}
      }
    }
  }
}
