// Product retirement must close every entry without resetting shared tap data.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { execFileSync } = require('node:child_process');

const root = path.resolve(__dirname, '../..');
// Freeze the current, device-verified HEAD so committing retirement does not
// turn the already retired version into its own pre-retirement comparison.
const BASELINE = '56c9e55';
const read = file => fs.readFileSync(path.join(root, file), 'utf8');
const baseline = file => execFileSync('git', ['show', `${BASELINE}:${file}`], {
  cwd: root, encoding: 'utf8'
});
const pagesPath = 'entry/src/main/resources/base/profile/main_pages.json';
const tapPath = 'entry/src/main/ets/pages/AudioCalibrationPage.ets';
const retiredPath = 'entry/src/main/ets/pages/MicLoopbackCalibrationPage.ets';
const micRoute = 'pages/MicLoopbackCalibrationPage';
const tapRoute = 'pages/AudioCalibrationPage';
const currentTapRoute = 'pages/TimeCardCalibrationPage';
const pages = JSON.parse(read(pagesPath)).src;

const expectedPages = JSON.parse(baseline(pagesPath)).src.filter(page => page !== micRoute);
expectedPages.splice(expectedPages.indexOf(tapRoute) + 1, 0, currentTapRoute);
assert.deepEqual(pages.filter(page => page !== 'pages/RecordingLibraryPage'), expectedPages,
  'Keep the registered comic tap page and retire only the mic page');
assert.ok(pages.includes(tapRoute), 'The previous verified tap page remains available in the source tree');
assert.ok(pages.includes(currentTapRoute), 'The promoted comic tap page must be registered');

const tap = read(tapPath);
assert.match(tap, /@Entry\s+@Component\s+struct AudioCalibrationPage\b/,
  'The tap measurement remains a product page');
assert.doesNotMatch(tap, /MicLoopbackCalibrationPage|openMicLoopbackCalibration|麦克风回环/,
  'The tap header must not expose a retired mic link');
const lobby = read('entry/src/main/ets/pages/LeaderLobbyPage.ets');
assert.match(lobby, /router\.pushUrl\(\{\s*url:\s*'pages\/TimeCardCalibrationPage'\s*\}\)/,
  'The confirmed lobby route opens the promoted comic tap page');
assert.match(lobby, /\.onClick\(\(\) => \{ void this\.confirmBluetoothCalibration\(\); \}\)/,
  'The existing confirmation action still reaches tap calibration');

for (const entry of fs.readdirSync(path.join(root, 'entry/src/main/ets/pages'), { withFileTypes: true })) {
  if (!entry.isFile() || !entry.name.endsWith('.ets') || entry.name === 'MicLoopbackCalibrationPage.ets') continue;
  assert.doesNotMatch(read(`entry/src/main/ets/pages/${entry.name}`), /MicLoopbackCalibrationPage/,
    `${entry.name} must not contain another route or import for the retired page`);
}
const retired = read(retiredPath);
assert.match(retired, /@Component\s+struct MicLoopbackCalibrationPage\b/,
  'Keep the investigation component available for reproducible tests');
assert.doesNotMatch(retired, /@Entry\b/,
  'The retained investigation source must not register a page entry');

const manifestPath = 'entry/src/main/module.json5';
const permissions = JSON.parse(read(manifestPath)).module.requestPermissions;
assert.deepEqual(permissions.filter(permission => permission.name !== 'ohos.permission.MICROPHONE'),
  JSON.parse(baseline(manifestPath)).module.requestPermissions
    .filter(permission => permission.name !== 'ohos.permission.MICROPHONE'),
  'Retired mic calibration must not change unrelated permission scopes');
const recordingMic = permissions.find(permission => permission.name === 'ohos.permission.MICROPHONE');
assert.equal(recordingMic?.reason, '$string:perm_recording_microphone_reason',
  'Microphone access belongs to explicit video recording, never the retired calibration page');
const stringsPath = 'entry/src/main/resources/base/element/string.json';
assert.deepEqual(JSON.parse(read(stringsPath)).string.filter(item => item.name !== 'perm_recording_microphone_reason'),
  JSON.parse(baseline(stringsPath)).string.filter(item => item.name !== 'perm_microphone_reason'),
  'Remove only the unused mic permission reason');

// Mic and tap previously wrote the same key without provenance. Any migration
// that guesses the source of a value could erase a device-verified tap result.
const persistencePath = 'entry/src/main/ets/store/AudioLatencyPersistence.ets';
assert.equal(read(persistencePath), baseline(persistencePath),
  'Retirement must preserve shared saved compensation and its restore/save behavior');

function businessSource(source) {
  const boundary = source.indexOf('  @Builder');
  assert.ok(boundary > 0, 'Tap business methods must precede UI builders');
  return source.slice(0, boundary);
}
const oldBusiness = businessSource(baseline(tapPath));
const retiredNavigation = /  private openMicLoopbackCalibration\(\): void \{\n    void router\.pushUrl\(\{ url: 'pages\/MicLoopbackCalibrationPage' \}\);\n  \}\n\n/;
assert.match(oldBusiness, retiredNavigation, 'The baseline contains exactly the navigation being retired');
assert.equal(businessSource(tap), oldBusiness.replace(retiredNavigation, ''),
  'Tap measurement, preview, saving and lifecycle must match HEAD after removing the retired navigation');

console.log('PASS: mic calibration routes retired; recording has its own microphone purpose; comic tap entry active, previous tap logic and shared saved data preserved');
