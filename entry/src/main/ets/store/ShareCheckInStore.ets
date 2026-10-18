import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { MonotonicClock } from '../common/MonotonicClock';
import { readOptional, writeAtomic } from '../common/AtomicTextFile';
import { isMonthlyPassActive, isMonthlyPassRewardStateKnown, waitForMonthlyPassCache } from './EntitlementStore';
import {
  beijingDayIndex, emptyShareCheckInSnapshot, reduceShareCheckIn, ShareCheckInDay,
  ShareCheckInResult, ShareCheckInSnapshot, visibleShareStreak
} from './ShareCheckInRules';

export { ShareCheckInDay, ShareCheckInResult } from './ShareCheckInRules';

const PREFERENCES_NAME: string = 'onebeat_share_check_in';
const SNAPSHOT_KEY: string = 'snapshot_v1';
const CLOCK_ROLLBACK_TOLERANCE_MS: number = 120000;
const CLOCK_CHECKPOINT_INTERVAL_MS: number = 60000;

export interface ShareCheckInSummary {
  streakDays: number;
  todayCompleted: boolean;
  todayRewarded: boolean;
  trialExpiresAt: number;
  history: ShareCheckInDay[];
  clockBlocked: boolean;
  ready: boolean;
}

interface ShareCheckInClockWatermark {
  version: number;
  lastObservedWallMs: number;
}

let snapshot: ShareCheckInSnapshot = emptyShareCheckInSnapshot();
let snapshotFilePath: string = '';
let clockWatermarkPath: string = '';
let initialization: Promise<void> | undefined = undefined;
let mutations: Promise<void> = Promise.resolve();
let checkpointTimer: number = -1;
let wallAnchorMs: number = 0;
let monoAnchorMs: number = 0;
let ready: boolean = false;

function effectiveNow(): number {
  return Math.max(Date.now(), snapshot.lastObservedWallMs,
    wallAnchorMs + Math.max(0, MonotonicClock.nowMs() - monoAnchorMs));
}

function clockBlocked(): boolean {
  return Date.now() + CLOCK_ROLLBACK_TOLERANCE_MS < effectiveNow();
}

function projectSnapshot(notifyCheckIn: boolean = true): void {
  const previousExpiry = AppStorage.get<number>('shareTrialExpiresAt') ?? 0;
  const previouslyReady = AppStorage.get<boolean>('shareCheckInReady') ?? false;
  AppStorage.setOrCreate('shareTrialExpiresAt', snapshot.trialExpiresAt);
  AppStorage.setOrCreate('shareLastObservedWallMs', snapshot.lastObservedWallMs);
  AppStorage.setOrCreate('shareTrialClockWallAnchor', wallAnchorMs);
  AppStorage.setOrCreate('shareTrialClockMonoAnchor', monoAnchorMs);
  AppStorage.setOrCreate('shareCheckInReady', ready);
  if (notifyCheckIn) {
    AppStorage.setOrCreate('shareCheckInEpoch', (AppStorage.get<number>('shareCheckInEpoch') ?? 0) + 1);
  }
  if (previousExpiry !== snapshot.trialExpiresAt || previouslyReady !== ready) {
    AppStorage.setOrCreate('storeEntitlementEpoch', (AppStorage.get<number>('storeEntitlementEpoch') ?? 0) + 1);
  }
}

function validSnapshot(value: ShareCheckInSnapshot): boolean {
  if (value.schemaVersion !== 1 || !Array.isArray(value.days) || !Array.isArray(value.consumedAttempts) ||
    !Number.isFinite(value.trialExpiresAt) || value.trialExpiresAt < 0 ||
    !Number.isFinite(value.lastObservedWallMs) || value.lastObservedWallMs < 0) {
    return false;
  }
  let lastDay = -1;
  for (let i = 0; i < value.days.length; i++) {
    const day = value.days[i];
    if (day.dayIndex <= lastDay || !Number.isInteger(day.dayIndex) || day.streakOrdinal < 1 ||
      !Number.isFinite(day.firstAcceptedAt) || typeof day.dayKey !== 'string' ||
      typeof day.rewardGranted !== 'boolean' || !Number.isFinite(day.trialExpiresAt)) {
      return false;
    }
    lastDay = day.dayIndex;
  }
  return value.consumedAttempts.every((attempt) => typeof attempt.attemptId === 'string' &&
    attempt.attemptId.length > 0 && typeof attempt.result.dayKey === 'string');
}

async function persist(next: ShareCheckInSnapshot): Promise<void> {
  if (snapshotFilePath.length === 0) {
    throw new Error('打卡记录尚未准备好，请稍后重试');
  }
  // Preferences strings are limited to 8192 characters. Keep the growing day
  // and deduplication ledger in one atomically replaced private file instead.
  await writeAtomic(snapshotFilePath, JSON.stringify(next));
  snapshot = next;
  projectSnapshot();
}

