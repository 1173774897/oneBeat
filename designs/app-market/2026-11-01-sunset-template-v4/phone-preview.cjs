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
const config = JSON.parse(fs.readFileSync(path.join(root, process.argv[2] || 'phone-frames.json'), 'utf8'));
const { width: W, height: H } = config.canvas;
const COUNT = config.pageCount, MW = W * COUNT;
const output = path.join(root, process.argv[3] || 'phone-preview');
const n = value => Math.round(value * 1000000) / 1000000;
function resolvePhone(phone, pageOffset = 0) {
  const scale = phone.scale ?? 1;
  assert(scale > 0, `Invalid scale for ${phone.id}`);
  return { ...phone, scale, x: phone.x + pageOffset, width: phone.width * scale, height: phone.height * scale };
}
const phones = [...config.pairPhones.map(p => resolvePhone(p)),
  ...config.singlePhones.map(p => resolvePhone(p, (p.page - 1) * W))];
function save(relative, bytes) {
  const target = path.join(output, relative);
  fs.mkdirSync(path.dirname(target), { recursive: true });
  fs.writeFileSync(target, bytes);
}
function rect(box, fill, extra = '') {
  return `<rect x="${n(box.x)}" y="${n(box.y)}" width="${n(box.width)}" height="${n(box.height)}" rx="${n(box.radius || 0)}" fill="${fill}" ${extra}/>`;
}
function rotate(phone, body) {
  return `<g transform="rotate(${n(phone.rotation)} ${n(phone.x + phone.width / 2)} ${n(phone.y + phone.height / 2)})">${body}</g>`;
}
function geometry(phone) {
  const f = config.frame;
  // Scale the entire mockup, including inset, radii and shadow, so the screen aspect ratio stays unchanged.
  const inset = f.inset * phone.scale;
  const radius = f.radius * phone.scale;
  const outer = { ...phone, radius };
  const screen = { x: phone.x + inset, y: phone.y + inset, width: phone.width - 2 * inset,
    height: phone.height - 2 * inset, radius: radius - inset };
  assert(screen.width > 0 && screen.height > 0 && screen.radius > 0, `Invalid screen geometry: ${phone.id}`);
  return { outer, screen };
}
function screenShapes(fill) {
  return phones.map(p => rotate(p, rect(geometry(p).screen, fill))).join('');
}
function frameShapes() {
  const f = config.frame, sh = f.shadow;
  return phones.map(p => {
    const { outer, screen } = geometry(p);
    const shadow = sh.opacity ? rect({ ...outer, x: outer.x + sh.x * p.scale, y: outer.y + sh.y * p.scale }, sh.color, `opacity="${sh.opacity}"`) : '';
    return rotate(p, `${shadow}<g id="phone-${p.id}">${rect(outer, f.fill, `stroke="${f.outline}" stroke-width="${f.outlineWidth * p.scale}"`)}<g id="replace-screen-${p.id}">${rect(screen, f.screenFill)}</g></g>`);
  }).join('');
}
function documentSvg(body, width = MW, cropX = 0, definitions = '') {
  return `<svg xmlns="http://www.w3.org/2000/svg" width="${width}" height="${H}" viewBox="${cropX} 0 ${width} ${H}">${definitions}${body}</svg>`;
}
function holeDefinition() {
  return `<defs><mask id="screen-hole" maskUnits="userSpaceOnUse" x="0" y="0" width="${MW}" height="${H}"><rect width="${MW}" height="${H}" fill="white"/>${screenShapes('black')}</mask></defs>`;
}
function quad(phone) {
  const s = geometry(phone).screen, a = phone.rotation * Math.PI / 180;
  const cx = phone.x + phone.width / 2, cy = phone.y + phone.height / 2;
  return [[s.x, s.y], [s.x + s.width, s.y], [s.x + s.width, s.y + s.height], [s.x, s.y + s.height]].map(([x, y]) => ({
    x: n(cx + (x - cx) * Math.cos(a) - (y - cy) * Math.sin(a)),
    y: n(cy + (x - cx) * Math.sin(a) + (y - cy) * Math.cos(a))
  }));
}
async function render(source) { return sharp(Buffer.from(source), { limitInputPixels: 100000000 }).png().toBuffer(); }
async function slices(master, folder, makeSvg) {
  const paths = [];
  for (let page = 0; page < COUNT; page++) {
    const id = String(page + 1).padStart(2, '0');
    const stem = folder ? `${folder}/${id}` : id;
    save(`${stem}.png`, await sharp(master).extract({ left: page * W, top: 0, width: W, height: H }).png().toBuffer());
    if (makeSvg) save(`${stem}.svg`, makeSvg(W, page * W));
    paths.push(`${stem}.png`);
  }
  return paths;
}
async function verifyReconstruction(master, pages) {
  const original = await sharp(master).ensureAlpha().raw().toBuffer();
  const joined = Buffer.alloc(MW * H * 4);
  for (let page = 0; page < COUNT; page++) {
    const part = await sharp(path.join(output, pages[page])).ensureAlpha().raw().toBuffer();
    for (let row = 0; row < H; row++) part.copy(joined, (row * MW + page * W) * 4, row * W * 4, (row + 1) * W * 4);
  }
  assert.deepEqual(joined, original, 'Six slices must reconstruct the one rendered master exactly');
  return { reconstructedPixelsEqual: true, comparedPixels: MW * H, cutXs: Array.from({ length: COUNT - 1 }, (_, i) => (i + 1) * W) };
}
async function main() {
  assert(W === 1080 && H === 1920 && COUNT === 6 && MW === 6480 && phones.length === 6);
  const backgroundFile = path.join(root, config.background);
  assert(fs.existsSync(backgroundFile), `Native panorama is not ready: ${backgroundFile}`);
  const background = fs.readFileSync(backgroundFile), initialHash = crypto.createHash('sha256').update(background).digest('hex');
  const sourceMeta = await sharp(background).metadata();
  assert.equal(sourceMeta.width, MW, 'Read the native six-page master at its original width; do not rescale it');
  assert.equal(sourceMeta.height, H, 'Read the native six-page master at its original height; do not crop it');
  const foregroundSvg = documentSvg(frameShapes());
  const foreground = await render(foregroundSvg);
  // Composite the vector frame layer onto the original PNG directly. Pixels
  // outside the frame/shadow layer remain exactly those of the native scene.
  const master = await sharp(background).composite([{ input: foreground }]).png().toBuffer();
  const uri = `data:image/png;base64,${background.toString('base64')}`;
  const nativeBackground = `<image href="${uri}" x="0" y="0" width="${MW}" height="${H}"/>`;
  const templateSource = (width = MW, cropX = 0) => documentSvg(`${nativeBackground}${frameShapes()}`, width, cropX);
  const maskSource = (width = MW, cropX = 0) => documentSvg(screenShapes('white'), width, cropX);
  const overlaySource = (width = MW, cropX = 0) => documentSvg(`<g mask="url(#screen-hole)">${nativeBackground}${frameShapes()}</g>`, width, cropX, holeDefinition());
  const screenMask = await render(maskSource());
  const overlay = await sharp(master).composite([{ input: screenMask, blend: 'dest-out' }]).png().toBuffer();
  save('master.png', master); save('master.svg', templateSource());
  save('layers/phone-frames.png', foreground); save('layers/phone-frames.svg', foregroundSvg);
  save('layers/master-screen-mask.png', screenMask); save('layers/master-screen-mask.svg', maskSource());
  save('layers/master-overlay.png', overlay); save('layers/master-overlay.svg', overlaySource());
  const pages = await slices(master, '', templateSource);
  await slices(overlay, 'layers/overlay', overlaySource);
  await slices(screenMask, 'layers/screen-mask', maskSource);
  save('pair.png', await sharp(master).extract({ left: 0, top: 0, width: W * 2, height: H }).png().toBuffer());
  save('pair.svg', templateSource(W * 2));
  const p = config.preview, tw = Math.round(W * p.scale), th = Math.round(H * p.scale);
  const thumbs = [];
  for (let page = 0; page < COUNT; page++) thumbs.push({ input: await sharp(path.join(output, pages[page])).resize(tw, th).toBuffer(),
    left: p.padding + page * (tw + p.gutter), top: p.padding });
  const stripWidth = p.padding * 2 + tw * COUNT + p.gutter * (COUNT - 1), stripHeight = th + p.padding * 2;
  save('strip.png', await sharp({ create: { width: stripWidth, height: stripHeight, channels: 4, background: '#EAE7E0' } }).composite(thumbs).png().toBuffer());
  save('continuous-preview.png', await sharp(master).resize(2160, 640).png().toBuffer());
  const templateRaw = await sharp(master).ensureAlpha().raw().toBuffer();
  const originalRaw = await sharp(background).ensureAlpha().raw().toBuffer();
  const frameRaw = await sharp(foreground).ensureAlpha().raw().toBuffer();
  const maskRaw = await sharp(screenMask).ensureAlpha().raw().toBuffer();
  const overlayRaw = await sharp(overlay).ensureAlpha().raw().toBuffer();
  const white = config.frame.screenFill.slice(1).match(/../g).map(v => parseInt(v, 16));
  let untouchedBackgroundPixels = 0, whiteScreenPixels = 0;
  for (let i = 0; i < MW * H; i++) {
    const offset = i * 4;
    if (frameRaw[offset + 3] === 0) {
      for (let channel = 0; channel < 4; channel++) assert.equal(templateRaw[offset + channel], originalRaw[offset + channel], `Background changed at pixel ${i}`);
      untouchedBackgroundPixels++;
    }
    if (maskRaw[offset + 3] === 255) {
      for (let channel = 0; channel < 3; channel++) assert.equal(templateRaw[offset + channel], white[channel], `Native scene leaked into white screen at pixel ${i}`);
      assert.equal(overlayRaw[offset + 3], 0, `Screen cutout is not transparent at pixel ${i}`);
      whiteScreenPixels++;
    }
  }
  assert.equal(crypto.createHash('sha256').update(fs.readFileSync(backgroundFile)).digest('hex'), initialHash, 'Source panorama was modified');
  const pageDimensions = [];
  for (let page = 0; page < COUNT; page++) {
    const meta = await sharp(path.join(output, pages[page])).metadata();
    assert.equal(meta.width, W); assert.equal(meta.height, H);
    pageDimensions.push({ page: page + 1, width: meta.width, height: meta.height });
  }
  const seam = await verifyReconstruction(master, pages);
  const report = { status: 'passed', canvas: config.canvas, pageCount: COUNT, master: { width: MW, height: H },
    background: { asset: config.background, sha256: initialHash, sourceUnmodified: true, untouchedBackgroundPixels },
    whiteScreenPixels, whiteScreensContainOnlyConfiguredColor: true, overlayScreenHolesVerified: true,
    seam, pageDimensions, phones: phones.map(phone => ({ ...phone, screen: geometry(phone).screen, screenQuad: quad(phone) })) };
  save('build-report.json', JSON.stringify(report, null, 2) + '\n');
  console.log(JSON.stringify({ status: report.status, pages: COUNT, seam: seam.reconstructedPixelsEqual,
    untouchedBackgroundPixels, whiteScreenPixels, sourceUnmodified: true }, null, 2));
}
main().catch(error => { console.error(error.stack || error); process.exitCode = 1; });
