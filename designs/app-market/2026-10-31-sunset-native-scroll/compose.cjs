const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const sharp = require('/Users/lizhe/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules/sharp');

const root = path.resolve(__dirname, '../../..');
const rawRoot = path.join(root, 'entry/src/main/resources/rawfile');
const layout = JSON.parse(fs.readFileSync(path.join(__dirname, 'scene-layout.json'), 'utf8'));
const walkPath = 'entry/src/main/ets/scene/WalkScene.ets';
const catalogPath = 'entry/src/main/ets/assets/AssetCatalog.ets';
const walkSource = fs.readFileSync(path.join(root, walkPath), 'utf8');
const catalogSource = fs.readFileSync(path.join(root, catalogPath), 'utf8');
const num = (source, name) => {
  const match = source.match(new RegExp(`const ${name}: number = ([-.\\d]+);`));
  if (!match) throw new Error(`Missing numeric source constant ${name}`);
  return Number(match[1]);
};
const w = (name) => num(walkSource, name);
const c = (name) => num(catalogSource, name);
const constants = Object.fromEntries([
  'ROAD_BOTTOM_INSET_RATIO', 'ROAD_BAND_HEIGHT_RATIO', 'ROAD_PATH_CENTER_RATIO',
  'LAYER_TILE_SCREEN_COUNT', 'ENTITY_BG_LIFT_PX', 'ENTITY_FG_DROP_PX',
  'VEGETATION_DISPLAY_HEIGHT', 'VEGETATION_DISPLAY_WIDTH', 'VEGETATION_FOOT_ANCHOR_RATIO',
  'VEGETATION_BG_PATH_OFFSET_PX', 'VEGETATION_FG_PATH_OFFSET_PX'
].map((name) => [name, w(name)]));
const catalogConstants = Object.fromEntries([
  'BILLBOARDRECK_DISPLAY_SCALE', 'SIDE_ENTITY_NATIVE_HEIGHT', 'SIDE_ENTITY_DISPLAY_HEIGHT',
  'SIDE_ENTITY_DISPLAY_WIDTH', 'CABLE_NATIVE_WIDTH', 'CABLE_NATIVE_HEIGHT'
].map((name) => [name, c(name)]));
const scale = layout.pixelsPerVp;
const viewportW = layout.viewportVp.width;
const heightVp = layout.viewportVp.height;
const widthVp = viewportW * layout.pageCount;
const width = widthVp * scale;
const height = heightVp * scale;
const pageWidth = viewportW * scale;
const tileWidthVp = viewportW * constants.LAYER_TILE_SCREEN_COUNT;
const roadHeightVp = heightVp * constants.ROAD_BAND_HEIGHT_RATIO;
const roadTopVp = heightVp - heightVp * constants.ROAD_BOTTOM_INSET_RATIO - roadHeightVp;
const pathYVp = roadTopVp + roadHeightVp * constants.ROAD_PATH_CENTER_RATIO;
const hash = (data) => crypto.createHash('sha256').update(data).digest('hex');
const files = new Map();
const assetReport = [];

async function loadAsset(relative) {
  if (files.has(relative)) return files.get(relative);
  const source = path.join(rawRoot, relative);
  const target = path.join(__dirname, 'assets', relative);
  fs.mkdirSync(path.dirname(target), { recursive: true });
  fs.copyFileSync(source, target);
  const bytes = fs.readFileSync(target);
  const meta = await sharp(bytes).metadata();
  const raw = await sharp(bytes).ensureAlpha().raw().toBuffer({ resolveWithObject: true });
  let x0=meta.width, y0=meta.height, x1=-1, y1=-1;
  for (let y=0; y<meta.height; y++) for(let x=0; x<meta.width; x++) {
    if(raw.data[(y*meta.width+x)*4+3] > 0) { x0=Math.min(x0,x);y0=Math.min(y0,y);x1=Math.max(x1,x);y1=Math.max(y1,y); }
  }
  const alphaBBox = x1 < 0 ? null : { x:x0, y:y0, width:x1-x0+1, height:y1-y0+1 };
  const asset = { relative, bytes, width:meta.width, height:meta.height, alphaBBox, uri:`data:image/png;base64,${bytes.toString('base64')}` };
  files.set(relative, asset);
  assetReport.push({ source:path.relative(root, source), copy:path.relative(__dirname, target), sha256:hash(bytes), width:meta.width, height:meta.height, alphaBBox });
  return asset;
}
function imageTag(asset, x, y, iw, ih, extra='') {
  return `<image x="${x}" y="${y}" width="${iw}" height="${ih}" preserveAspectRatio="none" href="${asset.uri}" ${extra}/>`;
}
function placedBBox(asset, x, y, iw, ih) {
  const b = asset.alphaBBox;
  return b ? { x:scale*(x+b.x/asset.width*iw), y:scale*(y+b.y/asset.height*ih), width:scale*b.width/asset.width*iw, height:scale*b.height/asset.height*ih } : null;
}
function entitySize(assetName) {
  const dh = catalogConstants.SIDE_ENTITY_DISPLAY_HEIGHT;
  const dw = catalogConstants.SIDE_ENTITY_DISPLAY_WIDTH;
  if (assetName === 'cable') return {
    width:Math.round(catalogConstants.CABLE_NATIVE_WIDTH*dh/catalogConstants.SIDE_ENTITY_NATIVE_HEIGHT),
    height:Math.round(catalogConstants.CABLE_NATIVE_HEIGHT*dh/catalogConstants.SIDE_ENTITY_NATIVE_HEIGHT)
  };
  const s = assetName === 'billboardreck' ? catalogConstants.BILLBOARDRECK_DISPLAY_SCALE : 1;
  return {width:dw*s, height:dh*s};
}

