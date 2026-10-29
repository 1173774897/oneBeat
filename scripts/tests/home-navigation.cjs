// router.back({ url }) silently does nothing when that URL is no longer on the
// stack (a remote disband clears it). Leaving the team must still reach Index.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const ts = require(process.argv[2]);

function load(stack) {
  const calls = [];
  const router = {
    getStateByUrl: url => stack.filter(entry => entry === url).map(name => ({ name })),
    back: options => calls.push(`back:${options.url}`),
    clear: () => calls.push('clear'),
    replaceUrl: async options => calls.push(`replace:${options.url}`)
  };
  const context = { exports: {}, require: name => { assert.equal(name, '@kit.ArkUI'); return { router }; } };
  vm.runInNewContext(ts.transpileModule(fs.readFileSync('entry/src/main/ets/app/HomeNavigation.ets', 'utf8'),
    { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 } }).outputText, context);
  return { navigateToHome: context.exports.navigateToHome, calls };
}

(async () => {
  const normal = load(['pages/Index', 'pages/TeamPage', 'pages/LeaderLobbyPage']);
  await normal.navigateToHome();
  assert.deepEqual(normal.calls, ['back:pages/Index'], 'Index on the stack is popped to');

  const afterDisband = load(['pages/TeamPage', 'pages/LeaderLobbyPage']);
  await afterDisband.navigateToHome();
  assert.deepEqual(afterDisband.calls, ['clear', 'replace:pages/Index'],
    'Without Index on the stack (remote disband cleared it) home is rebuilt instead of a silent no-op back');
  console.log('PASS home navigation: pops to Index when stacked, rebuilds it after a cleared stack');
})().catch(error => { console.error(error); process.exitCode = 1; });
