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
const dialog = source.slice(source.indexOf('private purchaseDialog()'), source.indexOf('  build()'));
assert.ok(banner.length > 0 && dialog.length > 0);

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
assert.match(banner, /Button\(this\.passButtonLabel\(\), \{ type: ButtonType\.Normal \}\)/);
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
assert.deepEqual(actionBox.map(value => Number(value.toFixed(4))), [0.784, 0.592, 0.174, 0.205]);
for (const [name, [x, y, width, height]] of [['status', statusBox], ['CTA', actionBox]]) {
  assert.ok(x >= 0 && y >= 0 && width > 0 && height > 0 && x + width <= 1 && y + height <= 1,
    name + ' stays inside the cropped artwork');
}

const helpers = source.slice(source.indexOf('private passDate('), source.indexOf('  @Builder\n  private redemptionCard()'));
const ticketHelpers = source.slice(source.indexOf('private passTicketStatusLabel()'), source.indexOf('  @Builder\n  private passBanner()'));
const openPlan = source.slice(source.indexOf('private openPassPurchase()'), source.indexOf('private openDrumIntro()'));
const constantSource = source.match(/const PASS_PRODUCT_ID: string = '[^']+';/)[0] + '\n' +
  source.match(/const PASS_BANNER_DEFAULT_WIDTH: number = [0-9.]+;/)[0];
const compiled = ts.transpileModule(constantSource + '\nexport class PassContract {\n' + helpers + ticketHelpers + openPlan + '\n}', {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 }, reportDiagnostics: true
});
assert.equal(compiled.diagnostics.filter(d => d.category === ts.DiagnosticCategory.Error).length, 0);
const context = { exports: {} };
vm.runInNewContext(compiled.outputText, context);
const pass = new context.exports.PassContract();
for (const viewport of [320, 360, 390, 430, 600, 768]) {
  const width = Math.min((viewport - 32) * 1.02, numberConstant('PASS_BANNER_MAX_WIDTH'));
  const height = width / numberConstant('PASS_BANNER_DISPLAY_RATIO');
  pass.passBannerWidth = width;
  const scale = pass.passBannerScale();
  assert.equal(scale, width / numberConstant('PASS_BANNER_DEFAULT_WIDTH'));
  assert.ok(actionBox[2] * width > 10.5 * scale * 5, viewport + ': reserve width for the longest CTA');
  assert.ok(actionBox[3] * height > 10.5 * scale, viewport + ': reserve height for the CTA');
  assert.ok(statusBox[2] * width > 7.2 * scale * 7, viewport + ': reserve width for short status/date text');
  assert.ok(statusBox[3] * height > 7.2 * scale, viewport + ': reserve height for the status');
}
const cases = [
  [{ passActive: false }, '付费角色、场景与 PRO 定制鼓机', '查看方案  ›', '全权益通行'],
  [{ passActive: true }, '付费角色与场景', '已开通', '已开通'],
  [{ passActive: true, passAutoRenewing: true }, '自动续费中', '已开通', '自动续费中'],
  [{ passActive: true, passStatus: 'CANCELED_ACTIVE' }, '已取消续费，本期仍可使用', '已开通', '本期仍有效'],
  [{ passActive: true, passSource: 'PASS_REDEMPTION' }, '口令赠送月卡', '赠送生效中', '赠送月卡'],
  [{ passActive: true, passAutoRenewing: true, passExpiresAt: '2030-03-21T12:00:00' }, '自动续费中 · 可使用至 2030-03-21', '已开通', '续费至 03-21'],
  [{ passActive: true, passStatus: 'CANCELED_ACTIVE', passExpiresAt: '2030-03-21T12:00:00' }, '已取消续费，可使用至 2030-03-21', '已开通', '有效至 03-21'],
  [{ passActive: true, passSource: 'PASS_REDEMPTION', passExpiresAt: '2030-03-21T12:00:00' }, '口令赠送 · 可使用至 2030-03-21', '赠送生效中', '赠送至 03-21'],
  [{ passActive: true, passExpiresAt: 'not-a-date' }, '付费角色与场景', '已开通', '已开通'],
  [{ passActive: false, passExpiresAt: '2030-03-21T12:00:00' }, '已于 2030-03-21 到期', '查看方案  ›', '全权益通行']
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
console.log('PASS monthly pass: approved PNG composition, responsive status/CTA at 320–768vp, full accessible expiry, ten status cases, plan-entry guards and restricted native purchase confirmation');
