const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const ts = require(process.argv[2] || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
const source = fs.readFileSync('entry/src/main/ets/pages/MainPage.ets', 'utf8');
const business = (source.slice(0, source.indexOf('  @Builder')) + '\n}')
  .replace(/^import[\s\S]*?from\s+['"][^'"]+['"];\s*/gm, '')
  .replace(/@(?:Entry|Component)\b\s*/g, '').replace(/@State\s+/g, '')
  .replace(/@(?:StorageLink|Watch)\([^)]*\)\s*/g, '')
  .replace('struct MainPage', 'export class MainPage');
const compiled = ts.transpileModule(business, {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 }, reportDiagnostics: true
});
assert.equal(compiled.diagnostics.filter(item => item.category === ts.DiagnosticCategory.Error).length, 0);
const clip = { id: 'save-1', scope: 'solo' };
function harness() {
  let snapshot = { state: 'recording', elapsedMs: 1000, error: '', saveFailureDetail: '', micMuted: false };
  const context = { exports: {}, Map, defaultBeatPointStates: () => [],
    RecordingCoordinator: { getSnapshot: () => snapshot,
      saveFailureNoticeText: current => (current ?? snapshot).error },
    showUserNotice() { throw new Error('Save results must use the shared dialog'); } };
  vm.runInNewContext(compiled.outputText, context);
  const page = new context.exports.MainPage();
  page.recordingState = 'recording';
  return { page, update(values) { snapshot = { ...snapshot, ...values }; page.refreshRecordingState(); } };
}
const overlay = source.slice(source.indexOf('  private recordingSaveOverlay() {'), source.indexOf('  private recordingErrorOverlay() {'));
assert.match(overlay, /height\(RECORD_SAVE_DIALOG_HEIGHT\)/);
assert.match(overlay, /constraintSize\(\{ maxHeight: RECORD_SAVE_DIALOG_MAX_HEIGHT \}\)/);
assert.match(overlay, /Scroll\(\)[\s\S]*layoutWeight\(1\)/);
assert.match(overlay, /height\(RECORD_SAVE_ACTION_HEIGHT\)/);
assert.match(overlay, /Progress\(\{ value: this\.recordingSaveStageNumber\(\) - 1, total: 3/);
assert.match(overlay, /ActionButton\(\{\s*label: '正在保存…', active: false,[\s\S]*?action: \(\) => \{\}/,
  'The saving face remains a native disabled action with no operation');
assert.match(overlay, /ActionButton\(\{\s*label: '退出去查看', active: !this\.exiting,[\s\S]*?inkShadow: CONTROL_SHADOW,[\s\S]*?action: \(\) => \{ void this\.exitAndViewSavedRecording\(\); \}/,
  'The saved action keeps its native busy gate, ink shadow and explicit exit handler');
assert.match(overlay, /ActionButton\(\{\s*label: '放弃这段', active: !this\.retrySaveBusy,[\s\S]*?action: \(\) => this\.requestDiscardPendingRecording\(\)/,
  'Discard must retain the retry guard and confirmation request');
assert.doesNotMatch(source, /private (?:recordingSavedOverlay|saveRecoveryOverlay)\(\)/,
  'Saving, success and retry share one frame rather than independently sized overlays');

const active = harness();
active.update({ state: 'stopping', savePhase: 'finishing', error: '系统已结束录制，练习仍可继续' });
assert.equal(active.page.showRecordingSaving, true);
assert.equal(active.page.showSaveRecovery, false, 'A capture reason cannot masquerade as a failed save while export runs');
assert.equal(active.page.showRecordingError, false);
assert.equal(active.page.recordingSaveTitle(), '正在保存这一拍');
assert.equal(active.page.recordingSaveStageNumber(), 1);
active.update({ savePhase: 'mixing', pendingClip: clip });
assert.equal(active.page.recordingSaveStageNumber(), 2);
assert.equal(active.page.showSaveRecovery, false, 'Retained input is normal during export, not evidence of a save failure');
active.page.continueWalkingAfterRecording();
active.update({ savePhase: 'indexing' });
assert.equal(active.page.showRecordingSaving, false, 'Closing the saving state does not reopen it on every poll');
assert.equal(active.page.recordingSaveStageNumber(), 3);
active.update({ state: 'idle', lastClip: clip, pendingClip: undefined, error: '' });
assert.equal(active.page.showRecordingSaved, true);
assert.equal(active.page.showRecordingSaving, false);
assert.equal(active.page.showSaveRecovery, false);
assert.equal(active.page.recordingSaveTitle(), '这一拍已保存');
active.page.continueWalkingAfterRecording();
active.update({});
assert.equal(active.page.showRecordingSaved, false, 'A saved work is announced exactly once');

const failure = harness();
failure.update({ state: 'stopping', pendingClip: clip, savePhase: 'mixing' });
failure.update({ state: 'failed', error: '原始音轨已保留，合成成品视频失败', saveFailureDetail: '编码器暂时不可用' });
assert.equal(failure.page.showRecordingSaving, false);
assert.equal(failure.page.showSaveRecovery, true);
assert.equal(failure.page.showRecordingSaved, false);
assert.equal(failure.page.recordingSaveTitle(), '这一拍还在等保存');
assert.equal(failure.page.recordingSaveDetail, '编码器暂时不可用');
failure.page.continueWalkingAfterRecording();
failure.update({});
assert.equal(failure.page.showSaveRecovery, false, 'A dismissed failure stays dismissed until retry or a new failure');
failure.update({ state: 'stopping', savePhase: 'mixing' });
assert.equal(failure.page.showRecordingSaving, true);
failure.update({ state: 'failed' });
assert.equal(failure.page.showSaveRecovery, true, 'A repeated failure after retry must remain actionable even when its error text matches');

const discard = harness();
discard.page.showDiscardRecordingConfirm = true;
discard.update({ state: 'stopping', pendingClip: clip });
assert.equal(discard.page.showRecordingSaving, false, 'Explicit discard cleanup must not display a misleading saving state');

console.log('PASS Recording save dialog: real stages, one frame, success/failure transitions and nonblocking dismissal');
