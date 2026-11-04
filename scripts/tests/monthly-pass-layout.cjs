// Run with Node and a typescript/lib/typescript.js path. Geometry is not device-pixel verification.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require(process.argv[2]);
const root = path.resolve(__dirname, '../..');
const source = fs.readFileSync(path.join(root, 'entry/src/main/ets/pages/StorePage.ets'), 'utf8');
const asset = fs.readFileSync(path.join(root, 'entry/src/main/resources/rawfile/comic/decor/monthly_pass_ticket_v2.png'));
function numberConstant(name) {
  const match = source.match(new RegExp('const ' + name + ': number = ([0-9.]+);'));
  assert.ok(match, name + ' must remain adjustable');
  return Number(match[1]);
}
function percentageConstant(name) {
  const match = source.match(new RegExp("const " + name + ": string = '([0-9.]+)%';"));
  assert.ok(match, name + ' must remain responsive');
  return Number(match[1]) / 100;
}
const banner = source.slice(source.indexOf('private passBanner()'), source.indexOf('private restorePurchasesAction()'));
// The purchase dialog is split into section builders; the confirmation button
// lives in purchaseDialogActions(), which purchaseDialog() must still render.
const dialog = source.slice(source.indexOf('private purchaseIntroduction()'), source.indexOf('  build()'));
const dialogShell = source.slice(source.indexOf('private purchaseDialog()'), source.indexOf('  build()'));
assert.ok(banner.length > 0 && dialog.length > 0 && dialogShell.length > 0);
assert.ok(source.indexOf('private purchaseIntroduction()') < source.indexOf('private purchaseDialogActions()') &&
  source.indexOf('private purchaseDialogActions()') < source.indexOf('private purchaseDialog()'));
assert.match(dialogShell, /this\.purchaseDialogActions\(\)/, 'The confirmation actions are rendered in the dialog');

// The approved PNG replaced the old SVG/native three-portrait composition.
// Keep the live overlays and purchase boundary; do not resurrect the old UI.
assert.equal(asset.subarray(0, 8).toString('hex'), '89504e470d0a1a0a');
assert.equal(asset.subarray(12, 16).toString(), 'IHDR');
assert.equal(asset.readUInt32BE(16) / asset.readUInt32BE(20), 1750 / 899,
  'Retain the approved canvas ratio when exporting a higher-resolution copy');
assert.match(banner, /Image\(\$rawfile\('comic\/decor\/monthly_pass_ticket_v2\.png'\)\)/);
assert.match(banner, /\.width\('100%'\)\.height\('100%'\)\.objectFit\(ImageFit\.Cover\)\.zIndex\(0\)/);
assert.match(banner, /\.hitTestBehavior\(HitTestMode\.None\)\.accessibilityLevel\('no'\)/,
  'The baked-in composition cannot intercept the live CTA or repeat its copy');
