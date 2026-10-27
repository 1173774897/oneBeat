import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { fileIo as fs, fileUri } from '@kit.CoreFileKit';
import * as recordingNative from 'libonebeat_recording.so';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { util } from '@kit.ArkTS';
import { readOptional, writeAtomic } from '../common/AtomicTextFile';
import { RecordingCoverService } from './RecordingCoverService';
import { PendingRecordingCapture, RecordingClip, RecordingScope } from './RecordingModels';
import { MAX_MIC_SHIFT_US, RecordingMixer } from './RecordingMixer';

const LIBRARY_PREFERENCES: string = 'onebeat_recording_library';
const LIBRARY_KEY: string = 'recordingLibraryV1';
const RECORDING_COVER_VERSION: number = 1;

export interface RecordingTarget {
  id: string;
  path: string;
  createdAt: number;
}

interface LibrarySnapshot {
  version: number;
  clips: RecordingClip[];
}

/** Finished recordings outlive rooms; only the library owns their files. */
export class RecordingRepository {
  private static directory: string = '';
  private static ready: boolean = false;
  private static indexPath: string = '';
  private static clips: RecordingClip[] = [];
  private static initialization: Promise<void> | undefined = undefined;
  private static operation: Promise<void> = Promise.resolve();

  static initialize(context: common.Context): Promise<void> {
    if (RecordingRepository.initialization === undefined) {
      RecordingRepository.initialization = RecordingRepository.restore(context).catch((error: Error) => {
        RecordingRepository.initialization = undefined;
        throw error;
      });
    }
    return RecordingRepository.initialization;
  }

  private static async restore(context: common.Context): Promise<void> {
    RecordingRepository.directory = `${context.filesDir}/recordings`;
    if (!await fs.access(RecordingRepository.directory)) {
      await fs.mkdir(RecordingRepository.directory, true);
    }
    RecordingRepository.indexPath = `${RecordingRepository.directory}/library-v1.json`;
    let raw = await readOptional(RecordingRepository.indexPath);
    const migratePreferences = raw.length === 0;
    if (migratePreferences) {
      const pref = await preferences.getPreferences(context, LIBRARY_PREFERENCES);
      raw = await pref.get(LIBRARY_KEY, '') as string;
    }
    const clips: RecordingClip[] = [];
    let coverMetadataChanged = false;
    if (raw.length > 0) {
      try {
        const snapshot = JSON.parse(raw) as LibrarySnapshot;
        if (snapshot.version === 1 && Array.isArray(snapshot.clips)) {
          for (const clip of snapshot.clips) {
            if (RecordingRepository.isOwnedPath(clip.path) && clip.id.length > 0 &&
              Number.isFinite(clip.durationMs) && clip.durationMs > 0 && await fs.access(clip.path)) {
              const restored = await RecordingRepository.copyWithValidCover(clip);
              coverMetadataChanged = coverMetadataChanged || restored.coverPath !== clip.coverPath;
              clips.push(restored);
            }
          }
        }
      } catch (_error) {
        // A corrupt index must never authorize deletion or sharing outside our directory.
        throw new Error('录制作品列表读取失败，请重启应用后重试');
      }
    }
    const recoveryPaths: string[] = [];
    const files = await fs.listFile(RecordingRepository.directory);
    for (const file of files) {
      if (!file.endsWith('.recovery.json')) { continue; }
      const path = `${RecordingRepository.directory}/${file}`;
      try {
        const clip = JSON.parse(await fs.readText(path)) as RecordingClip;
        if (RecordingRepository.isOwnedPath(clip.path) && clip.id.length > 0 &&
          Number.isFinite(clip.durationMs) && clip.durationMs > 0 && await fs.access(clip.path) &&
          (await fs.stat(clip.path)).size > 0) {
          const restored = await RecordingRepository.copyWithValidCover(clip);
          coverMetadataChanged = coverMetadataChanged || restored.coverPath !== clip.coverPath;
          const existing = clips.findIndex((entry: RecordingClip) => entry.id === clip.id);
          if (existing < 0) { clips.push(restored); }
          else if ((restored.renderedAt ?? restored.createdAt) >
            (clips[existing].renderedAt ?? clips[existing].createdAt)) {
            clips[existing] = restored;
          }
          recoveryPaths.push(path);
        }
      } catch (_error) {
        // An interrupted metadata write is not a finished work; keep it for diagnosis.
      }
    }
    if (recoveryPaths.length > 0 || migratePreferences || coverMetadataChanged) {
      const snapshot: LibrarySnapshot = { version: 1, clips: clips };
      await writeAtomic(RecordingRepository.indexPath, JSON.stringify(snapshot));
      for (const path of recoveryPaths) {
        try { await fs.unlink(path); } catch (_error) {}
      }
    }
    RecordingRepository.ready = true;
    RecordingRepository.clips = clips;
    RecordingRepository.notify();
  }