async function initialize(context: common.Context): Promise<void> {
  snapshotFilePath = `${context.filesDir}/share-check-in-v1.json`;
  clockWatermarkPath = `${context.filesDir}/clock-watermark-v1.json`;
  let raw = await readOptional(snapshotFilePath);
  if (raw.length === 0) {
    const legacy = await preferences.getPreferences(context, PREFERENCES_NAME);
    raw = await legacy.get(SNAPSHOT_KEY, '') as string;
  }
  if (raw.length > 0) {
    const restored = JSON.parse(raw) as ShareCheckInSnapshot;
    if (!validSnapshot(restored)) {
      throw new Error('本机打卡记录无法读取，请保留数据后重试');
    }
    snapshot = restored;
  }
  const watermarkRaw = await readOptional(clockWatermarkPath);
  let persistedWatermark = 0;
  if (watermarkRaw.length > 0) {
    const watermark = JSON.parse(watermarkRaw) as ShareCheckInClockWatermark;
    if (watermark.version !== 1 || !Number.isFinite(watermark.lastObservedWallMs) || watermark.lastObservedWallMs < 0) {
      throw new Error('本机试用时间记录无法读取，请稍后重试');
    }
    persistedWatermark = watermark.lastObservedWallMs;
  }
  monoAnchorMs = MonotonicClock.nowMs();
  wallAnchorMs = Math.max(Date.now(), snapshot.lastObservedWallMs, persistedWatermark);
  const next = JSON.parse(JSON.stringify(snapshot)) as ShareCheckInSnapshot;
  next.lastObservedWallMs = wallAnchorMs;
  await persist(next);
  ready = true;
  projectSnapshot();
  if (checkpointTimer < 0) {
    checkpointTimer = setInterval(() => {
      if (ready && snapshot.trialExpiresAt > effectiveNow()) {
        void refreshShareCheckInClock().catch(() => console.warn('[ShareCheckIn] clock checkpoint failed'));
      }
    }, CLOCK_CHECKPOINT_INTERVAL_MS);
  }
}

/** Per-install ledger; it is independent of account bootstrap and session transport. */
export async function initializeShareCheckInStore(context: common.Context): Promise<void> {
  if (initialization === undefined) {
    initialization = initialize(context).catch((error: Error) => {
      initialization = undefined;
      throw error;
    });
  }
  await initialization;
}

export function getShareCheckInSummary(): ShareCheckInSummary {
  const now = effectiveNow();
  const today = snapshot.days.find((day: ShareCheckInDay) => day.dayIndex === beijingDayIndex(now));
  const history = JSON.parse(JSON.stringify(snapshot.days)) as ShareCheckInDay[];
  return {
    streakDays: visibleShareStreak(snapshot, now), todayCompleted: today !== undefined,
    todayRewarded: today?.rewardGranted ?? false, trialExpiresAt: snapshot.trialExpiresAt,
    history: history.reverse(), clockBlocked: clockBlocked(), ready
  };
}

/** Call only after the share service has verified a handed-off local recording. */
export function acceptShareCheckIn(attemptId: string): Promise<ShareCheckInResult> {
  const operation = mutations.then(async (): Promise<ShareCheckInResult> => {
    if (!ready || snapshotFilePath.length === 0) {
      throw new Error('打卡记录尚未准备好，请稍后重试');
    }
    if (attemptId.trim().length === 0 || attemptId.length > 256) {
      throw new Error('分享记录无效，请重新分享');
    }
    // Replaying an already committed request must work even after a clock edit;
    // its original calendar day can never acquire another reward.
    const replay = snapshot.consumedAttempts.find((attempt) => attempt.attemptId === attemptId);
    if (replay !== undefined) {
      return reduceShareCheckIn(snapshot, attemptId, effectiveNow(), false).result;
    }
    await waitForMonthlyPassCache();
    if (clockBlocked()) {
      throw new Error('设备时间发生回拨，请开启自动时间后再确认打卡');
    }
    if (!isMonthlyPassRewardStateKnown()) {
      throw new Error('月卡状态暂时无法核对，请稍后重试；本次分享会保留');
    }
    if (AppStorage.get<boolean>('storePurchasePending') === true) {
      throw new Error('月卡购买结果待确认，请完成购买后再确认分享');
    }
    const now = effectiveNow();
    const reduced = reduceShareCheckIn(snapshot, attemptId, now, isMonthlyPassActive(now));
    await persist(reduced.snapshot);
    return reduced.result;
  });
  mutations = operation.then(() => {}).catch(() => {});
  return operation;
}

/** Foreground checkpoints prevent a restart from making a previous trial younger. */
export function refreshShareCheckInClock(): Promise<void> {
  const operation = mutations.then(async (): Promise<void> => {
    if (!ready) {
      return;
    }
    const now = effectiveNow();
    const watermark: ShareCheckInClockWatermark = { version: 1, lastObservedWallMs: now };
    // A minute checkpoint may run during synchronized playback. Its work stays
    // bounded as years of share history grow; full ledger serialization belongs
    // to explicit share confirmation, whose UI protects the playback boundary.
    await writeAtomic(clockWatermarkPath, JSON.stringify(watermark));
    snapshot = {
      schemaVersion: snapshot.schemaVersion, days: snapshot.days,
      consumedAttempts: snapshot.consumedAttempts, trialExpiresAt: snapshot.trialExpiresAt,
      lastObservedWallMs: now
    };
    projectSnapshot(false);
  });
  mutations = operation.catch(() => {});
  return operation;
}
