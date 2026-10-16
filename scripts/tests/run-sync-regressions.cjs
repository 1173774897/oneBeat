// Run from any directory with Node; an optional argument selects typescript.js.
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const root = path.resolve(__dirname, '../..');
const suites = [
  'clock-sync-fit.cjs',
  'transport-start-readiness.cjs',
  'transport-start-diagnostics.cjs',
  'transport-restart-configuration-order.cjs',
  'metronome-count-in-realtime.cjs',
  'metronome-start-timing.cjs',
  'metronome-configuration.cjs',
  'metronome-start-buffer-diagnostics.cjs',
  'production-clock-diagnostics.cjs',
  'metronome-playback-baseline.cjs',
  'metronome-audio-lifecycle.cjs',
  'metronome-route-transition.cjs',
  'metronome-drum-preview-seek.cjs',
  'drum-subdivision-model.cjs',
  'drum-editor-preview.cjs',
  'drum-lobby-editor-settings.cjs',
  'drum-preview-session-ownership.cjs',
  'drum-preview-live-update.cjs',
  'latency-calibration-routing.cjs',
  'route-probe-playback.cjs',
  'time-card-calibration.cjs'
];

function resolveTypeScript() {
  if (process.argv[2]) {
    const explicit = path.resolve(process.argv[2]);
    if (!fs.existsSync(explicit)) throw new Error(`TypeScript not found: ${explicit}`);
    return explicit;
  }
  try { return require.resolve('typescript'); } catch {}
  const bundled = [
    path.resolve(path.dirname(process.execPath), '../../hvigor/hvigor/node_modules/typescript/lib/typescript.js'),
    '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js'
  ];
  const found = bundled.find(candidate => fs.existsSync(candidate));
  if (found) return found;
  throw new Error('Pass the path to typescript/lib/typescript.js as the first argument; no dependency is installed automatically.');
}

try {
  const typescript = resolveTypeScript();
  let passed = 0;
  for (const suite of suites) {
    const result = spawnSync(process.execPath, [path.join(__dirname, suite), typescript], {
      cwd: root, encoding: 'utf8', timeout: 60000, maxBuffer: 4 * 1024 * 1024
    });
    process.stdout.write(result.stdout ?? '');
    process.stderr.write(result.stderr ?? '');
    // A promise waiting on fake/native I/O can leave Node with no live handles
    // and exit 0 before assertions finish. Require the suite's final PASS too.
    if (result.error || result.status !== 0 || !/^PASS\b/m.test(result.stdout ?? '')) {
      throw new Error(`${suite} failed (${result.error?.message ?? `exit=${result.status}, signal=${result.signal ?? 'none'}`})`);
    }
    passed++;
  }
  console.log(`PASS sync regression gate: ${passed}/${suites.length} suites`);
} catch (error) {
  console.error(error.message);
  process.exitCode = 1;
}
