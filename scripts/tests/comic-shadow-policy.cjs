// Style invariants, not call-count snapshots; device rendering still needs visual QA.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const root = path.resolve(__dirname, '../../entry/src/main/ets');
const read = file => fs.readFileSync(path.join(root, file), 'utf8');
const kit = read('components/ComicKit.ets');
const radiusMatch = kit.match(/export const INK_SHADOW_RADIUS: number = ([\d.]+);/);
assert.ok(radiusMatch, 'Legacy native shadows need a shared compatibility radius');
const sharedRadius = Number(radiusMatch[1]);
assert.ok(sharedRadius >= 0 && sharedRadius <= 1, 'Legacy ink may be hard or use at most 1vp compatibility blur');

// Nested conditions in the join-code button contain parentheses before the
// shadow object. Stopping at the first ")" would silently skip that branch.
function calls(source, method) {
  const results = [];
  for (const match of source.matchAll(new RegExp('\\.' + method + '\\(', 'g'))) {
    const start = match.index + match[0].length;
    let depth = 1, quote = '';
    for (let index = start; index < source.length; index++) {
      const char = source[index];
      if (quote) {
        if (char === '\\') index++;
        else if (char === quote) quote = '';
      } else if (char === "'" || char === '"' || char.charCodeAt(0) === 96) quote = char;
      else if (char === '(') depth++;
      else if (char === ')' && --depth === 0) { results.push(source.slice(start, index)); break; }
    }
    assert.equal(depth, 0, 'Unclosed .' + method + '() call');
  }
  return results;
}

function checkOptions(object, file, constants, text = false) {
  const match = object.match(/\bradius:\s*([^,}\s]+)/);
  assert.ok(match, file + ': shadow objects must declare a reviewable radius');
  const radius = Object.hasOwn(constants, match[1]) ? constants[match[1]] : Number(match[1]);
  assert.ok(Number.isFinite(radius) && radius >= 0, file + ': invalid or unreviewed shadow radius ' + match[1]);
  if (text) {
    assert.equal(radius, 0, file + ': text ink must stay sharp, separate from component compatibility blur');
    return;
  }
  if (radius <= 1) return;
  // This existing cyan playback cue is a semantic glow, not a card-shadow exemption.
  assert.ok(file === 'pages/MainPage.ets' && radius === 8 &&
    /color:\s*'#CC35D6E4'/.test(object) && /offsetX:\s*0\b/.test(object) && /offsetY:\s*0\b/.test(object),
    file + ': component ink must be hard (radius 0) or legacy-compatible (at most 1vp)');
}

