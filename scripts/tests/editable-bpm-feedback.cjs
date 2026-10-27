// Run with Node and the same TypeScript compiler path as the sync regressions.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require(process.argv[2]);
const source = fs.readFileSync(path.resolve(__dirname,
  '../../entry/src/main/ets/components/EditableBpm.ets'), 'utf8');
const buildStart = source.indexOf('  build()');
assert.ok(buildStart > 0);
const business = source.slice(0, buildStart)
  .replace(/@(?:Component|Prop|State)\b\s*/g, '')
  .replace(/@Watch\([^)]*\)\s*/g, '')
  .replace('export struct EditableBpm', 'export class EditableBpm') + '\n}\n';
const compiled = ts.transpileModule(business, {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 },
  reportDiagnostics: true
});
assert.deepEqual((compiled.diagnostics ?? []).filter(d => d.category === ts.DiagnosticCategory.Error), []);
const notices = [];
const mocks = {
  '@kit.ArkUI': { FrameCallback: class {} },
  '../common/UserFeedback': { showUserNotice: (message, key) => notices.push({ message, key }) },
  './ComicKit': { INK: '#000000', CONTROL_SHADOW: {} }
};
const context = {
  exports: {},
  TextInputController: class {
    stopCount = 0;
    onStop = () => {};
    stopEditing() { this.stopCount++; this.onStop(); }
  },
  require(name) {
    assert.ok(Object.hasOwn(mocks, name), `Unexpected BPM dependency: ${name}`);
    return mocks[name];
  }
};
vm.runInNewContext(compiled.outputText, context);
const { EditableBpm } = context.exports;
let fieldNumber = 0;

function field() {
  const input = new EditableBpm();
  const commits = [];
  const frames = [];
  const focusRequests = [];
  const feedbackStart = notices.length;
  input.inputId = `test-bpm-${++fieldNumber}`;
  input.editable = true;
  input.onCommit = value => commits.push(value);
  input.getUIContext = () => ({
    postFrameCallback: callback => frames.push(callback),
    getFocusController: () => ({ requestFocus: id => { focusRequests.push(id); return true; } })
  });
  return { input, commits, frames, focusRequests, feedback: () => notices.slice(feedbackStart) };
}

for (const invalid of ['', '39', '241', '12.5', '120x', 'NaN', 'Infinity', '   ']) {
  const { input, commits, feedback } = field();
  input.startEditing();
  input.draft = invalid;
  input.commitEditing();
  assert.deepEqual(commits, [], `${JSON.stringify(invalid)} must not commit`);
  assert.equal(input.editing, false);
  assert.equal(input.draft, '120', 'Invalid input returns to the currently committed BPM');
  assert.equal(input.value, 120);
  assert.deepEqual(feedback(), [{ message: '请输入 40–240 之间的 BPM', key: `bpm.validation.${input.inputId}` }],
    'An invalid edit must report the actual accepted range through the scoped feedback API');
  input.commitEditing();
  input.updateDraft('128');
  assert.equal(input.draft, '120', 'A delayed native change after stopEditing cannot reopen the old edit');
  assert.deepEqual(commits, [], 'The blur following a rejected submit cannot commit its fallback');
  assert.equal(feedback().length, 1, 'The following blur cannot duplicate invalid-input feedback');
  input.startEditing();
  input.updateDraft('128');
  input.commitEditing();
  input.commitEditing();
  assert.deepEqual(commits, [128], 'An explicit correction commits once across submit followed by blur');
}

for (const bpm of [40, 120, 240]) {
  const { input, commits, feedback } = field();
  input.startEditing();
  input.updateDraft(`${bpm}`);
  input.commitEditing();
  assert.deepEqual(commits, bpm === 120 ? [] : [bpm], 'Bounds are valid and an unchanged BPM needs no mutation');
  assert.deepEqual(feedback(), []);
  assert.equal(input.value, 120, 'The parent owns committed BPM until its update is confirmed');
  input.value = bpm;
  input.onValueChanged();
  assert.equal(input.draft, `${bpm}`);
  input.startEditing();
  assert.equal(input.draft, `${bpm}`, 'Reopening starts from the current committed value');
}

