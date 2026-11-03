#!/usr/bin/env node
'use strict';
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
let sharp;
try { sharp = require('sharp'); } catch (_) {
  sharp = require('/Users/lizhe/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules/sharp');
}
const root = __dirname;
const layout = JSON.parse(fs.readFileSync(path.join(root, 'layout.json'), 'utf8'));
const outlines = JSON.parse(fs.readFileSync(path.join(root, 'text-paths.json'), 'utf8'));
const { width: W, height: H } = layout.canvas;
const MW = W * layout.pages.length;
const palette = layout.palette;
const effect = layout.titleEffects;
const hash = bytes => crypto.createHash('sha256').update(bytes).digest('hex');
const n = value => Math.round(value * 1000) / 1000;
const esc = value => value.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('"', '&quot;');
function save(relative, content) {
  const target = path.join(root, relative);
  fs.mkdirSync(path.dirname(target), { recursive: true });
  fs.writeFileSync(target, content);
}
function pathShape(text, x, baseline, fill, extra = '') {
  return `<path d="${text.path}" transform="translate(${n(x)} ${n(baseline)})" fill="${fill}" ${extra}/>`;
}
function bound(text, x, baseline, bleed = 0) {
  const b = text.bounds;
  return { x: n(x + b.x - bleed), y: n(baseline + b.y - bleed), width: n(b.width + bleed * 2), height: n(b.height + bleed * 2) };
}
function textLayer(page, text) {
  const x = page.x;
  const yOffset = page.yOffset ?? 0;
  const tagWidth = Math.ceil(text.eyebrow.advance + 28);
  const tagHeight = 44;
  const stroke = `stroke="${palette.ink}" stroke-width="${effect.outlineWidth}" stroke-linejoin="round" paint-order="stroke fill"`;
  let body = `<g id="copy-${page.id}" transform="translate(0 ${yOffset})" aria-label="${esc(page.headline.join('，'))}">`;
  body += `<rect x="${x + 5}" y="${page.eyebrowY + 5}" width="${tagWidth}" height="${tagHeight}" rx="3" fill="${palette.teal}"/>`;
  body += `<rect x="${x}" y="${page.eyebrowY}" width="${tagWidth}" height="${tagHeight}" rx="3" fill="${palette.ink}"/>`;
  body += pathShape(text.eyebrow, x + 14, page.eyebrowY + 30, palette.paper);
  body += pathShape(text.first, x, page.firstBaseline, palette.ink);
  body += pathShape(text.second, x + effect.shadowX, page.secondBaseline + effect.shadowY, palette.teal, stroke);
  body += pathShape(text.second, x, page.secondBaseline, palette.paper, stroke);
  body += pathShape(text.subtitle, x, page.subtitleBaseline, palette.ink);
  const boxes = [
    { role: 'eyebrow', text: text.eyebrow.text, x, y: page.eyebrowY, width: tagWidth + 5, height: tagHeight + 5 },
    { role: 'first-title', text: text.first.text, ...bound(text.first, x, page.firstBaseline) },
    { role: 'second-title', text: text.second.text, ...bound(text.second, x, page.secondBaseline, effect.outlineWidth / 2) },
    { role: 'second-title-shadow', text: text.second.text, ...bound(text.second, x + effect.shadowX, page.secondBaseline + effect.shadowY, effect.outlineWidth / 2) },
    { role: 'subtitle', text: text.subtitle.text, ...bound(text.subtitle, x, page.subtitleBaseline) }
  ];
  if (text.note) {
    const noteWidth = Math.ceil(text.note.advance + 24);
    body += `<rect x="${x}" y="${page.noteY}" width="${noteWidth}" height="36" rx="4" fill="${palette.paper}" stroke="${palette.ink}" stroke-width="1.5"/>`;
    body += pathShape(text.note, x + 12, page.noteY + 25, palette.ink);
    boxes.push({ role: 'access-note', text: text.note.text, x: x - 0.75, y: page.noteY - 0.75, width: noteWidth + 1.5, height: 37.5 });
  }
  return { body: body + '</g>', boxes: boxes.map(box => ({ ...box, y: n(box.y + yOffset) })) };
}
const svg = (width, body) => `<svg xmlns="http://www.w3.org/2000/svg" width="${width}" height="${H}" viewBox="0 0 ${width} ${H}">${body}</svg>`;
async function main() {
  assert.equal(layout.pages.length, 6);
  const sources = [], textLayers = [], geometry = [], sourceHashes = [];
  for (let index = 0; index < layout.pages.length; index++) {
    const page = layout.pages[index];
    const source = fs.readFileSync(path.join(root, page.source));
    const meta = await sharp(source).metadata();
    assert.equal(meta.width, W); assert.equal(meta.height, H);
    sourceHashes.push({ page: page.id, source: page.source, sha256: hash(source) });
    sources.push({ input: source, left: index * W, top: 0 });
    const paths = outlines.pages.find(item => item.id === page.id);
    assert(paths, `Missing text paths for ${page.id}`);
    const layer = textLayer(page, paths.texts);
    for (const b of layer.boxes) {
      assert(b.x >= 0 && b.y >= 0 && b.x + b.width <= W && b.y + b.height <= H,
        `Text exceeds page ${page.id}: ${JSON.stringify(b)}`);
    }
    const layerSvg = svg(W, layer.body);
    save(`layers/${page.id}-text.svg`, layerSvg);
    save(`layers/${page.id}-text.png`, await sharp(Buffer.from(layerSvg)).png().toBuffer());
    textLayers.push(`<g transform="translate(${index * W} 0)">${layer.body}</g>`);
    geometry.push({ page: page.id, bounds: layer.boxes, source: page.source });
    const composedSvg = svg(W, `<image href="data:image/png;base64,${source.toString('base64')}" width="${W}" height="${H}"/>${layer.body}`);
    save(`editable/${page.id}.svg`, composedSvg);
  }
  const base = await sharp({ create: { width: MW, height: H, channels: 4, background: '#00000000' } }).composite(sources).png().toBuffer();
  const overlay = await sharp(Buffer.from(svg(MW, textLayers.join('')))).png().toBuffer();
  const master = await sharp(base).composite([{ input: overlay }]).png().toBuffer();
  save('master.png', master);
  save('layers/master-text.svg', svg(MW, textLayers.join('')));
  save('layers/master-text.png', overlay);
  const parts = [];
  for (let index = 0; index < layout.pages.length; index++) {
    const part = await sharp(master).extract({ left: index * W, top: 0, width: W, height: H }).png().toBuffer();
    save(`${layout.pages[index].id}.png`, part);
    parts.push(part);
  }
  save('pair-01-02.png', await sharp(master).extract({ left: 0, top: 0, width: W * 2, height: H }).png().toBuffer());
  save('continuous-preview.jpg', await sharp(master).flatten({ background: palette.paper }).resize(2160).jpeg({ quality: 94 }).toBuffer());
  const tw = 324, th = 576, gap = 24, pad = 48;
  const thumbs = [];
  for (let index = 0; index < parts.length; index++) thumbs.push({ input: await sharp(parts[index]).flatten({ background: palette.paper }).resize(tw, th).png().toBuffer(), left: pad + index * (tw + gap), top: pad });
  save('strip.jpg', await sharp({ create: { width: tw * 6 + gap * 5 + pad * 2, height: th + pad * 2, channels: 3, background: '#EAE7E0' } }).composite(thumbs).jpeg({ quality: 94 }).toBuffer());
  const contact = [];
  for (let index = 0; index < parts.length; index++) contact.push({ input: await sharp(parts[index]).flatten({ background: palette.paper }).resize(540, 960).png().toBuffer(), left: 24 + index % 3 * 564, top: 24 + Math.floor(index / 3) * 984 });
  save('contact-sheet.jpg', await sharp({ create: { width: 1716, height: 1992, channels: 3, background: '#EAE7E0' } }).composite(contact).jpeg({ quality: 94 }).toBuffer());
  // One master render owns all cut edges; no per-page font rasterization can shift the shared seam.
  // Copy decoded rows directly: alpha compositing would round partially transparent source pixels a second time.
  const joined = Buffer.alloc(MW * H * 4);
  for (let index = 0; index < parts.length; index++) {
    const partRaw = await sharp(parts[index]).ensureAlpha().raw().toBuffer();
    for (let y = 0; y < H; y++) partRaw.copy(joined, (y * MW + index * W) * 4, y * W * 4, (y + 1) * W * 4);
  }
  const actual = await sharp(master).ensureAlpha().raw().toBuffer();
  const baseRaw = await sharp(base).ensureAlpha().raw().toBuffer();
  const overlayRaw = await sharp(overlay).ensureAlpha().raw().toBuffer();
  assert(actual.equals(joined), 'Six slices must reconstruct the master exactly');
  let unchangedOpaquePixels = 0, unchangedAlphaPixels = 0, seamPixels = 0;
  for (let i = 0; i < MW * H; i++) {
    const offset = i * 4;
    if (overlayRaw[offset + 3] !== 0) continue;
    assert.equal(actual[offset + 3], baseRaw[offset + 3], 'Source alpha changed outside typography');
    unchangedAlphaPixels++;
    if (baseRaw[offset + 3] === 255) {
      for (let channel = 0; channel < 4; channel++) assert.equal(actual[offset + channel], baseRaw[offset + channel], 'Opaque source content changed outside typography');
      unchangedOpaquePixels++;
    }
  }
  for (let y = 0; y < H; y++) for (const x of [W - 1, W]) {
    const offset = (y * MW + x) * 4;
    assert.equal(overlayRaw[offset + 3], 0, 'First-two-page seam must remain free of text');
    seamPixels++;
  }
  const report = { canvas: { width: W, height: H, pages: 6 }, palette, font: outlines.font, sourceHashes, geometry,
    checks: { sixSlicesReconstructMaster: true, typographyWithinPage: true, opaqueSourcePixelsOutsideTypographyUnchanged: unchangedOpaquePixels, sourceAlphaPixelsOutsideTypographyUnchanged: unchangedAlphaPixels, firstTwoSeamTextFreePixels: seamPixels },
    renderMode: 'Exact existing PNGs plus native vector type outlines; no generative redrawing or source screenshot replacement.' };
  save('build-report.json', JSON.stringify(report, null, 2) + '\n');
  console.log(JSON.stringify({ status: 'passed', pages: 6, checks: report.checks, titleBounds: geometry.map(item => ({ page: item.page, bounds: item.bounds.filter(b => b.role.includes('title')) })) }, null, 2));
}
main().catch(error => { console.error(error.stack || error); process.exitCode = 1; });
