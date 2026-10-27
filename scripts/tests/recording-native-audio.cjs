const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const root = path.resolve(__dirname, '../..');
const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'onebeat-recording-audio-'));
const compiler = process.env.CXX || (process.platform === 'darwin' ? 'clang++' : 'c++');

function run(command, args) {
  const result = spawnSync(command, args, {
    cwd: root, encoding: 'utf8', timeout: 30000, maxBuffer: 4 * 1024 * 1024
  });
  process.stdout.write(result.stdout ?? '');
  process.stderr.write(result.stderr ?? '');
  if (result.error || result.status !== 0) {
    throw new Error(`${command} failed: ${result.error?.message ?? `exit=${result.status}, signal=${result.signal}`}`);
  }
}

try {
  // Exercise the production C++ helpers too: ArkTS mocks cannot detect a DSP
  // regression in peak handling, PCM gain, or sample/timestamp conversion.
  for (const suite of ['recording-mic-level', 'recording-audio-math', 'recording-system-mic']) {
    const binary = path.join(temporary, suite);
    run(compiler, ['-std=c++17', '-O2', '-Wall', '-Wextra', '-Werror',
      path.join(__dirname, `${suite}.cpp`), '-o', binary]);
    run(binary, []);
  }
  console.log('PASS recording native audio: MIC level, accompaniment isolation and PCM timeline');
} catch (error) {
  console.error(`${error.message}\nA local C++17 compiler is required; set CXX to its executable path.`);
  process.exitCode = 1;
} finally {
  fs.rmSync(temporary, { recursive: true, force: true });
}
