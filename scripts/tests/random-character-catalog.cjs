// Run with Node and a typescript/lib/typescript.js path, matching existing test scripts.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const crypto = require('node:crypto');
const ts = require(process.argv[2]);
const root = path.resolve(__dirname, '../..');
const ets = name => fs.readFileSync(path.join(root, 'entry/src/main/ets', name), 'utf8');
const randomMath = Object.create(Math);
let random = 0;
randomMath.random = () => random;

function load(source, mocks) {
  const context = { exports: {}, Math: randomMath, require: name => {
    assert.ok(name in mocks, `Unexpected import: ${name}`);
    return mocks[name];
  }};
  const result = ts.transpileModule(source, {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 },
    reportDiagnostics: true
  });
  assert.equal(result.diagnostics.filter(d => d.category === ts.DiagnosticCategory.Error).length, 0);
  vm.runInNewContext(result.outputText, context);
  return context.exports;
}

const catalog = load(ets('assets/CharacterCatalog.ets'), {
  '../store/EntitlementStore': { isCharacterAccessible: () => false }
});
const assets = load(ets('assets/AssetCatalog.ets'), { './CharacterCatalog': catalog });
const comic = load(ets('components/ComicKit.ets').split('@Component')[0], {
  '../assets/CharacterCatalog': catalog
});
const keys = Array.from(catalog.RANDOM_CHARACTER_KEYS);
assert.deepEqual(keys, ['braids', 'boonie', 'curly', 'buzz']);
assert.equal(catalog.defaultSessionAvatar(), 'random');
assert.equal(catalog.isRandomPoolCharacter('unknown'), false);
assert.equal(catalog.randomPaletteCount('cloud'), 0);
assert.equal(catalog.isDuplicatableAvatar('random'), true);
assert.equal(catalog.isAvatarAllowedForSession('random', false), true);
const rawfiles = path.join(root, 'entry/src/main/resources/rawfile');

function png(filename) {
  const data = fs.readFileSync(path.join(rawfiles, filename));
  assert.deepEqual(data.subarray(0, 8), Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]));
  assert.ok(data.readUInt32BE(16) > 0 && data.readUInt32BE(20) > 0);
  let transparent = [4, 6].includes(data[25]);
  // Existing silhouettes use indexed PNG transparency rather than an RGBA color type.
  for (let offset = 8; offset + 12 <= data.length;) {
    const length = data.readUInt32BE(offset);
    assert.ok(offset + length + 12 <= data.length, `Truncated PNG: ${filename}`);
    const type = data.toString('ascii', offset + 4, offset + 8);
    if (type === 'tRNS') {
      transparent = data[25] === 3
        ? data.subarray(offset + 8, offset + 8 + length).some(alpha => alpha < 255)
        : [0, 2].includes(data[25]);
    }
    offset += length + 12;
  }
  assert.ok(transparent, `Missing PNG transparency: ${filename}`);
  return data;
}

for (const [index, key] of keys.entries()) {
  random = (index + 0.5) / keys.length;
  assert.equal(catalog.pickRandomCharacterKey(), key);
  assert.equal(catalog.randomPaletteCount(key), 2);
  assert.equal(catalog.isAvatarAllowedForSession(key, true), false, 'Random identities are not direct lobby choices');
  assert.equal(assets.memberAvatar('random', 0, key), key);
  assert.equal(assets.memberAvatar(key, 0), key);
  png(`comic/mystery/${key}.png`);
  for (const slot of [0, 1]) {
    const avatar = comic.revealedAvatarAsset('random', key, slot);
    assert.equal(avatar, `${key}_palette_${slot + 1}`);
    const firstFrame = png(assets.walkFramePath(key, 0, slot));
    const portrait = png(`comic/avatars/${avatar}.png`);
    assert.equal(crypto.createHash('sha256').update(firstFrame).digest('hex'),
      crypto.createHash('sha256').update(portrait).digest('hex'));
    for (let beat = 0; beat < 2; beat++) {
      for (let step = 0; step < 4; step++) {
        const frame = assets.walkerAnimFrameIndex(key, beat, step);
        assert.equal(frame, beat * 4 + step);
        png(assets.walkFramePath(key, frame, slot));
      }
    }
    assert.equal(assets.walkFramePath(key, 8, slot), assets.walkFramePath(key, 0, slot));
  }
  random = 0;
  const first = { id: 'first', avatarKey: 'random', resolvedAvatarKey: key, colorSlot: 0 };
  const second = { id: 'second', avatarKey: 'random', resolvedAvatarKey: key, colorSlot: 1 };
  assert.equal(catalog.pickRandomColorSlot([first], key, 'new'), 1);
  assert.equal(catalog.pickRandomColorSlot([first, second], key, 'new'), 0);
  assert.equal(catalog.pickRandomColorSlot([first], key, 'first'), 0);
  assert.equal(catalog.pickRandomColorSlot([{ ...first, resolvedAvatarKey: 'unknown' }], key, 'new'), 0);
}

// Exercise the film's actual pure index methods with the expanded pool.
const film = ets('components/RandomCharacterFilm.ets');
const constants = film.slice(film.indexOf('const FILM_SIDE_INSET'), film.indexOf('/** Lobby-only'));
const methods = film.slice(film.indexOf('  private poolSize()'), film.indexOf('  private invalidatePlayback()'));
const filmIndexes = load(`const RANDOM_CHARACTER_KEYS = ${JSON.stringify(keys)};\n${constants}
export class FilmIndexes {
  resolvedAvatarKey: string = '';
  cardIndices: number[] = [];
${methods}
}`, {});
const reel = new filmIndexes.FilmIndexes();
reel.cardIndices = reel.makeCardIndices();
for (const key of keys) {
  reel.resolvedAvatarKey = key;
  assert.equal(reel.cardAvatar(reel.resultIndex()), key);
  assert.ok(reel.cardIndices.includes(reel.resultIndex()));
  assert.equal(reel.cardOffset(reel.resultIndex()), -reel.resultIndex() * 130);
}
assert.match(ets('scene/WalkerSprite.ets'), /else if \(isRandomPoolCharacter\(this\.avatar\)\)/);
assert.match(ets('scene/RandomPoolWalkerLayers.ets'), /isRandomPoolCharacter\(this\.avatar\)/);
for (const key of ['curly', 'buzz']) {
  assert.match(ets('pages/StorePage.ets'), new RegExp(`key: '${key}'.*mystery: true`));
}
assert.equal(assets.memberAvatar('random', 1, 'unknown'), 'mismatch');
assert.equal(comic.revealedAvatarAsset('random', 'unknown', 1), 'random');
console.log('PASS: 4 random identities, 8 palette variants, 64 frames, concealed/colored avatars, palette allocation, film stops');
