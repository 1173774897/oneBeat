import { common } from '@kit.AbilityKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import { preferences, uniformTypeDescriptor } from '@kit.ArkData';
import { fileIo as fs, fileUri } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import { media } from '@kit.MediaKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { systemShare } from '@kit.ShareKit';
import { util } from '@kit.ArkTS';
import { readOptional, writeAtomic } from '../common/AtomicTextFile';
import { RecordingClip } from '../recording/RecordingModels';
import { RecordingRepository } from '../recording/RecordingRepository';
import {
  acceptShareCheckIn, getShareCheckInSummary, getShareCheckInTodayKey, initializeShareCheckInStore, ShareCheckInResult
} from '../store/ShareCheckInStore';

const SHARE_PREFERENCES: string = 'onebeat_video_share';
const LEGACY_PENDING_KEY: string = 'pendingVideoShareV1';

export type RecordingShareTarget = 'system' | 'wechat' | 'moments' | 'qq' | 'weibo' | 'rednote';

export interface PendingVideoShare {
  id: string;
  clipId: string;
  createdAt: number;
  dayKey: string;
  handedOff: boolean;
  handedOffAt?: number;
  verification: 'platform_handoff' | 'self_report';
  chooserOpened: boolean;
  target: RecordingShareTarget;
  sharedPath?: string;
}

interface PendingSharesSnapshot {
  version: number;
  attempts: PendingVideoShare[];
}

/** A platform handoff only enables the user's confirmation; it never proves publication or grants a reward. */
export class RecordingShareService {
  private static snapshotPath: string = '';
  private static directory: string = '';
  private static pending: PendingVideoShare[] = [];
  private static controllers: Map<string, systemShare.ShareController> = new Map();
  private static operation: Promise<void> = Promise.resolve();
  private static busy: boolean = false;

  static async initialize(context: common.Context): Promise<void> {
    await initializeShareCheckInStore(context);
    RecordingShareService.snapshotPath = `${context.filesDir}/video-share-pending-v2.json`;
    RecordingShareService.directory = `${context.filesDir}/recordings`;
    const raw = await readOptional(RecordingShareService.snapshotPath);
    let restored: PendingVideoShare[] = [];
    try {
      if (raw.length > 0) {
        const snapshot = JSON.parse(raw) as PendingSharesSnapshot;
        if (snapshot.version !== 2 || !Array.isArray(snapshot.attempts)) { throw new Error('invalid snapshot'); }
        restored = snapshot.attempts;
      } else {
        const pref = await preferences.getPreferences(context, SHARE_PREFERENCES);
        const legacyRaw = await pref.get(LEGACY_PENDING_KEY, '') as string;
        if (legacyRaw.length > 0) {
          const legacy = JSON.parse(legacyRaw) as PendingVideoShare;
          legacy.dayKey = new Date(legacy.createdAt + 8 * 3600000).toISOString().substring(0, 10);
          legacy.target = 'system';
          legacy.verification = 'platform_handoff';
          legacy.chooserOpened = false;
          // Older releases treated opening the chooser as a handoff. It cannot establish a selected target.
          legacy.handedOff = false;
          restored.push(legacy);
        }
      }
      const ids: string[] = [];
      for (const entry of restored) {
        // Version 2 was introduced before the explicit old-system self-report distinction.
        entry.verification = entry.verification ?? 'platform_handoff';
        entry.chooserOpened = entry.chooserOpened ?? entry.handedOff;
        if (!RecordingShareService.validId(entry.id) || ids.includes(entry.id) ||
          !RecordingShareService.validId(entry.clipId) || !Number.isFinite(entry.createdAt) ||
          typeof entry.dayKey !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(entry.dayKey) ||
          typeof entry.handedOff !== 'boolean' || !RecordingShareService.validTarget(entry.target) ||
          (entry.verification !== 'platform_handoff' && entry.verification !== 'self_report') ||
          typeof entry.chooserOpened !== 'boolean' ||
          (entry.sharedPath !== undefined && entry.sharedPath !== RecordingShareService.sharePath(entry))) {
          throw new Error('invalid attempt');
        }
        ids.push(entry.id);
      }
    } catch (_error) {
      throw new Error('分享记录读取失败，请重启应用后重试');
    }
    const today = getShareCheckInTodayKey();
    const todayCompleted = getShareCheckInSummary().todayCompleted;
    const retained = restored.filter((entry: PendingVideoShare) =>
      !todayCompleted && entry.dayKey === today && RecordingRepository.get(entry.clipId) !== undefined && (entry.handedOff ||
        (entry.verification === 'self_report' && entry.chooserOpened)));
    try {
      await RecordingShareService.commit(retained);
    } catch (error) {
      if (raw.length === 0) { throw new Error('分享记录尚未准备好，请稍后重试'); }
      RecordingShareService.pending = restored;
      RecordingShareService.notify();
      console.warn('[RecordingShare] startup cleanup deferred');
      return;
    }
    for (const entry of restored) {
      if (!retained.includes(entry)) { await RecordingShareService.removeSharedCopy(entry); }
    }
    await RecordingShareService.removeOrphanedSharedCopies();
  }