  private static isOwnedPath(path: string): boolean {
    return RecordingRepository.directory.length > 0 &&
      path.startsWith(`${RecordingRepository.directory}/`) &&
      path.indexOf('/../') < 0 && path.endsWith('.mp4');
  }

  static async createTarget(): Promise<RecordingTarget> {
    if (!RecordingRepository.ready) {
      throw new Error('录制作品尚未准备好，请稍后重试');
    }
    const id = util.generateRandomUUID(true);
    return { id: id, path: `${RecordingRepository.directory}/${id}.mp4`, createdAt: Date.now() };
  }

  static count(scope: RecordingScope): number {
    return RecordingRepository.clips.filter((clip: RecordingClip) => (clip.scope ?? 'solo') === scope).length;
  }

  static list(scope?: RecordingScope): RecordingClip[] {
    return RecordingRepository.clips.filter((clip: RecordingClip) =>
      scope === undefined || (clip.scope ?? 'solo') === scope).map((clip: RecordingClip) => RecordingRepository.copy(clip))
      .sort((a: RecordingClip, b: RecordingClip) => b.createdAt - a.createdAt);
  }

  static get(id: string): RecordingClip | undefined {
    const clip = RecordingRepository.clips.find((entry: RecordingClip) => entry.id === id);
    return clip === undefined ? undefined : RecordingRepository.copy(clip);
  }

  private static copy(clip: RecordingClip): RecordingClip {
    return {
      id: clip.id, path: clip.path, coverPath: clip.coverPath,
      createdAt: clip.createdAt, durationMs: clip.durationMs,
      width: clip.width, height: clip.height, interrupted: clip.interrupted, stopReason: clip.stopReason,
      scope: clip.scope ?? 'solo', sourcePath: clip.sourcePath, micPath: clip.micPath, innerPath: clip.innerPath,
      micOffsetUs: clip.micOffsetUs, innerOffsetUs: clip.innerOffsetUs,
      audioSampleRate: clip.audioSampleRate, audioChannels: clip.audioChannels,
      renderedGain: clip.renderedGain ?? 1, renderedAt: clip.renderedAt ?? clip.createdAt,
      renderedMicShiftUs: clip.renderedMicShiftUs ?? 0,
      autoMicShiftUs: clip.autoMicShiftUs,
      autoMicShiftConfidence: clip.autoMicShiftConfidence,
      autoMicShiftReliable: clip.autoMicShiftReliable,
      renderedMixVersion: clip.renderedMixVersion,
      captureSyncValid: clip.captureSyncValid, captureMappingVersion: clip.captureMappingVersion,
      videoTimestampDivisor: clip.videoTimestampDivisor, builtInSpeakerCapture: clip.builtInSpeakerCapture,
      micCaptureMode: clip.micCaptureMode,
      albumUri: clip.albumUri, albumContentAt: clip.albumContentAt
    };
  }

  private static coverPath(id: string): string {
    return `${RecordingRepository.directory}/${id}.cover-v${RECORDING_COVER_VERSION}.jpg`;
  }

  private static isOwnedCoverPath(clip: RecordingClip, path: string): boolean {
    return RecordingRepository.directory.length > 0 && path === RecordingRepository.coverPath(clip.id);
  }

  private static async copyWithValidCover(clip: RecordingClip): Promise<RecordingClip> {
    const restored = RecordingRepository.copy(clip);
    if (restored.coverPath !== undefined) {
      try {
        if (!RecordingRepository.isOwnedCoverPath(restored, restored.coverPath) ||
          !await fs.access(restored.coverPath) || (await fs.stat(restored.coverPath)).size <= 0) {
          restored.coverPath = undefined;
        }
      } catch (_error) {
        restored.coverPath = undefined;
      }
    }
    return restored;
  }

