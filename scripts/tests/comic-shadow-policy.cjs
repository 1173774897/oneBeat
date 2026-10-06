// Source-policy checks complement compilation; device rendering still needs visual QA.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const root = path.resolve(__dirname, '../../entry/src/main/ets');
const kit = fs.readFileSync(path.join(root, 'components/ComicKit.ets'), 'utf8');
const radiusMatch = kit.match(/export const INK_SHADOW_RADIUS: number = ([\d.]+);/);
assert.ok(radiusMatch, 'Component ink shadows need a shared nonzero blur radius');
const radius = Number(radiusMatch[1]);
assert.ok(radius > 0 && radius <= 1, 'Keep component shadows enabled and near-hard');
assert.match(kit, /CARD_SHADOW: ShadowOptions = \{ radius: INK_SHADOW_RADIUS, offsetX: 3, offsetY: 4, color: INK \}/);
assert.match(kit, /CONTROL_SHADOW: ShadowOptions = \{ radius: INK_SHADOW_RADIUS, offsetX: 2, offsetY: 2, color: INK \}/);

let shared = 0;
let inline = 0;
let transparentOff = 0;
let sharpText = 0;
function scan(dir) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const file = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      scan(file);
    } else if (file.endsWith('.ets')) {
      const source = fs.readFileSync(file, 'utf8');
      shared += (source.match(/\.shadow\((?:CARD_SHADOW|CONTROL_SHADOW)\)/g) || []).length;
      inline += (source.match(/\.shadow\(\{ radius: INK_SHADOW_RADIUS/g) || []).length;
      sharpText += (source.match(/\.textShadow\(\{ radius: 0/g) || []).length;
      for (const match of source.matchAll(/\.shadow\(([^)]*)\)/g)) {
        if (/radius:\s*0\b/.test(match[1])) {
          assert.match(match[1], /color:\s*'#00000000'/,
            path.relative(root, file) + ': visible native shadows must not use radius=0');
          transparentOff++;
        }
      }
    }
  }
}
scan(root);
assert.ok(shared >= 81, 'Shared card/control shadow references must remain intact');
assert.ok(inline >= 17, 'All audited inline shadows must use the shared compatible radius');
assert.equal(transparentOff, 1, 'Only the solid-button face intentionally disables native shadows');
assert.ok(sharpText >= 6, 'Do not blanket-rewrite sharp text shadows as component blur');
const main = fs.readFileSync(path.join(root, 'pages/MainPage.ets'), 'utf8');
assert.match(main, /\.shadow\(\{ radius: 8, color: '#9935D6E4', offsetX: 0, offsetY: 0 \}\)/);
assert.match(main, /radius: INK_SHADOW_RADIUS, offsetX: 3, offsetY: -4/, 'Keep upward bottom-panel shadow');
console.log('PASS: ' + shared + ' shared and ' + inline +
  ' inline component shadows enabled; sharp text, cyan glow and transparent shadow-off retained');
