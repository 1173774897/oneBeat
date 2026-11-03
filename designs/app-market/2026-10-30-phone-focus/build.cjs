#!/usr/bin/env node
'use strict';
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const root = __dirname;
const repo = path.resolve(root, '../../..');
const config = JSON.parse(fs.readFileSync(path.join(root, 'config.json'), 'utf8'));
let sharp;
try { sharp = require('sharp'); } catch (_) {
  sharp = require('/Users/lizhe/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules/sharp');
}
const { width: W, height: H } = config.canvas;
const n = value => Math.round(value * 1000000) / 1000000;
const escapeXml = value => String(value).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&apos;' }[c]));
function layout(mode) {
  const p = { ...config.modes[mode].phone };
  for (const key of ['x', 'y', 'width', 'inset', 'screenRadius']) assert(Number.isFinite(p[key]), `Invalid phone ${mode}.${key}`);
  assert(p.width > 2 * p.inset && p.inset > 0);
  const sw = p.width - 2 * p.inset;
  const sh = sw * config.screenRatio.height / config.screenRatio.width;
  p.height = sh + 2 * p.inset;
  p.radius = p.screenRadius + p.inset;
  const screen = { x: p.x + p.inset, y: p.y + p.inset, width: sw, height: sh, radius: p.screenRadius };
  assert(screen.radius > 0 && screen.radius <= sw / 2);
  return { phone: p, screen };
}
const layouts = Object.fromEntries(Object.keys(config.modes).map(mode => [mode, layout(mode)]));
function rect(box, fill, extra = '') {
  return `<rect x="${n(box.x)}" y="${n(box.y)}" width="${n(box.width)}" height="${n(box.height)}" rx="${n(box.radius || 0)}" fill="${fill}" ${extra}/>`;
}
function insetBox(p, inset) {
  return { x: p.x + inset, y: p.y + inset, width: p.width - 2 * inset, height: p.height - 2 * inset, radius: p.radius - inset };
}
function definitions(mode) {
  const { screen } = layouts[mode];
  const s = config.frame.shadow;
  return `<defs>
<linearGradient id="metal" x1="0" y1="0" x2="1" y2="0.07"><stop stop-color="#9DA3A8"/><stop offset="0.016" stop-color="#4B5056"/><stop offset="0.045" stop-color="#15191E"/><stop offset="0.48" stop-color="#333940"/><stop offset="0.93" stop-color="#12161B"/><stop offset="0.98" stop-color="#858D95"/><stop offset="1" stop-color="#434A52"/></linearGradient>
<linearGradient id="rim" x1="0" y1="0" x2="0.27" y2="1"><stop stop-color="#AEB4B9"/><stop offset="0.13" stop-color="#4B5157"/><stop offset="0.45" stop-color="#15191E"/><stop offset="0.82" stop-color="#353C43"/><stop offset="1" stop-color="#8A939C"/></linearGradient>
<filter id="shadow" x="-35%" y="-20%" width="170%" height="150%"><feDropShadow dx="${s.dx}" dy="${s.dy}" stdDeviation="${s.blur}" flood-color="#10131A" flood-opacity="${s.opacity}"/></filter>
<mask id="screen-hole" maskUnits="userSpaceOnUse" x="0" y="0" width="${W}" height="${H}"><rect width="${W}" height="${H}" fill="white"/>${rect(screen, 'black')}</mask>
<clipPath id="screen-clip">${rect(screen, 'white')}</clipPath>
</defs>`;
}
function phoneFrame(mode) {
  const { phone: p, screen } = layouts[mode];
  const f = config.frame;
  const h = f.highlightInset;
  const scale = p.width / f.detailReferenceWidth;
  const keys = f.sideKeys, ear = f.earpiece;
  const keyBox = (side, top, height) => ({
    x: side === 'left' ? p.x - keys.outset * scale : p.x + p.width - (keys.width - keys.outset) * scale,
    y: p.y + top * scale, width: keys.width * scale, height: height * scale, radius: keys.radius * scale
  });
  const sideKeys = `<g id="physical-side-keys">${[
    keyBox('left', keys.volumeTop, keys.volumeHeight),
    keyBox('left', keys.volumeTop + keys.volumeHeight + keys.volumeGap, keys.volumeHeight),
    keyBox('right', keys.powerTop, keys.powerHeight)
  ].map(box => rect(box, 'url(#metal)', 'stroke="#303740" stroke-width=".8"')).join('')}</g>`;
  const earpiece = { x: p.x + (p.width - ear.width * scale) / 2, y: p.y + ear.top * scale,
    width: ear.width * scale, height: ear.height * scale, radius: ear.radius * scale };
  assert(earpiece.y + earpiece.height < screen.y, 'Earpiece must remain above the replaceable screen');
  // There is no camera, island, status bar or reflection over the replaceable screen.
  return `<g id="phone-frame" mask="url(#screen-hole)">
${rect(p, '#11161D', 'filter="url(#shadow)"')}
${sideKeys}
${rect(p, 'url(#rim)', `stroke="${f.outerStroke}" stroke-width="1.6"`)}
${rect(insetBox(p, f.rimInset), 'url(#metal)', 'stroke="#C0C6CB" stroke-opacity=".5" stroke-width=".8"')}
${rect(insetBox(p, f.glassInset), f.glass, 'stroke="#242A32" stroke-width="1"')}
${rect({ x: screen.x - 1.2, y: screen.y - 1.2, width: screen.width + 2.4, height: screen.height + 2.4, radius: screen.radius + 1.2 }, '#11151B', 'stroke="#48515C" stroke-opacity=".6" stroke-width=".8"')}
${rect(earpiece, '#222B34', 'stroke="#4F5964" stroke-opacity=".55" stroke-width=".5"')}
<path d="M${n(p.x + h)} ${n(p.y + p.radius + 35)}V${n(p.y + p.height - p.radius - 35)}" stroke="#DCE0E5" stroke-width="1.1" opacity=".4"/>
<path d="M${n(p.x + p.width - h)} ${n(p.y + p.radius + 35)}V${n(p.y + p.height - p.radius - 35)}" stroke="#DCE0E5" stroke-width=".9" opacity=".3"/>
</g>`;
}
function svg(mode, body) {
  return `<svg xmlns="http://www.w3.org/2000/svg" width="${W}" height="${H}" viewBox="0 0 ${W} ${H}">${definitions(mode)}${body}</svg>`;
}
const imageTag = (uri, x, y, width, height, extra = '') => `<image href="${uri}" x="${n(x)}" y="${n(y)}" width="${n(width)}" height="${n(height)}" ${extra}/>`;
const dataUri = bytes => `data:image/png;base64,${bytes.toString('base64')}`;
const images = {};
async function loadPng(key, file) {
  const bytes = fs.readFileSync(file);
  const meta = await sharp(bytes).metadata();
  assert(meta.format === 'png', `Expected PNG: ${file}`);
  images[key] = { uri: dataUri(bytes), width: meta.width, height: meta.height };
}
function background(item) {
  return `<g id="background"><rect width="${W}" height="${H}" fill="${item.fallback}"/>${imageTag(images[item.background].uri, 0, 0, W, H, 'preserveAspectRatio="xMidYMid slice"')}</g>`;
}
function characters(item, mode) {
  return `<g id="characters-behind-phone">${item.characters.map(ch => {
    const pos = ch[mode], a = images[`assets/${ch.asset}`];
    const height = pos.width * a.height / a.width;
    return `<g transform="translate(${n(pos.x)} ${n(pos.y)})">${ch.flip ? `<g transform="translate(${n(pos.width)} 0) scale(-1 1)">` : ''}${imageTag(a.uri, 0, 0, pos.width, height)}${ch.flip ? '</g>' : ''}</g>`;
  }).join('')}</g>`;
}
async function savePair(relative, source) {
  const target = path.join(root, relative);
  fs.mkdirSync(path.dirname(target), { recursive: true });
  fs.writeFileSync(`${target}.svg`, source);
  const png = await sharp(Buffer.from(source)).png().toBuffer();
  fs.writeFileSync(`${target}.png`, png);
  return png;
}
async function verifyHole(png, mode, label) {
  const { data, info } = await sharp(png).ensureAlpha().raw().toBuffer({ resolveWithObject: true });
  const s = layouts[mode].screen;
  // Every interior pixel must stay transparent even when a character extends behind it.
  const left = Math.ceil(s.x + s.radius + 2), right = Math.floor(s.x + s.width - s.radius - 2);
  const top = Math.ceil(s.y + 2), bottom = Math.min(H - 1, Math.floor(s.y + s.height - 2));
  for (let y = top; y <= bottom; y++) for (let x = left; x <= right; x++) {
    assert.equal(data[(y * info.width + x) * 4 + 3], 0, `${label}: screen is covered at ${x},${y}`);
  }
  const p = layouts[mode].phone;
  const x = Math.round(p.x + p.width / 2), y = Math.round(p.y + p.inset / 2);
  assert(data[(y * info.width + x) * 4 + 3] > 240, `${label}: top frame missing`);
}
async function main() {
  assert(config.items.length === 5, 'Expected five themes');
  assert(W === 1080 && H === 1920, 'Unexpected output dimensions');
  for (const item of config.items) {
    assert(fs.existsSync(path.join(root, item.background)), `Background missing: ${item.background}`);
  }
  fs.mkdirSync(path.join(root, 'assets'), { recursive: true });
  for (const name of new Set(config.items.flatMap(item => item.characters.map(ch => ch.asset)))) {
    const source = path.join(repo, config.characterSourceDirectory, name);
    const target = path.join(root, 'assets', name);
    // The handoff ZIP keeps these exact assets so rebuilding also works outside the app repository.
    if (fs.existsSync(source)) fs.copyFileSync(source, target);
    else assert(fs.existsSync(target), `Character asset missing: ${name}`);
    await loadPng(`assets/${name}`, target);
  }
  for (const item of config.items) await loadPng(item.background, path.join(root, item.background));
  const bundle = { config, layouts, images, frames: {}, generatedAt: new Date().toISOString() };
  const reports = [];
  for (const mode of Object.keys(layouts)) {
    const frame = svg(mode, phoneFrame(mode));
    bundle.frames[mode] = `data:image/svg+xml;base64,${Buffer.from(frame).toString('base64')}`;
    const framePng = await savePair(`layers/${mode}/phone-frame`, frame);
    await verifyHole(framePng, mode, `${mode}/phone-frame`);
    await savePair(`layers/${mode}/screen-mask`, svg(mode, `<g id="screen-mask">${rect(layouts[mode].screen, 'white')}</g>`));
    const thumbs = [];
    for (const item of config.items) {
      const bg = background(item), chars = characters(item, mode);
      const assembly = `${bg}${chars}${phoneFrame(mode)}`;
      const template = svg(mode, `${assembly}<g id="replace-this-screen">${rect(layouts[mode].screen, config.screenFill)}</g>`);
      const overlay = svg(mode, `<g id="screen-transparent-overlay" mask="url(#screen-hole)">${assembly}</g>`);
      const png = await savePair(`templates/${mode}/${item.id}-template`, template);
      const overlayPng = await savePair(`layers/${mode}/${item.id}-overlay`, overlay);
      await verifyHole(overlayPng, mode, `${mode}/${item.id}-overlay`);
      await savePair(`layers/${mode}/${item.id}-background`, svg(mode, bg));
      await savePair(`layers/${mode}/${item.id}-characters`, svg(mode, `<g mask="url(#screen-hole)">${chars}</g>`));
      thumbs.push({ input: await sharp(png).resize(216, 384).toBuffer(), left: (Number(item.id) - 1) * 216, top: 0 });
    }
    fs.mkdirSync(path.join(root, 'previews'), { recursive: true });
    await sharp({ create: { width: W, height: 384, channels: 4, background: '#FFFFFF' } }).composite(thumbs).png().toFile(path.join(root, 'previews', `${mode}-contact.png`));
    reports.push({ mode, phone: layouts[mode].phone, screen: layouts[mode].screen, transparentScreenVerified: true });
  }
  // File URLs cannot fetch JSON reliably. Bundle one snapshot of config and image bytes
  // into the editor so it remains portable, private and exportable without a server.
  const editorPath = path.join(root, 'editor.html');
  const editor = fs.readFileSync(editorPath, 'utf8');
  const marker = /(<script id="template-bundle" type="application\/json">)[\s\S]*?(<\/script>)/;
  assert(marker.test(editor), 'Editor bundle marker missing');
  fs.writeFileSync(editorPath, editor.replace(marker, () => `<script id="template-bundle" type="application/json">${JSON.stringify(bundle).replace(/</g, '\\u003c')}</script>`));
  fs.writeFileSync(path.join(root, 'build-report.json'), JSON.stringify({ canvas: config.canvas, screenRatio: config.screenRatio, checks: reports }, null, 2) + '\n');
  console.log(JSON.stringify({ built: config.items.length, modes: reports, editor: editorPath }, null, 2));
}
main().catch(error => { console.error(error.stack || error); process.exitCode = 1; });