assert.doesNotMatch(banner, /ComicCharacter\(|passBannerTitle|monthly_pass_coupon|monthly_pass_rhythm/);
assert.match(banner, /Text\(this\.passTicketStatusLabel\(\)\)/);
assert.match(banner, /\.position\(\{ x: PASS_BANNER_STATUS_X, y: PASS_BANNER_STATUS_Y \}\)/);
assert.match(banner, /Button\(\{ type: ButtonType\.Normal \}\)/);
assert.match(banner, /Text\(this\.passButtonLabel\(\)\)/);
assert.doesNotMatch(banner, /Button\(this\.passButtonLabel\(\)/,
  'The CTA label and arrow no longer share the native label baseline');
assert.match(banner, /if \(!this\.passActive\)/,
  'Only the plan-entry label carries a chevron; active pass states remain plain text');
assert.match(banner, /Path\(\)\s*\.commands\(this\.passBannerChevronPath\(\)\)/);
assert.match(banner, /\.lineHeight\(PASS_BANNER_STATUS_LINE_HEIGHT \* this\.passBannerScale\(\)\)/);
assert.match(banner, /\.lineHeight\(PASS_BANNER_ACTION_LINE_HEIGHT \* this\.passBannerScale\(\)\)/);
assert.ok((banner.match(/\.halfLeading\(true\)/g) || []).length >= 2,
  'Both live labels distribute extra line leading symmetrically');
assert.match(banner, /\.position\(\{ x: PASS_BANNER_ACTION_X, y: PASS_BANNER_ACTION_Y \}\)/);
assert.match(banner, /\.backgroundColor\('#00000000'\)\.borderRadius\(18\)/,
  'The live label leaves the illustrated CTA face visible');
assert.match(banner, /\.onClick\(\(\) => this\.openPassPurchase\(\)\)/);
assert.doesNotMatch(banner, /\.enabled\(|\.opacity\(/,
  'The ticket opens plan details even when a current pass prevents a new purchase');
assert.match(banner, /\.width\('102%'\)/);
assert.match(banner, /\.constraintSize\(\{ maxWidth: PASS_BANNER_MAX_WIDTH \}\)/);
assert.match(banner, /\.height\(this\.passBannerWidth \/ PASS_BANNER_DISPLAY_RATIO\)/);
assert.match(banner, /\.clip\(true\)/);
assert.match(banner, /\.accessibilityGroup\(true\)/);
assert.match(banner, /\.accessibilityText\(`畅游月卡，\$\{this\.passDescription\(\)\}，\$\{this\.passButtonLabel\(\)\}`\)/,
  'The compact visible status keeps full live expiry/renewal information available');
assert.match(banner, /\.onAreaChange\(/);
assert.match(banner, /Number\.isFinite\(width\) && width > 0/);
assert.match(banner, /this\.passBannerWidth = width/);
assert.match(dialog, /ActionButton\(\{\s*label: this\.pendingType === 'pass' && this\.passPurchaseRestriction\(\)\.length > 0 \? '暂不可购买'/);
assert.match(dialog, /active: !this\.purchaseBusy &&\s*\(this\.pendingType !== 'pass' \|\| this\.passPurchaseRestriction\(\)\.length === 0\)/,
  'The actual purchase confirmation retains its pass entitlement gate');
assert.match(dialog, /action: \(\) => \{ void this\.confirmPurchase\(\); \}/);
assert.match(source, /private async confirmPurchase\(\): Promise<void> \{\s*if \(this\.purchaseBusy \|\| this\.redemptionBusy \|\| this\.pendingProductId\.length === 0 \|\|\s*\(this\.pendingType === 'pass' && this\.passPurchaseRestriction\(\)\.length > 0\)\) \{\s*return;/,
  'Programmatic entry cannot bypass the button restriction');

const statusBox = ['X', 'Y', 'WIDTH', 'HEIGHT'].map(suffix => percentageConstant('PASS_BANNER_STATUS_' + suffix));
const actionBox = ['X', 'Y', 'WIDTH', 'HEIGHT'].map(suffix => percentageConstant('PASS_BANNER_ACTION_' + suffix));
assert.deepEqual(statusBox.map(value => Number(value.toFixed(4))), [0.062, 0.852, 0.21, 0.1]);
assert.deepEqual(actionBox.map(value => Number(value.toFixed(4))), [0.785, 0.585, 0.174, 0.205]);
for (const [name, [x, y, width, height]] of [['status', statusBox], ['CTA', actionBox]]) {
  assert.ok(x >= 0 && y >= 0 && width > 0 && height > 0 && x + width <= 1 && y + height <= 1,
    name + ' stays inside the cropped artwork');
}

const helpers = source.slice(source.indexOf('private passDate('), source.indexOf('  @Builder\n  private redemptionCard()'));
const ticketHelpers = source.slice(source.indexOf('private passTicketStatusLabel()'), source.indexOf('  @Builder\n  private passBanner()'));
const openPlan = source.slice(source.indexOf('private openPassPurchase()'), source.indexOf('private openDrumIntro()'));
const constantSource = source.match(/const PASS_PRODUCT_ID: string = '[^']+';/)[0] + '\n' +
  [...source.matchAll(/const PASS_BANNER_[A-Z_]+: number = [0-9.]+;/g)].map(match => match[0]).join('\n');
const compiled = ts.transpileModule(constantSource + '\nexport class PassContract {\n' + helpers + ticketHelpers + openPlan + '\n}', {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 }, reportDiagnostics: true
});
assert.equal(compiled.diagnostics.filter(d => d.category === ts.DiagnosticCategory.Error).length, 0);
let displayDensity = 1;
const context = { exports: {}, vp2px: value => value * displayDensity };
vm.runInNewContext(compiled.outputText, context);
const pass = new context.exports.PassContract();
for (const viewport of [320, 360, 390, 430, 600, 768]) {
  const width = Math.min((viewport - 32) * 1.02, numberConstant('PASS_BANNER_MAX_WIDTH'));
  const height = width / numberConstant('PASS_BANNER_DISPLAY_RATIO');
  pass.passBannerWidth = width;
  const scale = pass.passBannerScale();
  assert.equal(scale, width / numberConstant('PASS_BANNER_DEFAULT_WIDTH'));
  const actionFont = numberConstant('PASS_BANNER_ACTION_FONT_SIZE');
  const statusFont = numberConstant('PASS_BANNER_STATUS_FONT_SIZE');
  const actionLine = numberConstant('PASS_BANNER_ACTION_LINE_HEIGHT');
  const statusLine = numberConstant('PASS_BANNER_STATUS_LINE_HEIGHT');
  const arrowWidth = numberConstant('PASS_BANNER_ACTION_ARROW_WIDTH');
  const arrowHeight = numberConstant('PASS_BANNER_ACTION_ARROW_HEIGHT');
  const arrowStroke = numberConstant('PASS_BANNER_ACTION_ARROW_STROKE');
  const contentGap = numberConstant('PASS_BANNER_ACTION_CONTENT_GAP');
  assert.ok(actionBox[2] * width > actionFont * scale * 5, viewport + ': reserve width for the longest active CTA');
  assert.ok(actionBox[2] * width > (actionFont * 4 + contentGap + arrowWidth) * scale,
    viewport + ': the plan label and independent chevron fit together');
  assert.ok(actionLine >= actionFont && statusLine >= statusFont, 'Text line boxes contain the font sizes');
  assert.ok(actionBox[3] * height > actionLine * scale, viewport + ': reserve height for the CTA line box');
  assert.ok(statusBox[2] * width > statusFont * scale * 7, viewport + ': reserve width for short status/date text');
  assert.ok(statusBox[3] * height > statusLine * scale, viewport + ': reserve height for the status line box');
  assert.ok(arrowHeight < actionLine && arrowStroke > 0 && arrowStroke < arrowWidth,
    'The chevron fits inside the same centered text row');
  for (const density of [1, 1.5, 2, 3]) {
    displayDensity = density;
    const coords = pass.passBannerChevronPath().match(/-?\d+(?:\.\d+)?/g).map(Number);
    assert.equal(coords.length, 6, 'The chevron is a three-point path');
    const [x1, y1, x2, y2, x3, y3] = coords;
    const epsilon = 1e-6;
    assert.ok(Math.abs(x1 - x3) < epsilon && x2 > x1,
      'The independent chevron points right without font-dependent bearings');
    assert.ok(y1 < y2 && y2 < y3 && Math.abs((y1 + y3) / 2 - y2) < epsilon,
      'The visible chevron is vertically symmetric at every viewport and pixel density');
    assert.ok(Math.min(x1, x2, x3) >= -epsilon && Math.max(x1, x2, x3) <= arrowWidth * scale * density + epsilon);
    assert.ok(Math.min(y1, y2, y3) >= -epsilon && Math.max(y1, y2, y3) <= arrowHeight * scale * density + epsilon);
  }
}
// Map the overlay center back through ImageFit.Cover to the illustrated CTA face.
// This catches a responsive-box drift without pretending to verify device glyph rasterization.
const sourceWidth = asset.readUInt32BE(16);
const sourceHeight = asset.readUInt32BE(20);
const visibleSourceHeight = sourceWidth / numberConstant('PASS_BANNER_DISPLAY_RATIO');
const sourceCropY = (sourceHeight - visibleSourceHeight) / 2;
const actionSourceCenter = [
  (actionBox[0] + actionBox[2] / 2) * sourceWidth,
  sourceCropY + (actionBox[1] + actionBox[3] / 2) * visibleSourceHeight
];
assert.ok(Math.abs(actionSourceCenter[0] - 1526) < 1 && Math.abs(actionSourceCenter[1] - 585.5) < 1,
  'The CTA content box remains centered on the painted capsule');
const cases = [
  [{ passActive: false }, '付费角色、场景与 PRO 定制鼓机', '查看方案', '全权益通行'],
  [{ passActive: true }, '付费角色与场景', '已开通', '已开通'],
  [{ passActive: true, passAutoRenewing: true }, '自动续费中', '已开通', '自动续费中'],
  [{ passActive: true, passStatus: 'CANCELED_ACTIVE' }, '已取消续费，本期仍可使用', '已开通', '本期仍有效'],
  [{ passActive: true, passSource: 'PASS_REDEMPTION' }, '口令赠送月卡', '赠送生效中', '赠送月卡'],
  [{ passActive: true, passAutoRenewing: true, passExpiresAt: '2030-03-21T12:00:00' }, '自动续费中 · 可使用至 2030-03-21', '已开通', '续费至 03-21'],
  [{ passActive: true, passStatus: 'CANCELED_ACTIVE', passExpiresAt: '2030-03-21T12:00:00' }, '已取消续费，可使用至 2030-03-21', '已开通', '有效至 03-21'],
  [{ passActive: true, passSource: 'PASS_REDEMPTION', passExpiresAt: '2030-03-21T12:00:00' }, '口令赠送 · 可使用至 2030-03-21', '赠送生效中', '赠送至 03-21'],
  [{ passActive: true, passExpiresAt: 'not-a-date' }, '付费角色与场景', '已开通', '已开通'],
  [{ passActive: false, passExpiresAt: '2030-03-21T12:00:00' }, '已于 2030-03-21 到期', '查看方案', '全权益通行']
];
for (const [state, description, label, status] of cases) {
  Object.assign(pass, { passActive: false, passAutoRenewing: false, passStatus: '', passSource: '', passExpiresAt: '' }, state);
  assert.equal(pass.passDescription(), description);
  assert.equal(pass.passButtonLabel(), label);
  assert.equal(pass.passTicketStatusLabel(), status);
}
for (const [state, restriction] of [
  [{ passActive: false, passIapPurchaseAllowed: true }, ''],
  [{ passActive: false, passIapPurchaseAllowed: false }, '当前暂不能购买自动续费月卡，请稍后重试'],
  [{ passActive: true, passSource: '' }, '畅游月卡已生效'],
  [{ passActive: true, passSource: 'PASS_REDEMPTION' }, '赠送月卡生效期间不能购买自动续费月卡']
]) {
  Object.assign(pass, { passActive: false, passIapPurchaseAllowed: true, passSource: '' }, state);
  assert.equal(pass.passPurchaseRestriction(), restriction);
  pass.productPrice = () => 'synthetic-price';
  Object.assign(pass, { purchaseVisible: false, purchaseBusy: false, redemptionBusy: false });
  pass.openPassPurchase();
  assert.equal(pass.purchaseVisible, true, 'A restricted pass can still open its plan details');
  assert.equal(pass.pendingProductId, 'onebeat.pass.monthly');
}
for (const busy of ['purchaseBusy', 'redemptionBusy']) {
  Object.assign(pass, { purchaseBusy: false, redemptionBusy: false, purchaseVisible: false }, { [busy]: true });
  pass.openPassPurchase();
  assert.equal(pass.purchaseVisible, false, busy + ': do not replace an in-flight transaction');
}
console.log('PASS monthly pass: approved PNG composition, centered status/CTA at 320–768vp, density-independent symmetric chevron, full accessible expiry, ten status cases, plan-entry guards and restricted native purchase confirmation');