  private static pendingPath(clip: RecordingClip): string {
    if (!/^[a-zA-Z0-9_-]+$/.test(clip.id) ||
      clip.path !== `${RecordingRepository.directory}/${clip.id}.mp4`) {
      throw new Error('待保存录制信息无效，原始文件已保留');
    }
    return `${RecordingRepository.directory}/${clip.id}.capture.json`;
  }

  /** Persist before exporting so a failed encode or restart cannot lose its source-track identity. */
  static retainPendingCapture(clip: RecordingClip): Promise<void> {
    return RecordingRepository.enqueue(async () => {
      const capture: PendingRecordingCapture = { version: 2, finished: true, clip: RecordingRepository.copy(clip) };
      await writeAtomic(RecordingRepository.pendingPath(clip), JSON.stringify(capture));
    });
  }

  static clearPendingCapture(clip: RecordingClip): Promise<void> {
    return RecordingRepository.enqueue(async () => {
      const path = RecordingRepository.pendingPath(clip);
      if (await fs.access(path)) { await fs.unlink(path); }
    });
  }

  /** Only versioned finished captures are recoverable. Unknown legacy stems remain untouched. */
  static async loadPendingCapture(): Promise<RecordingClip | undefined> {
    const files = (await fs.listFile(RecordingRepository.directory)).filter((file: string) =>
      file.endsWith('.capture.json')).sort();
    for (const file of files) {
      try {
        const capture = JSON.parse(await fs.readText(`${RecordingRepository.directory}/${file}`)) as PendingRecordingCapture;
        const clip = capture.clip;
        if (capture.version !== 2 || capture.finished !== true || clip === undefined ||
          (clip.captureMappingVersion !== 2 && clip.captureMappingVersion !== 3) ||
          (clip.captureMappingVersion === 3) !== (clip.micCaptureMode === 'system-aec') ||
          typeof clip.captureSyncValid !== 'boolean' ||
          !Number.isFinite(clip.durationMs) || clip.durationMs <= 0 ||
          RecordingRepository.pendingPath(clip) !== `${RecordingRepository.directory}/${file}`) { continue; }
        if (RecordingRepository.get(clip.id) !== undefined) {
          await RecordingRepository.clearPendingCapture(clip);
          continue;
        }
        const sources: string[] = [clip.sourcePath ?? '', clip.innerPath ?? '', clip.micPath ?? ''];
        let sourcesPresent = true;
        for (const path of sources) {
          if (!RecordingRepository.isOwnedMediaPath(path) || !await fs.access(path)) { sourcesPresent = false; break; }
        }
        if (sourcesPresent) { return RecordingRepository.copy(clip); }
      } catch (_error) {
        // Corrupt or incomplete metadata cannot authorize export, indexing or deletion.
      }
    }
    return undefined;
  }

