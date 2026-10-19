const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require(process.argv[2] || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
const root = path.resolve(__dirname, '../../entry/src/main/ets');

function testSharedCalendar() {
  const source = fs.readFileSync(path.join(root, 'components/ShareCalendarSheet.ets'), 'utf8');
  const business = (source.slice(0, source.indexOf('  @Builder')) + '\n}')
    .replace(/^import[\s\S]*?from\s+['"][^'"]+['"];\s*/gm, '')
    .replace(/@Component\b\s*/g, '').replace(/@(?:Prop|State)\s+/g, '')
    .replace(/@(?:StorageLink|Watch)\([^)]*\)\s*/g, '')
    .replace('export struct ShareCalendarSheet', 'export class ShareCalendarSheet');
  const result = ts.transpileModule(business, {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 }, reportDiagnostics: true
  });
  assert.equal(result.diagnostics.filter(item => item.category === ts.DiagnosticCategory.Error).length, 0);
  let now = Date.parse('2026-10-18T12:00:00+08:00');
  class CalendarDate extends Date { static now() { return now; } }
  const history = [{ dayKey: '2026-10-18', streakOrdinal: 3, shareCount: 2, rewardGranted: true, trialExpiresAt: 1000 }];
  let access = { source: 'trial', expiresAt: 1000 };
  const context = { exports: {}, Date: CalendarDate, Map,
    getShareCheckInSummary: () => ({ history, streakDays: 3, todayCompleted: true, ready: true, clockBlocked: false }),
    resolveDrumAccess: () => access, formatTrialExpiry: () => '10/19 20:00' };
  vm.runInNewContext(result.outputText, context);
  const calendar = new context.exports.ShareCalendarSheet();
  calendar.scope = 'team'; calendar.aboutToAppear();
  assert.equal(calendar.selectedDayKey, '2026-10-18');
  assert.equal(calendar.monthTitle, '2026 年 10 月');
  assert.equal(calendar.cells.length, 35);
  assert.equal(calendar.cells[3].day, 1, 'Monday-first October 2026 places Thursday 1 in column four');
  assert.equal(calendar.cells.find(cell => cell.day === 18).rewarded, true);
  assert.match(calendar.selectedDetail(), /分享 2 次\n已领 24h/);
  assert.equal(calendar.history.length, 1, 'Work scope never filters the install-wide reward ledger');
  assert.match(calendar.ruleLines().join('\n'), /24 小时试用/);
  access = { source: 'monthly', expiresAt: 2000 }; calendar.refreshAccess();
  assert.equal(calendar.showsTrialRewards(), false, 'Monthly members see practice records without trial promotion');
  assert.doesNotMatch(calendar.accessLabel(), /试用|赠|24/);
  assert.doesNotMatch(calendar.selectedDetail(), /已领|试用|24/);
  assert.doesNotMatch(calendar.ruleLines().join('\n'), /试用|赠|24/);
  assert.match(calendar.ruleLines().join('\n'), /月卡权益生效中/);
  assert.equal(calendar.history[0].rewardGranted, true, 'Hiding reward copy never rewrites historical benefits');
  access = { source: 'locked', expiresAt: 0 }; calendar.refreshAccess();
  assert.equal(calendar.showsTrialRewards(), true);
  assert.match(calendar.accessLabel(), /连续分享 3 天起/);
  assert.match(calendar.selectedDetail(), /已领 24h/, 'Historical rewards reappear when membership expires');
  access = { source: 'trial', expiresAt: 1000 }; calendar.refreshAccess();
  assert.match(calendar.accessLabel(), /试用中 · 截止/);

  calendar.moveMonth(-1); assert.equal(calendar.monthTitle, '2026 年 9 月');
  calendar.moveMonth(1); calendar.moveMonth(1);
  assert.equal(calendar.monthOffset, 0, 'Month navigation cannot advance beyond the current month');
  now = Date.parse('2028-02-29T12:00:00+08:00'); calendar.refresh();
  assert.equal(calendar.cells.filter(cell => cell.day > 0).length, 29, 'The calendar includes leap-day records');
  now = Date.parse('2026-10-18T15:59:59Z'); assert.equal(calendar.todayKey(), '2026-10-18');
  now = Date.parse('2026-10-18T16:00:00Z'); assert.equal(calendar.todayKey(), '2026-10-19', 'Day boundaries use Beijing rather than device timezone');
}

module.exports = testSharedCalendar;
if (require.main === module) {
  testSharedCalendar();
  console.log('PASS check-in calendar: Beijing dates, month navigation, membership-specific copy, entitlement refresh and preserved reward history');
}
