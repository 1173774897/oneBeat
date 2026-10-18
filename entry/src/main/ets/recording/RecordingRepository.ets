import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { fileIo as fs, fileUri } from '@kit.CoreFileKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { util } from '@kit.ArkTS';
import { readOptional, writeAtomic } from '../common/AtomicTextFile';
import { PendingRecordingCapture, RecordingClip, RecordingScope } from './RecordingModels';
import { RecordingMixer, RECORDING_MIX_VERSION } from './RecordingMixer';

const LIBRARY_PREFERENCES: string = 'onebeat_recording_library';
const LIBRARY_KEY: string = 'recordingLibraryV1';

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
    if (raw.length > 0) {
      try {
        const snapshot = JSON.parse(raw) as LibrarySnapshot;
        if (snapshot.version === 1 && Array.isArray(snapshot.clips)) {
          for (const clip of snapshot.clips) {
            if (RecordingRepository.isOwnedPath(clip.path) && clip.id.length > 0 &&
              Number.isFinite(clip.durationMs) && clip.durationMs > 0 && await fs.access(clip.path)) {
              clips.push(clip);
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
          const existing = clips.findIndex((entry: RecordingClip) => entry.id === clip.id);
          if (existing < 0) { clips.push(clip); }
          else if ((clip.renderedAt ?? clip.createdAt) > (clips[existing].renderedAt ?? clips[existing].createdAt)) {
            clips[existing] = clip;
          }
          recoveryPaths.push(path);
        }
      } catch (_error) {
        // An interrupted metadata write is not a finished work; keep it for diagnosis.
      }
    }
    if (recoveryPaths.length > 0 || migratePreferences) {
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
      id: clip.id, path: clip.path, createdAt: clip.createdAt, durationMs: clip.durationMs,
      width: clip.width, height: clip.height, interrupted: clip.interrupted, stopReason: clip.stopReason,
      scope: clip.scope ?? 'solo', sourcePath: clip.sourcePath, micPath: clip.micPath, innerPath: clip.innerPath,
      micOffsetUs: clip.micOffsetUs, innerOffsetUs: clip.innerOffsetUs,
      audioSampleRate: clip.audioSampleRate, audioChannels: clip.audioChannels,
      renderedGain: clip.renderedGain ?? 1, renderedAt: clip.renderedAt ?? clip.createdAt,
      renderedMixVersion: clip.renderedMixVersion,
      captureSyncValid: clip.captureSyncValid, captureMappingVersion: clip.captureMappingVersion,
      videoTimestampDivisor: clip.videoTimestampDivisor, builtInSpeakerCapture: clip.builtInSpeakerCapture
    };
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
          clip.captureMappingVersion !== 2 || typeof clip.captureSyncValid !== 'boolean' ||
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

  /** Each gain render reads immutable stems, so repeated edits never compound gain or touch app audio. */
  static render(clip: RecordingClip, gain: number): Promise<RecordingClip> {
    const task = RecordingRepository.operation.then(async (): Promise<RecordingClip> => {
      if (!Number.isFinite(gain) || gain < 0 || gain > 2) {
        throw new Error('麦克风音量无效，请重新调整');
      }
      const stored = RecordingRepository.get(clip.id);
      if (stored === undefined) { throw new Error('视频文件不存在，请重新录制'); }
      if (AppStorage.get<string>('recordingPendingClipId') === stored.id) {
        throw new Error('请先完成或取消这次分享，再调整声音');
      }
      const desired = Math.round(gain * 100) / 100;
      if (Math.abs((stored.renderedGain ?? 1) - desired) < 0.001 &&
        ((stored.renderedMixVersion ?? 0) >= RECORDING_MIX_VERSION || stored.sourcePath === undefined ||
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
        await RecordingMixer.exportMixed(stored, desired, output);
        if ((await fs.stat(output)).size <= 0) { throw new Error('声音处理未完成，请重试'); }
        const updated = RecordingRepository.copy(stored);
        updated.path = output;
        updated.renderedGain = desired;
        updated.renderedMixVersion = RECORDING_MIX_VERSION;
        updated.renderedAt = Math.max(Date.now(), (stored.renderedAt ?? stored.createdAt) + 1);
        const recoveryPath = await RecordingRepository.writeRecovery(updated);
        const next = RecordingRepository.clips.map((entry: RecordingClip) => entry.id === updated.id ? updated : entry);
        await RecordingRepository.commit(next);
        try { await fs.unlink(recoveryPath); } catch (_error) {}
        // Gain edits are forbidden while sharing. A paused preview may still
        // hold its old FD, but unlinking that derived file does not invalidate it.
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
      path.indexOf('/../') < 0 && (path.endsWith('.mp4') || path.endsWith('.pcm') || path.endsWith('.wav'));
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
      // A completed MP4 gets a durable recovery note before the index transaction.
      // If indexing fails or the process dies, next launch can recover this work.
      const recoveryPath = await RecordingRepository.writeRecovery(clip);
      const next = RecordingRepository.clips.filter((entry: RecordingClip) => entry.id !== clip.id);
      next.push(RecordingRepository.copy(clip));
      await RecordingRepository.commit(next);
      try { await fs.unlink(recoveryPath); } catch (_error) {}
    });
  }

  static remove(id: string): Promise<void> {
    return RecordingRepository.enqueue(async () => {
      if (AppStorage.get<string>('recordingPendingClipId') === id) {
        throw new Error('请先完成或取消这段视频的待确认分享');
      }
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
      const paths: string[] = [`${RecordingRepository.directory}/${clip.id}.mp4`, clip.path, clip.sourcePath ?? '', clip.micPath ?? '', clip.innerPath ?? ''];
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

  static async saveToAlbum(clip: RecordingClip, context: common.UIAbilityContext): Promise<void> {
    const stored = RecordingRepository.get(clip.id);
    if (stored === undefined || !await fs.access(stored.path)) {
      throw new Error('视频文件不存在，请重新录制');
    }
    const helper = photoAccessHelper.getPhotoAccessHelper(context);
    try {
      // The system dialog grants access only to this destination; no broad photo-library permission.
      const destinations = await helper.showAssetsCreationDialog([fileUri.getUriFromPath(stored.path)], [{
        title: `oneBeat-${stored.id.substring(0, 8)}`,
        fileNameExtension: 'mp4', photoType: photoAccessHelper.PhotoType.VIDEO
      }]);
      if (destinations.length !== 1) {
        throw new Error('已取消保存视频');
      }
      const target = await fs.open(destinations[0], fs.OpenMode.WRITE_ONLY);
      try {
        await fs.copyFile(stored.path, target.fd);
      } finally {
        await fs.close(target);
      }
    } finally {
      await helper.release();
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

  private static enqueue(action: () => Promise<void>): Promise<void> {
    const task = RecordingRepository.operation.then(action);
    RecordingRepository.operation = task.catch(() => {});
    return task;
  }

  private static notify(): void {
    AppStorage.setOrCreate('recordingLibraryEpoch', (AppStorage.get<number>('recordingLibraryEpoch') ?? 0) + 1);
  }
}
