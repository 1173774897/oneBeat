export const SHARE_CHECK_IN_DAY_MS: number = 86400000;
const BEIJING_OFFSET_MS: number = 8 * 3600000;

export interface ShareCheckInDay {
  dayKey: string;
  dayIndex: number;
  firstAcceptedAt: number;
  streakOrdinal: number;
  rewardGranted: boolean;
  memberSkipped: boolean;
  trialExpiresAt: number;
  shareCount: number;
}

export interface ShareCheckInResult {
  streakDays: number;
  rewardGranted: boolean;
  monthlySkipped: boolean;
  trialExpiresAt: number;
  alreadyProcessed: boolean;
  dayKey: string;
}

export interface ConsumedShareAttempt {
  attemptId: string;
  result: ShareCheckInResult;
}

export interface ShareCheckInSnapshot {
  schemaVersion: number;
  days: ShareCheckInDay[];
  consumedAttempts: ConsumedShareAttempt[];
  trialExpiresAt: number;
  lastObservedWallMs: number;
}

export interface ShareCheckInReduction {
  snapshot: ShareCheckInSnapshot;
  result: ShareCheckInResult;
}

export function beijingDayIndex(now: number): number {
  return Math.floor((now + BEIJING_OFFSET_MS) / SHARE_CHECK_IN_DAY_MS);
}

export function beijingDayKey(now: number): string {
  return new Date(now + BEIJING_OFFSET_MS).toISOString().substring(0, 10);
}

export function emptyShareCheckInSnapshot(): ShareCheckInSnapshot {
  return { schemaVersion: 1, days: [], consumedAttempts: [], trialExpiresAt: 0, lastObservedWallMs: 0 };
}

export function visibleShareStreak(snapshot: ShareCheckInSnapshot, now: number): number {
  if (snapshot.days.length === 0) {
    return 0;
  }
  const latest = snapshot.days[snapshot.days.length - 1];
  const gap = beijingDayIndex(now) - latest.dayIndex;
  return gap === 0 || gap === 1 ? latest.streakOrdinal : 0;
}

/** A confirmed attempt is consumed with its day and reward in the same snapshot. */
export function reduceShareCheckIn(snapshot: ShareCheckInSnapshot, attemptId: string,
  now: number, monthlyActive: boolean): ShareCheckInReduction {
  for (let i = 0; i < snapshot.consumedAttempts.length; i++) {
    const consumed = snapshot.consumedAttempts[i];
    if (consumed.attemptId === attemptId) {
      const original = consumed.result;
      const result: ShareCheckInResult = {
        streakDays: original.streakDays, rewardGranted: false,
        monthlySkipped: original.monthlySkipped, trialExpiresAt: original.trialExpiresAt,
        alreadyProcessed: true, dayKey: original.dayKey
      };
      return { snapshot, result };
    }
  }
  const next = JSON.parse(JSON.stringify(snapshot)) as ShareCheckInSnapshot;
  const today = beijingDayIndex(now);
  let entry: ShareCheckInDay | undefined = next.days.find((day: ShareCheckInDay) => day.dayIndex === today);
  if (entry === undefined) {
    const previous = next.days.length > 0 ? next.days[next.days.length - 1] : undefined;
    entry = {
      dayKey: beijingDayKey(now), dayIndex: today, firstAcceptedAt: now,
      streakOrdinal: previous !== undefined && previous.dayIndex === today - 1 ? previous.streakOrdinal + 1 : 1,
      rewardGranted: false, memberSkipped: false, trialExpiresAt: 0, shareCount: 0
    };
    next.days.push(entry);
  }
  entry.shareCount++;
  const eligible = entry.streakOrdinal >= 3 && !entry.rewardGranted;
  const rewardGranted = eligible && !monthlyActive;
  // Membership still records a day, but does not consume its eventual reward.
  if (monthlyActive) {
    entry.memberSkipped = true;
  }
  if (rewardGranted) {
    entry.rewardGranted = true;
    entry.trialExpiresAt = now + SHARE_CHECK_IN_DAY_MS;
    next.trialExpiresAt = entry.trialExpiresAt;
  }
  next.lastObservedWallMs = Math.max(next.lastObservedWallMs, now);
  const result: ShareCheckInResult = {
    streakDays: entry.streakOrdinal, rewardGranted, monthlySkipped: monthlyActive,
    trialExpiresAt: next.trialExpiresAt, alreadyProcessed: false, dayKey: entry.dayKey
  };
  next.consumedAttempts.push({ attemptId, result });
  return { snapshot: next, result };
}