  /** Each render reads immutable stems; the cached MIC residual makes later gain/shift edits cheap. */
  static render(clip: RecordingClip, gain: number,
    micShiftUs: number = clip.renderedMicShiftUs ?? 0): Promise<RecordingClip> {
    const task = RecordingRepository.operation.then(async (): Promise<RecordingClip> => {
      if (!Number.isFinite(gain) || gain < 0 || gain > 2) {
        throw new Error('麦克风音量无效，请重新调整');
      }
      if (!Number.isFinite(micShiftUs) || Math.abs(micShiftUs) > MAX_MIC_SHIFT_US) {
        throw new Error('人声对齐需在提前或延后 300 毫秒以内');
      }
      const stored = RecordingRepository.get(clip.id);
      if (stored === undefined) { throw new Error('视频文件不存在，请重新录制'); }
      const desired = Math.round(gain * 100) / 100;
      const desiredShiftUs = Math.round(micShiftUs / 1000) * 1000;
      const autoAlignmentKnown = stored.autoMicShiftUs !== undefined &&
        stored.autoMicShiftConfidence !== undefined && stored.autoMicShiftReliable !== undefined;
      if (Math.abs((stored.renderedGain ?? 1) - desired) < 0.001 &&
        (stored.renderedMicShiftUs ?? 0) === desiredShiftUs &&
        (((stored.renderedMixVersion ?? 0) >= RecordingMixer.mixVersion(stored) && autoAlignmentKnown) ||
          stored.sourcePath === undefined ||
          stored.innerPath === undefined || stored.micPath === undefined)) { return stored; }
      if (stored.sourcePath === undefined || stored.micPath === undefined || stored.innerPath === undefined) {
        throw new Error('这段旧视频已合并声音，重新录制后可单独调整麦克风音量');
      }
      for (const path of [stored.sourcePath, stored.micPath, stored.innerPath]) {
        if (!RecordingRepository.isOwnedMediaPath(path) || !await fs.access(path)) {
          throw new Error('原始音轨不存在，无法单独调整麦克风音量');
        }
      }
      const output = `${RecordingRepository.directory}/${stored.id}.mix-${util.generateRandomUUID(true)}.mp4`;
      try {
        const mixResult = await RecordingMixer.exportMixed(stored, desired, output, desiredShiftUs);
        if ((await fs.stat(output)).size <= 0) { throw new Error('声音处理未完成，请重试'); }
        const updated = RecordingRepository.copy(stored);
        updated.path = output;
        updated.renderedGain = desired;
        updated.renderedMicShiftUs = desiredShiftUs;
        updated.autoMicShiftUs = mixResult.autoMicShiftUs;
        updated.autoMicShiftConfidence = mixResult.autoMicShiftConfidence;
        updated.autoMicShiftReliable = mixResult.autoMicShiftReliable;
        updated.renderedMixVersion = RecordingMixer.mixVersion(stored);
        updated.renderedAt = Math.max(Date.now(), (stored.renderedAt ?? stored.createdAt) + 1);
        const recoveryPath = await RecordingRepository.writeRecovery(updated);
        const next = RecordingRepository.clips.map((entry: RecordingClip) => entry.id === updated.id ? updated : entry);
        await RecordingRepository.commit(next);
        try { await fs.unlink(recoveryPath); } catch (_error) {}
        // Share handoffs own immutable snapshots. A preview holding its old FD
        // remains valid after this obsolete derived file is unlinked.
        if (stored.path !== stored.sourcePath && stored.path !== stored.innerPath &&
          stored.path !== stored.micPath && RecordingRepository.isOwnedPath(stored.path)) {
          try { await fs.unlink(stored.path); } catch (_error) {}
        }
        return RecordingRepository.copy(updated);
      } catch (_error) {
        throw new Error('声音处理未完成，原视频和音轨已保留，请重试');
      }
    });
    RecordingRepository.operation = task.then(() => {}, () => {});
    return task;
  }

  private static isOwnedMediaPath(path: string): boolean {
    return RecordingRepository.directory.length > 0 && path.startsWith(`${RecordingRepository.directory}/`) &&
      path.indexOf('/../') < 0 &&
      (path.endsWith('.mp4') || path.endsWith('.pcm') || path.endsWith('.wav') ||
        path.endsWith('.f32') || path.endsWith('.f32.tmp'));
  }

  private static async withGeneratedCover(clip: RecordingClip): Promise<RecordingClip> {
    const updated = RecordingRepository.copy(clip);
    const coverPath = RecordingRepository.coverPath(updated.id);
    try {
      await RecordingCoverService.generate(updated.path, coverPath, updated.width, updated.height);
      if (await fs.access(coverPath) && (await fs.stat(coverPath)).size > 0) {
        updated.coverPath = coverPath;
      }
    } catch (_error) {
      // Covers are derived and retryable; a decoder failure must not hide or lose the playable work.
      console.warn('Recording cover generation deferred');
    }
    return updated;
  }

  static ensureCover(id: string): Promise<RecordingClip | undefined> {
    const task = RecordingRepository.operation.then(async (): Promise<RecordingClip | undefined> => {
      const stored = RecordingRepository.get(id);
      if (stored === undefined) { return undefined; }
      if (stored.coverPath !== undefined && RecordingRepository.isOwnedCoverPath(stored, stored.coverPath) &&
        await fs.access(stored.coverPath) && (await fs.stat(stored.coverPath)).size > 0) {
        return stored;
      }
      const updated = await RecordingRepository.withGeneratedCover(stored);
      if (updated.coverPath === undefined) { return stored; }
      const next = RecordingRepository.clips.map((entry: RecordingClip) =>
        entry.id === updated.id ? updated : entry);
      await RecordingRepository.commit(next);
      return RecordingRepository.copy(updated);
    });
    RecordingRepository.operation = task.then(() => {}, () => {});
    return task;
  }