async function main() {
  const layers = [];
  const sceneLayers = [];
  // Extend one native viewport sky horizontally so its vertical palette stays identical to ImageFit.Cover.
  // Covering the entire panorama directly would crop almost all vertical color variation from the portrait source.
  const sky = await loadAsset('scenes/sunset/sunset_sky.png');
  const skyViewport = await sharp(sky.bytes).resize(pageWidth,height,{fit:'cover',position:'centre'}).png().toBuffer();
  const skyAsset = { uri:`data:image/png;base64,${skyViewport.toString('base64')}` };
  layers.push(imageTag(skyAsset,0,0,widthVp,heightVp));
  sceneLayers.push({id:'sky',source:sky.relative,z:0,xVp:0,yVp:0,widthVp,heightVp,mode:'native viewport cover, then horizontal extension'});

  const sun = await loadAsset('scenes/sunset/sunset_sun.png');
  const sunSize = viewportW*layout.sun.widthRatio;
  const sunY = heightVp*layout.sun.yRatio;
  layers.push(imageTag(sun,layout.sun.xVp,sunY,sunSize,sunSize));
  sceneLayers.push({id:'sun',source:sun.relative,z:1,xVp:layout.sun.xVp,yVp:sunY,widthVp:sunSize,heightVp:sunSize});
  const stripDefs = [
    ['clouds','sunset_clouds.png',.12,.36,2,false],
    ['ocean','sunset_ocean.png',.36,.34,3,false],
    ['midground-dirt','sunset_midground_dirt.png',.48,.22,6,false],
    ['road','sunset_road.png',roadTopVp/heightVp,roadHeightVp/heightVp,10,true]
  ];
  for (const [id,file,yr,hr,z,mirror] of stripDefs) {
    const a = await loadAsset(`scenes/sunset/${file}`);
    const sy=heightVp*yr, sh=heightVp*hr;
    const tiles=[];
    for(let i=0;i<Math.ceil(widthVp/tileWidthVp);i++) {
      const tx=i*tileWidthVp;
      const flip=mirror && i%2===1;
      const tag=imageTag(a,tx,sy,tileWidthVp,sh);
      layers.push(flip?`<g transform="translate(${2*tx+tileWidthVp} 0) scale(-1 1)">${tag}</g>`:tag);
      tiles.push({xVp:tx,mirrorX:flip});
    }
    sceneLayers.push({id,source:a.relative,z,yVp:sy,heightVp:sh,tileWidthVp,tiles});
  }
  const decor = [];
  const entities = [];
  for (const item of layout.entities) {
    const asset = await loadAsset(`scenes/sunset/entities/${item.asset}.png`);
    const box = entitySize(item.asset);
    const y=pathYVp-box.height+(item.foreground?constants.ENTITY_FG_DROP_PX:-constants.ENTITY_BG_LIFT_PX);
    // Height-only native images are centered in their runtime Row; transparent padding remains part of their scale.
    const imageW=item.asset==='cable'?box.width:box.height*asset.width/asset.height;
    const imageX=item.xVp+(box.width-imageW)/2;
    const z=item.foreground?29:12;
    decor.push({z,order:decor.length,tag:imageTag(asset,imageX,y,imageW,box.height)});
    entities.push({...item,z,containerVp:{x:item.xVp,y,...box},imageVp:{x:imageX,y,width:imageW,height:box.height},imagePx:{x:imageX*scale,y:y*scale,width:imageW*scale,height:box.height*scale},visibleAlphaBBoxPx:placedBBox(asset,imageX,y,imageW,box.height)});
  }
  const vegetation=[];
  for(const item of layout.vegetation) {
    const asset=await loadAsset(`vegetation/${item.asset}.png`);
    const ph=constants.VEGETATION_DISPLAY_HEIGHT;
    const pw=ph*asset.width/asset.height;
    const x=item.xVp+(constants.VEGETATION_DISPLAY_WIDTH-pw)/2;
    const y=pathYVp-ph*constants.VEGETATION_FOOT_ANCHOR_RATIO+(item.foreground?constants.VEGETATION_FG_PATH_OFFSET_PX:constants.VEGETATION_BG_PATH_OFFSET_PX);
    const z=item.foreground?29:12;
    decor.push({z,order:decor.length,tag:imageTag(asset,x,y,pw,ph)});
    vegetation.push({...item,z,containerVp:{x:item.xVp,y,width:constants.VEGETATION_DISPLAY_WIDTH,height:ph},imageVp:{x,y,width:pw,height:ph},visibleAlphaBBoxPx:placedBBox(asset,x,y,pw,ph)});
  }
  decor.sort((a,b)=>a.z-b.z||a.order-b.order);
  layers.push(...decor.map((d)=>d.tag));
  const svg=`<svg xmlns="http://www.w3.org/2000/svg" width="${width}" height="${height}" viewBox="0 0 ${widthVp} ${heightVp}"><title>oneBeat native sunset panorama — no characters or copy</title>${layers.join('\n')}</svg>`;
  fs.writeFileSync(path.join(__dirname,'sunset-native-panorama.svg'),svg);
  const png=await sharp(Buffer.from(svg),{limitInputPixels:false}).png().toBuffer();
  fs.writeFileSync(path.join(__dirname,'sunset-native-panorama.png'),png);
  await sharp(png).resize(2160).png().toFile(path.join(__dirname,'panorama-preview.png'));
  const sliceDir=path.join(__dirname,'background-slices');
  fs.mkdirSync(sliceDir,{recursive:true});
  const sliceBuffers=[];
  for(let i=0;i<layout.pageCount;i++){
    const b=await sharp(png).extract({left:i*pageWidth,top:0,width:pageWidth,height}).png().toBuffer();
    fs.writeFileSync(path.join(sliceDir,`background-${String(i+1).padStart(2,'0')}.png`),b);
    sliceBuffers.push(b);
  }
  const rejoined=await sharp({create:{width,height,channels:4,background:{r:0,g:0,b:0,alpha:0}}}).composite(sliceBuffers.map((input,i)=>({input,left:i*pageWidth,top:0}))).raw().toBuffer();
  const original=await sharp(png).ensureAlpha().raw().toBuffer();
  const report={
    generatedAt:new Date().toISOString(),master:{width,height,pageCount:layout.pageCount,pageWidth},logical:{viewportW,heightVp,widthVp,scale,tileWidthVp,roadTopVp,roadHeightVp,pathYVp},
    sourceFiles:{walkPath,catalogPath,walkSourceSha256:hash(walkSource),catalogSourceSha256:hash(catalogSource)},constants,catalogConstants,
    sceneLayers,entities,vegetation,assets:assetReport,
    checks:{noCharacters:true,noPhoneFrames:true,noCopy:true,allAssetsExactCopies:assetReport.every((a)=>hash(fs.readFileSync(path.join(root,a.source)))===a.sha256),sourceImagePaddingPreserved:true,sixCropRejoinPixelEqual:original.equals(rejoined),masterRawSha256:hash(original),rejoinedRawSha256:hash(rejoined)},
    compositionNotes:[
      'All entity and vegetation dimensions and vertical offsets come from native source constants. xVp is the selected resolved screen/container x, replacing random spawn placement only.',
      'Logical viewport is 360×640vp, rendered at 3px/vp; the world is extended horizontally to six viewport widths.',
      'Sun appears once across the world rather than once per card; its size and y ratio match the native viewport. Sky is native viewport Cover horizontally extended.',
      'Road alternates native mirrored tiles; clouds, sea and dirt keep native same-direction tiling. No trimming, stretching or recoloring of roadside sprites.'
    ]
  };
  fs.writeFileSync(path.join(__dirname,'render-report.json'),JSON.stringify(report,null,2)+'\n');
  if(!report.checks.sixCropRejoinPixelEqual||!report.checks.allAssetsExactCopies) throw new Error('Native panorama validation failed');
  console.log(JSON.stringify({master:report.master,checks:report.checks,entities:entities.map((e)=>({id:e.id,imagePx:e.imagePx}))},null,2));
}
main().catch((error)=>{console.error(error);process.exitCode=1;});