const stats = { native: 0, text: 0, solid: 0 };
function inspect(file, source, count = false) {
  const constants = { INK_SHADOW_RADIUS: sharedRadius };
  for (const match of source.matchAll(/\bconst\s+(\w+):\s*number\s*=\s*([-\d.]+);/g)) constants[match[1]] = Number(match[2]);
  const named = new Set(['CARD_SHADOW', 'CONTROL_SHADOW']);
  for (const match of source.matchAll(/(?:\bconst|@Prop)\s+(\w+):\s*ShadowOptions\s*=\s*(\{[^{}]*\})/g)) {
    named.add(match[1]);
    checkOptions(match[2], file, constants);
  }
  for (const [method, text] of [['shadow', false], ['textShadow', true]]) {
    for (const body of calls(source, method)) {
      const objects = [...body.matchAll(/\{[^{}]*\}/g)];
      for (const object of objects) checkOptions(object[0], file, constants, text);
      if (objects.length === 0) {
        const prop = body.trim().match(/^this\.(\w+)$/);
        assert.ok(named.has(body.trim()) || (prop && new RegExp('@Prop\\s+' + prop[1] + ':\\s*ShadowOptions').test(source)),
          file + ': named shadow options need a checked declaration');
      }
      if (count) stats[text ? 'text' : 'native']++;
    }
  }
  // ActionButton receives native shadow options as data. Inspect both branches
  // here because the shared face's .shadow() call cannot validate its callers.
  for (const match of source.matchAll(/\binkShadow:\s*([^,;{}]*)(\{[^{}]*\})(?:\s*:\s*(\{[^{}]*\}))?/g)) {
    if (/^ShadowOptions\b/.test(match[1])) continue;
    checkOptions(match[2], file, constants);
    if (match[3]) checkOptions(match[3], file, constants);
  }
  if (count) stats.solid += (source.match(/\bDrumPaper\(\{|\.background\(comicInkSurface\(|\bhardShadow:\s*\{/g) || []).length;
}

// Validate both acceptance and rejection so the obsolete rule is replaced,
// rather than weakened into a check that accepts any blur.
for (const source of [
  'Box().shadow({ radius: 0, offsetX: 4, offsetY: 4, color: INK })',
  'Box().shadow({ radius: 1, color: INK })',
  "Box().shadow({ radius: 0, color: '#00000000' })",
  'const HARD: ShadowOptions = { radius: 0, color: INK }; Box().shadow(HARD)',
  'Box().shadow(ready && (scan || digits === 6) ? { radius: 0, color: INK } : CONTROL_SHADOW)',
  'ActionButton({ inkShadow: { radius: 1, color: INK } })',
  'ActionButton({ inkShadow: ready && (scan || digits === 6) ? { radius: 0, color: INK } : { radius: 1, color: INK } })'
]) inspect('fixture.ets', source);
for (const source of [
  'Box().shadow({ radius: 2, color: INK })',
  'const SOFT: ShadowOptions = { radius: 6, color: INK }; Box().shadow(SOFT)',
  'Box().shadow(ready && (scan || digits === 6) ? CONTROL_SHADOW : { radius: 5, color: INK })',
  "Box().shadow({ radius: 8, color: '#CC35D6E4', offsetX: 0, offsetY: 0 })",
  'Box().shadow({ radius: -1, color: INK })',
  'Box().shadow(UNREVIEWED)',
  'Text().textShadow({ radius: 1, color: INK })',
  'ActionButton({ inkShadow: { radius: 2, color: INK } })',
  'ActionButton({ inkShadow: ready && (scan || digits === 6) ? { radius: 0, color: INK } : { radius: 5, color: INK } })'
]) assert.throws(() => inspect('fixture.ets', source), assert.AssertionError);
inspect('pages/MainPage.ets', "Box().shadow({ radius: 8, color: '#CC35D6E4', offsetX: 0, offsetY: 0 })");

function scan(dir) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const file = path.join(dir, entry.name);
    if (entry.isDirectory()) scan(file);
    else if (file.endsWith('.ets')) inspect(path.relative(root, file).split(path.sep).join('/'), fs.readFileSync(file, 'utf8'), true);
  }
}
scan(root);
for (const name of ['CARD_SHADOW', 'CONTROL_SHADOW']) {
  assert.match(kit, new RegExp(name + ': ShadowOptions = \\{ radius: INK_SHADOW_RADIUS,.*color: INK \\}'),
    'Shared native ink defaults retain their compatibility radius and ink color');
}

const surface = read('components/ComicInkSurface.ets');
assert.match(surface, /COMIC_CARD_INK_OFFSET: number = 4;/);
assert.match(surface, /COMIC_CONTROL_INK_OFFSET: number = 2;/);
for (const [file, positioning] of [
  ['components/DrumPaper.ets', /\.position\(\{ x: this\.offsetX, y: this\.offsetY \}\)/],
  ['components/ComicInkSurface.ets', /\.translate\(\{ x: inkOffset, y: inkOffset \}\)/]
]) {
  const source = read(file);
  assert.match(source, /Rect\(\)[\s\S]*?\.fill\(INK\)/, file + ': hard ink needs a solid backing');
  assert.match(source, positioning, file + ': backing must be offset from its face');
  assert.match(source, /\.hitTestBehavior\(HitTestMode\.None\)/, file + ': backing cannot intercept controls');
  assert.match(source, /\.clip\(false\)/, file + ': outer ink must remain visible');
  assert.equal(calls(source, 'shadow').length, 0, file + ': a solid backing cannot acquire a second native shadow');
}
const actionButton = read('components/ActionButton.ets');
assert.match(kit, /ActionButton\(\{[\s\S]*?hardShadow: this\.hardShadow, inkShadow: this\.inkShadow/,
  'ComicButton must pass both shadow forms to the shared disabled renderer');
assert.match(actionButton, /inkShadow: this\.hardShadow === undefined \? this\.effectiveInkShadow\(\) : undefined/,
  'Solid button faces disable their native shadow to avoid doubled ink');
assert.match(actionButton, /if \(!this\.active\) \{ return \{ radius: 0, color: '#00000000' \}; \}/,
  'Disabled native blur must drop so it cannot bleed through a faded face');
assert.match(actionButton, /\.shadow\(this\.faceInkShadow\)/,
  'Face shadow follows the live enabled state instead of a cached appearance');
assert.match(actionButton, /resolveFaceInkShadow\(config\)/,
  'Disabled native blur must drop so it cannot bleed through a faded face');
assert.match(actionButton, /\.position\(\{ x: this\.hardShadow\.offsetX[\s\S]*?\.hitTestBehavior\(HitTestMode\.None\)/,
  'Solid button backing stays outside intrinsic layout and independent of input handling');
for (const file of ['DrumMachinePage', 'LeaderLobbyPage', 'RecordingLibraryPage', 'SavedRecordingPage', 'StorePage']) {
  assert.match(read('pages/' + file + '.ets'), /DrumPaper\(\{|\.background\(comicInkSurface\(|\bhardShadow:\s*\{/,
    file + ': migrated surfaces must retain solid ink');
}

const main = read('pages/MainPage.ets');
assert.match(main, /\{ radius: 8, color: '#CC35D6E4', offsetX: 0, offsetY: 0 \}/, 'The current beat keeps its cyan glow');
const recordStart = main.indexOf("active: this.recordingState !== 'stopping'");
const recordEnd = main.indexOf("Text(this.recordingState === 'recording' ? '停止' : '录制')", recordStart);
assert.ok(recordStart >= 0 && recordEnd > recordStart, 'Keep the live recording/stop action and its label');
const record = main.slice(recordStart, recordEnd);
assert.match(record, /inkShadow: CONTROL_SHADOW/,
  'The recording button passes its ink shadow through the shared disabled appearance');
assert.match(record, /action: \(\) => this\.requestRecording\(\)/);
assert.match(record, /Rect\(\)\.width\(15\)\.height\(15\)/);
assert.match(record, /Circle\(\)\.width\(17\)\.height\(17\)\.fill\(CORAL\)/);
assert.doesNotMatch(main, /Text\('人'\)/, 'The removed member button must not reappear');
console.log('PASS comic shadow policy: ' + stats.solid + ' solid surfaces, ' + stats.native + ' native and ' +
  stats.text + ' sharp text calls; hard/legacy-compatible ink, transparent off, isolated cyan glow and rejection cases');
