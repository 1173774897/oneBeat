const fs=require('node:fs');
const path=require('node:path');
const sharp=require('/Users/lizhe/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules/sharp');
const root=__dirname;
const themes=[['01','left','#ED8C79'],['02','right','#B2D9CC'],['03','top','#C8B8DF'],['04','right','#EBC786'],['05','left','#414C5A']];
(async()=>{
for(const[id,pose,accent]of themes){
const p=pose==='top'?{x:180,y:430,w:720,h:1450}:pose==='left'?{x:180,y:300,w:760,h:1520}:{x:140,y:300,w:760,h:1520};
const character=pose==='top'?'<ellipse cx="540" cy="300" rx="205" ry="195"/><path d="M220 550Q270 320 400 380L680 380Q820 320 860 550L780 800H300Z"/>':pose==='left'?'<ellipse cx="85" cy="1130" rx="200" ry="210"/><path d="M-100 1340Q130 1260 310 1480L420 1920H-100Z"/>':'<ellipse cx="995" cy="1130" rx="200" ry="210"/><path d="M1180 1340Q950 1260 770 1480L660 1920H1180Z"/>';
const hands=pose==='top'?'<rect x="210" y="405" width="135" height="112" rx="48"/><rect x="735" y="405" width="135" height="112" rx="48"/>':pose==='left'?'<rect x="155" y="1400" width="100" height="185" rx="43"/><path d="M240 1820Q400 1780 525 1812Q450 1900 280 1880Z"/>':'<rect x="825" y="1400" width="100" height="185" rx="43"/><path d="M555 1812Q680 1780 840 1820L800 1880Q630 1900 555 1812Z"/>';
const svg=`<svg xmlns="http://www.w3.org/2000/svg" width="1080" height="1920" viewBox="0 0 1080 1920"><rect width="1080" height="1920" fill="#F7F1E7"/><circle cx="${pose==='right'?100:980}" cy="1580" r="620" fill="${accent}"/><g fill="#A7A9A7" stroke="#747B7A" stroke-width="4">${character}</g><rect x="${p.x}" y="${p.y}" width="${p.w}" height="${p.h}" rx="78" fill="#202329"/><rect x="${p.x+17}" y="${p.y+17}" width="${p.w-34}" height="${p.h-34}" rx="62" fill="#FEFDF9"/><g fill="#A7A9A7" stroke="#747B7A" stroke-width="4">${hands}</g></svg>`;
fs.writeFileSync(path.join(root,`${id}-layout.svg`),svg);
await sharp(Buffer.from(svg)).png().toFile(path.join(root,`${id}-layout.png`));
}
})();