{
  const { input, commits, feedback } = field();
  input.startEditing();
  input.updateDraft('150');
  input.value = 136;
  input.onValueChanged();
  assert.equal(input.draft, '150', 'A parent update must not overwrite a draft in progress');
  input.updateDraft('999');
  input.commitEditing();
  assert.equal(input.draft, '136', 'Rejected input must return to the latest parent value');
  input.value = 140;
  input.onValueChanged();
  assert.equal(input.draft, '140');
  assert.deepEqual(commits, []);
  assert.equal(feedback().length, 1);
}

{
  const { input, commits, feedback } = field();
  input.startEditing();
  input.updateDraft('155');
  input.editable = false;
  input.onEditabilityChanged();
  input.commitEditing();
  input.updateDraft('160');
  input.startEditing();
  assert.equal(input.editing, false);
  assert.equal(input.draft, '120');
  assert.deepEqual(feedback(), []);
  assert.deepEqual(commits, [], 'Losing edit permission cancels the draft and blocks subsequent changes');
}

{
  const { input, commits, feedback } = field();
  input.inputController.onStop = () => {
    input.commitEditing();
    input.updateDraft('211');
  };
  input.startEditing();
  input.updateDraft('128');
  input.commitEditing();
  assert.deepEqual(commits, [128], 'Synchronous blur/change during stopEditing cannot double-commit or replace the captured draft');
  assert.equal(input.inputController.stopCount, 1, 'Reentrant blur must not recursively stop the native editor');
  assert.equal(input.editing, false);
  assert.equal(input.draft, '128');
  assert.deepEqual(feedback(), []);
}

{
  const { input, commits } = field();
  input.updateDraft('155');
  assert.equal(input.draft, '', 'An inactive display control cannot accept hidden TextInput changes');
  input.startEditing();
  input.updateDraft('1x2-8');
  assert.equal(input.draft, '128', 'Native editing normalizes the draft to decimal digits');
  input.updateDraft('2409');
  assert.equal(input.draft, '240', 'The business guard also enforces the native three-digit cap');
  input.commitEditing();
  assert.deepEqual(commits, [240]);
}

for (const invalidate of ['permission', 'disappear', 'restart']) {
  const { input, frames, focusRequests } = field();
  input.startEditing();
  assert.equal(frames.length, 0, 'Focus waits for the on-demand native field to appear');
  input.requestEditingFocus();
  assert.equal(frames.length, 1);
  assert.deepEqual(focusRequests, [], 'Focus must wait for the native field layout frame');
  if (invalidate === 'permission') {
    input.editable = false;
    input.onEditabilityChanged();
  } else if (invalidate === 'disappear') {
    input.aboutToDisappear();
  } else {
    input.commitEditing();
    input.startEditing();
    input.requestEditingFocus();
  }
  frames[0].onIdle(0);
  assert.deepEqual(focusRequests, [], `A stale frame after ${invalidate} must not take focus`);
  if (invalidate === 'restart') {
    frames[1].onIdle(0);
    assert.deepEqual(focusRequests, [input.inputId], 'Only the current edit revision may focus its own native input');
  } else {
    assert.equal(input.editing, false);
  }
}

for (const failure of ['frame', 'focus']) {
  const { input, frames, commits } = field();
  input.startEditing();
  input.updateDraft('155');
  input.getUIContext = () => ({
    postFrameCallback: callback => {
      if (failure === 'frame') throw new Error('page unmounted');
      frames.push(callback);
    },
    getFocusController: () => ({ requestFocus: () => { throw new Error('native field unavailable'); } })
  });
  input.requestEditingFocus();
  if (failure === 'focus') frames[0].onIdle(0);
  assert.equal(input.editing, false, `${failure} failure must cancel rather than retain a hidden editor`);
  assert.equal(input.draft, '120');
  assert.deepEqual(commits, []);
}

