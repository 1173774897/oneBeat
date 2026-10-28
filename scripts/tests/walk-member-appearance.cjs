// Execute the actual page options and shared read-only BPM contract; device pixels require visual QA.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require(process.argv[2] || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
const root = path.resolve(__dirname, '../../entry/src/main/ets');
const main = fs.readFileSync(path.join(root, 'pages/MainPage.ets'), 'utf8');
const bpm = fs.readFileSync(path.join(root, 'components/EditableBpm.ets'), 'utf8');

function argumentsFor(source, component) {
  const results = [];
  for (const match of source.matchAll(new RegExp('\\b' + component + '\\(\\s*\\{', 'g'))) {
    const start = match.index + match[0].length - 1;
    let depth = 0, quote = '';
    for (let i = start; i < source.length; i++) {
      const char = source[i];
      if (quote) {
        if (char === '\\') i++;
        else if (char === quote) quote = '';
      } else if (char === '"' || char === "'" || char === '`') quote = char;
      else if (char === '{') depth++;
      else if (char === '}' && --depth === 0) { results.push(source.slice(start, i + 1)); break; }
    }
    assert.equal(depth, 0, 'Every button option must be a complete production object');
  }
  return results;
}

const beat = main.slice(main.indexOf('  private beatPoint(index:'), main.indexOf('  private beatUnitIconPath'));
const top = main.slice(main.indexOf('  private topPanel()'), main.indexOf('  private bottomPanel()'));
const bottom = main.slice(main.indexOf('  private bottomPanel()'), main.indexOf('  build()'));
const buttonOptions = [...argumentsFor(beat, 'ActionButton'),
  ...argumentsFor(top.slice(0, top.indexOf('  @Builder', 1)), 'ActionButton'),
  ...argumentsFor(bottom, 'ActionButton')];
const bpmOptions = argumentsFor(top, 'EditableBpm');
assert.equal(buttonOptions.length, 8, 'Cover beat, meter, both sound modes, BPM controls, transport and recording');
assert.equal(bpmOptions.length, 1);
const valueShadow = bpm.match(/\.textShadow\((this\.editable[^\n]*)\)/);
assert.ok(valueShadow);
const sharedBpmOptions = argumentsFor(bpm, 'ActionButton');
const compiled = ts.transpileModule(buttonOptions.map((object, index) =>
  `export function button${index}(index = 0) { return ${object}; }`).join('\n') +
  `\nexport function bpmOptions() { return ${bpmOptions[0]}; }
  export function bpmButtonOptions() { return ${sharedBpmOptions[0]}; }
  export function bpmValueShadow() { return ${valueShadow[1]}; }`, {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 }, reportDiagnostics: true
  });
assert.equal(compiled.diagnostics.filter(d => d.category === ts.DiagnosticCategory.Error).length, 0);
const context = { exports: {}, Color: { Transparent: '#00000000' }, CORAL: '#FF7056', INK: '#171B1F',
  LILAC: '#C5B7EB', PAPER: '#FFF9EE', INK_SHADOW_RADIUS: 1,
  CONTROL_SHADOW: { radius: 1, offsetX: 2, offsetY: 2, color: '#171B1F' } };
vm.runInNewContext(compiled.outputText, context);
const page = { leader: false, busy: false, bpm: 120, beats: 4, unit: 4, beat: 0,
  visualPlaying: true, visualCountIn: false, sounds: ['电子'], sound: 0, showStyles: false,
  recordingState: 'idle', state: 'playing', beatPointSize: () => 80, beatPointHeight: () => 12,
  beatPointFill: () => '#FF7056' };
const options = () => buttonOptions.map((_value, i) => context.exports[`button${i}`].call(page));
for (const [role, busy] of [[false, false], [false, true], [true, false], [true, true]]) {
  page.leader = role; page.busy = busy;
  const buttons = options();
  for (const button of buttons.slice(0, -1)) {
    assert.equal(button.preserveDisabledAppearance, !role, 'Member readouts keep ink independent of loading state');
    if (!role) assert.equal(button.active, false, 'Retaining ink cannot grant members team controls');
  }
  const recording = buttons[buttons.length - 1];
  assert.equal(recording.active, true, 'Local recording remains available to members');
  assert.equal(recording.preserveDisabledAppearance, undefined, 'Local recording retains ordinary disabled styling');
  const value = context.exports.bpmOptions.call(page);
  assert.equal(value.editable, role && !busy);
  assert.equal(value.preserveDisabledAppearance, !role);
  const field = { ...value, value: value.value, controlCornerRadius: 5 };
  const shared = context.exports.bpmButtonOptions.call(field);
  assert.equal(shared.active, value.editable);
  assert.equal(shared.preserveDisabledAppearance, !role, 'The shared BPM button receives the read-only style');
  const shadow = context.exports.bpmValueShadow.call(field);
  assert.equal(shadow.color, !role || !busy ? context.INK : '#00000000');
}
assert.match(top, /\.textShadow\(!this\.leader \|\| !this\.busy \? \{ radius: 0, offsetX: 2, offsetY: 2, color: INK \}/,
  'Member meter text keeps its ink while leader busy feedback remains dimmed');
require('./action-button-disabled.cjs');
console.log('PASS walk member appearance: BPM/meter/beat/bottom ink retained, leader busy styling, local recording and native permission guards');
