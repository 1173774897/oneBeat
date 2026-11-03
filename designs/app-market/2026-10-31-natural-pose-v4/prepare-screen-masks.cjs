#!/usr/bin/env node
'use strict';
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
let sharp;
try { sharp = require('sharp'); } catch (_) {
  sharp = require('/Users/lizhe/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules/sharp');
}
const root = __dirname;
const W = 1080, H = 1920;
const names = ['珊瑚 · Lilroll', '薄荷 · Wave', '丁香 · 云行者', '杏黄 · 条纹步客', '墨蓝 · 台灯漫游者'];
const median = values => {
  const sorted = values.slice().sort((a, b) => a - b);
  return sorted[Math.floor(sorted.length / 2)];
};
async function main() {
  const items = [];
  for (let index = 0; index < 5; index++) {
    const id = String(index + 1).padStart(2, '0');
    const file = path.join(root, 'artwork', `${id}.png`);
    assert(fs.existsSync(file), `Artwork missing: ${file}`);
    const { data } = await sharp(file).resize(W, H, { fit: 'fill' }).removeAlpha().raw().toBuffer({ resolveWithObject: true });
    const visited = new Uint8Array(W * H);
    const queue = new Int32Array(W * H);
    const seedX = 540, seedY = 1000;
    // Only the light connected screen is selected. Dark ink contours disconnect
    // hands from the screen even when skin and screen colors are similar.
    const qualifies = i => {
      const p = i * 3, r = data[p], g = data[p + 1], b = data[p + 2];
      return Math.min(r, g, b) >= 218 && Math.max(r, g, b) - Math.min(r, g, b) <= 34;
    };
    const seed = seedY * W + seedX;
    assert(qualifies(seed), `${id}: inspect the screen before choosing a seed`);
    let read = 0, write = 1;
    queue[0] = seed; visited[seed] = 1;
    while (read < write) {
      const i = queue[read++], x = i % W, y = Math.floor(i / W);
      const neighbors = [];
      if (x > 0) neighbors.push(i - 1);
      if (x + 1 < W) neighbors.push(i + 1);
      if (y > 0) neighbors.push(i - W);
      if (y + 1 < H) neighbors.push(i + W);
      for (const next of neighbors) if (!visited[next] && qualifies(next)) {
        visited[next] = 1; queue[write++] = next;
      }
    }
    assert(write > W * H * .25 && write < W * H * .8, `${id}: unexpected mask area ${write}`);
    const rowLeft = new Int32Array(H).fill(W), rowRight = new Int32Array(H).fill(-1);
    const colTop = new Int32Array(W).fill(H), colBottom = new Int32Array(W).fill(-1);
    let minX = W, minY = H, maxX = 0, maxY = 0;
    const alpha = Buffer.alloc(W * H);
    for (let i = 0; i < visited.length; i++) if (visited[i]) {
      const x = i % W, y = Math.floor(i / W);
      alpha[i] = 255;
      rowLeft[y] = Math.min(rowLeft[y], x); rowRight[y] = Math.max(rowRight[y], x);
      colTop[x] = Math.min(colTop[x], y); colBottom[x] = Math.max(colBottom[x], y);
      minX = Math.min(minX, x); maxX = Math.max(maxX, x); minY = Math.min(minY, y); maxY = Math.max(maxY, y);
    }
    const sideRows = Array.from({ length: H }, (_, y) => y).filter(y => y > minY + (maxY - minY) * .22 && y < minY + (maxY - minY) * .60 && rowRight[y] > rowLeft[y]);
    const middleCols = Array.from({ length: W }, (_, x) => x).filter(x => x > minX + (maxX - minX) * .35 && x < minX + (maxX - minX) * .65 && colBottom[x] > colTop[x]);
    const left = median(sideRows.map(y => rowLeft[y]));
    const right = median(sideRows.map(y => rowRight[y]));
    const top = median(middleCols.map(x => colTop[x]));
    const bottom = median(middleCols.map(x => colBottom[x]));
    const bounds = { x: left, y: top, width: right - left + 1, height: bottom - top + 1 };
    await sharp(alpha, { raw: { width: W, height: H, channels: 1 } }).png().toFile(path.join(root, 'masks', `${id}-screen.png`));
    const annotation = Buffer.alloc(W * H * 4);
    for (let i = 0; i < visited.length; i++) {
      annotation[i * 4] = 255;
      annotation[i * 4 + 1] = 55;
      annotation[i * 4 + 2] = 55;
      annotation[i * 4 + 3] = visited[i] ? 100 : 0;
    }
    const red = await sharp(annotation, { raw: { width: W, height: H, channels: 4 } }).png().toBuffer();
    fs.mkdirSync(path.join(root, 'previews'), { recursive: true });
    // QA shows the selected pixels; the original generated artwork is never repainted.
    await sharp(file).resize(W, H, { fit: 'fill' }).composite([{ input: red }]).png().toFile(path.join(root, 'previews', `${id}-mask-check.png`));
    items.push({ id, name: names[index], artwork: `artwork/${id}.png`, mask: `masks/${id}-screen.png`, screen: { bounds, samplePoint: { x: seedX, y: seedY }, fill: '#FEFDF9' }, maskAnalysis: { pixelCount: write, extent: { minX, minY, maxX, maxY }, threshold: { minChannel: 218, maxChroma: 34 } } });
    console.log(JSON.stringify({ id, bounds, selected: write }));
  }
  const config = { canvas: { width: W, height: H }, screenFill: '#FEFDF9', artworkTransform: { x: 0, y: 0, width: W, height: H }, items };
  fs.writeFileSync(path.join(root, 'config.json'), JSON.stringify(config, null, 2) + '\n');
}
main().catch(error => { console.error(error); process.exitCode = 1; });