  /** Compatibility accessor for callers that need the most recent attempt, including an opening chooser. */
  static getPending(): PendingVideoShare | undefined {
    const entries = RecordingShareService.pending;
    return entries.length === 0 ? undefined : RecordingShareService.copy(entries[entries.length - 1]);
  }

  static getPendingListToday(): PendingVideoShare[] {
    if (getShareCheckInSummary().todayCompleted) { return []; }
    const today = getShareCheckInTodayKey();
    return RecordingShareService.pending.filter((entry: PendingVideoShare) => entry.handedOff &&
      entry.dayKey === today && RecordingRepository.get(entry.clipId) !== undefined)
      .map((entry: PendingVideoShare) => RecordingShareService.copy(entry));
  }

  static getPendingForClipToday(clipId: string): PendingVideoShare | undefined {
    const entries = RecordingShareService.getPendingListToday().filter((entry: PendingVideoShare) => entry.clipId === clipId);
    return entries.length === 0 ? undefined : entries[entries.length - 1];
  }

  /** Extract a small JPEG cover frame for the share preview. Returns undefined (non-fatal) on any failure. */
  private static async extractVideoThumbnail(path: string, sourceWidth: number, sourceHeight: number): Promise<Uint8Array | undefined> {
    let file: fs.File | undefined = undefined;
    let avImageGenerator: media.AVImageGenerator | undefined = undefined;
    let imagePacker: image.ImagePacker | undefined = undefined;
    let pixelMap: image.PixelMap | undefined = undefined;
    try {
      file = await fs.open(path, fs.OpenMode.READ_ONLY);
      avImageGenerator = await media.createAVImageGenerator();
      avImageGenerator.fdSrc = { fd: file.fd };
      // Preserve the source aspect ratio; a fixed 16:9 box would stretch non-16:9 clips.
      const maxThumbDim = 480;
      const scale = Math.min(1, maxThumbDim / Math.max(1, sourceWidth), maxThumbDim / Math.max(1, sourceHeight));
      const thumbWidth = Math.max(2, Math.round(sourceWidth * scale));
      const thumbHeight = Math.max(2, Math.round(sourceHeight * scale));
      pixelMap = await avImageGenerator.fetchFrameByTime(
        0, media.AVImageQueryOptions.AV_IMAGE_QUERY_NEXT_SYNC, { width: thumbWidth, height: thumbHeight });
      imagePacker = image.createImagePacker();
      const packed: ArrayBuffer = await imagePacker.packing(pixelMap, { format: 'image/jpeg', quality: 80 });
      return new Uint8Array(packed);
    } catch (error) {
      return undefined;
    } finally {
      if (pixelMap !== undefined) { try { await pixelMap.release(); } catch (e) {} }
      if (imagePacker !== undefined) { try { await imagePacker.release(); } catch (e) {} }
      if (avImageGenerator !== undefined) { try { await avImageGenerator.release(); } catch (e) {} }
      if (file !== undefined) { try { await fs.close(file); } catch (e) {} }
    }
  }

  /** 通过系统授权弹窗把沙箱视频保存到相册，返回可被其他应用（微信/小红书）读取的媒体库 URI；用户取消弹窗时抛错中断分享。 */
  private static async publishToGalleryForShare(path: string, context: common.UIAbilityContext): Promise<string> {
    const source = await fs.open(path, fs.OpenMode.READ_ONLY);
    try {
      const helper = photoAccessHelper.getPhotoAccessHelper(context);
      try {
        const destinations = await helper.showAssetsCreationDialog([fileUri.getUriFromPath(path)], [{
          title: `oneBeat-share-${Date.now()}`,
          fileNameExtension: 'mp4',
          photoType: photoAccessHelper.PhotoType.VIDEO
        }]);
        if (destinations.length === 0) {
          throw new Error('已取消保存，分享未完成');
        }
        if (destinations.length !== 1 || destinations[0].length === 0) {
          throw new Error('相册保存位置无效，请重新分享');
        }
        const destination = await fs.open(destinations[0], fs.OpenMode.WRITE_ONLY);
        try {
          await fs.copyFile(source.fd, destination.fd);
        } finally {
          try { await fs.close(destination); } catch (_error) {}
        }
        return destinations[0];
      } finally {
        try { await helper.release(); } catch (_error) {}
      }
    } finally {
      try { await fs.close(source); } catch (_error) {}
    }
  }

