// Run with Node and a typescript/lib/typescript.js path, matching existing test scripts.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require(process.argv[2]);
const source = fs.readFileSync(path.resolve(__dirname, '../../entry/src/main/ets/scene/WalkScene.ets'), 'utf8');
const constants = source.slice(source.indexOf('const ENTITY_DISPLAY_HEIGHT'), source.indexOf('interface SideEntityView'));
const methods = source.slice(source.indexOf('  private walkerStandLeftMinXPx()'),
  source.indexOf('  @Builder\n  private roadTileDirt1('));
assert.ok(methods.includes('private ensureWalkerStands()'), 'Test must exercise the scene layout implementation');
const code = constants + '\n' + [
  'interface WalkerStandSlot { xRatio: number; yOffset: number; }',
  'export class WalkerLayout {',
  'sceneWidth: number = 360;',
  'members: { id: string; avatarKey: string; }[] = [];',
  "walkerLayoutMemberSig: string = '';",
  'walkerStands: WalkerStandSlot[] = [];',
  'private walkerColumnTop(): number { return 100; }',
  methods,
  '}'
].join('\n');
let seed = 1;
const layoutMath = Object.create(Math);
layoutMath.random = () => {
  seed = (1664525 * seed + 1013904223) >>> 0;
  return seed / 4294967296;
};
const context = { exports: {}, Math: layoutMath };
const result = ts.transpileModule(code, {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 },
  reportDiagnostics: true
});
assert.equal(result.diagnostics.filter(d => d.category === ts.DiagnosticCategory.Error).length, 0);
vm.runInNewContext(result.outputText, context);
const layout = new context.exports.WalkerLayout();
const close = (actual, expected) => assert.ok(Math.abs(actual - expected) < 1e-9);

close(layout.walkerSlotXRatio(0, 0), 0.5);
close(layout.walkerSlotXRatio(0, 1), 0.5);
close(layout.walkerSlotXRatio(0, 2), 0.97);
close(layout.walkerSlotXRatio(1, 2), 0.03);
close(layout.walkerSlotXRatio(1, 3), 0.5);

function checkPositions(scene) {
  for (let index = 0; index < scene.members.length; index++) {
    const x = scene.walkerPositionX(index);
    assert.ok(x >= scene.walkerStandLeftMinXPx() && x <= scene.walkerStandLeftMaxXPx());
    if (index > 0 && scene.walkerStandCenterSpanPx() > 0) {
      assert.ok(scene.walkerPositionX(index - 1) > x, 'Higher member number must be further left');
    }
  }
}
let cases = 0;
for (const width of [120, 320, 360, 480, 768, 1280]) {
  for (let count = 1; count <= 8; count++) {
    for (let trial = 1; trial <= 20; trial++) {
      seed = trial;
      const scene = new context.exports.WalkerLayout();
      scene.sceneWidth = width;
      scene.members = Array.from({ length: count }, (_, index) => ({
        id: 'member-' + index, avatarKey: 'random'
      }));
      const membersBefore = JSON.stringify(scene.members);
      // Rendering before initialization must use the same right-to-left order.
      checkPositions(scene);
      scene.ensureWalkerStands();
      assert.equal(scene.walkerStands.length, count);
      checkPositions(scene);
      assert.equal(JSON.stringify(scene.members), membersBefore, 'Layout must not reorder session members');
      const stands = scene.walkerStands;
      scene.ensureWalkerStands();
      assert.equal(scene.walkerStands, stands, 'Repeated frames must not reroll positions');
      scene.members[0].avatarKey = 'cloud';
      scene.ensureWalkerStands();
      assert.equal(scene.walkerStands, stands, 'Avatar changes must not reroll positions');
      for (let index = 0; index < count; index++) {
        const offset = scene.walkerDepthYOffset(index);
        assert.ok(offset >= -38 && offset <= 26);
        assert.ok(scene.walkerDepthScale(index) >= 0.80 && scene.walkerDepthScale(index) <= 1.12);
        assert.ok(scene.walkerPositionZ(index) >= 18 && scene.walkerPositionZ(index) <= 28);
      }
      if (count === 1) {
        close(scene.walkerPositionX(0),
          (scene.walkerStandLeftMinXPx() + scene.walkerStandLeftMaxXPx()) / 2);
        close(scene.walkerPositionY(0), 100);
      }
      cases++;
    }
  }
}
layout.members = [{ id: 'first' }, { id: 'second' }, { id: 'third' }];
layout.ensureWalkerStands();
layout.members.splice(1, 1);
layout.ensureWalkerStands();
assert.equal(layout.walkerStands.length, 2);
checkPositions(layout);
layout.members.push({ id: 'new' });
layout.ensureWalkerStands();
assert.equal(layout.walkerStands.length, 3);
checkPositions(layout);
assert.match(source, /ForEach\(this\.members, \(member: SessionMember, index: number\)/);
assert.match(source, /\$\{index \+ 1\} · \$\{member\.displayName\}/);
console.log('PASS: ' + cases + ' layouts, right-to-left member order, single-member center, safe bounds, stable positions, add/remove members');
