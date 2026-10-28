// Current-fix verification entry; the 2026-10-27 defect observations remain immutable.
// Run with Node and an explicit typescript/lib/typescript.js path as argv[2].
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { spawnSync } = require('node:child_process');
const root = path.resolve(__dirname, '../..');
const compiler = process.argv[2];
assert.ok(compiler && fs.existsSync(compiler), 'Pass the installed TypeScript compiler path');
const sources = [
  'entry/src/main/ets/sync/ClockSync.ets',
  'entry/src/main/ets/session/SessionController.ets',
  'entry/src/main/ets/audio/MetronomeEngine.ets',
  'entry/src/main/ets/app/AppSession.ets',
  'entry/src/main/ets/audio/TeamAcousticProbe.ets'
];
const checks = [];
for (const suite of ['clock-sync-readiness.cjs', 'metronome-shared-clock.cjs', 'metronome-phase-feedback.cjs', 'metronome-phase-drift.cjs']) {
  const result = spawnSync(process.execPath, [path.join(__dirname, suite), path.resolve(compiler)],
    { cwd: root, encoding: 'utf8', timeout: 60000 });
  const passed = !result.error && result.status === 0 && /^PASS /m.test(result.stdout || '');
  checks.push({ suite, passed, output: ((result.stdout || '') + (result.stderr || '')).trim() });
  console.log(checks[checks.length - 1].output);
}
const result = {
  generatedAt: new Date().toISOString(),
  historicalBaseline: 'docs/design/clock-sync-accuracy-probe-results.json',
  sourceSha256: Object.fromEntries(sources.map(file => [file,
    crypto.createHash('sha256').update(fs.readFileSync(path.join(root, file))).digest('hex')])),
  checks,
  clockAdmissionEnabled: true,
  phaseCorrectionEnabledByDefault: true,
  hardwareAcousticValidation: 'not performed by this software regression command',
  scope: 'Deterministic execution of production clock, strict READY and PCM feedback methods with simulated native clocks. No acoustic accuracy certification.'
};
fs.writeFileSync(path.join(root, 'docs/design/clock-sync-fix-validation-results.json'), JSON.stringify(result, null, 2) + '\n');
assert.ok(checks.every(check => check.passed), 'At least one current-fix regression failed');
console.log('PASS current clock/audio fixes; historical baseline preserved; quantitative acoustic validation remains separate');
