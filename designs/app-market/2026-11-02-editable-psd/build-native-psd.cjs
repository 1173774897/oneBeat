#!/usr/bin/env node
'use strict';
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const { spawnSync } = require('node:child_process');
function dependency(name, override, fallback) {
  if (override) return require(override);
  try { return require(name); } catch (_) { return require(fallback); }
}
const sharp = dependency('sharp',process.env.ONEBEAT_SHARP,'/Users/lizhe/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules/sharp');
const { writePsdBuffer, readPsd } = dependency('ag-psd',process.env.ONEBEAT_AG_PSD,'/private/tmp/onebeat-psd-tools/node_modules/ag-psd');
const root = __dirname;
const layout = JSON.parse(fs.readFileSync(path.join(root, 'layout.json')));
const outlines = JSON.parse(fs.readFileSync(path.join(root, 'text-paths.json')));
const { width: W, height: H } = layout.canvas;
const C = layout.palette, E = layout.titleEffects;
const rgb = hex => ({ r: parseInt(hex.slice(1, 3), 16), g: parseInt(hex.slice(3, 5), 16), b: parseInt(hex.slice(5, 7), 16) });
const px = value => ({ units: 'Pixels', value });
const save = (relative, data) => {
  const destination = path.join(root, relative);
  fs.mkdirSync(path.dirname(destination), { recursive: true });
  fs.writeFileSync(destination, data);
  return destination;
};
const svg = (w, h, content, x = 0, y = 0) => Buffer.from(`<svg xmlns="http://www.w3.org/2000/svg" width="${w}" height="${h}" viewBox="${x} ${y} ${w} ${h}">${content}</svg>`);
const glyph = (run, x, y, color, extra = '') => `<path d="${run.path}" transform="translate(${x} ${y})" fill="${color}" ${extra}/>`;
const stroke = (color, width) => `stroke="${color}" stroke-width="${width}" stroke-linejoin="round"`;
function shadow(color, dx, dy) {
  return { enabled: true, present: true, showInDialog: true, color: rgb(color), opacity: 1,
    blendMode: 'normal', useGlobalLight: false, angle: Math.atan2(dy, -dx) * 180 / Math.PI,
    distance: px(Math.hypot(dx, dy)), size: px(0), choke: px(0), layerConceals: true };
}
function edge(color, width) {
  return { enabled: true, present: true, showInDialog: true, color: rgb(color),
    size: px(width), position: 'center', fillType: 'color', blendMode: 'normal', opacity: 1 };
}
async function raster(content, b, bleed = 2) {
  const left = Math.floor(b.x - bleed), top = Math.floor(b.y - bleed);
  const width = Math.ceil(b.x + b.width + bleed) - left;
  const height = Math.ceil(b.y + b.height + bleed) - top;
  const data = await sharp(svg(width, height, content, left, top)).ensureAlpha().raw().toBuffer();
  return { left, top, imageData: { width, height, data: new Uint8ClampedArray(data) } };
}
function unitBounds(b) {
  return { left: px(b.x), top: px(b.y), right: px(b.x + b.width), bottom: px(b.y + b.height) };
}
async function typeLayer(id, name, run, x, baseline, fill, effects) {
  const b = run.bounds, normal = run.normalBounds, style = run.style;
  const cache = await raster(glyph(run, x, baseline, fill), { x: x + b.x, y: baseline + b.y, width: b.width, height: b.height });
  // Only glyph fill belongs in the layer cache. Native layer effects remain editable and must not be baked into it.
  return { id, name, ...cache, blendMode: 'normal', opacity: 1, effects,
    text: { text: run.text, shapeType: 'point', orientation: 'horizontal', antiAlias: 'smooth',
      transform: [1, 0, -Math.tan(style.slantDegrees * Math.PI / 180), 1, x, baseline],
      left: normal.x, top: normal.y, right: normal.x + normal.width, bottom: normal.y + normal.height,
      bounds: unitBounds(normal), boundingBox: unitBounds(normal), pointBase: [0, 0],
      useFractionalGlyphWidths: true,
      style: { font: { name: run.fontPostScriptName }, fontSize: style.fontSize, fillColor: rgb(fill),
        fauxBold: false, fauxItalic: false, horizontalScale: 1, verticalScale: 1,
        tracking: style.letterSpacing / style.fontSize * 1000, autoKerning: false, kerning: 0 },
      paragraphStyle: { justification: 'left', autoHyphenate: false } } };
}
function roundedRectPath(x, y, w, h, r) {
  const k = 0.552284749831 * r;
  const point = (ax, ay, bx = ax, by = ay, cx = ax, cy = ay) => ({ linked: true, points: [bx, by, ax, ay, cx, cy] });
  return { open: false, operation: 'combine', fillRule: 'non-zero', knots: [
    point(x+r,y,x+r-k,y), point(x+w-r,y,x+w-r,y,x+w-r+k,y),
    point(x+w,y+r,x+w,y+r-k), point(x+w,y+h-r,x+w,y+h-r,x+w,y+h-r+k),
    point(x+w-r,y+h,x+w-r+k,y+h), point(x+r,y+h,x+r,y+h,x+r-k,y+h),
    point(x,y+h-r,x,y+h-r+k), point(x,y+r,x,y+r,x,y+r-k)
  ] };
}
async function shapeLayer(id, name, x, y, w, h, radius, fill, effects) {
  return { id, name, ...await raster(`<rect x="${x}" y="${y}" width="${w}" height="${h}" rx="${radius}" fill="${fill}"/>`, {x,y,width:w,height:h}),
    vectorFill: { type: 'color', color: rgb(fill) }, vectorMask: { paths: [roundedRectPath(x,y,w,h,radius)] }, effects };
}
function flattenLayers(children) {
  return children.flatMap(layer => layer.children ? flattenLayers(layer.children) : [layer]);
}
async function buildPage(page, index) {
  const runs = outlines.pages.find(item => item.id === page.id).texts;
  const x = page.x, dy = page.yOffset || 0, tagY = page.eyebrowY + dy;
  const tagW = Math.ceil(runs.eyebrow.advance + 28);
  const layers = [], preview = [], report = [];
  let id = 10000 + index * 100;
  layers.push(await shapeLayer(id++, `${page.id} · 编号底牌（形状）`, x, tagY, tagW, 44, 3, C.ink,
    { scale: 1, dropShadow: [shadow(C.teal, 5, 5)] }));
  preview.push(`<rect x="${x+5}" y="${tagY+5}" width="${tagW}" height="44" rx="3" fill="${C.teal}"/><rect x="${x}" y="${tagY}" width="${tagW}" height="44" rx="3" fill="${C.ink}"/>`);
  async function add(role, label, xx, baseline, fill, effects, rendered) {
    const run = runs[role];
    const layer = await typeLayer(id++, `${page.id} · ${label} · ${run.text}`, run, xx, baseline, fill, effects);
    layers.push(layer);
    preview.push(rendered || glyph(run, xx, baseline, fill));
    report.push({ role, name: layer.name, text: run.text, font: run.fontPostScriptName, fontSize: run.style.fontSize,
      slantDegrees: run.style.slantDegrees, x: xx, baseline, effects, id: layer.id });
  }
  await add('eyebrow', '编号', x+14, tagY+30, C.paper);
  const y1 = page.firstBaseline + dy, y2 = page.secondBaseline + dy;
  await add('first', '主标题', x, y1, C.ink, { scale: 1, dropShadow: [shadow(C.paper,E.shadowX,E.shadowY)] },
    glyph(runs.first,x+E.shadowX,y1+E.shadowY,C.paper)+glyph(runs.first,x,y1,C.ink));
  await add('second', '副标题', x, y2, C.paper,
    { scale: 1, stroke: [edge(C.ink,E.outlineWidth)], dropShadow: [shadow(C.teal,E.shadowX,E.shadowY)] },
    glyph(runs.second,x+E.shadowX,y2+E.shadowY,C.teal,stroke(C.teal,E.outlineWidth))+
    glyph(runs.second,x,y2,C.paper,stroke(C.ink,E.outlineWidth)));
  await add('subtitle', '说明', x, page.subtitleBaseline+dy, C.ink);
  if (runs.note) {
    const ny = page.noteY + dy, nw = Math.ceil(runs.note.advance+24);
    layers.push(await shapeLayer(id++, `${page.id} · 提示底牌（形状）`, x, ny, nw, 36, 4, C.paper, {scale:1,stroke:[edge(C.ink,1.5)]}));
    preview.push(`<rect x="${x}" y="${ny}" width="${nw}" height="36" rx="4" fill="${C.paper}" ${stroke(C.ink,1.5)}/>`);
    await add('note', '功能提示', x+12, ny+25, C.ink);
  }
  const sourcePng = path.join(root,page.source);
  assert(fs.existsSync(sourcePng), `Missing decoded source composite: ${sourcePng}`);
  const finalPng = await sharp(sourcePng).composite([{input:svg(W,H,preview.join(''))}]).png().toBuffer();
  save(`previews/${page.id}.png`, finalPng);
  const raw = await sharp(finalPng).ensureAlpha().raw().toBuffer();
  const rawPath = save(`.build/${page.id}.rgba`, raw);
  const thumb = save(`.build/${page.id}-thumbnail.jpg`, await sharp(finalPng).flatten({background:C.paper}).resize(144,256).jpeg({quality:85}).toBuffer());
  // Append the new records through the byte-preserving merger: ag-psd must never rewrite existing smart objects.
  const additions = writePsdBuffer({width:W,height:H,imageData:{width:W,height:H,data:new Uint8ClampedArray(raw)},children:layers},
    {noBackground:true,generateThumbnail:false,trimImageData:false});
  const additionPath = save(`.build/${page.id}-additions.psd`, additions);
  const output = path.join(root,'psd',`${page.id}.psd`);
  fs.mkdirSync(path.dirname(output),{recursive:true});
  const merged = spawnSync('python3',[path.join(root,'preserve_psd.py'),'--original',path.join(layout.sourcePsdDirectory,`${page.id}.psd`),
    '--additions',additionPath,'--output',output,'--composite-rgba',rawPath,'--thumbnail-jpeg',thumb],{encoding:'utf8'});
  if (merged.status !== 0) throw new Error(merged.stderr || merged.stdout);
  const parsed = readPsd(fs.readFileSync(output),{skipLayerImageData:true,skipCompositeImageData:true,skipThumbnail:true});
  const parsedLayers = flattenLayers(parsed.children);
  for (const expected of report) {
    const actual = parsedLayers.find(l => l.id === expected.id);
    assert(actual?.text, `Missing native TySh: ${expected.name}`);
    assert.equal(actual.text.text,expected.text);
    assert.equal(actual.text.style.font.name,expected.font);
    assert.equal(actual.text.style.fontSize,expected.fontSize);
    assert(Math.abs(actual.text.transform[2]+Math.tan(expected.slantDegrees*Math.PI/180))<1e-10);
    if (expected.role === 'first') assert.deepEqual(actual.effects.dropShadow[0].color,rgb(C.paper));
    if (expected.role === 'second') {
      assert.deepEqual(actual.effects.dropShadow[0].color,rgb(C.teal));
      assert.deepEqual(actual.effects.stroke[0].color,rgb(C.ink));
    }
  }
  console.log(`${page.id}: ${report.length} editable type layers, ${layers.length} added layers, preserved original PSD`);
  return {page:page.id,layers:report,output:`psd/${page.id}.psd`,png:finalPng};
}
async function main() {
  const results = [];
  for (let i=0;i<layout.pages.length;i++) results.push(await buildPage(layout.pages[i],i));
  const tw=324,th=576,gap=24,pad=48;
  const tiles=[];
  for (let i=0;i<results.length;i++) tiles.push({input:await sharp(results[i].png).flatten({background:C.paper}).resize(tw,th).png().toBuffer(),left:pad+i*(tw+gap),top:pad});
  save('strip.jpg',await sharp({create:{width:tw*6+gap*5+pad*2,height:th+pad*2,channels:3,background:'#EAE7E0'}}).composite(tiles).jpeg({quality:94}).toBuffer());
  save('build-report.json',JSON.stringify({canvas:layout.canvas,palette:C,fontFiles:outlines.font.files,
    editableTextCount:results.reduce((n,r)=>n+r.layers.length,0),pages:results.map(({png,...r})=>r),
    verification:'Native TySh/EngineData, font PostScript names, font sizes, shear transforms and editable effects read back. Original layer records/channel bytes and embedded smart objects retained by byte-preserving merger. No native-editor re-save verification.'},null,2));
}
main().catch(error=>{console.error(error);process.exitCode=1;});
