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
const config = JSON.parse(fs.readFileSync(path.join(root, 'config.json'), 'utf8'));
const { width: W, height: H } = config.canvas;
const palette = config.palette;
const color = key => { assert(palette[key], `Unknown palette key ${key}`); return palette[key]; };
const n = value => Math.round(value * 1000000) / 1000000;
const rect = (b, fill, extra = '') => `<rect x="${n(b.x)}" y="${n(b.y)}" width="${n(b.width)}" height="${n(b.height)}" rx="${n(b.radius || 0)}" fill="${fill}" ${extra}/>`;
const withTransform = (phone, body) => `<g transform="rotate(${phone.rotation} ${n(phone.x + phone.width / 2)} ${n(phone.y + phone.height / 2)})">${body}</g>`;
function geometry(scheme, phone) {
  const style = { ...config.phone, ...scheme.phoneOverrides };
  const outer = { ...phone, radius: style.radius };
  const screen = { x: phone.x + style.inset, y: phone.y + style.inset, width: phone.width - 2 * style.inset,
    height: phone.height - 2 * style.inset, radius: style.radius - style.inset };
  assert(screen.width > 0 && screen.height > 0 && screen.radius > 0);
  return { style, outer, screen };
}
function screenShape(scheme, phone, fill) { return withTransform(phone, rect(geometry(scheme, phone).screen, fill)); }
function phoneShape(scheme, phone) {
  const { style, outer, screen } = geometry(scheme, phone), sh = scheme.shadow;
  // Shadows and frame are intentionally flat like the app's ink-backed controls.
  // They remain part of the shared panoramic scene rather than per-page effects.
  const shadow = sh.opacity > 0 ? rect({ ...outer, x: outer.x + sh.x, y: outer.y + sh.y }, color(sh.color), `opacity="${sh.opacity}"`) : '';
  const frame = rect(outer, color(scheme.frame), style.outlineWidth ? `stroke="${color(scheme.outline)}" stroke-width="${style.outlineWidth}"` : '');
  const blank = rect(screen, color(scheme.screen), style.innerOutlineWidth ? `stroke="${color(scheme.outline)}" stroke-width="${style.innerOutlineWidth}"` : '');
  return withTransform(phone, `${shadow}<g id="phone-${phone.id}">${frame}<g id="replace-screen-${phone.id}">${blank}</g></g>`);
}
function makeSvg(scheme, phones, mode, width = W, cropX = 0) {
  const sceneWidth = phones.length === 2 ? W * 2 : W;
  const screen = phones.map(p => screenShape(scheme, p, 'black')).join('');
  const mask = `<defs><mask id="screens-hole" maskUnits="userSpaceOnUse" x="0" y="0" width="${sceneWidth}" height="${H}"><rect width="${sceneWidth}" height="${H}" fill="white"/>${screen}</mask></defs>`;
  const body = `<rect width="${sceneWidth}" height="${H}" fill="${color(scheme.background)}"/>${phones.map(p => phoneShape(scheme, p)).join('')}`;
  let content;
  if (mode === 'screen-mask') content = phones.map(p => screenShape(scheme, p, 'white')).join('');
  else if (mode === 'overlay') content = `${mask}<g mask="url(#screens-hole)">${body}</g>`;
  else if (mode === 'guide') {
    const safe = phones.length === 2 ? config.titleSafeAreas.pair : [config.titleSafeAreas.single];
    const accents = safe.map(b => rect(b, 'none', `stroke="${color(scheme.background === 'ink' ? 'paper' : 'ink')}" stroke-width="3" stroke-dasharray="14 12" opacity=".45"`)).join('');
    content = `${body}<g id="title-safe-guides">${accents}</g>${phones.length === 2 ? `<path d="M${W} 0V${H}" stroke="${color('coral')}" stroke-width="3" stroke-dasharray="16 12"/>` : ''}`;
  } else content = body;
  return `<svg xmlns="http://www.w3.org/2000/svg" width="${width}" height="${H}" viewBox="${cropX} 0 ${width} ${H}">${content}</svg>`;
}
function screenQuad(scheme, phone) {
  const { screen } = geometry(scheme, phone), angle = phone.rotation * Math.PI / 180;
  const cx = phone.x + phone.width / 2, cy = phone.y + phone.height / 2;
  return [[screen.x, screen.y], [screen.x + screen.width, screen.y], [screen.x + screen.width, screen.y + screen.height], [screen.x, screen.y + screen.height]].map(([x, y]) => ({ x: n(cx + (x - cx) * Math.cos(angle) - (y - cy) * Math.sin(angle)), y: n(cy + (x - cx) * Math.sin(angle) + (y - cy) * Math.cos(angle)) }));
}
async function png(svg) { return sharp(Buffer.from(svg)).png().toBuffer(); }
function save(file, bytes) { fs.mkdirSync(path.dirname(file), { recursive: true }); fs.writeFileSync(file, bytes); }
async function writePairFiles(folder, scheme, pairPng, mode) {
  const suffix = mode === 'template' ? '' : `-${mode}`;
  for (let page = 0; page < 2; page++) {
    const id = String(page + 1).padStart(2, '0');
    const target = mode === 'template' ? path.join(folder, id) : path.join(folder, 'layers', `${id}${suffix}`);
    const image = await sharp(pairPng).extract({ left: page * W, top: 0, width: W, height: H }).png().toBuffer();
    save(`${target}.png`, image);
    save(`${target}.svg`, makeSvg(scheme, scheme.pairPhones, mode, W, page * W));
  }
}
async function verifySeam(folder, pair) {
  const first = await sharp(path.join(folder, '01.png')).ensureAlpha().raw().toBuffer();
  const second = await sharp(path.join(folder, '02.png')).ensureAlpha().raw().toBuffer();
  const master = await sharp(pair).ensureAlpha().raw().toBuffer();
  const joined = Buffer.alloc(W * 2 * H * 4);
  for (let row = 0; row < H; row++) {
    first.copy(joined, row * W * 8, row * W * 4, (row + 1) * W * 4);
    second.copy(joined, row * W * 8 + W * 4, row * W * 4, (row + 1) * W * 4);
  }
  assert.deepEqual(joined, master, 'Joined first two images must reproduce the shared master pixel for pixel');
  return { sharedCanvas: { width: W * 2, height: H }, cutX: W, reconstructedPixelsEqual: true, comparedPixels: W * 2 * H };
}
async function verifyOverlay(bytes, scheme, phones) {
  const { data } = await sharp(bytes).ensureAlpha().raw().toBuffer({ resolveWithObject: true });
  const width = phones.length === 2 ? W * 2 : W;
  const checks = [];
  for (const p of phones) {
    const cx = Math.round(p.x + p.width / 2), cy = Math.round(p.y + p.height / 2);
    if (cx >= 0 && cx < width && cy >= 0 && cy < H) {
      const alpha = data[(cy * width + cx) * 4 + 3];
      assert.equal(alpha, 0, `Phone ${p.id}: screen center must stay transparent`);
      checks.push({ phone: p.id, sample: { x: cx, y: cy }, alpha });
    }
  }
  return checks;
}
async function main() {
  assert(W === 1080 && H === 1920 && config.schemes.length === 3);
  const reports = [], strips = [];
  for (const scheme of config.schemes) {
    const folder = path.join(root, scheme.id);
    fs.mkdirSync(path.join(folder, 'layers'), { recursive: true });
    const pairSource = makeSvg(scheme, scheme.pairPhones, 'template', W * 2);
    const pairPng = await png(pairSource);
    save(path.join(folder, 'pair.svg'), pairSource); save(path.join(folder, 'pair.png'), pairPng);
    // Render once and crop: page edges inherit exactly the same antialiased pixels.
    // Independently rendering the pages could change clipping at the shared edge.
    await writePairFiles(folder, scheme, pairPng, 'template');
    const transparentChecks = [];
    for (const mode of ['overlay', 'screen-mask']) {
      const wideSource = makeSvg(scheme, scheme.pairPhones, mode, W * 2);
      const wide = await png(wideSource);
      save(path.join(folder, 'layers', `pair-${mode}.svg`), wideSource); save(path.join(folder, 'layers', `pair-${mode}.png`), wide);
      await writePairFiles(folder, scheme, wide, mode);
      if (mode === 'overlay') transparentChecks.push(...await verifyOverlay(wide, scheme, scheme.pairPhones));
    }
    save(path.join(folder, 'layout-guide.svg'), makeSvg(scheme, scheme.pairPhones, 'guide', W * 2));
    const phones = scheme.pairPhones.map(p => ({ ...p, screen: geometry(scheme, p).screen, screenQuad: screenQuad(scheme, p) }));
    for (let index = 0; index < scheme.singlePhones.length; index++) {
      const phone = scheme.singlePhones[index], id = String(index + 3).padStart(2, '0');
      for (const mode of ['template', 'overlay', 'screen-mask']) {
        const source = makeSvg(scheme, [phone], mode), rendered = await png(source);
        const target = mode === 'template' ? path.join(folder, id) : path.join(folder, 'layers', `${id}-${mode}`);
        save(`${target}.svg`, source); save(`${target}.png`, rendered);
        if (mode === 'overlay') transparentChecks.push(...await verifyOverlay(rendered, scheme, [phone]));
      }
      save(path.join(folder, `layout-guide-${id}.svg`), makeSvg(scheme, [phone], 'guide'));
      phones.push({ ...phone, page: Number(id), screen: geometry(scheme, phone).screen, screenQuad: screenQuad(scheme, phone) });
    }
    const pageDimensions = [];
    for (let page = 1; page <= 5; page++) {
      const meta = await sharp(path.join(folder, String(page).padStart(2, '0') + '.png')).metadata();
      assert.equal(meta.width, W); assert.equal(meta.height, H);
      pageDimensions.push({ page, width: meta.width, height: meta.height });
    }
    const seam = await verifySeam(folder, pairPng);
    const { scale, gutter, padding } = config.preview;
    const tw = Math.round(W * scale), th = Math.round(H * scale);
    const stripWidth = tw * 5 + gutter * 4 + padding * 2, stripHeight = th + padding * 2;
    const thumbs = [];
    for (let page = 1; page <= 5; page++) thumbs.push({ input: await sharp(path.join(folder, String(page).padStart(2, '0') + '.png')).resize(tw, th).toBuffer(), left: padding + (page - 1) * (tw + gutter), top: padding });
    const strip = await sharp({ create: { width: stripWidth, height: stripHeight, channels: 4, background: color(scheme.background) } }).composite(thumbs).png().toBuffer();
    save(path.join(folder, 'strip.png'), strip);
    strips.push({ scheme: scheme.id, file: `${scheme.id}/strip.png`, width: stripWidth, height: stripHeight });
    const report = { id: scheme.id, name: scheme.name, pageDimensions, seam, transparentChecks, phones };
    save(path.join(folder, 'metadata.json'), JSON.stringify(report, null, 2) + '\n'); reports.push(report);
  }
  save(path.join(root, 'build-report.json'), JSON.stringify({ canvas: config.canvas, paletteSource: config.paletteSource, schemes: reports, previews: strips }, null, 2) + '\n');
  console.log(JSON.stringify({ built: reports.length, pages: reports.length * 5, seams: reports.map(r => ({ id: r.id, ...r.seam })), previews: strips }, null, 2));
}
main().catch(error => { console.error(error.stack || error); process.exitCode = 1; });
