// Source-contract checks complement the ArkUI build; they do not verify device pixels.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require(process.argv[2] || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
const root = path.resolve(__dirname, '../..');
const home = fs.readFileSync(path.join(root, 'entry/src/main/ets/pages/Index.ets'), 'utf8');
require('./comic-button-disabled.cjs');
assert.match(home, /this\.practiceEntryPanel\('team', '多人练习', '组队同行 · 同拍出发', CORAL\)/);
assert.match(home, /this\.practiceEntryPanel\('solo', '单人练习', '跟着节奏 · 找到步调', WHITE\)/);
assert.match(home, /Row\(\{ space: HOME_ENTRANCE_GAP \}\)[\s\S]*this\.storeEntryPanel\(\)/);
assert.match(home, /scenes\/sunset\/entities\/tree\.png/);
assert.match(home, /vegetation\/plant_06\.png/);
assert.match(home, /vegetation\/plant_09\.png/);
assert.match(home, /scenes\/sunset\/entities\/rocks\.png/);
assert.match(home, /vegetation\/plant_08\.png/);
assert.match(home, /scenes\/sunset\/entities\/sign\.png/);
const homeCard = home.slice(home.indexOf('  private practiceEntryPanel('), home.indexOf('  @Builder\n  private storeEntryPanel'));
const cardFaceStart = homeCard.indexOf('      Button({ type: ButtonType.Normal })');
assert.ok(cardFaceStart > 0);
const homeBacking = homeCard.slice(0, cardFaceStart);
assert.match(homeBacking, /backgroundColor\(INK\)\.borderRadius\(HOME_ENTRY_RADIUS\)/);
assert.match(homeBacking, /translate\(\{ x: HOME_ENTRY_SHADOW_X, y: HOME_ENTRY_SHADOW_Y \}\)/);
assert.match(homeBacking, /hitTestBehavior\(HitTestMode\.None\)\.accessibilityLevel\('no'\)/);
assert.doesNotMatch(homeBacking, /\.onClick/);
assert.doesNotMatch(home,
  /recording_share_hero|worksEntry\(|HOME_WORKS_(?:ROW|GROUP|ART)|stopPropagation|badgeLabel: '(?:TEAM|SOLO)'/);
assert.equal((homeCard.match(/Button\(\{ type: ButtonType\.Normal \}\)/g) || []).length, 2,
  'Practice and works use sibling controls rather than nested buttons');
assert.equal((homeCard.match(/onClick\(\(\) => this\.goPrimary\(kind\)\)/g) || []).length, 1);
assert.equal((homeCard.match(/onClick\(\(\) => this\.goSecondary\(kind\)\)/g) || []).length, 1);
assert.match(homeCard, /\.position\(\{[\s\S]*HOME_WORKS_PILL_INSET_LEFT/,
  'Works pill uses explicit coordinates so it cannot stack over the title');
assert.match(homeCard,
  /layoutWeight\(kind === 'team' \? HOME_TEAM_ENTRY_WEIGHT : HOME_SOLO_ENTRY_WEIGHT\)/,
  'The selected C layout must retain asymmetric practice cards');
assert.match(home, /const HOME_TEAM_ENTRY_WEIGHT: number = 56/);
assert.match(home, /const HOME_SOLO_ENTRY_WEIGHT: number = 44/);
assert.match(homeCard, /backgroundColor\(PAPER\)/,
  'Works pills use a soft paper capsule distinct from the practice card fill');
assert.match(homeCard, /HOME_WORKS_PILL_INK/);
assert.match(homeCard, /HOME_WORKS_PILL_BORDER/);
const storeCard = home.slice(home.indexOf('  private storeEntryPanel('), home.indexOf('  build()'));
assert.doesNotMatch(storeCard, /Image\(/, 'The selected store panel intentionally has no illustration');
assert.match(storeCard, /backgroundColor\(LILAC\)/);
assert.match(storeCard, /角色 \/ 场景 \/ 鼓机/);
assert.match(home, /SAME BEAT!/);
assert.match(storeCard, /onClick\(\(\) => this\.goPrimary\('store'\)\)/);
assert.match(home, /onebeat_wordmark\.png[\s\S]*entry_burst\.png[\s\S]*height\(245\)\.clip\(true\)/,
  'The existing title and hero remain unchanged above the redesigned entries');
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
assert.equal(page.worksCount('team'), 2);
assert.equal(page.worksCount('solo'), 1);
assert.match(page.practiceAccessibility('team', '多人练习'), /组队同行，同拍出发/);
assert.match(page.worksAccessibility('team'), /多人练习作品，2段/);
clips = [{ scope: 'team', durationMs: 65000 }];
page.onPageShow();
assert.equal(page.worksCount('team'), 1, 'Returning from deletion refreshes the real count');
assert.equal(page.worksCount('solo'), 0, 'Empty libraries do not show fabricated works');
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
console.log('PASS: paired home panels preserve the hero, use selected scene assets, independent works controls and scoped counts; shared ComicButton fallback retained');