for (const [width, height] of [[55, 26], [52, 28]]) {
  for (const fontScale of [1, 1.3, 2]) {
    const { input } = field();
    input.controlWidth = width;
    input.controlHeight = height;
    input.valueFontSize = 18;
    input.getUIContext = () => ({
      fp2px: value => value * 3 * fontScale,
      px2vp: value => value / 3
    });
    input.updateInputArea(width, height);
    input.startEditing();
    input.updateDraft('240');
    const font = input.inputFontSize();
    assert.ok(font < 18, `${width}×${height} must shrink its focused input instead of scrolling the number`);
    const renderedFontVp = font * fontScale;
    // A conservative numeric-font fixture includes the separate cursor, both
    // borders and horizontal insets rather than checking a font number alone.
    const digitsAndCaretWidth = 3 * renderedFontVp * 0.75 + 2;
    assert.ok(digitsAndCaretWidth + 2 * 4 + 2 * 1.5 + 2 <= width,
      `Three digits and the caret must remain inside a ${width}vp box at ${fontScale}× text scaling`);
    assert.ok(renderedFontVp * 1.3 + 2 * 1.5 <= height,
      'The focused line must fit vertically without retaining TextInput default top/bottom insets');
    input.updateDraft('40');
    assert.equal(input.inputFontSize(), font, 'Two-to-three digit edits must not make the field jump in size');
  }
}

{
  const { input } = field();
  input.controlWidth = '100%';
  input.controlHeight = 48;
  input.valueFontSize = 40;
  input.updateInputArea(52, 28);
  const narrow = input.inputFontSize();
  assert.ok(narrow < 18, 'A percentage-sized caller must fit its measured width, not the default width');
  input.updateInputArea(NaN, 0);
  assert.equal(input.inputFontSize(), narrow, 'A transient empty area cannot discard the last usable measurement');
  input.updateInputArea(150, 62);
  assert.ok(input.inputFontSize() > narrow, 'Expanding the actual field must release its narrow-layout font cap');
  assert.ok(input.inputFontSize() <= 40, 'Responsive fitting must never enlarge beyond the caller font size');
  input.valueFontSize = 18;
  assert.equal(input.inputFontSize(), 18, 'A roomy input preserves a caller font that already fits');
}

assert.ok(source.includes('.onChange((raw: string) => this.updateDraft(raw))'));
assert.ok(source.includes('.onSubmit(() => this.commitEditing())') &&
  source.includes('.onBlur(() => this.commitEditing())'), 'Keyboard submit and blur must use the tested commit path');
const view = source.slice(buildStart);
assert.match(view, /if \(this\.editing\) \{\s*TextInput\(/,
  'The native editing field must exist only during an explicit edit');
assert.ok(view.includes('.onAppear(() => this.requestEditingFocus())'),
  'Native field appearance must enter the tested revision-checked frame focus path');
const inputView = view.slice(view.indexOf('TextInput('), view.indexOf('} else {', view.indexOf('TextInput(')));
assert.ok(inputView.includes('.fontSize(this.inputFontSize())') &&
  !inputView.includes('.maxFontSize(') && !inputView.includes('.minFontSize('),
  'The editing field must apply the fitted font directly instead of overriding it with adaptive font modifiers');
assert.ok(inputView.includes('top: 0, bottom: 0') && inputView.includes('.caretStyle('),
  'Explicit vertical padding and cursor width must match the focused-font budget');
assert.ok(view.includes('this.updateInputArea(Number(area.width), Number(area.height))'),
  'The fixed input box must feed actual geometry into the tested fitting logic');
assert.match(view, /ActionButton\(\{[\s\S]*?active: this\.editable[\s\S]*?action: \(\) => this\.startEditing\(\)/,
  'The display control must pass current editability to the shared native button and open only the tested editing path');
assert.ok(source.includes('showUserNotice(') && !source.includes('showToast'),
  'Invalid-input guidance must use the scoped feedback path covered by the harness');
console.log('PASS editable BPM feedback: scoped validation, committed-value recovery, native focus revisions and cleanup, stopEditing reentrancy, fitted digits/caret, resize, normalization, single commit and display-button editability');