  /** 若已通过「保存到相册」得到未过期的媒体库 URI 则直接复用，否则弹窗保存并记录，避免重复存图库。 */
  private static async resolveShareUri(path: string, clip: RecordingClip, context: common.UIAbilityContext): Promise<string> {
    const contentAt = clip.renderedAt ?? clip.createdAt;
    if (clip.albumUri !== undefined && clip.albumUri.length > 0 &&
        (clip.albumContentAt ?? 0) === contentAt) {
      return clip.albumUri;
    }
    const uri = await RecordingShareService.publishToGalleryForShare(path, context);
    await RecordingRepository.recordAlbumUri(clip.id, uri, contentAt);
    return uri;
  }

  /** Target currently labels the source button; every button uses the system chooser until platform SDKs are configured. */
  static async share(clip: RecordingClip, context: common.UIAbilityContext,
    target: RecordingShareTarget = 'system'): Promise<PendingVideoShare> {
    if (RecordingShareService.busy) { throw new Error('分享正在处理中，请稍后再试'); }
    if (!RecordingShareService.validTarget(target)) { throw new Error('分享平台无效，请重新选择'); }
    RecordingShareService.busy = true;
    let attempt: PendingVideoShare | undefined = undefined;
    try {
      const stored = RecordingRepository.get(clip.id);
      if (stored === undefined || !await fs.access(stored.path)) { throw new Error('视频文件不存在，请重新录制'); }
      attempt = {
        id: util.generateRandomUUID(true), clipId: stored.id, createdAt: Date.now(),
        dayKey: getShareCheckInTodayKey(), handedOff: false, target,
        verification: 'platform_handoff', chooserOpened: false
      };
      attempt.sharedPath = RecordingShareService.sharePath(attempt);
      // A receiver may read the URI after returning to oneBeat. Preserve its exact render while the user edits freely.
      const sharedFile = await fs.open(attempt.sharedPath, fs.OpenMode.CREATE | fs.OpenMode.TRUNC | fs.OpenMode.WRITE_ONLY);
      try { await fs.copyFile(stored.path, sharedFile.fd); } finally { await fs.close(sharedFile); }
      const current = attempt;
      await RecordingShareService.enqueue(async () => {
        await RecordingShareService.commit([...RecordingShareService.pending, current]);
      });
      // 用精确的文件类型（video.mp4）而非笼统的 general.video，接收端（微信/小红书）才能正确匹配分享能力并打开对应页面。
      const videoUtd = uniformTypeDescriptor.getUniformDataTypeByFilenameExtension('.mp4', uniformTypeDescriptor.UniformDataType.VIDEO);
      const shareSourcePath: string = current.sharedPath ?? stored.path;
      const thumbnail = await RecordingShareService.extractVideoThumbnail(shareSourcePath, stored.width, stored.height);
      // 优先复用「保存到相册」已产生的媒体库 URI，没有才弹窗保存，避免重复存图库。
      const galleryUri = await RecordingShareService.resolveShareUri(shareSourcePath, stored, context);
      const data = new systemShare.SharedData({
        utd: videoUtd,
        uri: galleryUri, title: '同拍 · 一起行进',
        description: '记录这一段同拍时刻。分享完成后回到同拍，点击票根页的“去打卡”确认。',
        thumbnail: thumbnail
      });
      const controller = new systemShare.ShareController(data);
      RecordingShareService.controllers.set(current.id, controller);
      // Old runtimes can silently accept an unknown event, so registration success alone cannot prove support.
      let callbackSupported: boolean = deviceInfo.sdkApiVersion >= 18;
      let dismissed: boolean = false;
      if (callbackSupported) {
        try {
          controller.on('shareCompleted', (result: systemShare.ShareOperationResult) => {
            const name = result.targetAbilityInfo?.name ?? '';
            // Save/copy/print and dismiss are system operations, not a handoff to a publishing or messaging app.
            if (name.length === 0 || name.startsWith('SystemShare_')) { return; }
            void RecordingShareService.markHandedOff(current.id).catch(() => {
              console.warn('[RecordingShare] handoff record could not be saved');
            });
          });
        } catch (_error) {
          // Some newer devices may still reject registration; use the same explicit self-report fallback.
          callbackSupported = false;
          console.warn('[RecordingShare] target handoff callback unavailable');
        }
      }
      controller.on('dismiss', () => {
        dismissed = true;
        // Dismiss can precede a receiver's completion; keeping an unhanded attempt hidden permits the later callback.
        void RecordingShareService.dismissChooser(current.id).catch(() => {
          console.warn('[RecordingShare] chooser cleanup could not be saved');
        });
      });
      try {
        await controller.show(context, {
          previewMode: systemShare.SharePreviewMode.DETAIL,
          selectionMode: systemShare.SelectionMode.SINGLE
        });
      } catch (_error) {
        throw new Error('未能打开系统分享面板，请稍后重试');
      }
      await RecordingShareService.enqueue(async () => {
        const next = RecordingShareService.pending.map((entry: PendingVideoShare) => {
          const copy = RecordingShareService.copy(entry);
          if (copy.id === current.id) {
            copy.chooserOpened = true;
            copy.verification = callbackSupported ? 'platform_handoff' : 'self_report';
          }
          return copy;
        });
        await RecordingShareService.commit(next);
      });
      if (!callbackSupported && dismissed) { await RecordingShareService.markReturnedToApp(); }
      return RecordingShareService.copy(RecordingShareService.pending.find((entry: PendingVideoShare) =>
        entry.id === current.id) ?? current);
    } catch (error) {
      if (attempt !== undefined) {
        await RecordingShareService.dismissPending(attempt.id);
        await RecordingShareService.removeSharedCopy(attempt);
      }
      throw new Error(error instanceof Error ? error.message : '分享未完成，请稍后重试');
    } finally {
      RecordingShareService.busy = false;
    }
  }

