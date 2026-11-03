#!/usr/bin/env node
'use strict';
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const root = __dirname;
const config = JSON.parse(fs.readFileSync(path.join(root, 'config.json'), 'utf8'));
let sharp;
try { sharp = require('sharp'); } catch (_) {
  sharp = require('/Users/lizhe/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules/sharp');
}
const { width: W, height: H } = config.canvas;
const dataUri = bytes => `data:image/png;base64,${bytes.toString('base64')}`;
const n = value => Math.round(value * 1000000) / 1000000;
const finite = value => typeof value === 'number' && Number.isFinite(value);
function resolveGeometry(item) {
  const t = item.artworkTransform || config.artworkTransform;
  assert(t && ['x', 'y', 'width', 'height'].every(key => finite(t[key])), `${item.id}: artworkTransform required`);
  assert(t.width > 0 && t.height > 0, `${item.id}: positive artworkTransform dimensions required`);
  const b = item.screen?.bounds;
  let quad = item.screen?.quad;
  if (quad) {
    assert(quad.length === 4, `${item.id}: screen.quad must contain TL, TR, BR, BL`);
    quad = quad.map(point => Array.isArray(point) ? { x: point[0], y: point[1] } : { x: point.x, y: point.y });
    assert(quad.every(point => finite(point.x) && finite(point.y)), `${item.id}: invalid screen.quad`);
  } else {
    assert(b && ['x', 'y', 'width', 'height'].every(key => finite(b[key])) && b.width > 0 && b.height > 0,
      `${item.id}: screen.bounds or screen.quad required; bounds are never guessed`);
    quad = [{ x: b.x, y: b.y }, { x: b.x + b.width, y: b.y },
      { x: b.x + b.width, y: b.y + b.height }, { x: b.x, y: b.y + b.height }];
  }
  const crosses = quad.map((point, i) => {
    const next = quad[(i + 1) % 4], last = quad[(i + 2) % 4];
    return (next.x - point.x) * (last.y - next.y) - (next.y - point.y) * (last.x - next.x);
  });
  assert(crosses.every(value => value > 0.01) || crosses.every(value => value < -0.01), `${item.id}: quad must be convex and ordered`);
  const length = (a, b) => Math.hypot(a.x - b.x, a.y - b.y);
  const plane = {
    width: (length(quad[0], quad[1]) + length(quad[2], quad[3])) / 2,
    height: (length(quad[0], quad[3]) + length(quad[1], quad[2])) / 2
  };
  const contentRatio = item.screen.contentRatio;
  if (contentRatio) {
    assert(finite(contentRatio.width) && finite(contentRatio.height) && contentRatio.width > 0 && contentRatio.height > 0,
      `${item.id}: screen.contentRatio must have positive width and height`);
    // A perspective quad cannot reveal the original physical screen aspect ratio.
    // Explicit ratios keep contain/cover consistent across differently tilted phones.
    plane.height = plane.width * contentRatio.height / contentRatio.width;
  }
  const samplePoint = item.screen.samplePoint || {
    x: quad.reduce((sum, point) => sum + point.x, 0) / 4,
    y: quad.reduce((sum, point) => sum + point.y, 0) / 4
  };
  assert(samplePoint.x >= 0 && samplePoint.x < W && samplePoint.y >= 0 && samplePoint.y < H,
    `${item.id}: provide a visible screen.samplePoint when the quad center is outside the canvas`);
  return { transform: { ...t }, quad, plane, samplePoint };
}
function transform(t) { return `translate(${n(t.x)} ${n(t.y)}) scale(${n(t.width / W)} ${n(t.height / H)})`; }
const image = uri => `<image href="${uri}" x="0" y="0" width="${W}" height="${H}"/>`;
function svg(body, defs = '') {
  return `<svg xmlns="http://www.w3.org/2000/svg" width="${W}" height="${H}" viewBox="0 0 ${W} ${H}">${defs}${body}</svg>`;
}
async function normalizeArtwork(file) {
  return sharp(file).resize(W, H, { fit: 'fill' }).ensureAlpha().png().toBuffer();
}
async function normalizeMask(file, id) {
  const { data, info } = await sharp(file).resize(W, H, { fit: 'fill' }).toColourspace('srgb').ensureAlpha().raw().toBuffer({ resolveWithObject: true });
  assert.equal(info.channels, 4);
  const rgba = Buffer.alloc(W * H * 4), inverse = Buffer.alloc(W * H * 4), alpha = Buffer.alloc(W * H);
  let visiblePixels = 0, partialPixels = 0;
  for (let i = 0; i < W * H; i++) {
    const p = i * 4;
    // White-on-black and white-on-transparent masks share this contract.
    // Multiplying luminance by alpha also preserves antialiased hand boundaries.
    const a = Math.round((0.2126 * data[p] + 0.7152 * data[p + 1] + 0.0722 * data[p + 2]) * data[p + 3] / 255);
    alpha[i] = a;
    rgba[p] = rgba[p + 1] = rgba[p + 2] = 255; rgba[p + 3] = a;
    inverse[p] = inverse[p + 1] = inverse[p + 2] = 255 - a; inverse[p + 3] = 255;
    if (a > 0) visiblePixels++;
    if (a > 0 && a < 255) partialPixels++;
  }
  assert(visiblePixels > 100, `${id}: screen mask is empty`);
  assert(visiblePixels < W * H * 0.95, `${id}: screen mask unexpectedly erases almost the entire artwork`);
  return {
    alpha, visiblePixels, partialPixels,
    png: await sharp(rgba, { raw: { width: W, height: H, channels: 4 } }).png().toBuffer(),
    inversePng: await sharp(inverse, { raw: { width: W, height: H, channels: 4 } }).png().toBuffer()
  };
}
async function saveSvgPng(relative, source) {
  const target = path.join(root, relative);
  fs.mkdirSync(path.dirname(target), { recursive: true });
  fs.writeFileSync(`${target}.svg`, source);
  const png = await sharp(Buffer.from(source)).png().toBuffer();
  fs.writeFileSync(`${target}.png`, png);
  return png;
}
async function main() {
  assert(W === 1080 && H === 1920, 'Output canvas must be 1080×1920');
  assert(Array.isArray(config.items) && config.items.length === 5, 'Five artworks required');
  const geometries = Object.fromEntries(config.items.map(item => [item.id, resolveGeometry(item)]));
  for (const item of config.items) {
    for (const file of [item.artwork, item.mask]) assert(file && fs.existsSync(path.join(root, file)), `${item.id}: missing ${file}`);
  }
  const bundle = { config, geometries, images: {}, builtAt: new Date().toISOString() };
  const checks = [], thumbs = [];
  for (const item of config.items) {
    const geometry = geometries[item.id];
    const art = await normalizeArtwork(path.join(root, item.artwork));
    const mask = await normalizeMask(path.join(root, item.mask), item.id);
    const sample = geometry.samplePoint;
    const centerAlpha = mask.alpha[Math.floor(sample.y) * W + Math.floor(sample.x)];
    assert(centerAlpha >= 240, `${item.id}: screen samplePoint is not inside the visible white screen mask (alpha ${centerAlpha})`);
    const artUri = dataUri(art), maskUri = dataUri(mask.png), inverseUri = dataUri(mask.inversePng);
    bundle.images[item.id] = { artwork: artUri, mask: maskUri };
    const group = transform(geometry.transform);
    const templateSvg = svg(`<g id="artwork-and-phone" transform="${group}">${image(artUri)}</g>`);
    const overlaySvg = svg(`<g transform="${group}"><g id="artwork-with-visible-screen-cutout" mask="url(#visible-screen-hole)">${image(artUri)}</g></g>`,
      `<defs><mask id="visible-screen-hole" maskUnits="userSpaceOnUse" x="0" y="0" width="${W}" height="${H}">${image(inverseUri)}</mask></defs>`);
    const maskSvg = svg(`<g id="visible-screen-mask" transform="${group}">${image(maskUri)}</g>`);
    const template = await saveSvgPng(`templates/${item.id}-template`, templateSvg);
    const overlay = await saveSvgPng(`layers/${item.id}-overlay`, overlaySvg);
    await saveSvgPng(`layers/${item.id}-screen-mask`, maskSvg);
    fs.mkdirSync(path.join(root, 'source'), { recursive: true });
    fs.writeFileSync(path.join(root, 'source', `${item.id}-template.svg`), templateSvg);
    fs.writeFileSync(path.join(root, 'source', `${item.id}-overlay.svg`), overlaySvg);
    // Validate the cutout in local design coordinates, independently of a crop or scale.
    const localOverlay = await sharp(art).composite([{ input: mask.png, blend: 'dest-out' }]).ensureAlpha().raw().toBuffer();
    const sourceRgba = await sharp(art).ensureAlpha().raw().toBuffer();
    let preservedPixels = 0;
    for (let i = 0; i < W * H; i++) {
      const expectedAlpha = Math.round(sourceRgba[i * 4 + 3] * (255 - mask.alpha[i]) / 255);
      assert(Math.abs(localOverlay[i * 4 + 3] - expectedAlpha) <= 1, `${item.id}: alpha mismatch at ${i}`);
      if (mask.alpha[i] === 0) {
        assert.equal(localOverlay[i * 4 + 3], sourceRgba[i * 4 + 3], `${item.id}: protected artwork alpha changed`);
        preservedPixels++;
      }
    }
    const outputSample = { x: Math.floor(geometry.transform.x + sample.x * geometry.transform.width / W),
      y: Math.floor(geometry.transform.y + sample.y * geometry.transform.height / H) };
    assert(outputSample.x >= 0 && outputSample.x < W && outputSample.y >= 0 && outputSample.y < H,
      `${item.id}: artworkTransform puts the screen sample outside the output`);
    const renderedOverlay = await sharp(overlay).ensureAlpha().raw().toBuffer();
    const renderedHoleAlpha = renderedOverlay[(outputSample.y * W + outputSample.x) * 4 + 3];
    assert(renderedHoleAlpha <= 15, `${item.id}: rendered SVG overlay screen hole is not transparent`);
    checks.push({ id: item.id, geometry, centerMaskAlpha: centerAlpha, renderedHoleAlpha, visibleMaskPixels: mask.visiblePixels,
      antialiasedMaskPixels: mask.partialPixels, preservedPixels, cutoutAlphaVerified: true });
    thumbs.push({ input: await sharp(template).resize(216, 384).toBuffer(), left: thumbs.length * 216, top: 0 });
  }
  fs.mkdirSync(path.join(root, 'previews'), { recursive: true });
  await sharp({ create: { width: W, height: 384, channels: 4, background: '#FFFFFF' } }).composite(thumbs).png().toFile(path.join(root, 'previews', 'contact-sheet.png'));
  const editorPath = path.join(root, 'editor.html');
  const editor = fs.readFileSync(editorPath, 'utf8');
  const marker = /<script id="template-bundle" type="application\/json">[\s\S]*?<\/script>/;
  assert(marker.test(editor), 'Editor bundle marker missing');
  // A bundled snapshot avoids file:// fetch restrictions and keeps local screenshots private.
  fs.writeFileSync(editorPath, editor.replace(marker, () => `<script id="template-bundle" type="application/json">${JSON.stringify(bundle).replace(/</g, '\\u003c')}</script>`));
  fs.writeFileSync(path.join(root, 'build-report.json'), JSON.stringify({ canvas: config.canvas, checks }, null, 2) + '\n');
  console.log(JSON.stringify({ built: checks.length, checks: checks.map(c => ({ id: c.id, centerMaskAlpha: c.centerMaskAlpha, cutoutAlphaVerified: c.cutoutAlphaVerified })), editor: editorPath }, null, 2));
}
main().catch(error => { console.error(error.stack || error); process.exitCode = 1; });