  /**
   * Temporary debug helper: copy the latest recording's raw PCM tracks
   * (inner + mic) to world-readable files so they can be pulled via hdc.
   */
  static async exportLatestTracksForDebug(): Promise<string[]> {
    const clips = RecordingRepository.list();
    if (clips.length === 0) {
      return [];
    }
    const latest = clips[0];
    const exported: string[] = [];
    await RecordingRepository.exportTrackForDebug(latest.innerPath, 'inner', exported);
    await RecordingRepository.exportTrackForDebug(latest.micPath, 'mic', exported);
    return exported;
  }

  private static async exportTrackForDebug(src: string | undefined, label: string, exported: string[]): Promise<void> {
    if (src === undefined || src.length === 0 || !RecordingRepository.isOwnedMediaPath(src)) {
      return;
    }
    if (!await fs.access(src)) {
      return;
    }
    const dest = `${RecordingRepository.directory}/debug-export-${label}.pcm`;
    await fs.copyFile(src, dest);
    recordingNative.chmod(dest, 0o644);
    exported.push(dest);
  }

  static add(clip: RecordingClip): Promise<void> {
    return RecordingRepository.enqueue(async () => {
      if (!RecordingRepository.isOwnedPath(clip.path) || !Number.isFinite(clip.durationMs) || clip.durationMs <= 0) {
        throw new Error('录制视频无效，无法加入作品列表');
      }
      const stat = await fs.stat(clip.path);
      if (!stat.isFile() || stat.size <= 0) {
        throw new Error('录制视频生成失败，请重新录制');
      }
      const stored = await RecordingRepository.withGeneratedCover(clip);
      // A completed MP4 gets a durable recovery note before the index transaction.
      // If indexing fails or the process dies, next launch can recover this work.
      const recoveryPath = await RecordingRepository.writeRecovery(stored);
      const next = RecordingRepository.clips.filter((entry: RecordingClip) => entry.id !== stored.id);
      next.push(RecordingRepository.copy(stored));
      await RecordingRepository.commit(next);
      try { await fs.unlink(recoveryPath); } catch (_error) {}
    });
  }

  static remove(id: string): Promise<void> {
    return RecordingRepository.enqueue(async () => {
      const clip = RecordingRepository.get(id);
      if (clip === undefined) {
        return;
      }
      const recoveryPath = `${clip.path}.recovery.json`;
      if (await fs.access(recoveryPath)) { await fs.unlink(recoveryPath); }
      for (const name of await fs.listFile(RecordingRepository.directory)) {
        if (name.startsWith(clip.id) && name.endsWith('.recovery.json')) {
          await fs.unlink(`${RecordingRepository.directory}/${name}`);
        }
      }
      // Remove the index first. A failed file cleanup leaves an orphan, never a broken visible work.
      await RecordingRepository.commit(RecordingRepository.clips.filter((entry: RecordingClip) => entry.id !== id));
      const coverPath = RecordingRepository.coverPath(clip.id);
      for (const path of [coverPath, `${coverPath}.tmp`]) {
        if (await fs.access(path)) { await fs.unlink(path); }
      }
      const processedMic = clip.micPath === undefined ? '' : RecordingMixer.processedMicPath(clip.micPath, clip.micCaptureMode);
      const paths: string[] = [`${RecordingRepository.directory}/${clip.id}.mp4`, clip.path,
        clip.sourcePath ?? '', clip.micPath ?? '', clip.innerPath ?? '', processedMic,
        processedMic.length === 0 ? '' : `${processedMic}.tmp`];
      if (clip.micCaptureMode === 'system-aec' && clip.micPath !== undefined) {
        // Derived caches from earlier level algorithms can coexist after an
        // upgrade; deleting a take must remove those obsolete copies too.
        for (const version of [1, 2]) {
          paths.push(`${clip.micPath}.system-aec-v${version}.f32`, `${clip.micPath}.system-aec-v${version}.f32.tmp`);
        }
      }
      for (const name of await fs.listFile(RecordingRepository.directory)) {
        if (name.startsWith(`${clip.id}.mix-`) && name.endsWith('.mp4')) {
          paths.push(`${RecordingRepository.directory}/${name}`);
        }
      }
      for (const path of paths) {
        if (RecordingRepository.isOwnedMediaPath(path) && await fs.access(path)) { await fs.unlink(path); }
      }
    });
  }

