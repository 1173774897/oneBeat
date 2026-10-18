// Source-contract checks complement the ArkUI build; they do not verify device pixels.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require(process.argv[2] || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
const root = path.resolve(__dirname, '../..');
const home = fs.readFileSync(path.join(root, 'entry/src/main/ets/pages/Index.ets'), 'utf8');
const kit = fs.readFileSync(path.join(root, 'entry/src/main/ets/components/ComicKit.ets'), 'utf8');
const button = kit.slice(kit.indexOf('export struct ComicButton'));
const hardStart = button.indexOf('if (this.hardShadow !== undefined)');
const fallbackStart = button.indexOf('} else {', hardStart);
assert.ok(hardStart >= 0 && fallbackStart > hardStart, 'Keep hard shadows opt-in');
const hard = button.slice(hardStart, fallbackStart);
for (const [kind, title] of [['team', '多人练习'], ['solo', '单人练习'], ['store', '收藏小铺']]) {
  assert.ok(home.includes(`this.entryCard('${kind}', '${title}',`), title + ' uses the shared home card');
}
const homeCard = home.slice(home.indexOf('  private entryCard('), home.indexOf('  build()'));
const cardFaceStart = homeCard.indexOf('      Column()');
assert.ok(cardFaceStart > 0);
const homeBacking = homeCard.slice(0, cardFaceStart);
assert.match(homeBacking, /backgroundColor\(INK\)\.borderRadius\(HOME_CARD_RADIUS\)/);
assert.match(homeBacking, /translate\(\{ x: HOME_CARD_SHADOW_X, y: HOME_CARD_SHADOW_Y \}\)/);
assert.match(homeBacking, /hitTestBehavior\(HitTestMode\.None\)\.accessibilityLevel\('no'\)/);
assert.doesNotMatch(homeBacking, /\.onClick/);
assert.doesNotMatch(home, /recording_share_hero|worksEntry\(|HOME_WORKS_|stopPropagation|badgeLabel: '(?:TEAM|SOLO)'/);
assert.equal((homeCard.match(/Button\(\{ type: ButtonType\.Normal \}\)/g) || []).length, 3,
  'Practice header, metric and works use sibling controls rather than nested buttons');
assert.equal((homeCard.match(/onClick\(\(\) => this\.goPrimary\(kind\)\)/g) || []).length, 2);
assert.equal((homeCard.match(/onClick\(\(\) => this\.goSecondary\(kind\)\)/g) || []).length, 1);
assert.doesNotMatch(homeCard.slice(homeCard.lastIndexOf('      }.width')), /\.onClick/,
  'The shared face/wrapper must not intercept works taps');
assert.match(button, /@Prop hardShadow: ComicHardShadowOptions \| undefined = undefined/);
assert.ok(hard.indexOf('Row()') < hard.indexOf('this.buttonFace()'), 'Backing must paint before the face');
assert.match(hard, /backgroundColor\(this\.hardShadow\?\.color \?\? INK\)/);
assert.match(hard, /translate\(\{ x: this\.hardShadow\?\.offsetX \?\? 0, y: this\.hardShadow\?\.offsetY \?\? 0 \}\)/);
assert.match(hard, /hitTestBehavior\(HitTestMode\.None\)\.accessibilityLevel\('no'\)/);
assert.match(hard, /height\(COMIC_BUTTON_HEIGHT\)\.clip\(false\)/);
assert.equal((button.match(/height\(COMIC_BUTTON_HEIGHT\)/g) || []).length, 3, 'Face, backing and wrapper must have the same height');
assert.equal((button.match(/borderRadius\(COMIC_BUTTON_RADIUS\)/g) || []).length, 2, 'Backing must match the face corners');
assert.match(button, /shadow\(this\.hardShadow !== undefined \? \{ radius: 0, color: '#00000000' \} : this\.inkShadow\)/);
assert.match(button, /enabled\(this\.active\)\.opacity\(this\.active \? 1 : 0\.5\)\.onClick\(this\.action\)/);
assert.match(hard, /opacity\(this\.active \? 1 : 0\.5\)/);
assert.match(button.slice(fallbackStart), /this\.buttonFace\(\)/);
assert.match(kit, /const COMIC_BUTTON_HEIGHT: number = 56/);
assert.match(kit, /const COMIC_BUTTON_RADIUS: number = 7/);

// Run the real home methods with repository/router boundaries replaced. This
// verifies scope routing and live statistics without pretending to render ArkUI.
const business = (home.slice(0, home.indexOf('  @Builder')) + '\n}')
  .replace(/^import[\s\S]*?from\s+['"][^'"]+['"];\s*/gm, '')
  .replace(/@(?:Entry|Component)\b\s*/g, '')
  .replace(/@State\s+/g, '')
  .replace(/@(?:StorageLink|Watch)\([^)]*\)\s*/g, '')
  .replace('struct Index', 'export class Index');
const compiled = ts.transpileModule(business, {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 }, reportDiagnostics: true
});
assert.equal((compiled.diagnostics ?? []).filter(item => item.category === ts.DiagnosticCategory.Error).length, 0);
let clips = [
  { scope: 'team', durationMs: 65000 }, { scope: 'team', durationMs: 90000 },
  { scope: 'solo', durationMs: 3661000 }
];
const routes = [];
let bootstraps = 0;
const context = {
  exports: {},
  RecordingRepository: { list: scope => clips.filter(clip => clip.scope === scope) },
  router: { pushUrl: args => routes.push(args) },
  ensureStoreBootstrapReady: () => { bootstraps++; return Promise.resolve(); }
};
vm.runInNewContext(compiled.outputText, context);
const page = new context.exports.Index();
page.aboutToAppear();
assert.equal(bootstraps, 1);
assert.equal(page.secondaryLabel('team'), '作品 2');
assert.equal(page.secondaryLabel('solo'), '作品 1');
assert.equal(page.entryMetric('team'), '累计录制 2:35');
assert.equal(page.entryMetric('solo'), '累计录制 1小时1分');
assert.equal(page.entryMetric('store'), '角色 · 场景 · 鼓机');
assert.match(page.secondaryAccessibility('team'), /多人练习作品，2段/);
clips = [{ scope: 'team', durationMs: 65000 }];
page.onPageShow();
assert.equal(page.secondaryLabel('team'), '作品 1', 'Returning from deletion refreshes the real count');
assert.equal(page.entryMetric('team'), '累计录制 1:05');
assert.equal(page.secondaryLabel('solo'), '作品 0');
assert.equal(page.entryMetric('solo'), '累计录制 0:00', 'Empty libraries do not show fabricated practice stats');
for (const kind of ['team', 'solo', 'store']) page.goPrimary(kind);
for (const kind of ['team', 'solo', 'store']) page.goSecondary(kind);
assert.deepEqual(JSON.parse(JSON.stringify(routes)), [
  { url: 'pages/TeamPage' },
  { url: 'pages/LeaderLobbyPage', params: { displayName: '我', solo: '1' } },
  { url: 'pages/StorePage' },
  { url: 'pages/RecordingLibraryPage', params: { scope: 'team' } },
  { url: 'pages/RecordingLibraryPage', params: { scope: 'solo' } },
  { url: 'pages/StorePage' }
], 'Practice navigation and scoped works navigation remain distinct');
console.log('PASS: home cards use non-interactive ink backings, independent works controls, real scoped counts/durations; shared ComicButton fallback retained');
