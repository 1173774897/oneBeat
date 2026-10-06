// Source/geometry checks complement the ArkUI build; they do not verify device pixels.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const root = path.resolve(__dirname, '../..');
const source = fs.readFileSync(path.join(root, 'entry/src/main/ets/pages/StorePage.ets'), 'utf8');
const asset = fs.readFileSync(path.join(root, 'entry/src/main/resources/rawfile/comic/decor/redemption_speech_bubble.svg'), 'utf8');
function constant(name) {
  const match = source.match(new RegExp('const ' + name + ': number = ([0-9.]+);'));
  assert.ok(match, name + ' must remain adjustable');
  return Number(match[1]);
}
const bubbleWidth = constant('REDEMPTION_SPEECH_WIDTH');
const bodyHeight = constant('REDEMPTION_SPEECH_BODY_HEIGHT');
const tailHeight = constant('REDEMPTION_SPEECH_TAIL_HEIGHT');
const paddingX = constant('REDEMPTION_SPEECH_PADDING_X');
const heroHeight = constant('REDEMPTION_HERO_HEIGHT');
const characterWidth = constant('REDEMPTION_CHARACTER_WIDTH');
const characterHeight = constant('REDEMPTION_CHARACTER_HEIGHT');
const characterTop = constant('REDEMPTION_CHARACTER_TOP');
const rightBleed = constant('REDEMPTION_CHARACTER_RIGHT_BLEED');
const bubble = source.slice(source.indexOf('private redemptionSpeechBubble()'), source.indexOf('private redemptionHero()'));
const hero = source.slice(source.indexOf('private redemptionHero()'), source.indexOf('private redemptionPage()'));
const page = source.slice(source.indexOf('private redemptionPage()'), source.indexOf('private limitedPrice('));
const contours = [...asset.matchAll(/<path d="([^"]+)"/g)].map(match => match[1]);
assert.equal(contours.length, 2);
assert.equal(contours[0], contours[1], 'Face and solid shadow must include the same tail');
assert.match(contours[0], /H127L131 111L107 99/, 'Keep the tail within the shared silhouette');
assert.match(asset, /transform="translate\(3 4\)"/);
assert.match(asset, /fill="#FFFDF8"/);
assert.doesNotMatch(asset, /<text\b/, 'Speech must remain live native text');
assert.match(asset, new RegExp('viewBox="0 0 ' + (bubbleWidth + 8) + ' ' + (bodyHeight + tailHeight + 8) + '"'));
assert.match(bubble, /Text\('说出暗号，'\)/);
assert.match(bubble, /Text\('节拍开门！'\)/);
assert.equal((bubble.match(/\.maxLines\(1\)/g) || []).length, 2, 'Each complete phrase stays on its own line');
assert.ok(bubbleWidth - paddingX * 2 >= 25 * 5, 'Do not trim the five-character phrases');
assert.match(bubble, /\.clip\(false\)/, 'The arrow shadow must not be clipped');
assert.match(bubble, /\.position\(\{ x: 0, y: 8 \}\)/, 'Position the bubble root, not the void builder call');
assert.match(hero, /pose: 'mismatch-ticket'/);
assert.match(hero, /\.scale\(\{ x: -1, y: 1 \}\)/, 'Mirror only the editorial pose');
assert.match(hero, /\.position\(\{ x: '100%', y: REDEMPTION_CHARACTER_TOP \}\)/);
assert.match(hero, /REDEMPTION_CHARACTER_RIGHT_BLEED - REDEMPTION_CHARACTER_WIDTH/);
assert.ok(characterHeight > 194, 'Enlarge the selected concept\'s character');
assert.ok(characterTop + characterHeight <= heroHeight, 'Reserve space before the redemption form');
assert.ok(rightBleed < 32, 'Overhang must stay inside the pose\'s transparent trailing margin');
for (const viewport of [320, 360, 390, 430]) {
  const contentWidth = viewport - 18 * 2;
  const characterLeft = contentWidth - characterWidth + rightBleed;
  assert.ok(characterLeft + 12 > bubbleWidth + 8, viewport + ': keep the mirrored ticket clear of the bubble');
  assert.ok(characterLeft >= contentWidth * 0.46, viewport + ': keep explanatory text clear of the character');
  assert.ok(bubbleWidth + 8 < contentWidth, viewport + ': keep the speech bubble inside the page');
}
assert.match(page, /this\.redemptionHero\(\)/);
assert.match(page, /this\.redemptionCard\(\)/);
assert.match(source, /\.enabled\(!this\.redemptionBusy && this\.redemptionCode\.trim\(\)\.length > 0\)/);
assert.match(source, /\.onClick\(\(\) => void this\.submitRedemption\(\)\)/);
assert.ok(fs.existsSync(path.join(root, 'entry/src/main/resources/rawfile/comic/poses/mismatch-ticket.png')));
console.log('PASS: compact live speech, unified arrow hard shadow, enlarged mirrored pose, 320–430vp clearance and existing redemption flow retained');
