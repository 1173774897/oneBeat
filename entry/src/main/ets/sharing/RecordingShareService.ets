import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { fileIo as fs, fileUri } from '@kit.CoreFileKit';
import { systemShare } from '@kit.ShareKit';
import { uniformTypeDescriptor } from '@kit.ArkData';
import { util } from '@kit.ArkTS';
import { RecordingClip } from '../recording/RecordingModels';
import { RecordingRepository } from '../recording/RecordingRepository';
import { acceptShareCheckIn, ShareCheckInResult } from '../store/ShareCheckInStore';

const SHARE_PREFERENCES: string = 'onebeat_video_share';
const PENDING_KEY: string = 'pendingVideoShareV1';

export interface PendingVideoShare {
  id: string;
  clipId: string;
  createdAt: number;
  handedOff: boolean;
}

/** System handoff is not publication proof. Only explicit user confirmation records a check-in. */
export class RecordingShareService {
  private static pref: preferences.Preferences | undefined = undefined;
  private static pending: PendingVideoShare | undefined = undefined;
  private static controller: systemShare.ShareController | undefined = undefined;
  private static operation: Promise<void> = Promise.resolve();
  private static busy: boolean = false;

  static async initialize(context: common.Context): Promise<void> {
    const pref = await preferences.getPreferences(context, SHARE_PREFERENCES);
    const raw = await pref.get(PENDING_KEY, '') as string;
    let pending: PendingVideoShare | undefined = undefined;
    if (raw.length > 0) {
      try {
        const entry = JSON.parse(raw) as PendingVideoShare;
        if (typeof entry.id === 'string' && entry.id.length > 0 && typeof entry.clipId === 'string' &&
          Number.isFinite(entry.createdAt) && RecordingRepository.get(entry.clipId) !== undefined) {
          pending = entry;
        }
      } catch (_error) {
        throw new Error('分享记录读取失败，请重启应用后重试');
      }
    }
    RecordingShareService.pref = pref;
    RecordingShareService.pending = pending;
    RecordingShareService.notify();
  }

  static getPending(): PendingVideoShare | undefined {
    const entry = RecordingShareService.pending;
    return entry === undefined ? undefined : {
      id: entry.id, clipId: entry.clipId, createdAt: entry.createdAt, handedOff: entry.handedOff
    };
  }

  static async share(clip: RecordingClip, context: common.UIAbilityContext): Promise<PendingVideoShare> {
    if (RecordingShareService.busy) {
      throw new Error('分享正在处理中，请稍后再试');
    }
    RecordingShareService.busy = true;
    try {
      const stored = RecordingRepository.get(clip.id);
      if (stored === undefined || !await fs.access(stored.path)) {
        throw new Error('视频文件不存在，请重新录制');
      }
      if (RecordingShareService.pending !== undefined) {
        throw new Error('请先确认或取消上一次分享，再发起新的分享');
      }
      const attempt: PendingVideoShare = {
        id: util.generateRandomUUID(true), clipId: stored.id, createdAt: Date.now(), handedOff: false
      };
      await RecordingShareService.commit(attempt);
      const data = new systemShare.SharedData({
        utd: uniformTypeDescriptor.UniformDataType.VIDEO,
        uri: fileUri.getUriFromPath(stored.path), title: 'oneBeat · 一起行进',
        description: '记录这一段同拍时刻。请选择小红书，发布完成后回到 oneBeat 确认今日打卡。'
      });
      const controller = new systemShare.ShareController(data);
      RecordingShareService.controller = controller;
      try {
        await controller.show(context, {
          previewMode: systemShare.SharePreviewMode.DETAIL,
          selectionMode: systemShare.SelectionMode.SINGLE
        });
        // This flag only enables the honest self-report flow; neither show nor dismiss grants a reward.
        const handedOff: PendingVideoShare = {
          id: attempt.id, clipId: attempt.clipId, createdAt: attempt.createdAt, handedOff: true
        };
        await RecordingShareService.commit(handedOff);
        return handedOff;
      } catch (_error) {
        await RecordingShareService.commit(undefined);
        throw new Error('未能打开系统分享面板，请稍后重试');
      } finally {
        RecordingShareService.controller = undefined;
      }
    } finally {
      RecordingShareService.busy = false;
    }
  }

  static confirmPublished(attemptId: string): Promise<ShareCheckInResult> {
    const task = RecordingShareService.operation.then(async (): Promise<ShareCheckInResult> => {
      const pending = RecordingShareService.pending;
      if (pending === undefined || pending.id !== attemptId || !pending.handedOff ||
        RecordingRepository.get(pending.clipId) === undefined) {
        throw new Error('没有待确认的小红书分享，请先分享一段录制视频');
      }
      // The ledger consumes attemptId durably, so replay after a crash cannot claim another day.
      const result = await acceptShareCheckIn(pending.id);
      await RecordingShareService.commit(undefined);
      return result;
    });
    RecordingShareService.operation = task.then(() => {}, () => {});
    return task;
  }

  static dismissPending(attemptId: string): Promise<void> {
    const task = RecordingShareService.operation.then(async () => {
      if (RecordingShareService.busy) {
        throw new Error('分享正在处理中，请稍后再试');
      }
      if (RecordingShareService.pending?.id === attemptId) {
        await RecordingShareService.commit(undefined);
      }
    });
    RecordingShareService.operation = task.catch(() => {});
    return task;
  }

  private static async commit(pending: PendingVideoShare | undefined): Promise<void> {
    const pref = RecordingShareService.pref;
    if (pref === undefined) {
      throw new Error('分享记录尚未准备好，请稍后重试');
    }
    await pref.put(PENDING_KEY, pending === undefined ? '' : JSON.stringify(pending));
    await pref.flush();
    RecordingShareService.pending = pending;
    RecordingShareService.notify();
  }

  private static notify(): void {
    AppStorage.setOrCreate('recordingPendingClipId', RecordingShareService.pending?.clipId ?? '');
    AppStorage.setOrCreate('recordingShareEpoch', (AppStorage.get<number>('recordingShareEpoch') ?? 0) + 1);
  }
}
