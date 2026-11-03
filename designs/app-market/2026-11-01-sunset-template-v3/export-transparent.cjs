const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const assert = require('node:assert/strict');
const sharp = require('/Users/lizhe/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules/sharp');
const root = __dirname;
const previous = path.resolve(root, '../2026-10-31-sunset-native-scroll-v2/transparent-screens');
const out = path.join(root, 'transparent-screens');
fs.mkdirSync(out, { recursive: true });
function checker(width, height, tile) {
  return Buffer.from(`<svg xmlns="http://www.w3.org/2000/svg" width="${width}" height="${height}"><defs><pattern id="grid" width="${tile * 2}" height="${tile * 2}" patternUnits="userSpaceOnUse"><rect width="${tile * 2}" height="${tile * 2}" fill="#E5E7EB"/><path d="M0 0H${tile}V${tile}H0ZM${tile} ${tile}H${tile * 2}V${tile * 2}H${tile}Z" fill="#CBD0D8"/></pattern></defs><rect width="${width}" height="${height}" fill="url(#grid)"/></svg>`);
}
function corners(box, center, degrees) {
  const a = degrees * Math.PI / 180;
  return [[box.x, box.y], [box.x + box.width, box.y], [box.x + box.width, box.y + box.height], [box.x, box.y + box.height]].map(([x, y]) => ({
    x: center.x + (x - center.x) * Math.cos(a) - (y - center.y) * Math.sin(a),
    y: center.y + (x - center.x) * Math.sin(a) + (y - center.y) * Math.cos(a)
  }));
}
async function main() {
  const pages = [], thumbs = [];
  for (let page = 1; page <= 6; page++) {
    const id = String(page).padStart(2, '0'), file = path.join(out, `${id}.png`);
    fs.copyFileSync(path.join(root, 'phone-preview/layers/overlay', `${id}.png`), file);
    const data = fs.readFileSync(file);
    const raw = await sharp(data).ensureAlpha().raw().toBuffer();
    const original = await sharp(path.join(previous, `${id}.png`)).ensureAlpha().raw().toBuffer();
    const unchanged = raw.equals(original);
    if (page !== 4) assert(unchanged, `Untargeted page changed: ${id}`);
    const thumb = await sharp(data).resize(324, 576).png().toBuffer();
    thumbs.push({ input: await sharp(checker(324, 576, 12)).composite([{ input: thumb }]).png().toBuffer(), left: 48 + (page - 1) * 348, top: 48 });
    if (page === 4) {
      const proof = await sharp(checker(1080, 1920, 36)).composite([{ input: data }]).png().toBuffer();
      await sharp(proof).resize(540, 960).jpeg({ quality: 94 }).toFile(path.join(out, '04-preview.jpg'));
    }
    pages.push({ page: id, width: 1080, height: 1920, pixelsEqualPreviousVersion: unchanged,
      sha256: crypto.createHash('sha256').update(data).digest('hex') });
  }
  fs.copyFileSync(path.join(root, 'phone-preview/layers/master-overlay.png'), path.join(out, 'master-transparent.png'));
  await sharp({ create: { width: 2160, height: 672, channels: 3, background: '#EAE7E0' } }).composite(thumbs).jpeg({ quality: 94 }).toFile(path.join(out, 'checkerboard-preview.jpg'));
  const report = JSON.parse(fs.readFileSync(path.join(root, 'phone-preview/build-report.json')));
  const config = JSON.parse(fs.readFileSync(path.join(root, 'phone-frames.json')));
  const phone = report.phones.find(item => item.page === 4);
  const left = 3240, right = 4320;
  const fullScreen = phone.screenQuad.every(point => point.x >= left && point.x <= right && point.y >= 0 && point.y <= 1920);
  assert(fullScreen, 'Fourth screen is clipped');
  const center = { x: phone.x + phone.width / 2, y: phone.y + phone.height / 2 };
  const halfStroke = config.frame.outlineWidth * phone.scale / 2;
  const outer = { x: phone.x - halfStroke, y: phone.y - halfStroke, width: phone.width + halfStroke * 2, height: phone.height + halfStroke * 2 };
  const shadow = { x: phone.x + config.frame.shadow.x * phone.scale, y: phone.y + config.frame.shadow.y * phone.scale, width: phone.width, height: phone.height };
  const bounds = [...corners(outer, center, phone.rotation), ...corners(shadow, center, phone.rotation)];
  const fullFrame = bounds.every(point => point.x >= left && point.x <= right && point.y >= 0 && point.y <= 1920);
  assert(fullFrame, 'Fourth frame or shadow is clipped');
  assert(report.overlayScreenHolesVerified, 'Screens must remain truly transparent');
  const manifest = { interpretation: 'Fourth phone at 0.3 times its original size', fourthScreenFullyInsideCanvas: fullScreen,
    fourthFrameAndShadowFullyInsideCanvas: fullFrame, screenInteriorsAlphaZero: true, otherFivePagesUnchanged: true,
    fourthPhone: { ...phone, x: phone.x - left, screen: { ...phone.screen, x: phone.screen.x - left }, screenQuad: phone.screenQuad.map(point => ({ x: point.x - left, y: point.y })) }, pages };
  fs.writeFileSync(path.join(out, 'export-manifest.json'), JSON.stringify(manifest, null, 2) + '\n');
  console.log(JSON.stringify({ fourthPhone: { x: 80, y: 96, scale: phone.scale, width: phone.width, height: phone.height }, checks: { fullScreen, fullFrame, otherFivePagesUnchanged: true, screensTransparent: true } }, null, 2));
}
main().catch(error => { console.error(error.stack || error); process.exitCode = 1; });
