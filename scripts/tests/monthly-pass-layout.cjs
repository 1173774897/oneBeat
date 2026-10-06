// Run with Node and a typescript/lib/typescript.js path. Geometry is not device-pixel verification.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require(process.argv[2]);
const root = path.resolve(__dirname, '../..');
const source = fs.readFileSync(path.join(root, 'entry/src/main/ets/pages/StorePage.ets'), 'utf8');
const asset = fs.readFileSync(path.join(root, 'entry/src/main/resources/rawfile/comic/decor/monthly_pass_coupon.svg'), 'utf8');
const rhythm = fs.readFileSync(path.join(root, 'entry/src/main/resources/rawfile/comic/decor/monthly_pass_rhythm.svg'), 'utf8');
function numberConstant(name) {
  const match = source.match(new RegExp('const ' + name + ': number = ([0-9.]+);'));
  assert.ok(match, name + ' must remain adjustable');
  return Number(match[1]);
}
function shareConstant(name) {
  const match = source.match(new RegExp("const " + name + ": string = '([0-9.]+)%';"));
  assert.ok(match, name + ' must remain responsive');
  return Number(match[1]) / 100;
}
const art = source.slice(source.indexOf('private passBannerArt()'), source.indexOf('private passBanner()'));
const banner = source.slice(source.indexOf('private passBanner()'), source.indexOf('private tabBar()'));
const titleLayer = source.slice(source.indexOf('private passBannerTitleLayer('), source.indexOf('private passBannerTitle()'));
const title = source.slice(source.indexOf('private passBannerTitle()'), source.indexOf('private passBannerArt()'));
assert.match(titleLayer, /Text\('畅游月卡'\)/, 'Keep all four characters in a single text run');
assert.match(titleLayer, /\.maxLines\(1\)/);
assert.match(titleLayer, /\.fontSize\(this\.passBannerTitleSize\(\)\)/);
assert.match(titleLayer, /\.accessibilityLevel\('no'\)/, 'Outlined copies must not be announced four times');
assert.match(title, /\.accessibilityGroup\(true\)\.accessibilityText\('畅游月卡'\)/);
for (const layer of ['INK, 5', 'LILAC, 3.6', 'INK, 1.35', 'PAPER, 0']) {
  assert.ok(title.includes('this.passBannerTitleLayer(' + layer + ')'), 'Keep the layered comic lettering');
}
assert.doesNotMatch(banner, /Text\('畅游'\)|Text\('月卡'\)/, 'Do not return to a two-line title');
assert.match(banner, /this\.passBannerTitle\(\)/);
assert.match(banner, /comic\/decor\/monthly_pass_rhythm\.svg/);
assert.match(banner, /\.onAreaChange\(/, 'Use the rendered main-ticket width rather than a guessed device width');
assert.match(banner, /Number\.isFinite\(width\) && width > 0/);
assert.match(banner, /\.constraintSize\(\{ maxWidth: PASS_BANNER_MAX_WIDTH \}\)/);
assert.doesNotMatch(banner, /subscription_ticket|\.rotate\(/, 'Keep live text flat, not mapped onto a curved ticket');
assert.doesNotMatch(art, /lamp|wave/, 'Use the requested Cloud/Lilroll/Mismatch trio');
assert.doesNotMatch(art, /curly|buzz|braids|boonie/, 'Free random-pool members are not monthly-pass artwork');
for (const name of ['cloud', 'lilroll', 'mismatch']) {
  assert.match(art, new RegExp("avatar: '" + name + "', portrait: true"));
  assert.match(source, new RegExp("key: '" + name + "'.*productId: 'onebeat\\.character\\." + name + "'"), 'Editorial faces must be paid catalog characters');
  assert.ok(fs.existsSync(path.join(root, 'entry/src/main/resources/rawfile/comic/avatars', name + '.png')));
}
const portraits = art.split('ComicCharacter(').slice(1);
assert.equal(portraits.length, 3, 'Keep exactly three interleaved portrait layers');
assert.match(portraits[0], /avatar: 'cloud'/);
assert.doesNotMatch(portraits[0], /\.scale\(/);
assert.match(portraits[1], /avatar: 'lilroll'/);
assert.match(portraits[1], /\.scale\(\{ x: -1, y: 1 \}\)/, 'Only Lilroll is horizontally mirrored');
assert.match(portraits[2], /avatar: 'mismatch'/);
assert.doesNotMatch(portraits[2], /\.scale\(/, 'Mismatch must retain the original direction');
assert.match(art, /\.hitTestBehavior\(HitTestMode.None\)\.accessibilityLevel\('no'\)/);
assert.match(banner, /Text\(this\.passDescription\(\)\)/, 'Expiry and renewal status must stay live');
const description = banner.slice(banner.indexOf('Text(this.passDescription())'), banner.indexOf('}.width(PASS_BANNER_MAIN_SHARE)'));
assert.match(description, /\.maxLines\(1\)\.align\(Alignment.Start\)/, 'Keep live status on one vertically centered line');
assert.match(description, /\.minFontSize\(PASS_BANNER_DESCRIPTION_FONT_MIN\)\.maxFontSize\(PASS_BANNER_DESCRIPTION_FONT_MAX\)/);
assert.match(description, /\.heightAdaptivePolicy\(TextHeightAdaptivePolicy.MIN_FONT_SIZE_FIRST\)/, 'Shrink for width instead of wrapping or truncating');
assert.match(banner, /Button\(this\.passButtonLabel\(\)/);
assert.match(banner, /\.enabled\(this\.passIapPurchaseAllowed && !this\.passActive\)/);
assert.match(banner, /\.onClick\(\(\) => this\.openPassPurchase\(\)\)/);
const action = banner.slice(banner.indexOf('Stack() {', banner.indexOf('Blank()')), banner.indexOf('}.width(PASS_BANNER_STUB_SHARE)'));
assert.match(action, /Stack\(\) \{\s+Button\(this\.passButtonLabel\(\)/, 'Keep the opaque backing outside the disabled button');
assert.match(action, /\.backgroundColor\('#00000000'\)/, 'Only the interactive surface receives native disabled opacity');
assert.match(action, /\}\.width\('100%'\)\.height\(34\)\.backgroundColor\(PAPER\)/, 'Mask the perforations with an opaque face in all states');
const actionBacking = action.slice(action.indexOf("}.width('100%')"));
assert.match(actionBacking, /\.shadow\(CONTROL_SHADOW\)\.zIndex\(2\)/);
assert.doesNotMatch(actionBacking, /\.enabled\(|\.opacity\(/, 'Never dim the independent opaque backing');
assert.match(banner, /\.objectFit\(ImageFit.Fill\)\.zIndex\(0\)/);
assert.match(banner, /\.width\('97\.78%'\)\.height\(PASS_BANNER_FACE_HEIGHT\)\.zIndex\(1\)/);
assert.match(banner, /\.shadow\(CONTROL_SHADOW\)/);
assert.match(banner, /\.minFontSize\(20\)\.maxFontSize\(23\)/, 'PASS must fit the narrow stub');
assert.match(banner, /\.clip\(false\)/, 'Keep the hard backing visible');
assert.doesNotMatch(asset, /<text\b|<image\b/, 'Background must not bake in copy or character images');
assert.match(asset, /preserveAspectRatio="none"/, 'Fixed-height responsive tickets must not letterbox the vector face');
for (const color of ['#FFF9EE', '#FF7056', '#C5B7EB', '#171B1F']) {
  assert.ok(asset.includes(color), 'Keep the application palette: ' + color);
}
const contours = [...asset.matchAll(/<path d="([^"]+)"/g)].map(match => match[1]);
assert.equal(contours[0], contours[1], 'Shadow and face must share both cutouts');
assert.equal(contours[0], contours.at(-1), 'Outer ink contour must match the face');
assert.match(asset, /transform="translate\(3 4\)"/);
assert.equal((contours[0].match(/A13 13/g) || []).length, 2);
assert.match(asset, /stroke-dasharray="6 5"/);
assert.doesNotMatch(rhythm, /<text\b|<image\b/);
for (const color of ['#FFF9EE', '#FF7056', '#C5B7EB', '#171B1F', '#29B5AE']) {
  assert.ok(rhythm.includes(color), 'Percussion illustration must use the application palette: ' + color);
}
assert.equal((rhythm.match(/rx="(?:41|42)" ry="16"/g) || []).length, 2, 'Keep two distinct drum heads');
const mainShare = shareConstant('PASS_BANNER_MAIN_SHARE');
const stubShare = shareConstant('PASS_BANNER_STUB_SHARE');
assert.equal(mainShare + stubShare, 1);
assert.ok(Math.abs(mainShare - 254 / 352) < 0.002, 'Native text and artwork must align with the SVG perforation');
const height = numberConstant('PASS_BANNER_HEIGHT');
const faceHeight = numberConstant('PASS_BANNER_FACE_HEIGHT');
const artBottom = numberConstant('PASS_BANNER_ART_TOP') + numberConstant('PASS_BANNER_ART_HEIGHT');
const textLeft = numberConstant('PASS_BANNER_TEXT_LEFT');
const descriptionTop = numberConstant('PASS_BANNER_DESCRIPTION_TOP');
const descriptionLineTop = descriptionTop + (numberConstant('PASS_BANNER_DESCRIPTION_HEIGHT') -
  numberConstant('PASS_BANNER_DESCRIPTION_LINE_HEIGHT')) / 2;
assert.ok(artBottom <= descriptionLineTop, 'The centered single status line must remain below the artwork');
assert.ok(numberConstant('PASS_BANNER_DESCRIPTION_LINE_HEIGHT') >= numberConstant('PASS_BANNER_DESCRIPTION_FONT_MAX'));
assert.ok(numberConstant('PASS_BANNER_DESCRIPTION_FONT_MIN') > 0 &&
  numberConstant('PASS_BANNER_DESCRIPTION_FONT_MIN') < numberConstant('PASS_BANNER_DESCRIPTION_FONT_MAX'));
assert.ok(descriptionTop + numberConstant('PASS_BANNER_DESCRIPTION_HEIGHT') <= faceHeight - 4,
  'Keep live status clear of the bottom ink border without increasing ticket height');
assert.ok(faceHeight + 8 <= height, 'Reserve hard-shadow space before the next section');
const sizingHelpers = source.slice(source.indexOf('private passBannerArtWidth()'), source.indexOf('  @Builder\n  private passBannerTitleLayer('));
const sizingConstants = source.slice(source.indexOf('const PASS_BANNER_HEIGHT:'), source.indexOf('// The bubble hugs'));
const sizingCompiled = ts.transpileModule(sizingConstants + '\nexport class PassSizing { passBannerMainWidth = 203;\n' + sizingHelpers + '\n}', {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 }, reportDiagnostics: true
});
assert.equal(sizingCompiled.diagnostics.filter(d => d.category === ts.DiagnosticCategory.Error).length, 0);
const sizingContext = { exports: {} };
vm.runInNewContext(sizingCompiled.outputText, sizingContext);
const sizing = new sizingContext.exports.PassSizing();
let previousSize = 0;
for (const viewport of [320, 360, 390, 430, 600, 768]) {
  const faceWidth = Math.min(viewport - 32, numberConstant('PASS_BANNER_MAX_WIDTH')) * 0.9778;
  const mainWidth = faceWidth * mainShare;
  sizing.passBannerMainWidth = mainWidth;
  const artWidth = sizing.passBannerArtWidth();
  const artLeft = mainWidth - artWidth - numberConstant('PASS_BANNER_ART_RIGHT');
  const titleWidth = sizing.passBannerTitleWidth();
  const fontSize = sizing.passBannerTitleSize();
  assert.ok(fontSize >= previousSize && fontSize >= 22 && fontSize <= 43, viewport + ': scale the title with usable width');
  previousSize = fontSize;
  assert.ok(fontSize * 4 <= titleWidth - numberConstant('PASS_BANNER_TITLE_INSET') * 2, viewport + ': keep the title on one line');
  const outerStroke = 5 * fontSize / 33;
  assert.ok((fontSize * 4 + outerStroke * 2) / titleWidth >= 0.93, viewport + ': fill the space left of the portraits');
  assert.ok(textLeft + titleWidth + numberConstant('PASS_BANNER_TITLE_GAP') <= artLeft + 0.01, viewport + ': keep the outlined title clear of portraits');
  const titleBottom = numberConstant('PASS_BANNER_TITLE_TOP') + (numberConstant('PASS_BANNER_TITLE_HEIGHT') + fontSize) / 2 + outerStroke;
  assert.ok(titleBottom <= numberConstant('PASS_BANNER_DRUMS_TOP'), viewport + ': clear the percussion row');
  const shadows = Array.from(sizing.passBannerTitleOutline('#171B1F', 5));
  assert.equal(shadows.length, 24);
  assert.ok(shadows.every(shadow => shadow.radius === 0), 'Keep typography edges sharp, not blurred');
  assert.equal(sizing.passBannerTitleOutline('#FFF9EE', 0).length, 0);
  const actionWidth = faceWidth * stubShare - 9 * 2;
  assert.ok(actionWidth - 4 >= 10.5 * 5, viewport + ': the longest active-state button label must fit');
  assert.ok(mainWidth - textLeft - 16 >= 150, viewport + ': reserve usable single-line status width before native font fitting');
}
assert.ok(numberConstant('PASS_BANNER_DRUMS_TOP') + numberConstant('PASS_BANNER_DRUMS_HEIGHT') <= descriptionTop,
  'Drums must never cover entitlement or expiration information');
// Execute the real status/label helpers without the ArkUI builders or payment side effects.
const helpers = source.slice(source.indexOf('private passDate('), source.indexOf('  @Builder\n  private redemptionCard()'));
const compiled = ts.transpileModule('export class PassContract {\n' + helpers + '\n}', {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 }, reportDiagnostics: true
});
assert.equal(compiled.diagnostics.filter(d => d.category === ts.DiagnosticCategory.Error).length, 0);
const context = { exports: {} };
vm.runInNewContext(compiled.outputText, context);
const pass = new context.exports.PassContract();
const cases = [
  [{ passActive: false }, '付费角色、场景与 PRO 定制鼓机', '查看方案  ›'],
  [{ passActive: true }, '付费角色与场景', '已开通'],
  [{ passActive: true, passAutoRenewing: true }, '自动续费中', '已开通'],
  [{ passActive: true, passStatus: 'CANCELED_ACTIVE' }, '已取消续费，本期仍可使用', '已开通'],
  [{ passActive: true, passSource: 'PASS_REDEMPTION' }, '口令赠送月卡', '赠送生效中'],
  [{ passActive: true, passAutoRenewing: true, passExpiresAt: '2030-03-21T12:00:00' }, '自动续费中 · 可使用至 2030-03-21', '已开通'],
  [{ passActive: true, passStatus: 'CANCELED_ACTIVE', passExpiresAt: '2030-03-21T12:00:00' }, '已取消续费，可使用至 2030-03-21', '已开通'],
  [{ passActive: true, passSource: 'PASS_REDEMPTION', passExpiresAt: '2030-03-21T12:00:00' }, '口令赠送 · 可使用至 2030-03-21', '赠送生效中'],
  [{ passActive: true, passExpiresAt: 'not-a-date' }, '付费角色与场景', '已开通']
];
for (const [state, description, label] of cases) {
  Object.assign(pass, { passActive: false, passAutoRenewing: false, passStatus: '', passSource: '', passExpiresAt: '' }, state);
  assert.equal(pass.passDescription(), description);
  assert.equal(pass.passButtonLabel(), label);
}
console.log('PASS: single-line responsive outlined title, paid Cloud/Lilroll/Mismatch trio, double drums, 320–768vp clearance, hard shadow and nine live status cases');
