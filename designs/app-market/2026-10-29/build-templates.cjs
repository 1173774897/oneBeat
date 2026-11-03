const fs = require('node:fs');
const path = require('node:path');
const root = __dirname;
const config = JSON.parse(fs.readFileSync(path.join(root, 'templates.config.json'), 'utf8'));
const { phone: p, canvas: c } = config.common;
const screen = { x: p.x + p.inset, y: p.y + p.inset, width: p.width - p.inset * 2, height: p.height - p.inset * 2, radius: config.common.screenRadius };
config.common.screen = screen;
const { x: sx, y: sy, width: sw, height: sh, radius: sr } = screen;
const cache = new Map();
function asset(name) {
  if (!cache.has(name)) {
    const buf = fs.readFileSync(path.join(root, 'assets', name));
    cache.set(name, { uri: `data:image/png;base64,${buf.toString('base64')}`, width: buf.readUInt32BE(16), height: buf.readUInt32BE(20) });
  }
  return cache.get(name);
}
function image(name, x, y, w, h, extra = '') {
  const a = asset(name);
  return `<image href="${a.uri}" x="${x}" y="${y}" width="${w}" height="${h ?? w * a.height / a.width}" ${extra}/>`;
}
function star(x, y, size = 54, color = '#ff7058', angle = 0) {
  return `<g transform="translate(${x} ${y}) rotate(${angle})"><path d="M0 ${-size / 2} Q${size / 14} ${-size / 14} ${size / 2} 0 Q${size / 14} ${size / 14} 0 ${size / 2} Q${-size / 14} ${size / 14} ${-size / 2} 0 Q${-size / 14} ${-size / 14} 0 ${-size / 2}Z" fill="${color}" stroke="#222428" stroke-width="3.5" stroke-linejoin="round"/></g>`;
}
function beat(x, y, color = '#202327', angle = 0) {
  return `<g transform="translate(${x} ${y}) rotate(${angle})" stroke="${color}" stroke-width="8" stroke-linecap="round"><path d="M-25 20l-10-23M0 10V-23M25 20L37 1"/></g>`;
}
const defs = `<defs>
<linearGradient id="metal" x1="0" x2="1" y1="0" y2=".1"><stop stop-color="#6d6f71"/><stop offset=".012" stop-color="#b9b9b6"/><stop offset=".026" stop-color="#55575a"/><stop offset=".06" stop-color="#191a1d"/><stop offset=".48" stop-color="#393a3c"/><stop offset=".9" stop-color="#17181b"/><stop offset=".971" stop-color="#77797c"/><stop offset=".986" stop-color="#c5c5c0"/><stop offset="1" stop-color="#55565a"/></linearGradient>
<linearGradient id="rim" x1="0" x2=".3" y1="0" y2="1"><stop stop-color="#bbbcb8"/><stop offset=".07" stop-color="#5a5d5e"/><stop offset=".28" stop-color="#16181a"/><stop offset=".8" stop-color="#333638"/><stop offset="1" stop-color="#aaa9a5"/></linearGradient>
<filter id="phone-shadow" x="-40%" y="-20%" width="190%" height="160%"><feDropShadow dx="16" dy="25" stdDeviation="20" flood-color="#28202d" flood-opacity=".26"/></filter>
<filter id="paper-shadow" x="-15%" y="-15%" width="140%" height="140%"><feDropShadow dx="7" dy="9" stdDeviation="0" flood-color="#202327" flood-opacity=".2"/></filter>
<pattern id="dots" width="18" height="18" patternUnits="userSpaceOnUse"><circle cx="4" cy="4" r="2.5" fill="#202327"/></pattern>
<pattern id="soft-dots" width="22" height="22" patternUnits="userSpaceOnUse"><circle cx="5" cy="5" r="2.8" fill="#202327" opacity=".16"/></pattern>
<clipPath id="sunset-clip"><path d="M0 1560Q570 1510 1080 1580V1920H0Z"/></clipPath>
<clipPath id="neon-clip"><path d="M0 1560Q580 1500 1080 1570V1920H0Z"/></clipPath>
<mask id="screen-hole" maskUnits="userSpaceOnUse" x="0" y="0" width="1080" height="1920"><rect width="1080" height="1920" fill="white"/><rect x="${sx}" y="${sy}" width="${sw}" height="${sh}" rx="${sr}" fill="black"/></mask>
</defs>`;
function decorations(item) {
  switch (item.theme) {
    case 'coral-arc': return `<path d="M-180 1500Q430 1080 1230 1495L1230 2020H-180Z" fill="#ff745a"/><path d="M-190 1525Q410 1130 1220 1530" fill="none" stroke="#23262a" stroke-width="5"/><circle cx="1037" cy="821" r="163" fill="#d5c6f2"/><circle cx="1045" cy="824" r="144" fill="url(#soft-dots)"/><path d="M0 772Q94 769 134 830V1088Q39 1045 0 999Z" fill="url(#dots)" opacity=".2"/>${star(78, 684, 59, '#24b9b0', 12)}${beat(1010, 1210, '#202327', 17)}<path d="M25 1855Q530 1780 1060 1870" fill="none" stroke="#fff5e7" stroke-width="26"/>`;
    case 'mint-rings': return `<circle cx="586" cy="1365" r="654" fill="#fff7e9"/><circle cx="588" cy="1365" r="576" fill="none" stroke="#90d8cb" stroke-width="97"/><circle cx="590" cy="1365" r="640" fill="none" stroke="#2a3330" stroke-width="4"/><path d="M-10 1730Q550 1655 1090 1760V1930H-10Z" fill="#fff8eb"/><path d="M956 655h124v320H945Z" fill="url(#soft-dots)"/>${star(1002, 1060, 62, '#c6b4e9', -15)}${beat(63, 900, '#ff7357', -19)}`;
    case 'paper-ticket': return `<rect x="73" y="649" width="955" height="1140" rx="25" fill="#fff8eb" stroke="#24272c" stroke-width="4" transform="rotate(-7 550 1220)" filter="url(#paper-shadow)"/><path d="M-20 1770L1090 1640V1930H-20Z" fill="#ff8069"/><path d="M43 1140h118v340H43Z" fill="url(#dots)" opacity=".3"/><path d="M955 1380h132v340H955Z" fill="url(#dots)" opacity=".2"/>${star(1004, 700, 64, '#29b9b1', 5)}${beat(73, 688, '#24272c', -12)}`;
    case 'lilac-disc': return `<circle cx="554" cy="1310" r="675" fill="#d4c3ef" stroke="#24272c" stroke-width="4"/><circle cx="554" cy="1310" r="590" fill="none" stroke="#eee4fb" stroke-width="33"/><circle cx="555" cy="1310" r="548" fill="none" stroke="#24272c" stroke-width="3" opacity=".35"/><path d="M957 935h140v410H957Z" fill="url(#dots)" opacity=".15"/>${star(1008, 729, 66, '#ff795b', -9)}${beat(65, 1020, '#24272c', -20)}<g transform="translate(1015 1580) rotate(16)" fill="#26262c"><path d="M-10-75v88c-32-7-38 28-11 28 15 0 22-9 22-20V-44l33 10v63c-31-5-35 29-10 29 16 0 22-9 22-20V-57Z"/></g>`;
    case 'sunset-band': return `<circle cx="1011" cy="1110" r="195" fill="#ffd68c"/><path d="M3 737h136v380H3Z" fill="url(#soft-dots)"/>${star(75, 666, 57, '#ff8c67', -14)}<g clip-path="url(#sunset-clip)">${image('sunset-sky.png', 0, 1400, 1080, 1000, 'preserveAspectRatio="xMidYMid slice"')}${image('sunset-clouds.png', 0, 1470, 1080, 300, 'preserveAspectRatio="xMidYMid slice"')}${image('sunset-ocean.png', 0, 1610, 1080, 270, 'preserveAspectRatio="xMidYMid slice"')}${image('sunset-road.png', 0, 1770, 1080, 240, 'preserveAspectRatio="xMidYMid slice"')}</g><path d="M0 1560Q570 1510 1080 1580" fill="none" stroke="#df9f78" stroke-width="4"/>${beat(1004, 780, '#25282b', 14)}`;
    case 'neon-band': return `<path d="M0 1010Q160 870 233 900L100 1215H0Z" fill="#b3e2dc"/><circle cx="1055" cy="1260" r="185" fill="#ffd2c7"/><circle cx="1044" cy="1260" r="170" fill="url(#soft-dots)"/>${star(1003, 730, 64, '#ff7c68', 10)}${star(70, 1290, 39, '#21b7b0', -10)}<g clip-path="url(#neon-clip)">${image('neon-sky.png', 0, 1420, 1080, 700, 'preserveAspectRatio="xMidYMid slice"')}${image('neon-blocks.png', 0, 1542, 1080, 375, 'preserveAspectRatio="xMidYMid slice"')}${image('neon-road.png', 0, 1820, 1080, 180, 'preserveAspectRatio="xMidYMid slice"')}</g><path d="M0 1560Q580 1500 1080 1570" fill="none" stroke="#a0a4d5" stroke-width="4"/>`;
    default: throw new Error(`Unknown theme ${item.theme}`);
  }
}
function characterGroup(item) {
  // Use the shipped character PNGs unchanged; the screen cutout keeps future app UI unobstructed.
  return item.characters.map(ch => {
    const a = asset(ch.asset), h = ch.width * a.height / a.width;
    return `<g transform="translate(${ch.x} ${ch.y}) rotate(${ch.rotation ?? 0} ${ch.width / 2} ${h / 2})"><g ${ch.flip ? `transform="translate(${ch.width} 0) scale(-1 1)"` : ''}>${image(ch.asset, 0, 0, ch.width, h)}</g></g>`;
  }).join('');
}
function phoneGroup() {
  return `<g id="device-frame"><g filter="url(#phone-shadow)"><rect x="${p.x}" y="${p.y}" width="${p.width}" height="${p.height}" rx="${p.radius}" fill="#17191b"/></g>
<g fill="url(#metal)" stroke="#55575b" stroke-width="1.5"><rect x="${p.x - 6}" y="${p.y + 256}" width="9" height="97" rx="4"/><rect x="${p.x - 6}" y="${p.y + 376}" width="9" height="97" rx="4"/><rect x="${p.x + p.width - 3}" y="${p.y + 316}" width="9" height="150" rx="4"/></g>
<rect x="${p.x}" y="${p.y}" width="${p.width}" height="${p.height}" rx="${p.radius}" fill="url(#rim)" stroke="#222429" stroke-width="2.5"/>
<rect x="${p.x + 4}" y="${p.y + 4}" width="${p.width - 8}" height="${p.height - 8}" rx="${p.radius - 4}" fill="url(#metal)" stroke="#bdbeb7" stroke-opacity=".72" stroke-width="1.4"/>
<rect x="${p.x + 11}" y="${p.y + 11}" width="${p.width - 22}" height="${p.height - 22}" rx="${p.radius - 11}" fill="#08090b" stroke="#51545a" stroke-width="2"/>
<rect x="${sx - 1.5}" y="${sy - 1.5}" width="${sw + 3}" height="${sh + 3}" rx="${sr + 1.5}" fill="#181a1c" stroke="#35373a" stroke-width="1"/>
<path d="M${p.x + 5} ${p.y + 201}v${p.height - 402}" stroke="#d1d0c9" stroke-width="1.2" opacity=".5"/>
<path d="M${p.x + p.width - 5} ${p.y + 201}v${p.height - 402}" stroke="#dddcd5" stroke-width="1" opacity=".6"/>
<rect x="${p.x + p.width / 2 - 49}" y="${p.y + 15}" width="98" height="3.5" rx="1.7" fill="#343638"/><circle cx="${p.x + p.width / 2 + 68}" cy="${p.y + 17}" r="2.2" fill="#253a45"/>
</g>`;
}
function makeSVG(item, mode) {
  const background = `<g id="background"><rect width="1080" height="1920" fill="${item.background}"/>${decorations(item)}</g>`;
  const foreground = `<g id="character-decorations" mask="url(#screen-hole)">${characterGroup(item)}</g>`;
  const phone = phoneGroup();
  const blank = `<g id="replace-this-screen"><rect x="${sx}" y="${sy}" width="${sw}" height="${sh}" rx="${sr}" fill="${config.common.screenFill}"/></g>`;
  let body;
  if (mode === 'background') body = background;
  else if (mode === 'foreground') body = foreground;
  else if (mode === 'frame') body = `<g mask="url(#screen-hole)">${phone}</g>`;
  else if (mode === 'mask') body = `<rect x="${sx}" y="${sy}" width="${sw}" height="${sh}" rx="${sr}" fill="white"/>`;
  else if (mode === 'overlay') body = `<g mask="url(#screen-hole)">${background}${phone}${foreground}</g>`;
  else body = `${background}${phone}${blank}${foreground}`;
  return `<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="${c.width}" height="${c.height}" viewBox="0 0 ${c.width} ${c.height}">${defs}${body}</svg>`;
}
for (const d of ['source', 'layers', 'png', '.render']) fs.mkdirSync(path.join(root, d), {recursive:true});
for (const item of config.items) {
  fs.writeFileSync(path.join(root, 'source', `${item.id}-template.svg`), makeSVG(item, 'preview'));
  for (const mode of ['overlay', 'background', 'foreground']) fs.writeFileSync(path.join(root, '.render', `${item.id}-${mode}.svg`), makeSVG(item, mode));
}
for (const mode of ['frame', 'mask']) fs.writeFileSync(path.join(root, '.render', `${mode}.svg`), makeSVG(config.items[0], mode));
fs.writeFileSync(path.join(root, 'templates.json'), JSON.stringify(config, null, 2) + '\n');
fs.writeFileSync(path.join(root, 'templates-data.js'), `window.ONEBEAT_TEMPLATES = ${JSON.stringify(config)};\n`);
console.log(`Built ${config.items.length} editable SVG templates. Screen ${sw}×${sh} at (${sx},${sy}); exact 9:16=${sw * 16 === sh * 9}.`);
