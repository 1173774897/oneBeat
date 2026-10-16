// Run alongside run-sync-regressions.cjs; native UI and services are mocked.
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const root = path.resolve(__dirname, '../..');
const typescript = process.argv[2] ??
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js';
const suites = ['user-feedback.cjs', 'editable-bpm-feedback.cjs', 'store-user-feedback.cjs',
  'member-join-session-reset.cjs', 'route-probe-dialog.cjs', 'session-reset-lifecycle.cjs'];
try {
  if (!fs.existsSync(typescript)) throw new Error('Pass the path to typescript/lib/typescript.js as the first argument.');
  for (const suite of suites) {
    const result = spawnSync(process.execPath, [path.join(__dirname, suite), typescript], {
      cwd: root, encoding: 'utf8', timeout: 60000, maxBuffer: 4 * 1024 * 1024
    });
    process.stdout.write(result.stdout ?? '');
    process.stderr.write(result.stderr ?? '');
    if (result.error || result.status !== 0 || !/^PASS\b/m.test(result.stdout ?? '')) {
      throw new Error(`${suite} failed (${result.error?.message ?? `exit=${result.status}`})`);
    }
  }
  console.log(`PASS notice regression gate: ${suites.length}/${suites.length} suites`);
} catch (error) {
  console.error(error.message);
  process.exitCode = 1;
}
