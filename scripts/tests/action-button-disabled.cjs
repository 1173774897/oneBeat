// Native rendering/input dispatch is checked on a device; this protects the
// shared state/event contract and executes the real extent/forwarding methods.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require(process.argv[2] || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
const root = path.resolve(__dirname, '../..');
const source = fs.readFileSync(path.join(root, 'entry/src/main/ets/components/ActionButton.ets'), 'utf8');
assert.match(source, /ACTION_DISABLED_OPACITY: number = 0\.68/);
assert.match(source, /Button\(this\.label[\s\S]*?\.contentModifier\([\s\S]*?\.enabled\(this\.active\)/);
assert.match(source, /function resolveFaceInkShadow\(config: ButtonConfiguration\)/);
assert.match(source, /if \(!config\.enabled\) \{\s*return TRANSPARENT_FACE;/,
  'Native blur must follow the live Button enabled state, not a cached appearance');
assert.match(source, /if \(!this\.active\) \{ return 0; \}/,
  'Disabled native-shadow buttons must not reserve blur fringe');
assert.match(source,
  /\.renderGroup\(fadeOnExpandedBounds && !this\.active && this\.hardShadow !== undefined\)/,
  'renderGroup is only for hard-ink disabled compositing');
assert.match(source, /private hardInkShadowRow\(\)/,
  'Solid ink uses an Index-style Stack sibling instead of Button.background()');
assert.match(source, /this\.hardInkShadowRow\(\)/);
assert.match(source, /private faceWithHardInk\(\)/);
const backing = source.slice(source.indexOf('  private hardInkShadowRow()'), source.indexOf('  private actionHost()'));
const host = source.slice(source.indexOf('  private actionHost()'), source.indexOf('  private faceWithHardInk()'));
assert.match(backing, /Row\(\)\.width\(this\.hardFaceWidth\)\.height\(this\.hardFaceHeight\)/,
  'Auto-sized backing must use the measured native face rather than an empty intrinsic Row');
assert.match(backing, /\.position\(\{ x: this\.hardShadow\.offsetX, y: this\.hardShadow\.offsetY \}\)/,
  'Absolute ink cannot participate in intrinsic measurement or keep a shortened label wide');
assert.match(host, /\.onAreaChange\(\(_before: Area, area: Area\) => this\.updateHardFaceSize\(area\)\)/,
  'Measure the native button itself so content, padding and auto height share its actual bounds');
assert.doesNotMatch(host, /\.(?:width|height)\(this\.hardFace(?:Width|Height)\)/,
  'Measured decoration bounds must never feed back into native intrinsic sizing');
assert.doesNotMatch(source, /\.background\(this\.shadowBacking\(\)\)/);
assert.match(source, /\.onTouch\(\(event: TouchEvent\) => this\.touchAction\(event\)\)/,
  'Touch cleanup must not be filtered by a new active guard');
assert.match(source, /accessibilityLevel\('no-hide-descendants'\)/);
assert.match(source, /\.responseRegion\(this\.hitRegion/);

const forward = source.slice(source.indexOf('  private forwardContentClick('), source.indexOf('  @Builder\n  private defaultLabel'));
const extents = source.slice(source.indexOf('  private shadowNumber('), source.indexOf('  private appearance('));
const measurementStart = source.indexOf('  private updateHardFaceSize(');
const measurementEnd = source.indexOf('  @Builder\n  private hardInkShadowRow', measurementStart);
assert.ok(measurementStart > 0 && measurementEnd > measurementStart,
  'The production measurement method must remain executable independently of ArkUI builders');
const measurement = source.slice(measurementStart, measurementEnd);
const hostClick = source.match(/\.onClick\(\(event: ClickEvent\) => \{\s*(if \(this\.active\)[\s\S]*?)\n\s*\}\)/);
assert.ok(hostClick, 'The native host must own the single guarded business callback');
const compiled = ts.transpileModule(`export class Probe {
  active = true; controlWidth = '100%'; controlHeight = 40;
  hardShadow: any; inkShadow: any; contentClickEvent: any;
  hardFaceWidth = 0; hardFaceHeight = 0;
  action: (event: any) => void = () => {};
  nativeClick(event: any): void { ${hostClick[1]} }
  ${forward}
  ${extents}
  ${measurement}
}`, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 }, reportDiagnostics: true });
assert.equal((compiled.diagnostics ?? []).filter(item => item.category === ts.DiagnosticCategory.Error).length, 0);
const context = { exports: {}, px2vp: value => value / 3.5,
  getContext: () => ({ resourceManager: { getNumber: value => {
    if (value.id === 1) return 3;
    throw new Error('Missing optional resource');
  } } }) };
vm.runInNewContext(compiled.outputText, context);
const probe = new context.exports.Probe();
const original = { source: 'touch', timestamp: 123, x: 10, y: 20 };
const synthetic = { source: 'unknown', timestamp: 999, x: 10, y: 20 };
const events = [];
probe.action = event => events.push(event);
probe.forwardContentClick({ triggerClick: () => probe.nativeClick(synthetic) }, original);
assert.deepEqual(events, [original], 'Touch source and timestamp must survive native triggerClick synthesis');
assert.equal(probe.contentClickEvent, undefined);
probe.active = false;
probe.forwardContentClick({ triggerClick: () => probe.nativeClick(synthetic) }, original);
assert.equal(events.length, 1, 'A gesture release cannot invoke an action after it becomes disabled');
assert.equal(probe.contentClickEvent, undefined);
probe.active = true;
probe.nativeClick(synthetic);
assert.equal(events[1], synthetic, 'Keyboard/accessibility events use their own native event');
assert.throws(() => probe.forwardContentClick({ triggerClick: () => { throw new Error('Dispatch failed'); } }, original));
assert.equal(probe.contentClickEvent, undefined, 'A failed dispatch cannot leak its event to the next action');

const bounds = () => [probe.shadowOutset(true, true), probe.shadowOutset(true, false),
  probe.shadowOutset(false, true), probe.shadowOutset(false, false)];
probe.hardShadow = { offsetX: 4, offsetY: 4 };
assert.deepEqual(bounds(), [0, 4, 0, 4]);
assert.equal(probe.groupWidth(), 'calc(100% + 4vp)');
assert.equal(probe.groupHeight(), 44);
probe.hardShadow = { offsetX: -4, offsetY: -3 };
assert.deepEqual(bounds(), [4, 0, 3, 0]);
probe.controlWidth = 'auto'; probe.controlHeight = 'auto';
assert.equal(probe.groupWidth(), 'auto');
assert.equal(probe.groupHeight(), 'auto');
probe.hardShadow = undefined;
probe.inkShadow = { radius: 1, offsetX: 3, offsetY: -4 };
assert.deepEqual(bounds(), [1 / 3.5, 7 / 3.5, 8 / 3.5, 0]);
probe.inkShadow = undefined;
assert.deepEqual(bounds(), [0, 0, 0, 0]);
assert.equal(probe.shadowNumber({ id: 2 }), 0);

const sized = new context.exports.Probe();
sized.controlWidth = 'auto'; sized.controlHeight = 'auto';
let measuredWidth = 0, measuredHeight = 0;
const sizeWrites = [];
Object.defineProperties(sized, {
  hardFaceWidth: {
    get: () => measuredWidth,
    set: value => { measuredWidth = value; sizeWrites.push(['width', value]); }
  },
  hardFaceHeight: {
    get: () => measuredHeight,
    set: value => { measuredHeight = value; sizeWrites.push(['height', value]); }
  }
});
const measured = () => [sized.hardFaceWidth, sized.hardFaceHeight];
sized.updateHardFaceSize({ width: 43, height: 40 });
assert.equal(sized.hardShadow, undefined);
assert.deepEqual(measured(), [43, 40],
  'A host without ink must still retain its actual size for later shadow activation');
sized.hardShadow = { offsetX: 2, offsetY: 2 };
assert.deepEqual(measured(), [43, 40],
  'Adding ink without another area event must use the previously measured face');
for (const width of [91, 43, 0]) {
  sized.updateHardFaceSize({ width, height: 40 });
  assert.deepEqual(measured(), [width, 40],
    'A longer, shorter or empty label must resize its backing without retaining the widest previous face');
  assert.equal(sized.groupWidth(), 'auto', 'Measured ink cannot replace the native intrinsic-width contract');
}
for (const height of [24, 60, 24, 0]) {
  sized.updateHardFaceSize({ width: 43, height });
  assert.deepEqual(measured(), [43, height], 'Auto height must grow, shrink and clear independently of width');
  assert.equal(sized.groupHeight(), 'auto');
}
sized.updateHardFaceSize({ width: '43', height: '40' });
assert.deepEqual(measured(), [43, 40], 'Numeric area values must retain vp units without density conversion');
const stableWriteCount = sizeWrites.length;
sized.updateHardFaceSize({ width: 43, height: 40 });
assert.equal(sizeWrites.length, stableWriteCount,
  'An unchanged layout event must not schedule another state write or measurement loop');
for (const invalid of [NaN, Infinity, -Infinity, -1, 'invalid', undefined]) {
  sized.updateHardFaceSize({ width: invalid, height: invalid });
  assert.deepEqual(measured(), [43, 40], 'Invalid geometry cannot overwrite the last measured bounds');
}
assert.equal(sizeWrites.length, stableWriteCount);
sized.updateHardFaceSize({ width: NaN, height: 31 });
assert.deepEqual(measured(), [43, 31], 'A valid height still updates when the width is temporarily unavailable');
sized.updateHardFaceSize({ width: 28, height: -1 });
assert.deepEqual(measured(), [28, 31], 'A valid width still updates when the height is temporarily invalid');
sized.updateHardFaceSize({ width: 0, height: 0 });
assert.deepEqual(measured(), [0, 0], 'An actually empty host must clear stale ink in both dimensions');
console.log('PASS ActionButton: native state, original click event, late-disable guard, measured intrinsic growth/shrink/zero, auto height and shadow bounds');
