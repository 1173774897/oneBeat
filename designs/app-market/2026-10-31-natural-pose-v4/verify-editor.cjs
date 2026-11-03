'use strict';
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const sharp = require('/Users/lizhe/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules/sharp');
const { chromium } = require('/Users/lizhe/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules/playwright');
const root = __dirname;
const temp = fs.mkdtempSync('/private/tmp/onebeat-natural-pose-qa-');
const config = JSON.parse(fs.readFileSync(path.join(root, 'config.json'), 'utf8'));
const snapshot = async page => Buffer.from((await page.evaluate(() => document.getElementById('canvas').toDataURL('image/png'))).split(',')[1], 'base64');
const ready = page => page.waitForFunction(() => !document.getElementById('download').disabled);
async function main() {
  const square = path.join(temp, 'square.png');
  await sharp({ create: { width: 300, height: 300, channels: 4, background: '#12ABDE' } }).png().toFile(square);
  const browser = await chromium.launch({ executablePath: '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', headless: true });
  try {
    const context = await browser.newContext({ acceptDownloads: true, viewport: { width: 1360, height: 1100 } });
    await context.route(/^https?:/, route => route.abort());
    const page = await context.newPage(), errors = [], network = [], checked = [];
    page.on('pageerror', error => errors.push(error.message));
    page.on('request', request => { if (/^https?:/.test(request.url())) network.push(request.url()); });
    await page.goto('file://' + path.join(root, 'editor.html'));
    await ready(page);
    assert.equal(await page.locator('#themes button').count(), 5);
    for (const item of config.items) {
      await page.locator(`#themes button[data-id="${item.id}"]`).click();
      await page.waitForFunction(id => document.getElementById('name').textContent.startsWith(id) && !document.getElementById('download').disabled, item.id);
      const before = await sharp(await snapshot(page)).ensureAlpha().raw().toBuffer();
      await page.locator('#upload').setInputFiles(square);
      await page.waitForFunction(() => document.getElementById('filename').textContent === 'square.png' && !document.getElementById('download').disabled);
      await page.locator('#cover').click(); await ready(page);
      const after = await sharp(await snapshot(page)).ensureAlpha().raw().toBuffer();
      const mask = await sharp(path.join(root, item.mask)).resize(1080, 1920).greyscale().raw().toBuffer();
      let protectedPixels = 0, changedScreenPixels = 0;
      for (let i = 0; i < mask.length; i++) {
        const p = i * 4;
        if (mask[i] === 0) {
          for (let c = 0; c < 4; c++) assert.equal(after[p + c], before[p + c], `${item.id}: protected artwork changed at pixel ${i}`);
          protectedPixels++;
        } else if (before[p] !== after[p] || before[p + 1] !== after[p + 1] || before[p + 2] !== after[p + 2]) changedScreenPixels++;
      }
      const s = item.screen.samplePoint, offset = (s.y * 1080 + s.x) * 4;
      assert.deepEqual(Array.from(after.subarray(offset, offset + 4)), [18, 171, 222, 255]);
      assert(changedScreenPixels > 1080 * 1920 * .2, `${item.id}: screenshot did not cover the large screen`);
      await page.locator('#reset').click(); await ready(page);
      const reset = await snapshot(page);
      assert.deepEqual(await sharp(reset).ensureAlpha().raw().toBuffer(), before, `${item.id}: reset changed the empty template`);
      checked.push({ id: item.id, protectedPixels, changedScreenPixels, handsAndOutsideMaskUnchanged: true, reset: true });
    }
    await page.locator('#upload').setInputFiles(square);
    await page.waitForFunction(() => document.getElementById('filename').textContent === 'square.png' && !document.getElementById('download').disabled);
    await page.locator('#contain').click(); await ready(page);
    const downloadEvent = page.waitForEvent('download');
    await page.locator('#download').click();
    const download = await downloadEvent;
    const exported = path.join(temp, 'export.png'); await download.saveAs(exported);
    const meta = await sharp(exported).metadata();
    assert.equal(meta.width, 1080); assert.equal(meta.height, 1920); assert.equal(meta.format, 'png');
    assert.deepEqual(errors, []); assert.deepEqual(network, []);
    const report = { status: 'passed', offline: true, checked, export: { width: meta.width, height: meta.height }, pageErrors: errors, networkRequests: network };
    fs.writeFileSync(path.join(root, 'previews', 'editor-qa.json'), JSON.stringify(report, null, 2) + '\n');
    console.log(JSON.stringify(report, null, 2));
  } finally { await browser.close(); }
}
main().catch(error => { console.error(error); process.exitCode = 1; });