  /** Returns false for a cancelled system save dialog; true means the current indexed MP4 was copied to its authorized album URI. */
  static async saveToAlbum(clip: RecordingClip, context: common.UIAbilityContext): Promise<boolean> {
    const stored = RecordingRepository.get(clip.id);
    if (stored === undefined || !RecordingRepository.isOwnedPath(stored.path)) {
      throw new Error('视频文件不存在，请重新录制');
    }
    const source = await fs.open(stored.path, fs.OpenMode.READ_ONLY);
    try {
      const sourceStat = await fs.stat(source.fd);
      if (!sourceStat.isFile() || !Number.isFinite(sourceStat.size) || sourceStat.size <= 0) {
        throw new Error('视频文件无效，请重新录制');
      }
      const helper = photoAccessHelper.getPhotoAccessHelper(context);
      try {
        // The system grants only this destination. Keep the source FD open so a later MIC render cannot change its bytes.
        const destinations = await helper.showAssetsCreationDialog([fileUri.getUriFromPath(stored.path)], [{
          title: `oneBeat-${stored.id.substring(0, 8)}`,
          fileNameExtension: 'mp4', photoType: photoAccessHelper.PhotoType.VIDEO
        }]);
        if (destinations.length === 0) { return false; }
        if (destinations.length !== 1 || destinations[0].length === 0) {
          throw new Error('相册保存位置无效，请重新保存');
        }
        const destination = await fs.open(destinations[0], fs.OpenMode.WRITE_ONLY);
        try {
          await fs.copyFile(source.fd, destination.fd);
        } finally {
          try { await fs.close(destination); }
          catch (_error) { console.warn('[RecordingAlbum] destination close failed'); }
        }
        // Remember the media-library URI so later shares reuse this copy instead of saving again.
        await RecordingRepository.recordAlbumUri(stored.id, destinations[0], stored.renderedAt ?? stored.createdAt);
        return true;
      } finally {
        // Releasing a completed operation must not turn a successful save into a visible failure.
        try { await helper.release(); }
        catch (_error) { console.warn('[RecordingAlbum] helper release failed'); }
      }
    } finally {
      try { await fs.close(source); }
      catch (_error) { console.warn('[RecordingAlbum] source close failed'); }
    }
  }

  private static async writeRecovery(clip: RecordingClip): Promise<string> {
    const path = `${clip.path}.recovery.json`;
    await writeAtomic(path, JSON.stringify(clip));
    return path;
  }

  private static async commit(clips: RecordingClip[]): Promise<void> {
    if (!RecordingRepository.ready) {
      throw new Error('录制作品尚未准备好，请稍后重试');
    }
    const snapshot: LibrarySnapshot = { version: 1, clips: clips };
    await writeAtomic(RecordingRepository.indexPath, JSON.stringify(snapshot));
    RecordingRepository.clips = clips;
    RecordingRepository.notify();
  }

  /** Persist the media-library URI for a clip so shares can reuse it; no-op if the clip no longer exists. */
  static recordAlbumUri(id: string, albumUri: string, albumContentAt: number): Promise<void> {
    return RecordingRepository.enqueue(async () => {
      const current = RecordingRepository.get(id);
      if (current === undefined) { return; }
      const updated = RecordingRepository.copy(current);
      updated.albumUri = albumUri;
      updated.albumContentAt = albumContentAt;
      await RecordingRepository.commit(RecordingRepository.clips.map(
        (entry: RecordingClip) => entry.id === id ? updated : entry));
    });
  }

  private static enqueue(action: () => Promise<void>): Promise<void> {
    const task = RecordingRepository.operation.then(action);
    RecordingRepository.operation = task.catch(() => {});
    return task;
  }

  private static notify(): void {
    AppStorage.setOrCreate('recordingLibraryEpoch', (AppStorage.get<number>('recordingLibraryEpoch') ?? 0) + 1);
  }
}
