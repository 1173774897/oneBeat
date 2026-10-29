const fs = require('node:fs');
const path = require('node:path');
const root = path.resolve(__dirname, '../../..');
const sources = {
  'wordmark.png': 'entry/src/main/resources/rawfile/comic/brand/onebeat_wordmark.png',
  'app-icon.png': 'AppScope/resources/base/media/app_icon.png',
  'team-device.jpeg': 'designs/team-entry/2026-10-20/home-style-v2/halftone-device-checks/pura-pro-entry.jpeg',
  'walk-recording-device.jpeg': 'designs/drum-multi-style/2026-10-21/extensions-lobby-march/references/walk-current-ui.jpeg',
  'drum-device.jpeg': 'designs/store-portraits/2026-10-20/device-checks/x-drum-stopped.jpeg',
  'saved-device.png': 'designs/recording-share/saved-page-options-2026-10-19/B-implemented-device.png',
  'wave.png': 'entry/src/main/resources/rawfile/comic/poses/wave.png',
  'mismatch.png': 'entry/src/main/resources/rawfile/comic/poses/mismatch.png',
  'cloud.png': 'entry/src/main/resources/rawfile/comic/poses/cloud.png',
  'lamp.png': 'entry/src/main/resources/rawfile/comic/poses/lamp.png',
  'teapot.png': 'entry/src/main/resources/rawfile/comic/poses/teapot.png',
  'scooter.png': 'entry/src/main/resources/rawfile/comic/poses/scooter.png',
  'lilroll.png': 'entry/src/main/resources/rawfile/comic/poses/lilroll.png',
  'sunset-sky.png': 'entry/src/main/resources/rawfile/scenes/sunset/sunset_sky.png',
  'sunset-clouds.png': 'entry/src/main/resources/rawfile/scenes/sunset/sunset_clouds.png',
  'sunset-sun.png': 'entry/src/main/resources/rawfile/scenes/sunset/sunset_sun.png',
  'sunset-ocean.png': 'entry/src/main/resources/rawfile/scenes/sunset/sunset_ocean.png',
  'sunset-road.png': 'entry/src/main/resources/rawfile/scenes/sunset/sunset_road.png',
  'neon-sky.png': 'entry/src/main/resources/rawfile/scenes/neon/neon_sky.png',
  'neon-blocks.png': 'entry/src/main/resources/rawfile/scenes/neon/neon_street_blocks.png',
  'neon-road.png': 'entry/src/main/resources/rawfile/scenes/neon/neon_road.png',
};
for (const [name, src] of Object.entries(sources)) fs.copyFileSync(path.join(root, src), path.join(__dirname, 'assets', name));
fs.writeFileSync(path.join(__dirname, 'asset-sources.json'), JSON.stringify(sources, null, 2) + '\n');
