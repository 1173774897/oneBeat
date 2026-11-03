#!/usr/bin/env node
'use strict';

const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const assert = require('node:assert/strict');
let sharp;
try { sharp = require('sharp'); } catch (_) {
  sharp = require('/Users/lizhe/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules/sharp');
}

const root = __dirname;
const readJson = name => JSON.parse(fs.readFileSync(path.join(root, name), 'utf8'));
const hash = bytes => crypto.createHash('sha256').update(bytes).digest('hex');
const round = value => Number(value.toFixed(4));
const report = readJson('render-report.json');
const layout = readJson('scene-layout.json');
const phoneReport = readJson('phone-preview/build-report.json');
const width = report.master.width;
const height = report.master.height;
const scale = report.logical.scale;

async function sprite(item, type, order) {
  const relative = type === 'entity' ? `scenes/sunset/entities/${item.asset}.png` : `vegetation/${item.asset}.png`;
  const copiedPath = `assets/${relative}`;
  const source = report.assets.find(asset => asset.copy === copiedPath);
  assert(source, `Missing source manifest for ${item.id}`);
  const bytes = fs.readFileSync(path.join(root, copiedPath));
  assert.equal(hash(bytes), source.sha256, `Asset changed since rendering: ${copiedPath}`);
  const image = item.imagePx || Object.fromEntries(Object.entries(item.imageVp).map(([key, value]) => [key, value * scale]));
  const x = Math.floor(image.x), y = Math.floor(image.y);
  const w = Math.ceil(image.x + image.width) - x;
  const h = Math.ceil(image.y + image.height) - y;
  // Keep the global fractional-pixel origin: resizing a cropped PNG separately
  // would change edge coverage and mismeasure objects next to a rotated frame.
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="${w}" height="${h}" viewBox="${x} ${y} ${w} ${h}"><image href="data:image/png;base64,${bytes.toString('base64')}" x="${image.x}" y="${image.y}" width="${image.width}" height="${image.height}" preserveAspectRatio="none"/></svg>`;
  const raster = await sharp(Buffer.from(svg)).ensureAlpha().raw().toBuffer();
  const alpha = new Float32Array(w * h);
  for (let i = 0; i < alpha.length; i++) alpha[i] = raster[i * 4 + 3] / 255;
  return { id: item.id, asset: item.asset, type, order, z: item.z, foreground: item.foreground,
    cluster: item.cluster, xVp: item.xVp, source: copiedPath, imagePx: image, x, y, w, h, alpha };
}

function alphaAt(sprite, x, y) {
  const sx = x - sprite.x, sy = y - sprite.y;
  return sx >= 0 && sy >= 0 && sx < sprite.w && sy < sprite.h ? sprite.alpha[sy * sprite.w + sx] : 0;
}

function overlaps(a, b) {
  return a.x < b.x + b.w && a.x + a.w > b.x && a.y < b.y + b.h && a.y + a.h > b.y;
}

function measure(target, sprites, frameAlpha) {
  // Native rendering sorts by z, then keeps entity-before-vegetation insertion
  // order. Far entities can be covered by every plant; near ones only by z29.
  const above = sprites.filter(other => other !== target && overlaps(target, other) &&
    (other.z > target.z || (other.z === target.z && other.order > target.order)));
  let total = 0, inside = 0, frameOnly = 0, frameAndPlants = 0, final = 0;
  for (let sy = 0; sy < target.h; sy++) for (let sx = 0; sx < target.w; sx++) {
    const own = target.alpha[sy * target.w + sx];
    total += own;
    if (!own) continue;
    const x = target.x + sx, y = target.y + sy;
    if (x < 0 || y < 0 || x >= width || y >= height) continue;
    inside += own;
    const throughFrame = own * (1 - frameAlpha[y * width + x]);
    frameOnly += throughFrame;
    let throughPlants = throughFrame, throughAll = throughFrame;
    for (const other of above) {
      const transmission = 1 - alphaAt(other, x, y);
      throughAll *= transmission;
      if (other.type === 'vegetation') throughPlants *= transmission;
    }
    frameAndPlants += throughPlants;
    final += throughAll;
  }
  assert(total > 0, `Empty sprite: ${target.id}`);
  return { id: target.id, asset: target.asset, cluster: target.cluster, xVp: target.xVp,
    foreground: target.foreground, z: target.z, source: target.source, imagePx: target.imagePx,
    insideCanvasAlphaPct: round(inside / total * 100),
    afterFrameVisibleAlphaPct: round(frameOnly / total * 100),
    afterFrameAndVegetationVisibleAlphaPct: round(frameAndPlants / total * 100),
    finalVisibleAlphaPct: round(final / total * 100),
    finalVisibleOfInsideCanvasAlphaPct: inside ? round(final / inside * 100) : 0,
    potentialOccluders: above.map(other => ({ id: other.id, type: other.type, z: other.z })) };
}

async function main() {
  const frameFile = path.join(root, 'phone-preview/layers/phone-frames.png');
  const frameBytes = fs.readFileSync(frameFile);
  const frame = await sharp(frameBytes).ensureAlpha().raw().toBuffer({ resolveWithObject: true });
  assert.equal(frame.info.width, width);
  assert.equal(frame.info.height, height);
  assert.equal(hash(fs.readFileSync(path.join(root, 'sunset-native-panorama.png'))), phoneReport.background.sha256,
    'Phone preview is stale relative to the panorama');
  const frameAlpha = new Float32Array(width * height);
  for (let i = 0; i < frameAlpha.length; i++) frameAlpha[i] = frame.data[i * 4 + 3] / 255;
  const sprites = [];
  for (const item of report.entities) sprites.push(await sprite(item, 'entity', sprites.length));
  for (const item of report.vegetation) sprites.push(await sprite(item, 'vegetation', sprites.length));
  const entities = sprites.filter(item => item.type === 'entity').map(item => measure(item, sprites, frameAlpha));
  const vegetation = sprites.filter(item => item.type === 'vegetation').map(item => measure(item, sprites, frameAlpha));
  const entityTypes = new Set(entities.map(item => item.asset));
  const plantTypes = new Set(vegetation.map(item => item.asset));
  const clusters = new Set(vegetation.map(item => item.cluster));
  const checks = {
    entityCount: entities.length, uniqueEntityTypes: entityTypes.size,
    entityTypesDoNotRepeat: entityTypes.size === entities.length,
    vegetationCount: vegetation.length, uniqueVegetationTypes: plantTypes.size,
    vegetationClusterCount: clusters.size,
    allEntitiesAbove30PctAfterFramesAndPlants: entities.every(item => item.finalVisibleAlphaPct > 30),
    minimumEntityFinalVisibleAlphaPct: Math.min(...entities.map(item => item.finalVisibleAlphaPct)),
    backgroundSixCropRejoinPixelEqual: report.checks.sixCropRejoinPixelEqual === true,
    phoneSixCropRejoinPixelEqual: phoneReport.seam.reconstructedPixelsEqual === true,
    currentPanoramaMatchesPhonePreview: true,
    nativeSourceHashesMatchManifest: true
  };
  assert.equal(checks.entityCount, 8);
  assert.equal(checks.entityTypesDoNotRepeat, true);
  assert.equal(checks.vegetationCount, 18);
  assert.equal(checks.uniqueVegetationTypes, 12);
  assert.equal(checks.vegetationClusterCount, 6);
  assert.equal(checks.backgroundSixCropRejoinPixelEqual, true);
  assert.equal(checks.phoneSixCropRejoinPixelEqual, true);
  const output = {
    generatedAt: new Date().toISOString(), status: checks.allEntitiesAbove30PctAfterFramesAndPlants ? 'passed' : 'failed',
    method: {
      resolution: { width, height },
      metric: 'Original PNG alpha contribution remaining after canvas clipping, later native sprites, and phone frame including shadow; denominator includes the original full sprite alpha.',
      paintOrder: 'Increasing z, then original insertion order: all entities followed by vegetation. Occlusion multiplies transmission (1-alpha) for every later overlapping sprite and the phone frame.',
      paddingPreserved: true, fractionalPixelPlacementPreserved: true,
      frameMask: 'phone-preview/layers/phone-frames.png', frameMaskSha256: hash(frameBytes),
      layoutSha256: hash(fs.readFileSync(path.join(root, 'scene-layout.json'))),
      geometrySource: 'render-report.json', cropVerificationSources: ['render-report.json', 'phone-preview/build-report.json']
    },
    previousVersionSummary: 'Previous eight entity placements each exposed less than 0.42% of their original alpha through the unchanged phone frames.',
    checks, entities, vegetation,
    clusters: (layout.vegetationClusters || []).map(cluster => ({ id: cluster.id, xVp: cluster.xVp,
      foreground: cluster.foreground, assets: cluster.plants.map(plant => plant.asset),
      offsetsVp: cluster.plants.map(plant => plant.offsetVp) }))
  };
  fs.writeFileSync(path.join(root, 'visibility-report.json'), JSON.stringify(output, null, 2) + '\n');
  assert.equal(checks.allEntitiesAbove30PctAfterFramesAndPlants, true, 'An entity is still too hidden after framing and vegetation');
  console.log(JSON.stringify({ status: output.status, checks,
    entities: entities.map(item => ({ id: item.id, finalVisibleAlphaPct: item.finalVisibleAlphaPct })) }, null, 2));
}

main().catch(error => { console.error(error.stack || error); process.exitCode = 1; });
