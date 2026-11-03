'use strict';
const fs = require('node:fs');
const path = require('node:path');
let sharp;
try { sharp = require('sharp'); } catch (_) {
  sharp = require('/Users/lizhe/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules/sharp');
}
const root = __dirname;
const schemes = [
  { id: 'a-paper-coral', title: 'A · 纸白珊瑚', note: '纸白底 · 珊瑚框 · 墨色轮廓', colors: ['#FFF9EE', '#FF7056', '#171B1F'] },
  { id: 'b-ink-lilac', title: 'B · 墨黑丁香', note: '墨黑底 · 丁香框 · 暖白屏幕', colors: ['#171B1F', '#C5B7EB', '#FFFDF8'] },
  { id: 'c-lilac-paper', title: 'C · 丁香纸白', note: '丁香底 · 纸白框 · 青绿偏移影', colors: ['#C5B7EB', '#FFF9EE', '#29B5AE'] }
];
const uri = file => `data:image/png;base64,${fs.readFileSync(file).toString('base64')}`;
async function main() {
  let defs = '', body = '<rect width="1500" height="1876" fill="#EAE7E0"/>';
  schemes.forEach((scheme, row) => {
    const top = 48 + row * 604, y = top + 64;
    body += `<text x="48" y="${top + 32}" font-size="30" font-weight="700" fill="#171B1F">${scheme.title}</text>`;
    body += `<text x="380" y="${top + 31}" font-size="21" fill="#171B1F" opacity=".72">${scheme.note}</text>`;
    scheme.colors.forEach((color, i) => {
      body += `<circle cx="${1330 + i * 42}" cy="${top + 21}" r="12" fill="${color}" stroke="#171B1F" stroke-opacity=".3"/>`;
    });
    // Show the shared mother canvas, with no gutter at the cut, to make continuity visible.
    const cards = [{ file: 'pair.png', x: 48, width: 540, label: '01 → 02 · 连续画布' },
      ...['03', '04', '05'].map((id, i) => ({ file: `${id}.png`, x: 606 + i * 288, width: 270, label: id }))];
    cards.forEach((card, i) => {
      const clip = `clip-${row}-${i}`;
      defs += `<clipPath id="${clip}"><rect x="${card.x}" y="${y}" width="${card.width}" height="480" rx="10"/></clipPath>`;
      body += `<image href="${uri(path.join(root, scheme.id, card.file))}" x="${card.x}" y="${y}" width="${card.width}" height="480" clip-path="url(#${clip})"/>`;
      body += `<text x="${card.x + card.width / 2}" y="${y + 505}" font-size="17" text-anchor="middle" fill="#171B1F" opacity=".68">${card.label}</text>`;
    });
  });
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="1500" height="1876" viewBox="0 0 1500 1876"><defs>${defs}</defs><g font-family="PingFang SC, sans-serif">${body}</g></svg>`;
  fs.mkdirSync(path.join(root, 'previews'), { recursive: true });
  fs.writeFileSync(path.join(root, 'previews', 'three-schemes.svg'), svg);
  await sharp(Buffer.from(svg)).png().toFile(path.join(root, 'previews', 'three-schemes.png'));
  console.log('Saved previews/three-schemes.png');
}
main().catch(error => { console.error(error); process.exitCode = 1; });
