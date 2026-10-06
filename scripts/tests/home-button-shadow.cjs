// Source-contract checks complement the ArkUI build; they do not verify device pixels.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const root = path.resolve(__dirname, '../..');
const home = fs.readFileSync(path.join(root, 'entry/src/main/ets/pages/Index.ets'), 'utf8');
const kit = fs.readFileSync(path.join(root, 'entry/src/main/ets/components/ComicKit.ets'), 'utf8');
const button = kit.slice(kit.indexOf('export struct ComicButton'));
const hardStart = button.indexOf('if (this.hardShadow !== undefined)');
const fallbackStart = button.indexOf('} else {', hardStart);
assert.ok(hardStart >= 0 && fallbackStart > hardStart, 'Keep hard shadows opt-in');
const hard = button.slice(hardStart, fallbackStart);
assert.match(home, /HOME_BUTTON_SHADOW: ComicHardShadowOptions = \{ offsetX: 2, offsetY: 3, color: INK \}/);
for (const label of ['多人练习', '单人练习', '收藏小铺']) {
  const config = home.slice(home.indexOf(`ComicButton({ label: '${label}'`)).split('action:')[0];
  assert.match(config, /hardShadow: HOME_BUTTON_SHADOW/, label + ' needs a solid backing');
}
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
console.log('PASS: three home buttons use solid, non-interactive ink backings; original dimensions, actions and native-shadow fallback retained');
