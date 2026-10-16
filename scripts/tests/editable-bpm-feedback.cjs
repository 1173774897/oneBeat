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
const context = { exports: {}, require(name) {
  assert.equal(name, './ComicKit', 'BPM field validation must not depend on a global notice API');
  return { INK: '#000000' };
} };
vm.runInNewContext(compiled.outputText, context);
const { EditableBpm } = context.exports;

function field() {
  const input = new EditableBpm();
  const commits = [];
  input.editable = true;
  input.onCommit = value => commits.push(value);
  return { input, commits };
}

for (const invalid of ['', '39', '241', '12.5', '120x', 'NaN', 'Infinity', '   ']) {
  const { input, commits } = field();
  input.startEditing();
  input.draft = invalid;
  input.commitEditing();
  assert.deepEqual(commits, [], `${JSON.stringify(invalid)} must not commit`);
  assert.equal(input.editing, false);
  assert.equal(input.draft, '120', 'Invalid input returns to the currently committed BPM');
  assert.equal(input.value, 120);
  assert.equal(input.validationMessage, '请输入 40–240');
  input.commitEditing();
  assert.deepEqual(commits, [], 'The blur following a rejected submit must not commit its fallback');
  input.updateDraft('128');
  assert.equal(input.editing, true, 'Typing after submit must work even when the input retained focus');
  assert.equal(input.validationMessage, '');
  input.commitEditing();
  input.commitEditing();
  assert.deepEqual(commits, [128], 'Submit followed by blur commits a correction once');
}

for (const bpm of [40, 120, 240]) {
  const { input, commits } = field();
  input.startEditing();
  input.updateDraft(`${bpm}`);
  input.commitEditing();
  assert.deepEqual(commits, [bpm], 'Both bounds and an interior value are valid');
  assert.equal(input.validationMessage, '');
  assert.equal(input.value, 120, 'The parent owns committed BPM until its update is confirmed');
  input.value = bpm;
  input.onValueChanged();
  assert.equal(input.draft, `${bpm}`);
  input.startEditing();
  assert.equal(input.draft, `${bpm}`, 'Reopening starts from the current committed value');
}

{
  const { input, commits } = field();
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
  assert.equal(input.validationMessage, '', 'A newer committed value clears old field guidance');
  assert.deepEqual(commits, []);
}

{
  const { input, commits } = field();
  input.startEditing();
  input.updateDraft('155');
  input.editable = false;
  input.onEditabilityChanged();
  input.commitEditing();
  input.updateDraft('160');
  input.startEditing();
  assert.equal(input.editing, false);
  assert.equal(input.draft, '120');
  assert.equal(input.validationMessage, '');
  assert.deepEqual(commits, [], 'Losing edit permission cancels the draft and blocks subsequent changes');
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
assert.ok(view.includes('Column({ space: 4 })') &&
  view.indexOf('.height(this.controlHeight)') < view.indexOf('Text(this.validationMessage'),
  'Field-local guidance must flow below the fixed-height input rather than cover adjacent controls');
assert.equal(view.includes('.position(') || view.includes('.offset('), false);
const inputView = view.slice(view.indexOf('TextInput('), view.indexOf('if (!this.editing)'));
assert.ok(inputView.includes('.fontSize(this.inputFontSize())') &&
  !inputView.includes('.maxFontSize(') && !inputView.includes('.minFontSize('),
  'The editing field must apply the fitted font directly instead of overriding it with adaptive font modifiers');
assert.ok(inputView.includes('top: 0, bottom: 0') && inputView.includes('.caretStyle('),
  'Explicit vertical padding and cursor width must match the focused-font budget');
assert.ok(view.includes('this.updateInputArea(Number(area.width), Number(area.height))'),
  'The fixed input box must feed actual geometry into the tested fitting logic');
assert.equal(source.includes('showToast'), false);
console.log('PASS editable BPM feedback: local validation and committed-value recovery, focused three-digit/caret fitting at narrow widths and text scales, measured resize, single commit and lost edit permission');
