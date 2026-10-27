// ComicButton owns its visual layout and public compatibility surface. Native
// input, disabled composition and extent arithmetic live in ActionButton tests.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require(process.argv[2] || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
const root = path.resolve(__dirname, '../..');
const kit = fs.readFileSync(path.join(root, 'entry/src/main/ets/components/ComicKit.ets'), 'utf8');
const button = kit.slice(kit.indexOf('export struct ComicButton'));
assert.match(kit, /import \{ ActionButton \} from '\.\/ActionButton'/);
assert.match(button, /@Prop hardShadow: ComicHardShadowOptions \| undefined = undefined/,
  'Solid backing remains opt-in without changing the public shadow API');
assert.match(button, /@Prop inkShadow: ShadowOptions = CARD_SHADOW/,
  'Existing callers retain their native shadow unless they opt into a solid backing');
assert.match(kit, /export interface ComicHardShadowOptions \{\s*offsetX: number;\s*offsetY: number;\s*color: string;/);
assert.match(kit, /const COMIC_BUTTON_HEIGHT: number = 56/);
assert.match(kit, /const COMIC_BUTTON_RADIUS: number = 7/);
assert.doesNotMatch(kit, /COMIC_BUTTON_DISABLED_OPACITY|COMIC_BUTTON_PRESSED_TINT|ComicButtonContentModifier/,
  'The wrapper cannot fork the shared disabled or pressed rendering policy');
assert.doesNotMatch(button, /\.opacity\(|\.renderGroup\(|\.contentModifier\(|shadowOutset\(|shadowNumber\(/,
  'The shared button owns disabled rendering and both kinds of shadow bounds');
assert.doesNotMatch(button, /\.height\(COMIC_BUTTON_HEIGHT\)/,
  'Only the shared face fixes height; nested content must remain vertically centered inside its padded face');
assert.match(button, /Text\(this\.label\)\.fontSize\(22\)\.fontWeight\(900\)\.fontStyle\(FontStyle\.Italic\)\.fontColor\(INK\)/);
assert.match(button, /Text\('›'\)\.fontSize\(30\)\.fontColor\(INK\)/);
assert.match(button, /if \(this\.badgeLabel\.length > 0 && this\.badgeIcon\.length > 0\)/,
  'The badge still requires both text and artwork');
assert.match(button, /Row\(\{ space: 5 \}\)[\s\S]*?Image\(\$rawfile\(this\.badgeIcon\)\)\.width\(22\)\.height\(22\)\.objectFit\(ImageFit\.Contain\)/);
assert.match(button, /Text\(this\.badgeLabel\)\.fontSize\(9\)\.fontWeight\(900\)\.fontColor\(INK\)\.letterSpacing\(0\.7\)/);
assert.match(button, /\.width\(92\)\.height\(30\)\.justifyContent\(FlexAlign\.Center\)/);
assert.match(button, /\.backgroundColor\(this\.badgeFill\)\.border\(\{ width: 1\.2, color: INK \}\)\.borderRadius\(4\)/);
assert.match(button, /\.rotate\(\{ angle: -2 \}\)\.margin\(\{ right: 9 \}\)/);
assert.match(button, /\.width\('100%'\)\.alignItems\(VerticalAlign\.Center\)/);

// Evaluate the actual wrapper arguments so forwarding assertions cannot pass
// against a detached copy of the configuration or a hard-coded initial state.
const options = button.match(/ActionButton\((\{[\s\S]*?\})\)\s*\{/);
assert.ok(options, 'ComicButton must render the shared native button');
const compiled = ts.transpileModule(`export function buttonOptions() { return ${options[1]}; }`, {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 }, reportDiagnostics: true
});
assert.equal((compiled.diagnostics ?? []).filter(item => item.category === ts.DiagnosticCategory.Error).length, 0);
const context = { exports: {}, COMIC_BUTTON_HEIGHT: 56, COMIC_BUTTON_RADIUS: 7, INK: '#171B1F' };
vm.runInNewContext(compiled.outputText, context);
let actions = 0;
const props = {
  label: '出发', active: false, fill: '#FF7056', badgeLabel: '', badgeIcon: '',
  hardShadow: undefined, inkShadow: { radius: 1, offsetX: 3, offsetY: 4, color: '#171B1F' },
  action: () => actions++
};
const read = () => context.exports.buttonOptions.call(props);
for (const active of [false, true, false]) {
  props.active = active;
  const actual = read();
  assert.equal(actual.active, active, 'Availability must read the current wrapper property');
  assert.equal(actual.label, props.label);
  assert.equal(actual.fill, props.fill);
  assert.equal(actual.controlHeight, 56);
  assert.equal(actual.cornerRadius, 7);
  assert.equal(actual.lineWidth, 1.5);
  assert.equal(actual.lineColor, context.INK);
  assert.deepEqual(JSON.parse(JSON.stringify(actual.contentPadding)), { left: 16, right: 14 });
  assert.equal(actual.inkShadow, props.inkShadow, 'Native shadow resources and units must pass through unchanged');
  assert.equal(actual.hardShadow, undefined);
}
for (const hardShadow of [{ offsetX: 4, offsetY: 4, color: '#171B1F' },
  { offsetX: -4, offsetY: -3, color: '#271B1F' }]) {
  props.hardShadow = hardShadow;
  assert.equal(read().hardShadow, hardShadow, 'Signed vp offsets and custom ink color must reach the shared backing intact');
  assert.equal(read().inkShadow, props.inkShadow, 'Opt-in solid backing must not discard the caller native fallback');
}
for (const [badgeLabel, badgeIcon, expected] of [
  ['', '', '出发'], ['PRO', '', '出发'], ['', 'comic/badge.png', '出发'],
  ['PRO', 'comic/badge.png', '出发，PRO']
]) {
  Object.assign(props, { badgeLabel, badgeIcon });
  assert.equal(read().accessibilityLabel, expected, 'The native accessible label must match the visible badge condition');
}
props.label = '继续';
assert.equal(read().label, '继续');
assert.equal(read().accessibilityLabel, '继续，PRO', 'Both accessible and visible labels must follow later parent updates');
read().action();
assert.equal(actions, 1, 'The wrapper must preserve its one public action callback');
console.log('PASS ComicButton wrapper: live availability/labels, original badge and face geometry, unchanged native/solid shadow API and one shared rendering policy');
