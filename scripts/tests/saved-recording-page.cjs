const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const ts = require(process.argv[2] || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');

const source = fs.readFileSync('entry/src/main/ets/pages/SavedRecordingPage.ets', 'utf8');
const comicInkOffsets = Object.fromEntries([...fs.readFileSync('entry/src/main/ets/components/ComicInkSurface.ets', 'utf8')
  .matchAll(/export const (COMIC_[A-Z_]+): number = ([\d.]+);/g)].map(match => [match[1], Number(match[2])]));
assert.match(source, /private shareButton\(\) \{\s*ActionButton\(\{\s*active: !this\.busy && this\.savedClip !== undefined,[\s\S]*?hardShadow: \{ offsetX: COMIC_CARD_INK_OFFSET, offsetY: COMIC_CARD_INK_OFFSET, color: INK \},[\s\S]*?action: \(\) => this\.requestShare\(\)/,
  'Sharing retains its unavailable-work gate, solid backing and explicit share action');
assert.match(source, /ActionButton\(\{\s*label: this\.checkingIn \? '记卡中…' : '去打卡', active: !this\.busy,[\s\S]*?action: \(\) => \{ void this\.confirmToday\(\); \}/,
  'Daily check-in stays disabled during work and requires a deliberate confirmation');
const business = (source.slice(0, source.indexOf('  @Builder')) + '\n}')
  .replace(/^import[\s\S]*?from\s+['"][^'"]+['"];\s*/gm, '')
  .replace(/@(?:Entry|Component)\b\s*/g, '').replace(/@State\s+/g, '')
  .replace(/@(?:StorageLink|Watch)\([^)]*\)\s*/g, '')
  .replace('struct SavedRecordingPage', 'export class SavedRecordingPage');
const compiled = ts.transpileModule(business, {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 }, reportDiagnostics: true
});
assert.equal(compiled.diagnostics.filter(item => item.category === ts.DiagnosticCategory.Error).length, 0);

function harness() {
  const trace = [], notices = [];
  let stored = { id: 'take', path: '/private/current.mp4', durationMs: 3200 };
  let pending;
  let todayCompleted = false;
  let now = Date.parse('2026-10-19T12:00:00+08:00');
  let timerId = 0;
  const timers = new Map();
  class PageDate extends Date { static now() { return now; } }
  const todayKey = () => new Date(now + 8 * 3600000).toISOString().substring(0, 10);
  const controller = { isLeader: true, state: 'paused' };
  let session = { controller, async leaderPause() { trace.push('pause'); controller.state = 'paused'; } };
  const context = { exports: {}, WHITE: '#fff', INK: '#000', Date: PageDate,
    ...comicInkOffsets,
    SHARE_CHECK_IN_DAY_MS: 86400000,
    getShareCheckInSummary: () => ({ todayCompleted, ready: true, clockBlocked: false }),
    getShareCheckInTodayKey: todayKey,
    setTimeout: (callback, delay) => { timers.set(++timerId, { callback, delay }); return timerId; },
    clearTimeout: id => timers.delete(id),
    router: { getParams: () => ({ clipId: 'take', scope: 'team' }) },
    AppSession: { get: () => session },
    RecordingRepository: {
      get: id => stored?.id === id ? { ...stored } : undefined,
      async ensureCover(id) { trace.push(`cover:${id}`); stored = { ...stored, coverPath: '/private/real.jpg' }; }
    },
    RecordingShareService: {
      async markReturnedToApp() {},
      async share(clip, host, target) { trace.push(`share:${target}:${clip.path}`); },
      getPendingForClipToday: id => !todayCompleted && pending?.clipId === id && pending.handedOff &&
        pending.dayKey === todayKey() && stored !== undefined ? pending : undefined,
      async confirmPublished(id) {
        trace.push(`confirm:${id}`); todayCompleted = true; pending = undefined;
        return { streakDays: 3, rewardGranted: true, trialExpiresAt: now + 86400000 };
      }
    },
    fileUri: { getUriFromPath: value => `file://${value}` },
    logUserFailure() {}, showUserNotice: value => notices.push(value), userErrorMessage: (_error, fallback) => fallback
  };
  vm.runInNewContext(compiled.outputText, context);
  const page = new context.exports.SavedRecordingPage();
  page.hostContext = () => ({});
  page.aboutToAppear();
  return { page, trace, notices, controller, get session() { return session; }, set session(value) { session = value; },
    timers, setNow(value) { now = value; }, setCompleted(value) { todayCompleted = value; },
    setPending(value) { pending = value === undefined ? undefined : { dayKey: todayKey(), handedOff: true, ...value }; },
    setStored(value) { stored = value; }, context };
}

async function flush() { for (let index = 0; index < 20; index++) { await Promise.resolve(); } }

(async () => {
  {
    const h = harness();
    await flush();
    assert.deepEqual(h.trace, ['cover:take'], 'Opening the saved page only derives a real cover; it neither shares nor checks in');
    assert.equal(h.page.coverSource(), 'file:///private/real.jpg');
    assert.equal(h.page.durationLabel(), '00:03');
    assert.equal(h.page.practiceLabel(), '多人练习 · 00:03', 'Legacy works use the originating library scope');
    h.page.requestShare();
    await flush();
    assert.equal(h.trace.at(-1), 'share:system:/private/current.mp4', 'The single share entry hands the current video to the real system chooser');
    assert.equal(h.page.busy, false);
    h.setPending({ id: 'attempt', clipId: 'take', handedOff: true });
    h.page.onPageHide(); h.page.refreshShareStatus();
    assert.equal(h.notices.length, 0, 'A background share callback must not interrupt another app with a notice');
    h.page.onPageShow(); h.page.refreshShareStatus();
    await flush();
    assert.equal(h.page.canCheckInToday, true, 'Returning with an eligible share enables the ticket action');
    assert.equal(h.page.calendarVisible, false, 'Returning never confirms publication or opens a popup automatically');
    assert.equal(h.notices.length, 0, 'The inline ticket action replaces the old work-list guidance');
    assert.equal(h.trace.some(value => value.startsWith('confirm:')), false);
  }
  {
    const h = harness(); await flush();
    h.controller.state = 'playing'; h.controller.isLeader = false;
    h.page.requestShare(); await flush();
    assert.equal(h.page.pauseConfirmVisible, false);
    assert.equal(h.trace.some(value => value === 'pause' || value.startsWith('share:')), false,
      'A member must never pause the team or launch an external share during live practice');
    assert.match(h.notices.at(-1), /等队长暂停/);
  }
  {
    const h = harness(); await flush();
    h.controller.state = 'countdown';
    h.page.requestShare(); await flush();
    assert.equal(h.page.pauseConfirmVisible, true);
    assert.deepEqual(h.trace, ['cover:take'], 'Requesting a share cannot automatically pause the leader');
    await h.page.pauseAndShare();
    assert.deepEqual(h.trace.slice(-2), ['pause', 'share:system:/private/current.mp4']);
    assert.equal(h.page.pauseConfirmVisible, false);
  }
  {
    const h = harness(); await flush();
    h.controller.state = 'playing';
    h.session.leaderPause = async () => {
      h.trace.push('pause');
      h.session = { controller: { state: 'paused', isLeader: true } };
    };
    h.page.requestShare(); await h.page.pauseAndShare();
    assert.equal(h.trace.some(value => value.startsWith('share:')), false,
      'A changed session during pause invalidates the pending external share');
    assert.match(h.notices.at(-1), /练习状态已变化/);
    assert.equal(h.page.busy, false);
  }
  {
    const h = harness(); await flush();
    h.context.RecordingShareService.share = async () => { throw new Error('native failure'); };
    h.page.requestShare(); await flush();
    assert.equal(h.page.busy, false, 'A chooser failure leaves the share control usable for retry');
    assert.match(h.notices.at(-1), /未能打开系统分享面板/);
    h.setStored(undefined); h.page.requestShare(); await flush();
    assert.match(h.notices.at(-1), /前往相册/);
  }
  {
    const h = harness(); await flush();
    assert.equal(h.page.canCheckInToday, false, 'Saving a video without sharing keeps one full-width action');
    h.setPending({ id: 'chooser-only', clipId: 'take', handedOff: false });
    h.page.refreshShareStatus();
    assert.equal(h.page.canCheckInToday, false, 'Opening or cancelling a modern chooser cannot enable a check-in');
    h.setPending({ id: 'another-work', clipId: 'other' }); h.page.refreshShareStatus();
    assert.equal(h.page.canCheckInToday, false, 'Another work cannot confirm this ticket');
    h.setPending({ id: 'first', clipId: 'take' }); h.page.refreshShareStatus();
    assert.equal(h.page.canCheckInToday, true);
    h.setPending({ id: 'second-before-confirm', clipId: 'take' }); h.page.refreshShareStatus();
    assert.equal(h.page.canCheckInToday, true, 'Repeated sharing must not strand the first daily confirmation');
    await Promise.all([h.page.confirmToday(), h.page.confirmToday()]);
    assert.equal(h.trace.filter(value => value === 'confirm:second-before-confirm').length, 1);
    assert.equal(h.page.calendarVisible, true, 'A deliberate confirmation opens the existing calendar, without a result popup');
    assert.equal(h.page.canCheckInToday, false);
    assert.equal(h.page.busy, false); assert.equal(h.page.checkingIn, false);
    assert.equal(h.page.onBackPress(), true); assert.equal(h.page.calendarVisible, false);
    h.setPending({ id: 'repeat-after-check-in', clipId: 'take' }); h.page.refreshShareStatus();
    assert.equal(h.page.canCheckInToday, false, 'A completed day never gets another daily action');
    assert.equal(h.trace.includes('pause'), false, 'A local check-in cannot alter the practice timeline');
  }
  {
    const h = harness(); await flush();
    h.context.RecordingShareService.markReturnedToApp = async () => {
      await Promise.resolve(); h.setPending({ id: 'legacy-return', clipId: 'take' });
    };
    h.page.onPageShow();
    assert.equal(h.page.canCheckInToday, false);
    await flush();
    assert.equal(h.page.canCheckInToday, true, 'Old-system return eligibility must refresh after the async fallback commits');
  }
  {
    const h = harness(); await flush();
    h.setPending({ id: 'failed-confirm', clipId: 'take' }); h.page.refreshShareStatus();
    h.context.RecordingShareService.confirmPublished = async () => { throw new Error('disk failure'); };
    await h.page.confirmToday();
    assert.equal(h.page.canCheckInToday, true, 'A failed durable check-in remains retryable');
    assert.equal(h.page.calendarVisible, false); assert.equal(h.page.busy, false);
    assert.match(h.notices.at(-1), /打卡暂未保存/);
  }
  {
    const h = harness(); await flush();
    h.setPending({ id: 'yesterday', clipId: 'take' }); h.page.refreshShareStatus();
    const timer = [...h.timers.values()][0];
    h.setNow(Date.parse('2026-10-20T00:00:01+08:00'));
    h.timers.delete(h.page.dayRefreshTimer);
    timer.callback();
    assert.equal(h.page.canCheckInToday, false, 'Midnight clears an unconfirmed previous-day action');
    await h.page.confirmToday();
    assert.equal(h.trace.some(value => value.startsWith('confirm:')), false, 'A stale tap cannot claim another day');
    h.page.onPageHide(); assert.equal(h.timers.size, 0, 'Hiding cancels the newly scheduled day refresh');
  }
  {
    const h = harness(); await flush();
    h.setPending({ id: 'other-completed', clipId: 'take' }); h.page.refreshShareStatus();
    h.setCompleted(true); await h.page.confirmToday();
    assert.equal(h.page.canCheckInToday, false); assert.equal(h.page.calendarVisible, true);
    assert.equal(h.trace.some(value => value.startsWith('confirm:')), false, 'An already committed day only opens its record');
  }
  console.log('PASS saved recording page: real static cover, single system share entry, explicit leader pause, member/session safeguards, daily ticket confirmation, calendar, midnight, async return and retry');
})().catch(error => { console.error(error); process.exitCode = 1; });