  static confirmPublished(attemptId: string): Promise<ShareCheckInResult> {
    const task = RecordingShareService.operation.then(async (): Promise<ShareCheckInResult> => {
      const pending = RecordingShareService.pending.find((entry: PendingVideoShare) => entry.id === attemptId);
      if (pending === undefined || !pending.handedOff || RecordingRepository.get(pending.clipId) === undefined) {
        throw new Error('没有待确认的分享，请先分享一段录制视频');
      }
      if (pending.dayKey !== getShareCheckInTodayKey()) {
        throw new Error('这次分享不是今天的记录，请重新分享后确认今日打卡');
      }
      // The ledger consumes attemptId durably before cleanup, so a crash replay cannot claim another day or reward.
      const result = await acceptShareCheckIn(pending.id);
      try {
        await RecordingShareService.removeAttempts(RecordingShareService.pending.filter((entry: PendingVideoShare) =>
          entry.dayKey === result.dayKey).map((entry: PendingVideoShare) => entry.id));
      } catch (_error) {
        // The check-in is already durable. Cleanup must not turn success into an error or request another reward.
        console.warn('[RecordingShare] completed day cleanup deferred until restart');
      }
      return result;
    });
    RecordingShareService.operation = task.then(() => {}, () => {});
    return task;
  }

  /** A foreground/page return can expose old-system self-report todos; reward still requires an explicit user tap. */
  static markReturnedToApp(): Promise<void> {
    return RecordingShareService.enqueue(async () => {
      const today = getShareCheckInTodayKey();
      let changed = false;
      const next = RecordingShareService.pending.map((entry: PendingVideoShare) => {
        const copy = RecordingShareService.copy(entry);
        if (copy.verification === 'self_report' && copy.chooserOpened && !copy.handedOff && copy.dayKey === today) {
          copy.handedOff = true;
          copy.handedOffAt = Date.now();
          changed = true;
        }
        return copy;
      });
      if (changed) { await RecordingShareService.commit(next); }
      if (getShareCheckInSummary().todayCompleted) {
        await RecordingShareService.removeAttempts(RecordingShareService.pending.filter((entry: PendingVideoShare) =>
          entry.dayKey === today && entry.handedOff).map((entry: PendingVideoShare) => entry.id));
      }
    });
  }

  static dismissPending(attemptId: string): Promise<void> {
    return RecordingShareService.enqueue(async () => { await RecordingShareService.removeAttempts([attemptId]); });
  }

  /** Deleting a work removes only its unfinished attempts; the separate historical check-in ledger is retained. */
  static dismissForClip(clipId: string): Promise<void> {
    return RecordingShareService.enqueue(async () => {
      await RecordingShareService.removeAttempts(RecordingShareService.pending.filter((entry: PendingVideoShare) =>
        entry.clipId === clipId).map((entry: PendingVideoShare) => entry.id));
    });
  }

