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
const COUNT = config.pageCount, MW = W * COUNT;
const n = value => Math.round(value * 1000000) / 1000000;
const color = key => { assert(config.palette[key], `Unknown palette color: ${key}`); return config.palette[key]; };
const phones = [...config.pairPhones.map(p => ({ ...p })), ...config.singlePhones.map(p => ({ ...p, x: p.x + (p.page - 1) * W }))];
const images = new Map();
const file = relative => path.join(root, relative);
function save(relative, data) {
  const target = file(relative);
  fs.mkdirSync(path.dirname(target), { recursive: true });
  fs.writeFileSync(target, data);
}
function rect(b, fill, extra = '') {
  return `<rect x="${n(b.x)}" y="${n(b.y)}" width="${n(b.width)}" height="${n(b.height)}" rx="${n(b.radius || 0)}" fill="${fill}" ${extra}/>`;
}
function rotated(phone, body) {
  return `<g transform="rotate(${n(phone.rotation)} ${n(phone.x + phone.width / 2)} ${n(phone.y + phone.height / 2)})">${body}</g>`;
}
function geometry(phone) {
  const p = config.phone;
  const outer = { ...phone, radius: p.radius };
  const screen = { x: phone.x + p.inset, y: phone.y + p.inset,
    width: phone.width - p.inset * 2, height: phone.height - p.inset * 2, radius: p.radius - p.inset };
  assert(screen.width > 0 && screen.height > 0 && screen.radius > 0, `Invalid phone ${phone.id}`);
  return { outer, screen };
}
function screenShape(phone, fill) { return rotated(phone, rect(geometry(phone).screen, fill)); }
function phoneShape(phone) {
  const p = config.phone, { outer, screen } = geometry(phone), s = p.shadow;
  const shadow = s.opacity ? rect({ ...outer, x: outer.x + s.x, y: outer.y + s.y }, color(s.color), `opacity="${s.opacity}"`) : '';
  return rotated(phone, `${shadow}${rect(outer, color(p.frame), `stroke="${color(p.outline)}" stroke-width="${p.outlineWidth}"`)}<g id="replace-screen-${phone.id}">${rect(screen, color(p.screen))}</g>`);
}
async function loadImage(asset) {
  if (images.has(asset)) return images.get(asset);
  assert(fs.existsSync(file(asset)), `Required final asset missing: ${asset}`);
  const bytes = fs.readFileSync(file(asset));
  const meta = await sharp(bytes).metadata();
  assert(meta.width && meta.height, `Invalid raster asset: ${asset}`);
  const mime = meta.format === 'jpeg' ? 'image/jpeg' : meta.format === 'webp' ? 'image/webp' : 'image/png';
  const image = { asset, width: meta.width, height: meta.height, uri: `data:${mime};base64,${bytes.toString('base64')}` };
  images.set(asset, image);
  return image;
}
async function prepareDirection(direction) {
  const overrides = new Map((direction.singlePhoneOverrides || []).map(p => [p.page, p]));
  const prepared = { ...direction, illustrations: [], phones: [...config.pairPhones.map(p => ({ ...p })), ...config.singlePhones.map(p => {
    const local = { ...p, ...(overrides.get(p.page) || {}) };
    return { ...local, x: local.x + (local.page - 1) * W };
  })] };
  if (direction.illustrationsFile) {
    assert(fs.existsSync(file(direction.illustrationsFile)), `Illustration placement file missing: ${direction.illustrationsFile}`);
    const parsed = JSON.parse(fs.readFileSync(file(direction.illustrationsFile), 'utf8'));
    const entries = Array.isArray(parsed) ? parsed : parsed.images || parsed.entries;
    assert(Array.isArray(entries) && entries.length, 'Direction one needs the app illustrations');
    for (const entry of entries) {
      assert(['behind', 'front'].includes(entry.layer), `Invalid illustration layer ${entry.id}`);
      assert([entry.x, entry.y, entry.width].every(Number.isFinite) && entry.width > 0, `Invalid illustration geometry ${entry.id}`);
      const source = await loadImage(entry.asset);
      prepared.illustrations.push({ ...entry, rotation: entry.rotation || 0, source, height: entry.width * source.height / source.width });
    }
  }
  if (direction.panorama) {
    const p = direction.panorama;
    assert(p.fit === 'cover' && [p.x, p.y, p.width, p.height, p.opacity].every(Number.isFinite), 'Panorama requires an explicit cover placement');
    assert(p.width > 0 && p.height > 0 && p.opacity >= 0 && p.opacity <= 1);
    prepared.panoramaSource = await loadImage(p.asset);
    const scale = Math.max(p.width / prepared.panoramaSource.width, p.height / prepared.panoramaSource.height);
    const width = prepared.panoramaSource.width * scale, height = prepared.panoramaSource.height * scale;
    prepared.coverPlacement = { x: p.x + (p.width - width) / 2, y: p.y + (p.height - height) / 2, width, height };
  }
  return prepared;
}
function background(direction) {
  let body = `<rect width="${MW}" height="${H}" fill="${color(direction.background)}"/>`;
  if (direction.panorama) {
    const p = direction.panorama, s = direction.panoramaSource;
    // One image viewport covers the entire six-page canvas. Sampling each page
    // independently would change the scene at crop edges and break continuity.
    body += `<image href="${s.uri}" x="${n(p.x)}" y="${n(p.y)}" width="${n(p.width)}" height="${n(p.height)}" preserveAspectRatio="xMidYMid slice" opacity="${p.opacity}"/>`;
  }
  return body;
}
function illustrationShape(entry) {
  return `<g id="art-${entry.id}" transform="translate(${n(entry.x)} ${n(entry.y)}) rotate(${n(entry.rotation)} ${n(entry.width / 2)} ${n(entry.height / 2)})"><g ${entry.flip ? `transform="translate(${n(entry.width)} 0) scale(-1 1)"` : ''}><image href="${entry.source.uri}" x="0" y="0" width="${n(entry.width)}" height="${n(entry.height)}" opacity="${entry.opacity ?? 1}"/></g></g>`;
}
function svg(direction, mode = 'template', width = MW, cropX = 0) {
  const phones = direction.phones;
  const holes = phones.map(p => screenShape(p, 'black')).join('');
  const defs = `<defs><mask id="screens-hole" maskUnits="userSpaceOnUse" x="0" y="0" width="${MW}" height="${H}"><rect width="${MW}" height="${H}" fill="white"/>${holes}</mask></defs>`;
  const bg = background(direction);
  const behind = direction.illustrations.filter(a => a.layer === 'behind').map(illustrationShape).join('');
  const front = direction.illustrations.filter(a => a.layer === 'front').map(illustrationShape).join('');
  // Foreground artwork may overlap the bezel, but never erase future app UI.
  const body = `${bg}<g id="illustrations-behind">${behind}</g>${phones.map(phoneShape).join('')}<g id="illustrations-front" mask="url(#screens-hole)">${front}</g>`;
  let content;
  if (mode === 'background') content = bg;
  else if (mode === 'screen-mask') content = phones.map(p => screenShape(p, 'white')).join('');
  else if (mode === 'overlay') content = `<g mask="url(#screens-hole)">${body}</g>`;
  else if (mode === 'guide') {
    const safe = [...config.titleSafeAreas.pair, ...config.singlePhones.map(p => ({ ...config.titleSafeAreas.single, x: config.titleSafeAreas.single.x + (p.page - 1) * W }))];
    content = body + safe.map(b => rect(b, 'none', `stroke="${color('ink')}" stroke-opacity=".5" stroke-width="3" stroke-dasharray="15 12"`)).join('') +
      Array.from({ length: COUNT - 1 }, (_, i) => `<path d="M${(i + 1) * W} 0V${H}" stroke="${color('coral')}" stroke-width="3" stroke-dasharray="18 12"/>`).join('');
  } else content = body;
  return `<svg xmlns="http://www.w3.org/2000/svg" width="${width}" height="${H}" viewBox="${cropX} 0 ${width} ${H}">${defs}${content}</svg>`;
}
async function render(source) { return sharp(Buffer.from(source), { limitInputPixels: 100000000 }).png().toBuffer(); }
async function sliceMaster(direction, master, mode) {
  const output = direction.id;
  for (let index = 0; index < COUNT; index++) {
    const id = String(index + 1).padStart(2, '0');
    const stem = mode === 'template' ? `${output}/${id}` : mode === 'background' ? `${output}/background/${id}` : `${output}/layers/${id}-${mode}`;
    save(`${stem}.png`, await sharp(master).extract({ left: index * W, top: 0, width: W, height: H }).png().toBuffer());
    save(`${stem}.svg`, svg(direction, mode, W, index * W));
  }
}
async function verifyReconstruction(output, master, mode) {
  const joined = Buffer.alloc(MW * H * 4);
  const masterRaw = await sharp(master).ensureAlpha().raw().toBuffer();
  for (let index = 0; index < COUNT; index++) {
    const id = String(index + 1).padStart(2, '0');
    const relative = mode === 'background' ? `${output}/background/${id}.png` : `${output}/${id}.png`;
    const page = await sharp(file(relative)).ensureAlpha().raw().toBuffer();
    for (let row = 0; row < H; row++) page.copy(joined, (row * MW + index * W) * 4, row * W * 4, (row + 1) * W * 4);
  }
  assert.deepEqual(joined, masterRaw, `${output}/${mode}: slices do not reconstruct their shared mother canvas`);
  return { reconstructedPixelsEqual: true, comparedPixels: MW * H, cutXs: Array.from({ length: COUNT - 1 }, (_, i) => (i + 1) * W) };
}
async function verifyScreens(overlay, template, phones) {
  const over = await sharp(overlay).ensureAlpha().raw().toBuffer();
  const art = await sharp(template).ensureAlpha().raw().toBuffer();
  const rgb = color(config.phone.screen).slice(1).match(/../g).map(v => parseInt(v, 16));
  const checks = [];
  for (const p of phones) {
    const x = Math.round(p.x + p.width / 2), y = Math.round(p.y + p.height / 2), offset = (y * MW + x) * 4;
    assert(x >= 0 && x < MW && y >= 0 && y < H);
    assert.equal(over[offset + 3], 0, `${p.id}: overlay center must be transparent`);
    assert.deepEqual(Array.from(art.subarray(offset, offset + 4)), [...rgb, 255], `${p.id}: artwork covers the blank screen`);
    checks.push({ phone: p.id, point: { x, y }, alpha: 0, screenColor: color(config.phone.screen) });
  }
  return checks;
}
function screenQuad(phone) {
  const s = geometry(phone).screen, a = phone.rotation * Math.PI / 180;
  const cx = phone.x + phone.width / 2, cy = phone.y + phone.height / 2;
  return [[s.x, s.y], [s.x + s.width, s.y], [s.x + s.width, s.y + s.height], [s.x, s.y + s.height]].map(([x, y]) => ({ x: n(cx + (x - cx) * Math.cos(a) - (y - cy) * Math.sin(a)), y: n(cy + (x - cx) * Math.sin(a) + (y - cy) * Math.cos(a)) }));
}
async function previews(direction, master) {
  const p = config.preview, tw = Math.round(W * p.scale), th = Math.round(H * p.scale);
  const thumbs = [];
  for (let page = 0; page < COUNT; page++) thumbs.push({ input: await sharp(file(`${direction.id}/${String(page + 1).padStart(2, '0')}.png`)).resize(tw, th).toBuffer(), left: p.padding + page * (tw + p.gutter), top: p.padding });
  const width = p.padding * 2 + tw * COUNT + p.gutter * (COUNT - 1), height = th + p.padding * 2;
  save(`${direction.id}/strip.png`, await sharp({ create: { width, height, channels: 4, background: color(direction.background) } }).composite(thumbs).png().toBuffer());
  save(`${direction.id}/continuous-preview.png`, await sharp(master).resize(Math.round(MW * p.scale), th).png().toBuffer());
}
async function main() {
  assert(W === 1080 && H === 1920 && COUNT === 6 && MW === 6480 && config.directions.length === 2);
  assert(phones.length === COUNT);
  const requested = process.argv.find(arg => arg.startsWith('--direction='))?.slice('--direction='.length);
  const selected = requested ? config.directions.filter(d => d.id === requested) : config.directions;
  assert(selected.length > 0, `Unknown direction: ${requested}`);
  // Validate selected branches before exporting anything: no fallback background may
  // masquerade as the requested generated panorama or app-illustration branch.
  const prepared = [];
  for (const direction of selected) prepared.push(await prepareDirection(direction));
  const report = { canvas: config.canvas, pageCount: COUNT, master: { width: MW, height: H }, partial: !!requested, directions: [] };
  for (const direction of prepared) {
    const templateSource = svg(direction), master = await render(templateSource);
    save(`${direction.id}/master.svg`, templateSource); save(`${direction.id}/master.png`, master);
    await sliceMaster(direction, master, 'template');
    const pair = await sharp(master).extract({ left: 0, top: 0, width: W * 2, height: H }).png().toBuffer();
    save(`${direction.id}/pair.png`, pair); save(`${direction.id}/pair.svg`, svg(direction, 'template', W * 2));
    const modes = {};
    for (const mode of ['overlay', 'screen-mask']) {
      const source = svg(direction, mode), rendered = await render(source);
      save(`${direction.id}/layers/master-${mode}.svg`, source); save(`${direction.id}/layers/master-${mode}.png`, rendered);
      await sliceMaster(direction, rendered, mode);
      modes[mode] = rendered;
    }
    const pageDimensions = [];
    for (let page = 1; page <= COUNT; page++) {
      const meta = await sharp(file(`${direction.id}/${String(page).padStart(2, '0')}.png`)).metadata();
      assert.equal(meta.width, W); assert.equal(meta.height, H);
      pageDimensions.push({ page, width: meta.width, height: meta.height });
    }
    const seam = await verifyReconstruction(direction.id, master, 'template');
    const screens = await verifyScreens(modes.overlay, master, direction.phones);
    const metadata = { id: direction.id, name: direction.name, pageDimensions, seam, screens,
      phones: direction.phones.map(p => ({ ...p, screen: geometry(p).screen, screenQuad: screenQuad(p) })),
      illustrations: direction.illustrations.map(({ source, ...entry }) => ({ ...entry, sourceDimensions: { width: source.width, height: source.height } })) };
    if (direction.panorama) {
      const bgSource = svg(direction, 'background'), bg = await render(bgSource);
      save(`${direction.id}/background/master.svg`, bgSource); save(`${direction.id}/background/master.png`, bg);
      await sliceMaster(direction, bg, 'background');
      metadata.backgroundSeam = await verifyReconstruction(direction.id, bg, 'background');
      metadata.panorama = { ...direction.panorama, sourceDimensions: { width: direction.panoramaSource.width, height: direction.panoramaSource.height }, coverPlacement: direction.coverPlacement };
    }
    save(`${direction.id}/layout-guide.svg`, svg(direction, 'guide'));
    await previews(direction, master);
    save(`${direction.id}/metadata.json`, JSON.stringify(metadata, null, 2) + '\n');
    report.directions.push(metadata);
  }
  save(requested ? `${requested}/build-report.json` : 'build-report.json', JSON.stringify(report, null, 2) + '\n');
  console.log(JSON.stringify({ built: report.directions.length, pages: COUNT * report.directions.length, master: report.master,
    directions: report.directions.map(d => ({ id: d.id, seam: d.seam.reconstructedPixelsEqual, backgroundSeam: d.backgroundSeam?.reconstructedPixelsEqual, screens: d.screens.length })) }, null, 2));
}
main().catch(error => { console.error(error.stack || error); process.exitCode = 1; });