  private static markHandedOff(attemptId: string): Promise<void> {
    return RecordingShareService.enqueue(async () => {
      const next = RecordingShareService.pending.map((entry: PendingVideoShare) => {
        const copy = RecordingShareService.copy(entry);
        if (copy.id === attemptId) {
          copy.handedOff = true;
          copy.handedOffAt = Date.now();
          copy.dayKey = getShareCheckInTodayKey();
        }
        return copy;
      });
      await RecordingShareService.commit(next);
      if (getShareCheckInSummary().todayCompleted) { await RecordingShareService.removeAttempts([attemptId]); }
    });
  }

  private static dismissChooser(attemptId: string): Promise<void> {
    const task = RecordingShareService.enqueue(async () => {
      RecordingShareService.controllers.delete(attemptId);
    });
    return task.then(() => RecordingShareService.markReturnedToApp());
  }

  private static async removeAttempts(ids: string[]): Promise<void> {
    const removed = RecordingShareService.pending.filter((entry: PendingVideoShare) => ids.includes(entry.id));
    if (removed.length === 0) { return; }
    await RecordingShareService.commit(RecordingShareService.pending.filter((entry: PendingVideoShare) => !ids.includes(entry.id)));
    for (const entry of removed) {
      RecordingShareService.controllers.delete(entry.id);
      await RecordingShareService.removeSharedCopy(entry);
    }
  }

  private static async removeSharedCopy(entry: PendingVideoShare): Promise<void> {
    if (RecordingShareService.validId(entry.id) && RecordingShareService.validId(entry.clipId) &&
      entry.sharedPath !== undefined && entry.sharedPath === RecordingShareService.sharePath(entry)) {
      try { if (await fs.access(entry.sharedPath)) { await fs.unlink(entry.sharedPath); } } catch (_error) {}
    }
  }

  private static async removeOrphanedSharedCopies(): Promise<void> {
    // A previous unlink may have failed after its pending snapshot committed. Sweep only our strict private filenames.
    try {
      const retained = RecordingShareService.pending.map((entry: PendingVideoShare) => entry.sharedPath ?? '');
      for (const name of await fs.listFile(RecordingShareService.directory)) {
        if (/^[A-Za-z0-9_-]{1,128}\.share-[A-Za-z0-9_-]{1,128}\.mp4$/.test(name)) {
          const path = `${RecordingShareService.directory}/${name}`;
          if (!retained.includes(path)) { await fs.unlink(path); }
        }
      }
    } catch (_error) {
      console.warn('[RecordingShare] obsolete video copy cleanup deferred');
    }
  }

  private static enqueue(action: () => Promise<void>): Promise<void> {
    const task = RecordingShareService.operation.then(action);
    RecordingShareService.operation = task.catch(() => {});
    return task;
  }

  private static sharePath(entry: PendingVideoShare): string {
    if (!RecordingShareService.validId(entry.id) || !RecordingShareService.validId(entry.clipId)) {
      throw new Error('分享记录无效，请重新选择作品');
    }
    return `${RecordingShareService.directory}/${entry.clipId}.share-${entry.id}.mp4`;
  }

  private static validId(id: string): boolean {
    // Both IDs become one filename: restoring a local record must never allow traversal outside recordings.
    return typeof id === 'string' && /^[A-Za-z0-9_-]{1,128}$/.test(id);
  }

  private static copy(entry: PendingVideoShare): PendingVideoShare {
    return { id: entry.id, clipId: entry.clipId, createdAt: entry.createdAt, dayKey: entry.dayKey,
      handedOff: entry.handedOff, handedOffAt: entry.handedOffAt, verification: entry.verification,
      chooserOpened: entry.chooserOpened, target: entry.target, sharedPath: entry.sharedPath };
  }

  private static validTarget(target: RecordingShareTarget): boolean {
    return target === 'system' || target === 'wechat' || target === 'moments' || target === 'qq' ||
      target === 'weibo' || target === 'rednote';
  }

  private static async commit(attempts: PendingVideoShare[]): Promise<void> {
    if (RecordingShareService.snapshotPath.length === 0) { throw new Error('分享记录尚未准备好，请稍后重试'); }
    const snapshot: PendingSharesSnapshot = { version: 2, attempts };
    await writeAtomic(RecordingShareService.snapshotPath, JSON.stringify(snapshot));
    RecordingShareService.pending = attempts;
    RecordingShareService.notify();
  }

  private static notify(): void {
    AppStorage.setOrCreate('recordingShareEpoch', (AppStorage.get<number>('recordingShareEpoch') ?? 0) + 1);
  }
}
